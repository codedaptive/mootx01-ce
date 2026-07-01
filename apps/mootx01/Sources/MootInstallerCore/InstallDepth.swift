// InstallDepth.swift
//
// Integration-depth feature (PLUGIN_PACKAGING_SPEC_v0.1 §4.4). Three depths,
// applied globally to every selected client:
//
//   server  — Mode 1: MCP wiring only (the shipping behaviour). No skills.
//   skills  — Mode 2: server + write the canonical SKILL.md into the client's
//             real skills dir (install-map skillUserPath, ~ expanded).
//   plugin  — Mode 3: server + install the host's pre-generated native package
//             into its local plugin dir; falls back to skills (and REPORTS the
//             fallback) where no plugin format exists (the §4.4 ceiling table).
//
// The depth is a TARGET: each client gets the most it supports, with any
// fallback reported. This vertical is the Apple installer; the Rust vertical
// (apps/mootx01/rust/src/commands/install.rs) implements the identical
// behaviour independently. No FFI — both read the embedded install bundle.
//
// The installer consumes pre-generated elements; it NEVER generates them
// (spec §4 / Decision 3). The packages and skill it places are byte-sourced
// from tools/moot-packager and embedded by EmbeddedArtifacts.

import Foundation

/// The integration depth requested for an install run.
public enum InstallDepth: String, Sendable, CaseIterable {
    case server
    case skills
    case plugin

    /// Default depth (§4.4: Full Plugin). Hitting Enter at the prompt and the
    /// `--yes` silent default both resolve here.
    public static let `default`: InstallDepth = .plugin

    /// Parse the `--mode` flag value. Returns nil for an unrecognised value so
    /// the caller can surface a usage error.
    public init?(modeFlag: String) {
        switch modeFlag.lowercased() {
        case "server": self = .server
        case "skills": self = .skills
        case "plugin": self = .plugin
        default: return nil
        }
    }
}

/// The achievable outcome for one client at the requested depth — what the
/// installer actually did, after applying the per-host ceiling.
public enum DepthOutcome: Equatable, Sendable {
    /// Server only (Mode 1): no skill payload exists for this client, or depth
    /// was `.server`.
    case server
    /// Skills (Mode 2): the canonical SKILL.md was written under `path`.
    case skills(path: String)
    /// Plugin (Mode 3): the native package was installed at `path`.
    case plugin(path: String)
    /// Plugin requested but this host has no plugin format — fell back to
    /// skills at `path`. `reason` is the ceiling note for reporting.
    case pluginFellBackToSkills(path: String, reason: String)
}

/// One host's row from the embedded install-map (schemaVersion 1).
public struct InstallMapHost: Sendable, Equatable, Codable {
    public let id: String
    public let displayName: String
    public let family: String
    public let mcpMapKey: String
    public let mcpUserFormat: String
    public let mcpUserPath: String
    public let roadmap: String
    public let skillUserPath: String

    /// Mode-3 capable when the host is a Family-A manifest bundle. The
    /// module-code (Cline, Hermes, opencode) and ide-config (Xcode) families
    /// have no drop-in plugin format today and ceil at Mode 2 (§4.4 table).
    public var supportsPlugin: Bool { family == "manifestBundle" }

    /// The ceiling note printed when a plugin target falls back to skills.
    public var fallbackReason: String {
        switch family {
        case "moduleCode": return "no drop-in plugin format (module-host shim is out of scope)"
        case "ideConfig":  return "config-route only; full plug-in is roadmap 1.1"
        default:           return "no plugin format on this host"
        }
    }
}

/// The decoded embedded install bundle: the canonical skill, the host map, and
/// the pre-generated package trees keyed by host-rooted relative path.
public struct InstallBundle: Sendable {
    public let skillMarkdown: String
    public let hosts: [String: InstallMapHost]
    /// Package files keyed by `"<host>/<relpath>"` → file contents.
    public let packages: [String: String]

    private struct Wire: Codable {
        struct Map: Codable { let hosts: [InstallMapHost] }
        let schemaVersion: Int
        let skillMarkdown: String
        let installMap: Map
        let packages: [String: String]
    }

    /// Decode the embedded `install-bundle.json`. Throws on malformed embedded
    /// data — that is a build-time defect (the artifact is committed), so a
    /// hard failure is correct.
    public init(json: String) throws {
        let wire = try JSONDecoder().decode(Wire.self, from: Data(json.utf8))
        self.skillMarkdown = wire.skillMarkdown
        var map: [String: InstallMapHost] = [:]
        for h in wire.installMap.hosts { map[h.id] = h }
        self.hosts = map
        self.packages = wire.packages
    }

