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
// from tools/moot-packager and embedded by EmbeddedArtifactsV2.

import Foundation
import AriaMCP

/// The install bundle must describe the same public ARIA release as the
/// executable that consumes it. The version comes from AriaMCP's public
/// envelope authority (AriaV2Envelope.surfaceVersion = "v2").
private enum SelectedARIARelease {
    static let version: String = AriaV2Envelope.surfaceVersion
}

public enum InstallBundleError: Error, Equatable {
    case ariaReleaseMismatch(bundle: String, executable: String)
    case missingAriaBundleIdentity(version: String)
}
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Abstraction over invoking the `claude` CLI (plugin-owned MCP connections:
/// "stranded cache"). Real callers use `ProcessClaudeCLIRunner`, which shells
/// out to `claude` resolved from PATH; tests inject a fake so the refresh
/// path is unit-testable without touching a real Claude Code installation.
/// Absence of the CLI on PATH and a nonzero exit both surface as `false` —
/// the caller never fails the install over this, only prints a fallback
/// instruction.
public protocol ClaudeCLIRunning: Sendable {
    /// Runs `claude <arguments>`. Returns `true` on a clean (exit 0) run,
    /// `false` if `claude` is absent from PATH or exits nonzero.
    func run(arguments: [String]) -> Bool
}

/// Default runner: shells out to `claude` resolved via `/usr/bin/env`
/// (Foundation's `Process.executableURL` requires an absolute path — it does
/// not search PATH itself — so `env` is the standard way to get PATH
/// resolution). `env` itself exits nonzero when `claude` is not found, which
/// this reports as `false`, identical to a nonzero exit from `claude` itself.
/// `env` resolves PATH binaries only — a shell alias or function named
/// `claude` (no PATH binary) is invisible to it, so an alias-only setup
/// falls into this same CLI-absent `false` fallback.
///
/// The child runs with stdin, stdout, AND stderr nulled, and is bounded by
/// `timeoutSeconds`. Both are load-bearing: the installer's own output is
/// the only thing the user sees, so a `claude` that decides to prompt
/// (first-run onboarding, consent, an update question) would otherwise read
/// from the inherited terminal with its question invisible — the install
/// appears to hang forever (observed on a brew-migrated machine, 2026-07-11).
/// Nulled stdin turns any such prompt into immediate EOF, and the timeout
/// catches non-prompt stalls (network, lock). Both surface as `false`,
/// which callers treat exactly like a nonzero exit: print the
/// run-`claude plugin update`-yourself fallback and continue the install.
public struct ProcessClaudeCLIRunner: ClaudeCLIRunning {
    public init() {}

    /// Upper bound on one `claude` invocation. `claude plugin update`
    /// normally finishes in seconds; 60s leaves room for a slow network
    /// fetch while still guaranteeing the installer returns.
    static let timeoutSeconds: TimeInterval = 60

    public func run(arguments: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["claude"] + arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in finished.signal() }
        do {
            try proc.run()
        } catch {
            return false
        }
        if finished.wait(timeout: .now() + Self.timeoutSeconds) == .timedOut {
            // SIGTERM first; escalate to SIGKILL for a child that ignores it.
            // The short waits let terminationHandler fire so the process is
            // reaped rather than left as a zombie for the installer's lifetime.
            proc.terminate()
            if finished.wait(timeout: .now() + 5) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            return false
        }
        return proc.terminationStatus == 0
    }
}

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
    /// The ARIA public-surface release selected when this artifact was made.
    public let ariaVersion: String
    /// Stable identity of the selected generated payload.
    public let ariaBundleIdentity: String
    public let skillMarkdown: String
    public let hosts: [String: InstallMapHost]
    /// Package files keyed by `"<host>/<relpath>"` → file contents.
    public let packages: [String: String]

    private struct Wire: Codable {
        struct Map: Codable { let hosts: [InstallMapHost] }
        let schemaVersion: Int
        let ariaVersion: String?
        let ariaBundleIdentity: String?
        let skillMarkdown: String
        let skillMarkdownByHost: [String: String]?
        let installMap: Map
        let packages: [String: String]
    }

    private let skillMarkdownByHost: [String: String]

    /// The ARIA release expected by this executable. Tests use this to stage a
    /// deliberately incompatible bundle without relying on build flags.
    static let selectedARIAReleaseVersion = SelectedARIARelease.version

    /// Decode the embedded `install-bundle-v2.json`. Throws on malformed embedded
    /// data — that is a build-time defect (the artifact is committed), so a
    /// hard failure is correct.
    public init(json: String) throws {
        let wire = try JSONDecoder().decode(Wire.self, from: Data(json.utf8))
        let ariaVersion = wire.ariaVersion ?? "v1"
        guard ariaVersion == Self.selectedARIAReleaseVersion else {
            throw InstallBundleError.ariaReleaseMismatch(
                bundle: ariaVersion,
                executable: Self.selectedARIAReleaseVersion
            )
        }
        guard let identity = wire.ariaBundleIdentity, !identity.isEmpty else {
            // Pre-selector bundles remain usable for the v1 compatibility
            // release only. A selected v2 bundle must carry its own identity.
            guard ariaVersion == "v1" else {
                throw InstallBundleError.missingAriaBundleIdentity(version: ariaVersion)
            }
            self.ariaBundleIdentity = "legacy-v1"
            self.ariaVersion = ariaVersion
            self.skillMarkdown = wire.skillMarkdown
            self.skillMarkdownByHost = wire.skillMarkdownByHost ?? [:]
            var legacyMap: [String: InstallMapHost] = [:]
            for h in wire.installMap.hosts { legacyMap[h.id] = h }
            self.hosts = legacyMap
            self.packages = wire.packages
            return
        }
        self.ariaVersion = ariaVersion
        self.ariaBundleIdentity = identity
        self.skillMarkdown = wire.skillMarkdown
        self.skillMarkdownByHost = wire.skillMarkdownByHost ?? [:]
        var map: [String: InstallMapHost] = [:]
        for h in wire.installMap.hosts { map[h.id] = h }
        self.hosts = map
        self.packages = wire.packages
    }

    /// The embedded bundle, parsed once. EmbeddedArtifactsV2 carries the v2
    /// install-bundle-v2.json generated by tools/moot-packager for the selected
    /// ARIA v2 surface.
    public static let embedded: InstallBundle = {
        do {
            return try InstallBundle(json: EmbeddedArtifactsV2.installBundleJSON)
        } catch {
            // The artifact is committed and generated; a parse failure here is a
            // build defect, surfaced loudly rather than silently degrading.
            fatalError("embedded install-bundle-v2.json failed to parse: \(error)")
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

    /// The generated teaching payload for one host. Legacy bundles carry only
    /// the neutral scalar and intentionally fall back to it.
    public func skillMarkdown(forHostID id: String) -> String {
        skillMarkdownByHost[id] ?? skillMarkdown
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
    ///     block of any command/stdio-shaped MCP server entry written by the
    ///     plugin installer (a host whose schema cannot express HTTP and
    ///     falls back to the proxy bridge — see `injectVaultEnv`). HTTP-shaped
    ///     entries are never touched: the resident daemon is the actual MCP
    ///     server for those, its own launchd/systemd/Task-Scheduler
    ///     environment already carries `MOOTX01_VAULT` (wired at daemon
    ///     registration time, independent of this function), and client-side
    ///     env on an HTTP entry is inert — nothing reads it. Defaults to
    ///     `false` (vault-on); absent `MOOTX01_VAULT` means vault-on per
    ///     the open 1.0 Vault posture.
    ///   - preserveRecordedPluginDisable: when `true`, an EXPLICIT
    ///     `enabledPlugins["mootx01@mootx01"] = false` already recorded in
    ///     `~/.claude/settings.json` is preserved rather than flipped back
    ///     to `true` during marketplace registration. `mootx01 upgrade`
    ///     passes `true` — a routine upgrade must honour a disable the user
    ///     deliberately recorded (Codex Finding #2). The default `false`
    ///     keeps `mootx01 install`'s behavior: an explicit install run is
    ///     itself the user's decision to have the integration active, so it
    ///     (re-)enables. An ABSENT enabledPlugins entry is not a recorded
    ///     decision and enables under both settings.
    ///   - claudeCLIRunner: injectable seam for the `claude plugin update`
    ///     stranded-cache refresh. Defaults to the
    ///     real process-based runner; tests inject a fake.
    /// - Returns: the achieved `DepthOutcome`.
    /// - Throws: filesystem errors writing the skill file or package tree.
    @discardableResult
    public static func apply(
        clientID: String,
        depth: InstallDepth,
        homeDirectory: URL,
        binaryPath: String,
        vaultOff: Bool = false,
        preserveRecordedPluginDisable: Bool = false,
        claudeCLIRunner: ClaudeCLIRunning = ProcessClaudeCLIRunner()
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
                    vaultOff: vaultOff,
                    preserveRecordedPluginDisable: preserveRecordedPluginDisable,
                    claudeCLIRunner: claudeCLIRunner
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

    /// The plugin-depth install directory for `host` (parent of the skill's
    /// `skills/` dir, `+ "mootx01-plugin"`), without checking existence.
    /// Exposed so callers outside this file (e.g. `mootx01 upgrade`) can
    /// check whether a plugin was previously materialized for this host, to
    /// decide whether to rematerialize it after a binary swap. An upgrade alone
    /// does not touch this directory or Claude Code's plugin cache unless
    /// something explicitly requests convergence.
    public static func pluginInstallDirectory(host: InstallMapHost, homeDirectory: URL) -> URL {
        let skillDest = expandTilde(host.skillUserPath, homeDirectory: homeDirectory)
        let root = skillDest
            .deletingLastPathComponent()  // mootx01-memory/
            .deletingLastPathComponent()  // skills/
            .deletingLastPathComponent()  // host plugin root
        // `~/.agents` is the agent-neutral skills root more than one host reads
        // (Codex and GitHub Copilot today). A package directory shared there
        // is overwritten by whichever host materializes last — on 2026-09-17
        // the Copilot package replaced the Codex one a second after it was
        // written and Codex's marketplace registration then failed against a
        // tree with no `.codex-plugin/`. Hosts on that root get their own
        // directory, named by host id; every host with a root of its own
        // keeps the plain name.
        let name = root.lastPathComponent == ".agents" ? "mootx01-plugin-\(host.id)" : "mootx01-plugin"
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// Every plugin-capable host that ALREADY has a plugin directory on disk
    /// for `homeDirectory` — the gating logic behind `mootx01 upgrade`'s
    /// rematerialization pass (plugin-owned MCP connections: an upgrade alone
    /// never touches `~/.claude/mootx01-plugin`, stranding the package and,
    /// for Claude Code, its plugin cache).
    ///
    /// Extracted from `UpgradeCommand.rematerializePluginDepth` (Adams
    /// wave-3 coverage finding) so the gate — CONVERGE existing installs,
    /// never CREATE a new one for a host that never had one — is directly
    /// unit-testable from `MootInstallerCoreTests` without needing the
    /// `mootx01` executable target's test seam. `UpgradeCommand` calls this,
    /// then loops the result through `apply(depth: .plugin, ...)` and prints
    /// its own per-host CLI output — that print/apply loop is left in the
    /// executable target because it is not itself logic worth testing (it is
    /// a straight iteration + one `apply` call already covered by
    /// `plugin_depth_installs_package`-shaped tests elsewhere).
    ///
    /// - Parameter homeDirectory: user's home (for plugin-directory resolution).
    /// - Returns: the plugin-capable hosts whose plugin directory already
    ///   exists, in `InstallBundle.embedded.hosts` iteration order.
    public static func hostsWithExistingPluginDirectory(homeDirectory: URL) -> [InstallMapHost] {
        InstallBundle.embedded.hosts.values
            .filter { host in
                host.supportsPlugin
                    && FileManager.default.fileExists(
                        atPath: pluginInstallDirectory(host: host, homeDirectory: homeDirectory).path)
            }
    }

    /// Mode 2: write the embedded canonical SKILL.md to the host's skillUserPath.
    static func writeSkill(
        host: InstallMapHost,
        bundle: InstallBundle = .embedded,
        homeDirectory: URL
    ) throws -> DepthOutcome {
        let dest = expandTilde(host.skillUserPath, homeDirectory: homeDirectory)
        let dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // §4.2: back up any existing skill file before overwriting.
        try Installer.backupExisting(at: dest)
        try bundle.skillMarkdown(forHostID: host.id)
            .write(to: dest, atomically: true, encoding: .utf8)
        return .skills(path: dest.path)
    }

    /// Mode 3: materialise the host's pre-generated package tree from the
    /// embedded bundle into the host's plugin root (the parent of the skill's
    /// `skills/` dir). The package's own SKILL.md is byte-identical to Mode 2's.
    ///
    /// When `vaultOff` is true, every command/stdio-shaped MCP entry in the
    /// package (the proxy-bridge fallback for hosts whose schema cannot
    /// express HTTP — see `injectVaultEnv`) has `env.MOOTX01_VAULT=0`
    /// injected after the binary-path rewrite. HTTP-shaped entries, skills
    /// files, and plugin-metadata files (plugin.json without an mcpServers
    /// block) are written verbatim.
    ///
    /// Claude Code loads plugins from a cache snapshot. After materializing
    /// the package, this also refreshes
    /// Claude Code's own plugin cache if it was already installed — see
    /// `refreshStrandedPluginCache`.
    private static func installPlugin(
        host: InstallMapHost,
        homeDirectory: URL,
        binaryPath: String,
        vaultOff: Bool,
        preserveRecordedPluginDisable: Bool,
        claudeCLIRunner: ClaudeCLIRunning
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
        let dest = pluginInstallDirectory(host: host, homeDirectory: homeDirectory)
        // Back up an existing plugin directory, then replace it.
        if FileManager.default.fileExists(atPath: dest.path) {
            try Installer.backupExisting(at: dest)
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for (rel, contents) in files {
            let fileURL = dest.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 1. Rewrite the bare "mootx01" command placeholder to the
            //    installed path — live only for hosts whose package still
            //    carries a `command` entry (the proxy-bridge fallback;
            //    currently none of the manifestBundle hosts reachable here,
            //    because all plugin-capable hosts now use HTTP entries — see
            //    rewriteBareMootCommand's own doc comment).
            // 2. When vault-off, inject MOOTX01_VAULT=0 into any
            //    command/stdio-shaped entry — HTTP entries are skipped (see
            //    injectVaultEnv): the resident daemon already carries the
            //    vault posture in its own launchd/systemd/Task-Scheduler
            //    environment, wired independently at daemon-registration
            //    time (sec-fix 6b08d56b's intent), and client-side env on an
            //    HTTP entry is inert — nothing reads it.
            var safeContents = rewriteBareMootCommand(in: contents, binaryPath: binaryPath)
            if vaultOff {
                safeContents = injectVaultEnv(in: safeContents, rel: rel)
            }
            try safeContents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        // Claude Code does NOT auto-discover a loose plugin directory — it only
        // loads plugins registered via a marketplace in settings. So write a
        // directory-marketplace manifest and register + enable it. Without this
        // the plugin files land but `/plugin` never lists or loads mootx01.
        // CodexPluginInstaller registers Codex after this materialization step.
        // This settings-file registration is Claude Code specific.
        if host.id == "claude-code" {
            try registerClaudeCodeMarketplace(
                pluginDir: dest,
                preserveRecordedPluginDisable: preserveRecordedPluginDisable)
            if let line = refreshStrandedPluginCache(
                homeDirectory: homeDirectory, claudeCLIRunner: claudeCLIRunner) {
                print(line)
            }
        }

        return .plugin(path: dest.path)
    }

    /// The Claude Code plugin registry id this installer manages. Shared by
    /// the stranded-cache refresh and (eventually) any other Claude-Code-
    /// specific plugin-identity lookup.
    static let claudeCodePluginID = "mootx01@mootx01"

    /// Claude Code loads plugins from a cache snapshot
    /// (`~/.claude/plugins/installed_plugins.json`) that pins `installPath`
    /// + `version` at install time — it does NOT re-read the marketplace
    /// directory on every launch. Rewriting `~/.claude/mootx01-plugin` above
    /// (a fresh package, current transport) does nothing to that cache: a
    /// user who already has the plugin installed keeps whatever snapshot
    /// Claude Code cached — potentially the OLD stdio manifest — no matter
    /// how many times `mootx01 install`/`upgrade` rewrites the on-disk
    /// package, until something explicitly tells Claude Code to refresh it.
    ///
    /// If the plugin is NOT yet installed, there is no stale cache to
    /// refresh: the marketplace registration just performed is sufficient —
    /// Claude Code discovers and installs fresh (reading the CURRENT
    /// package) the next time it loads.
    ///
    /// If it IS already installed, ask the live `claude` CLI to refresh its
    /// cached copy (`claude plugin update <id>`, default scope `user` —
    /// matches where `registerClaudeCodeMarketplace` registers). Never fails
    /// the install over this: a missing CLI or a nonzero exit only yields a
    /// one-line instruction asking the user to run the refresh themselves,
    /// then restart Claude Code.
    ///
    /// Returns the user-facing line the CALLER prints, or nil when the
    /// plugin was never installed (nothing to say). The success line exists
    /// because `claude plugin update` refreshes the ON-DISK cache only — a
    /// running Claude Code session keeps the previous plugin snapshot
    /// loaded until it is restarted, so a silent success left users testing
    /// against the old plugin while the upgrade reported clean
    /// (MOOT-INSTALL-E defect 1). Returning the message instead of printing
    /// it here keeps the line unit-testable via the fake runner.
    ///
    /// - Parameter claudeCLIRunner: injectable seam so this is testable
    ///   without shelling out to a real `claude` binary.
    static func refreshStrandedPluginCache(
        homeDirectory: URL,
        claudeCLIRunner: ClaudeCLIRunning
    ) -> String? {
        guard let entry = PluginDetector.installedEntry(
            pluginID: claudeCodePluginID, homeDirectory: homeDirectory
        ) else {
            return nil
        }
        guard claudeCLIRunner.run(arguments: ["plugin", "update", claudeCodePluginID]) else {
            return "  ⓘ Could not refresh the cached mootx01 plugin automatically — run `claude plugin update \(claudeCodePluginID)` yourself, then restart Claude Code."
        }
        // `claude plugin update` compares manifest VERSIONS only: a package
        // rewritten under the same version (the server key moved from
        // "mootx01" to "memory" on 2026-09-16 with no version bump) reports
        // "already at the latest version" and leaves the stale cache in
        // place. So compare the cached copy's MCP manifest with the package
        // just materialised, and when they differ reinstall through the CLI,
        // which rebuilds the cache from the current package.
        if cachedManifestDiffers(entry: entry, homeDirectory: homeDirectory) {
            // `claude plugin install` is an activation: it writes
            // `enabledPlugins[id] = true`, and the uninstall before it drops
            // the entry, so a user who deliberately turned the plugin off
            // would come out of a routine upgrade with it on again. Read the
            // recorded decision first and put it back after the rebuild; the
            // cache is fresh either way, and the plugin stays exactly as the
            // user left it. `mootx01 install` is how they turn it back on.
            let recordedDisable = PluginDetector.recordedPluginDisable(
                pluginID: claudeCodePluginID, homeDirectory: homeDirectory)
            guard claudeCLIRunner.run(arguments: ["plugin", "uninstall", claudeCodePluginID]),
                  claudeCLIRunner.run(arguments: ["plugin", "install", claudeCodePluginID]) else {
                return "  ⓘ The cached mootx01 plugin is stale under the same version — run `claude plugin uninstall \(claudeCodePluginID)` then `claude plugin install \(claudeCodePluginID)` yourself, then restart Claude Code."
            }
            if recordedDisable {
                do {
                    try writePluginEnabled(false, pluginID: claudeCodePluginID, homeDirectory: homeDirectory)
                } catch {
                    return "  ⓘ Claude Code plugin cache refreshed, but your recorded disable could not be restored (\(error.localizedDescription)) — run `claude plugin disable \(claudeCodePluginID)` yourself if you want it to stay off."
                }
                return "  ✓ Claude Code plugin cache refreshed; the plugin stays disabled as your settings record — run `mootx01 install` to turn it back on."
            }
        }
        return "  ✓ Claude Code plugin cache refreshed — restart Claude Code (start a new session) to load the updated plugin."
    }

    /// Write `enabledPlugins[pluginID] = value` into `~/.claude/settings.json`,
    /// keeping every other key. A settings file that exists but is not valid
    /// JSON is left untouched (same posture as the marketplace registration:
    /// never overwrite a user's settings with an empty document). Used by the
    /// cache refresh to restore a recorded disable after `claude plugin
    /// install` enabled the plugin.
    static func writePluginEnabled(_ value: Bool, pluginID: String, homeDirectory: URL) throws {
        let fm = FileManager.default
        let claudeDir = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json", isDirectory: false)
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            root = obj
        } else {
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        }
        var enabled = root["enabledPlugins"] as? [String: Any] ?? [:]
        enabled[pluginID] = value
        root["enabledPlugins"] = enabled
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
    }

    /// True when the cached plugin copy's `.mcp.json` differs from the
    /// package on disk. An unreadable cache reads as different (it must be
    /// rebuilt); an unreadable package reads as not different (nothing to
    /// compare against, and the update call above already ran).
    static func cachedManifestDiffers(entry: [String: Any], homeDirectory: URL) -> Bool {
        let claudeHome = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        guard let installPath = entry["installPath"] as? String else { return false }
        let cacheRoot = installPath.hasPrefix("/")
            ? URL(fileURLWithPath: installPath)
            : claudeHome.appendingPathComponent("plugins", isDirectory: true).appendingPathComponent(installPath)
        let packageManifest = claudeHome.appendingPathComponent("mootx01-plugin/.mcp.json")
        guard let package = try? Data(contentsOf: packageManifest) else { return false }
        guard let cached = try? Data(contentsOf: cacheRoot.appendingPathComponent(".mcp.json")) else { return true }
        return cached != package
    }

    /// Register the just-materialised plugin dir as a local (directory-source)
    /// marketplace in `~/.claude/settings.json` and enable it, so Claude Code
    /// discovers and loads it. Writes `.claude-plugin/marketplace.json` in the
    /// plugin dir and MERGES the two settings keys (never clobbering the user's
    /// other marketplaces/plugins). Takes effect after a Claude Code restart.
    ///
    /// Enablement honours recorded user intent (Codex Finding #2): when
    /// `preserveRecordedPluginDisable` is true and `enabledPlugins` already
    /// carries an EXPLICIT `false` for `mootx01@mootx01` — the state Claude
    /// Code records when the user disables the plugin — that decision
    /// survives: the entry is left `false` and only the marketplace
    /// registration is refreshed (so the package stays current for whenever
    /// the user re-enables it). An absent entry is NOT a recorded decision
    /// and enables under both settings, preserving default behavior for
    /// users who never expressed one.
    private static func registerClaudeCodeMarketplace(
        pluginDir: URL,
        preserveRecordedPluginDisable: Bool
    ) throws {
        let market = "mootx01"
        let plugin = "mootx01"
        let fm = FileManager.default

        // 1. marketplace.json beside the plugin's plugin.json.
        let mpDir = pluginDir.appendingPathComponent(".claude-plugin", isDirectory: true)
        try fm.createDirectory(at: mpDir, withIntermediateDirectories: true)
        let marketplace: [String: Any] = [
            "name": market,
            "owner": ["name": "Codedaptive", "url": "https://mootx01.ai"],
            "plugins": [[
                "name": plugin,
                "source": "./",
                "description": "MOOTx01 — active long-term memory and a low-token reasoning substrate.",
            ]],
        ]
        let mpData = try JSONSerialization.data(
            withJSONObject: marketplace, options: [.prettyPrinted, .sortedKeys])
        try mpData.write(to: mpDir.appendingPathComponent("marketplace.json"), options: .atomic)

        // 2. Merge into ~/.claude/settings.json (the plugin dir's parent is the
        //    Claude Code home). Back up first; preserve every existing key.
        let settingsURL = pluginDir.deletingLastPathComponent()
            .appendingPathComponent("settings.json", isDirectory: false)
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settingsURL.path) {
            try Installer.backupExisting(at: settingsURL)
            let data = try Data(contentsOf: settingsURL)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = obj
            } else {
                // File exists but is not valid JSON (#70). Do NOT overwrite
                // with an empty dict — that destroys the user's settings.
                // The backup above preserves the original; skip silently.
                return
            }
        }
        var markets = root["extraKnownMarketplaces"] as? [String: Any] ?? [:]
        markets[market] = ["source": ["source": "directory", "path": pluginDir.path]]
        root["extraKnownMarketplaces"] = markets

        var enabled = root["enabledPlugins"] as? [String: Any] ?? [:]
        let pluginKey = "\(plugin)@\(market)"
        if preserveRecordedPluginDisable, (enabled[pluginKey] as? Bool) == false {
            // Recorded user disable — an upgrade-shaped convergence must not
            // override it. The key is left exactly as the user set it.
        } else {
            enabled[pluginKey] = true
        }
        root["enabledPlugins"] = enabled

        let out = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
    }

    /// Inject
    /// `env.MOOTX01_VAULT=0` into the `mcpServers.<pluginServerName>` entry
    /// of a plugin package's MCP manifest — this runs only over the files
    /// `installPlugin` materialises, so the key is the plugin-package key
    /// (`MCPClients.pluginServerName`), never the direct-entry
    /// `MCPClients.serverName`. The two differ deliberately; see
    /// `ClientConfig.swift`.
    ///
    /// The patch applies ONLY when that entry is command/stdio-shaped
    /// (carries a `command` key: the proxy-bridge fallback for a host whose
    /// schema cannot express HTTP). An HTTP-shaped entry (`type`/`url`, no
    /// `command`) is left untouched: the resident daemon is the actual MCP
    /// server for HTTP transport, so client-side env on the entry is never
    /// read by anything — the vault posture for HTTP hosts is carried
    /// entirely by the daemon's own launchd/systemd/Task-Scheduler
    /// environment, wired independently at daemon-registration time
    /// (`InstallCommand.swift`'s `daemonEnv` / the Rust twins in
    /// `core::service`). Injecting a client-side env block there would be
    /// pure noise — worse, it could read as "vault-off applied" when it did
    /// nothing.
    ///
    /// Also returns `contents` unchanged for non-`.json` files and JSON
    /// files without an `mcpServers` declaration (plugin-metadata files:
    /// author/description only).
    ///
    /// On parse failure or re-serialisation failure the original content is
    /// returned so the host tool can surface the error rather than silently
    /// dropping the file.
    static func injectVaultEnv(in contents: String, rel: String) -> String {
        // Fast-path: non-JSON files and JSON files without a server declaration.
        guard rel.hasSuffix(".json"), contents.contains("\"mcpServers\"") else { return contents }
        guard let data = contents.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any],
              var server = servers[MCPClients.pluginServerName] as? [String: Any]
        else { return contents }

        // HTTP-shaped entry (no `command` key) — client-side env is inert;
        // skip it (Defect 2). Only command/stdio entries (the proxy bridge)
        // read their own env at all.
        guard server["command"] != nil else { return contents }

        // Merge MOOTX01_VAULT=0 into the existing env block or create a new one.
        var env = server["env"] as? [String: Any] ?? [:]
        env["MOOTX01_VAULT"] = "0"
        server["env"] = env
        servers[MCPClients.pluginServerName] = server
        root["mcpServers"] = servers

        guard let patched = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        ), let str = String(data: patched, encoding: .utf8) else { return contents }
        return str.hasSuffix("\n") ? str : str + "\n"
    }

    /// As of the current platform matrix,
    /// this rewrite is DEAD for every host `installPlugin` can reach today.
    /// `installPlugin` only runs for `family == "manifestBundle"` hosts
    /// (`host.supportsPlugin`) — antigravity, claude-code, codex, cursor,
    /// gemini-cli, github-copilot — and every one of those now packages an
    /// HTTP-shaped entry (`httpTyped`/`http`/`httpServerUrl`; plugin-owned MCP connections),
    /// which carries no `command` field at all. Xcode is the one host whose
    /// package still uses the proxy-bridge `command`/`args` shape, but Xcode
    /// is `family == "ideConfig"` — `supportsPlugin` is false for it, so it
    /// never reaches `installPlugin` (it ceils at Mode 2/skills instead; see
    /// `apply`'s `.plugin` branch). moduleCode hosts (cline, hermes,
    /// opencode) are in the same position — no plugin package is
    /// materialized for them at all.
    ///
    /// This function is kept, not deleted, as forward-compatible dead code:
    /// if `tools/moot-packager`'s platform matrix ever promotes a host to
    /// `manifestBundle` before its HTTP transport is verified (matching
    /// today's Xcode disposition), or a currently-HTTP host's schema turns
    /// out not to support HTTP after all and falls back to the proxy
    /// bridge, its embedded package would carry the portable bare
    /// executable name `"mootx01"` that must become the placed binary's
    /// absolute path at install time — exactly what this function does. If
    /// no host ever needs it again, remove it in a follow-up; do not treat
    /// its current inertness as license to silently keep it as ceremony
    /// without this note.
    // Internal (not private), matching `injectVaultEnv`'s access level —
    // both are direct-unit-test targets from `MootInstallerCoreTests` via
    // `@testable import` (Adams wave-3 coverage finding: this function had
    // no direct test despite being the forward-compat rewrite path).
    static func rewriteBareMootCommand(in contents: String, binaryPath: String) -> String {
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