    /// The embedded bundle, parsed once.
    public static let embedded: InstallBundle = {
        do {
            return try InstallBundle(json: EmbeddedArtifacts.installBundleJSON)
        } catch {
            // The artifact is committed and generated; a parse failure here is a
            // build defect, surfaced loudly rather than silently degrading.
            fatalError("embedded install-bundle.json failed to parse: \(error)")
        }
    }()

    /// The install-map host for an installer client id, or nil when the client
    /// carries no skill/plugin payload (claude-desktop, continue, kiro are
    /// MCP-only — they have no SKILL.md destination in the matrix).
    ///
    /// Installer client ids and install-map host ids are identical where both
    /// exist (claude-code, cursor, codex, gemini-cli, antigravity, cline,
    /// hermes, opencode), so the mapping is a direct lookup.
    public func host(forClientID id: String) -> InstallMapHost? {
        hosts[id]
    }

    /// The package files for a host, keyed by host-relative path
    /// (e.g. ".mcp.json", "skills/mootx01-memory/SKILL.md").
    public func packageFiles(forHostID id: String) -> [String: String] {
        let prefix = id + "/"
        var out: [String: String] = [:]
        for (key, contents) in packages where key.hasPrefix(prefix) {
            out[String(key.dropFirst(prefix.count))] = contents
        }
        return out
    }
}

/// Resolves and applies install depth per client. Filesystem writes go through
/// the same back-up-first discipline as the MCP merge.
public enum DepthInstaller {

    /// Expand a leading `~` in an install-map path against `homeDirectory`.
    /// install-map skillUserPaths are user-scope `~/…` paths.
    public static func expandTilde(_ path: String, homeDirectory: URL) -> URL {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    /// Apply the requested depth to one client. `server` is a no-op here (the
    /// MCP wiring already happened in the caller's Mode-1 path); `skills` and
    /// `plugin` add the skill/package payload. Backs up any existing file first
    /// (§4.2 discipline). Returns what was actually achieved.
    ///
    /// - Parameters:
    ///   - clientID: the installer client id (e.g. "claude-code").
    ///   - depth: the requested global depth.
    ///   - homeDirectory: user's home (for ~ expansion).
    ///   - binaryPath: absolute path of the placed binary, rewritten into MCP configs.
    ///   - vaultOff: when `true`, `MOOTX01_VAULT=0` is injected into the env
    ///     block of every MCP server entry written by the plugin installer so
    ///     plugin-spawned stdio servers inherit the correct vault posture.
    ///     Defaults to `false` (vault-on); absent `MOOTX01_VAULT` means
    ///     vault-on per ADR-015 §1.
    /// - Returns: the achieved `DepthOutcome`.
    /// - Throws: filesystem errors writing the skill file or package tree.
    @discardableResult
    public static func apply(
        clientID: String,
        depth: InstallDepth,
        homeDirectory: URL,
        binaryPath: String,
        vaultOff: Bool = false
    ) throws -> DepthOutcome {
        if depth == .server { return .server }

        // No matrix row → MCP-only client (claude-desktop, continue, kiro).
        guard let host = InstallBundle.embedded.host(forClientID: clientID) else {
            return .server
        }

        switch depth {
        case .server:
            return .server
        case .skills:
            return try writeSkill(host: host, homeDirectory: homeDirectory)
        case .plugin:
            if host.supportsPlugin {
                return try installPlugin(
                    host: host,
                    homeDirectory: homeDirectory,
                    binaryPath: binaryPath,
                    vaultOff: vaultOff
                )
            }
            // Ceiling: fall back to skills and report it (§4.4).
            let outcome = try writeSkill(host: host, homeDirectory: homeDirectory)
            if case let .skills(path) = outcome {
                return .pluginFellBackToSkills(path: path, reason: host.fallbackReason)
            }
            return outcome
        }
    }

    /// Mode 2: write the embedded canonical SKILL.md to the host's skillUserPath.
    private static func writeSkill(host: InstallMapHost, homeDirectory: URL) throws -> DepthOutcome {
        let dest = expandTilde(host.skillUserPath, homeDirectory: homeDirectory)
        let dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // §4.2: back up any existing skill file before overwriting.
        try Installer.backupExisting(at: dest)
        try InstallBundle.embedded.skillMarkdown
            .write(to: dest, atomically: true, encoding: .utf8)
        return .skills(path: dest.path)
    }

    /// Mode 3: materialise the host's pre-generated package tree from the
    /// embedded bundle into the host's plugin root (the parent of the skill's
    /// `skills/` dir). The package's own SKILL.md is byte-identical to Mode 2's.
    ///
    /// When `vaultOff` is true, every MCP config JSON file in the package that
    /// declares a `mcpServers.mootx01` entry has `env.MOOTX01_VAULT=0` injected
    /// after the binary-path rewrite. Skills files and plugin-metadata files
    /// (plugin.json without an mcpServers block) are written verbatim.
    private static func installPlugin(
        host: InstallMapHost,
        homeDirectory: URL,
        binaryPath: String,
        vaultOff: Bool
    ) throws -> DepthOutcome {
        let files = InstallBundle.embedded.packageFiles(forHostID: host.id)
        guard !files.isEmpty else {
            // No embedded package for this host — fall back to skills.
            let outcome = try writeSkill(host: host, homeDirectory: homeDirectory)
            if case let .skills(path) = outcome {
                return .pluginFellBackToSkills(path: path, reason: "no embedded package for host; wrote skill only")
            }
            return outcome
        }
        // Host plugin root: parent of the skill's `skills/` dir. For
        // ~/.claude/skills/mootx01-memory/SKILL.md that is ~/.claude.
        let skillDest = expandTilde(host.skillUserPath, homeDirectory: homeDirectory)
        let pluginRoot = skillDest
            .deletingLastPathComponent()  // mootx01-memory/
            .deletingLastPathComponent()  // skills/
            .deletingLastPathComponent()  // host plugin root
        let dest = pluginRoot.appendingPathComponent("mootx01-plugin", isDirectory: true)
        // §4.2: back up an existing plugin dir, then replace it.
        if FileManager.default.fileExists(atPath: dest.path) {
            try Installer.backupExisting(at: dest)
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for (rel, contents) in files {
            let fileURL = dest.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 1. Rewrite bare "mootx01" command placeholder to the installed path.
            // 2. When vault-off, inject MOOTX01_VAULT=0 so the plugin-spawned
            //    stdio server inherits the correct vault posture (sec-fix 6b08d56b).
            var safeContents = rewriteBareMootCommand(in: contents, binaryPath: binaryPath)
            if vaultOff {
                safeContents = injectVaultEnv(in: safeContents, rel: rel)
            }
            try safeContents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return .plugin(path: dest.path)
    }

    /// Inject `env.MOOTX01_VAULT=0` into the `mcpServers.mootx01` entry of an
    /// MCP config JSON file. Only operates on `.json` files whose content
    /// declares an `mcpServers` block — plugin-metadata files (author/description
    /// only) and non-JSON files (SKILL.md, YAML) are returned unchanged.
    ///
    /// On parse failure or re-serialisation failure the original content is
    /// returned so the host tool can surface the error rather than silently
    /// dropping the file.
    private static func injectVaultEnv(in contents: String, rel: String) -> String {
        // Fast-path: non-JSON files and JSON files without a server declaration.
        guard rel.hasSuffix(".json"), contents.contains("\"mcpServers\"") else { return contents }
        guard let data = contents.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any],
              var server = servers["mootx01"] as? [String: Any]
        else { return contents }

        // Merge MOOTX01_VAULT=0 into the existing env block or create a new one.
        var env = server["env"] as? [String: Any] ?? [:]
        env["MOOTX01_VAULT"] = "0"
        server["env"] = env
        servers["mootx01"] = server
        root["mcpServers"] = servers

        guard let patched = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        ), let str = String(data: patched, encoding: .utf8) else { return contents }
        return str.hasSuffix("\n") ? str : str + "\n"
    }

    /// Embedded plugin package MCP configs are generated with a portable bare
    /// executable name. Rewrite that placeholder at install time so plugin
    /// launches use the same absolute binary path as the normal MCP config.
    private static func rewriteBareMootCommand(in contents: String, binaryPath: String) -> String {
        let escapedBinaryPath = jsonEscapedString(binaryPath)
        return contents
            .replacingOccurrences(of: "\"command\" : \"mootx01\"", with: "\"command\" : \"\(escapedBinaryPath)\"")
            .replacingOccurrences(of: "\"command\": \"mootx01\"", with: "\"command\": \"\(escapedBinaryPath)\"")
    }

    private static func jsonEscapedString(_ value: String) -> String {
        // Use .withoutEscapingSlashes so paths like /usr/local/bin/mootx01 are
        // written verbatim in the rewritten MCP config. Forward slashes are legal
        // unescaped in JSON (RFC 8259 §7); escaping them as \/ adds noise without
        // benefit and breaks string-search assertions in both tests and shell scripts.
        // .withoutEscapingSlashes is available on macOS 13+ (target is macOS 15+).
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2
        else {
            return value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        return String(encoded.dropFirst().dropLast())
    }
}
