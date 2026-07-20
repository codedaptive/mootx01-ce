// ClientConfig.swift
//
// The client registry: the source of truth for which MCP clients the
// installer touches, where each config lives, the per-client servers key
// and entry shape, and format-aware wired detection. The merge engine
// itself is Installer.swift (the earlier bash + Python install.sh path is
// retired).
//
// Supported clients (11): Claude Desktop, Claude Code, Cursor, Cline, Continue,
// Codex (Desktop & CLI), Opencode, Hermes, Gemini CLI, Antigravity, Kiro.
//
// Transport: every client uses native HTTP (supportsLocalHTTP: true) where
// their config schema accepts a local HTTP url, or the proxy bridge
// (useProxyBridge: true) where a stdio command entry is required. No client
// uses bare stdio (isHeadlessStdio) — all clients have full monitoring.
//
// Entry transport is PER-CLIENT (see bounded loopback HTTP): HTTP clients are
// wired to the resident daemon's loopback endpoint so concurrent clients share
// the one running daemon + autonomic governor. Claude Desktop uses the native proxy
// subcommand (`mootx01 proxy`) so its calls execute inside
// the resident daemon with full telemetry and single-writer semantics;
// the installed binary is reused, no Node.js or npx required.
//
// Each client carries a `detectPath` that the installer probes before
// touching any config. Clients not found on the machine are skipped,
// preventing orphaned config entries for software the user hasn't installed.

import Foundation

/// One MCP client the installer targets. The `configPath` is the
/// macOS-relative path the installer merges the entry into;
/// `serverName` is the key used inside the JSON config's
/// `mcpServers` object.
///
/// `detectPath` is the probe path used by `isPresent` to decide
/// whether the client is installed. `nil` means always-wire.
///
/// `localConfigPath` is the relative filename used when the installer
/// is run with `--local`. Only Claude Code has a non-nil value
/// (`.mcp.json`) because it is the only supported client that accepts
/// a project-scoped config. All other clients remain global-only.
public struct MCPClient: Sendable, Equatable {
    public let id: String
    public let displayName: String
    /// Path relative to the user's home directory. Resolved by the
    /// installer; not used by the Swift code at runtime.
    public let configPath: String
    /// Server-name key inside the client's `mcpServers` map. All
    /// clients use the same name so a user with multiple clients
    /// sees the same MOOT in each.
    public let serverName: String
    /// Detection probe path used by `isPresent`.
    /// Absolute paths (starting with "/") are checked directly.
    /// Relative paths are resolved against the user's home directory.
    /// `nil` means always-wire (skip detection).
    public let detectPath: String?
    /// Relative filename for project-local wiring via `--local`.
    /// Non-nil only for Claude Code (`.mcp.json`). All other clients
    /// are global-only and have `nil` here; the installer skips the
    /// local-mode substitution for them.
    public let localConfigPath: String?

    /// Whether this client accepts a LOCAL HTTP MCP endpoint in its config, so
    /// the installer wires it to the resident daemon over HTTP (sharing the one
    /// running daemon + autonomic governor) instead of a stdio `command` entry.
    /// `false` → stdio command entry (e.g. Claude Desktop, whose config schema
    /// requires a command/args entry — the proxy bridge handles daemon routing).
    /// See bounded loopback HTTP.
    ///
    /// SECURITY AUDIT DISPOSITION — a `true` here makes the installer write the
    /// fixed unauthenticated `http://127.0.0.1:4242` into the client config
    /// (codex 7a245e3e, MEDIUM: a same-user process pre-binding the port could
    /// impersonate the daemon). This is the intended shared-resident-daemon
    /// design (the stdio alternative was the unauthorized flip reverted in
    /// 5c035e6), ACCEPTED for CE — the mitigation and rationale live in the
    /// transport's disposition note in `AriaMCP/HTTPServer.swift`. Endpoint
    /// authentication arrives with EE v1.1 (auth scheme + off-localhost hosting);
    /// do not re-flip these to stdio to "fix" the finding.
    public let supportsLocalHTTP: Bool

    /// For JSON HTTP clients, whether the entry carries an explicit
    /// `"type": "http"` field. Claude Code and Cline require it; Cursor infers
    /// HTTP from a bare `url`. Ignored for stdio clients and for Continue (YAML,
    /// handled separately). See bounded loopback HTTP.
    public let httpEntryIncludesType: Bool

    /// Whether this client should be wired via the native proxy subcommand
    /// (`mootx01 proxy`) instead of a bare `mootx01 serve`
    /// stdio entry. True for Claude Desktop, which cannot accept a direct HTTP
    /// URL in its config but gains single-writer and telemetry when routed
    /// through the resident daemon via the proxy. The installer writes
    /// `["command": binaryPath, "args": ["proxy"]]`.
    /// Clients with supportsLocalHTTP: true use the HTTP entry instead; the
    /// proxy flag is only consulted for non-HTTP clients.
    public let useProxyBridge: Bool

    /// True when this client uses the bare stdio entry (no proxy bridge, no HTTP).
    /// In this mode the client spawns its own ephemeral serve process on each
    /// invocation rather than routing through the resident daemon.
    /// Statistics and monitoring are NOT available in this mode; the client
    /// is invisible to moot-mgr. Use only for lightweight headless or embedded
    /// scenarios where the resident daemon is intentionally absent.
    ///
    /// No current entry in `MCPClients.supported` is in headless stdio mode
    /// (all supported clients use HTTP or the proxy bridge). This property is
    /// the canonical name for the mode so future headless clients and their
    /// tests can reference it explicitly.
    public var isHeadlessStdio: Bool {
        !supportsLocalHTTP && !useProxyBridge
    }

    public init(
        id: String,
        displayName: String,
        configPath: String,
        serverName: String,
        detectPath: String? = nil,
        localConfigPath: String? = nil,
        supportsLocalHTTP: Bool = false,
        httpEntryIncludesType: Bool = false,
        useProxyBridge: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.configPath = configPath
        self.serverName = serverName
        self.detectPath = detectPath
        self.localConfigPath = localConfigPath
        self.supportsLocalHTTP = supportsLocalHTTP
        self.httpEntryIncludesType = httpEntryIncludesType
        self.useProxyBridge = useProxyBridge
    }

    /// Returns `true` if this client appears to be installed on the machine.
    ///
    /// - For clients with a `nil` detectPath, always returns `true` (always-wire semantics).
    /// - For absolute detectPaths (e.g. `/Applications/Claude.app`), checks the path directly.
    /// - For relative detectPaths, resolves against `homeDirectory`.
    /// - Cline is a VS Code extension: its detectPath is the extensions directory,
    ///   and presence is confirmed by finding any entry with the `saoudrizwan.claude-dev-` prefix.
    public func isPresent(homeDirectory: URL) -> Bool {
        guard let detectPath else { return true }

        let resolved: URL
        if detectPath.hasPrefix("/") {
            resolved = URL(fileURLWithPath: detectPath)
        } else {
            resolved = homeDirectory.appendingPathComponent(detectPath)
        }

        if id == "cline" {
            // Cline is a VS Code extension installed under ~/.vscode/extensions/.
            // There is no single stable path — the directory name includes the
            // version number (e.g. saoudrizwan.claude-dev-4.1.0), so we enumerate
            // the extensions directory and look for any entry with that prefix.
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: resolved.path) else {
                return false
            }
            return contents.contains { $0.hasPrefix("saoudrizwan.claude-dev-") }
        }

        return FileManager.default.fileExists(atPath: resolved.path)
    }

    /// JSON servers key for this client. opencode's schema
    /// (https://opencode.ai/config.json) puts servers under top-level `mcp`;
    /// every other JSON client uses `mcpServers`.
    public var jsonServersKey: String {
        id == "opencode" ? "mcp" : "mcpServers"
    }

    /// Absolute config URL for this client on this machine. Static
    /// `configPath` resolution plus the two dynamic cases verified live:
    /// opencode prefers `opencode.jsonc` when present (a real install may
    /// carry only the .jsonc), and Hermes honors a `HERMES_HOME` env
    /// override before the platform default.
    public func resolvedConfigURL(homeDirectory: URL) -> URL {
        if id == "opencode" {
            let jsonc = homeDirectory.appendingPathComponent(
                ".config/opencode/opencode.jsonc", isDirectory: false)
            if FileManager.default.fileExists(atPath: jsonc.path) {
                return jsonc
            }
        }
        if id == "hermes",
           let hh = ProcessInfo.processInfo.environment["HERMES_HOME"]?
               .trimmingCharacters(in: .whitespaces),
           !hh.isEmpty {
            return URL(fileURLWithPath: hh).appendingPathComponent("config.yaml", isDirectory: false)
        }
        return homeDirectory.appendingPathComponent(configPath, isDirectory: false)
    }

    /// Whether this client's config currently carries the mootx01 entry.
    /// Format-aware: JSON looks for `<jsonServersKey>.<serverName>`, TOML
    /// for the `[mcp_servers.<serverName>]` table line, YAML for the
    /// 2-space-indented `<serverName>:` entry line (Hermes) or file
    /// existence (Continue's per-server file). The old JSON-only check was
    /// blind to Codex and Hermes wiring.
    public func wired(homeDirectory: URL) -> Bool {
        let configURL = resolvedConfigURL(homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: configURL.path) else { return false }

        switch configURL.pathExtension.lowercased() {
        case "json", "jsonc":
            // Strip a possible leading UTF-8 BOM before parsing — a BOM'd config
            // would otherwise read as "not wired" and trigger a redundant re-wire.
            guard let data = (try? Data(contentsOf: configURL))?.strippingLeadingUTF8BOM,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = obj[jsonServersKey] as? [String: Any] else { return false }
            return servers[serverName] != nil
        case "toml":
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
            let header = "[mcp_servers.\(serverName)]"
            return text.components(separatedBy: "\n")
                .contains { $0.trimmingCharacters(in: .whitespaces) == header }
        case "yaml", "yml":
            if id == "continue" { return true }  // per-server file: existence = wired
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
            let entryHeader = "  \(serverName):"
            return text.components(separatedBy: "\n").contains { line in
                let t = line.hasSuffix(" ")
                    ? String(line.reversed().drop(while: { $0 == " " }).reversed())
                    : line
                return t == entryHeader
            }
        default:
            return false
        }
    }
}

public enum MCPClients {

    /// The canonical server-name key. Picked so a user reading
    /// `mcpServers` in any client immediately recognizes which
    /// server is which — and so the installer's merge can replace
    /// a prior install in place rather than appending duplicates.
    public static let serverName: String = "mootx01"

    /// Clients the installer wires up on macOS. Order matches the
    /// install.sh merge sequence so the progress output is stable.
    ///
    /// Detection probes (AIRA-INSTALL-P1):
    ///   Claude Desktop  → /Applications/Claude.app (macOS app bundle)
    ///   Claude Code     → .claude.json (config file written on first login;
    ///                     bash also tries `command -v claude` as primary check)
    ///   Cursor          → /Applications/Cursor.app (macOS app bundle)
    ///   Cline           → .vscode/extensions (VS Code extensions dir; isPresent
    ///                     scans for saoudrizwan.claude-dev-* prefix)
    ///   Continue        → .continue (config directory written on first launch)
    ///   Codex (Desk&CLI)→ .codex (shared config dir; macOS also /Applications/Codex.app)
    ///   Opencode        → .config/opencode (config directory)
    ///   Hermes          → .hermes (config directory created on install)
    ///   Gemini CLI      → .gemini (config directory created on first run)
    ///   Antigravity     → /Applications/Antigravity.app (macOS app bundle)
    ///   Kiro            → /Applications/Kiro.app (macOS app bundle)
    public static let supported: [MCPClient] = [
        // Transport per client (see bounded loopback HTTP): clients are wired to the resident
        // daemon over HTTP where their config schema accepts a local HTTP/url entry, so
        // concurrent clients share the one running daemon + autonomic governor. Claude Desktop
        // uses the native proxy subcommand (`mootx01 proxy`) — its
        // config schema requires a stdio command entry, and the proxy routes each
        // JSON-RPC frame through the resident daemon so telemetry fires and a single
        // writer holds the estate (no second `mootx01 serve` process).
        MCPClient(
            id: "claude-desktop",
            displayName: "Claude Desktop",
            configPath: "Library/Application Support/Claude/claude_desktop_config.json",
            serverName: serverName,
            detectPath: "/Applications/Claude.app",
            supportsLocalHTTP: false,  // config schema requires stdio command entry
            useProxyBridge: true       // proxy routes frames through the resident daemon
        ),
        MCPClient(
            id: "claude-code",
            displayName: "Claude Code",
            configPath: ".claude.json",
            serverName: serverName,
            // bash uses `command -v claude` as the primary CLI probe;
            // Swift isPresent uses this config file as the file-based fallback.
            detectPath: ".claude.json",
            // Claude Code supports project-local MCP config via .mcp.json in
            // the project root. Other clients are global-only (nil).
            localConfigPath: ".mcp.json",
            supportsLocalHTTP: true,
            httpEntryIncludesType: true  // {"type":"http","url":...}
        ),
        MCPClient(
            id: "cursor",
            displayName: "Cursor",
            configPath: ".cursor/mcp.json",
            serverName: serverName,
            detectPath: "/Applications/Cursor.app",
            supportsLocalHTTP: true,
            httpEntryIncludesType: false  // Cursor infers HTTP from a bare url
        ),
        MCPClient(
            id: "cline",
            displayName: "Cline",
            configPath: "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
            serverName: serverName,
            // detectPath is the parent directory; isPresent enumerates it
            // for a saoudrizwan.claude-dev-* prefix (see isPresent implementation).
            detectPath: ".vscode/extensions",
            supportsLocalHTTP: true,
            httpEntryIncludesType: true  // {"type":"http","url":...}
        ),
        MCPClient(
            id: "continue",
            displayName: "Continue (VS Code / JetBrains)",
            configPath: ".continue/mcpServers/mootx01.yaml",
            serverName: serverName,
            detectPath: ".continue",
            supportsLocalHTTP: true
        ),

        // Codex (Desktop & CLI) — Codex CLI and Codex Desktop share
        // ~/.codex/config.toml, so a single entry wires both.
        // Detection: ~/.codex directory created on first CLI run; macOS also
        // accepts /Applications/Codex.app for the standalone Desktop app.
        // Source: developers.openai.com/codex/mcp
        MCPClient(
            id: "codex",
            displayName: "Codex (Desktop & CLI)",
            configPath: ".codex/config.toml",
            serverName: serverName,
            detectPath: ".codex",
            supportsLocalHTTP: true,
            httpEntryIncludesType: false  // TOML url field; no explicit type needed
        ),

        // Opencode — open-source terminal coding assistant (sst/opencode).
        // Config: ~/.config/opencode/opencode.json OR opencode.jsonc
        // (resolvedConfigURL prefers .jsonc when present). Schema-verified
        // against https://opencode.ai/config.json (McpRemoteConfig): entries
        // are {"type": "remote", "url": …} under the top-level "mcp" key —
        // NOT mcpServers/"http". Connection-verified live: `opencode mcp
        // list` performed an MCP handshake against the resident daemon.
        MCPClient(
            id: "opencode",
            displayName: "Opencode",
            configPath: ".config/opencode/opencode.json",
            serverName: serverName,
            detectPath: ".config/opencode",
            supportsLocalHTTP: true,
            httpEntryIncludesType: true  // shape overridden in mergeIntoJSONConfig: {"type":"remote","url"}
        ),

        // Hermes — NousResearch AI coding assistant (Python CLI tool).
        // Config: ~/.hermes/config.yaml on POSIX; resolution is HERMES_HOME
        // env override → platform default, per
        // hermes_constants._get_platform_default_hermes_home (source-grounded;
        // parser-verified on macOS and Windows). resolvedConfigURL honors
        // HERMES_HOME.
        MCPClient(
            id: "hermes",
            displayName: "Hermes",
            configPath: ".hermes/config.yaml",
            serverName: serverName,
            detectPath: ".hermes",
            supportsLocalHTTP: true,
            httpEntryIncludesType: false  // YAML url field; no explicit type needed
        ),

        // Gemini CLI — Google's Gemini terminal agent.
        // Config: ~/.gemini/settings.json (mcpServers.<name>.url for HTTP transport).
        // Source: geminicli.com/docs/tools/mcp-server/
        MCPClient(
            id: "gemini-cli",
            displayName: "Gemini CLI",
            configPath: ".gemini/settings.json",
            serverName: serverName,
            detectPath: ".gemini",
            supportsLocalHTTP: true,
            httpEntryIncludesType: false  // bare url field; Gemini CLI infers HTTP from url
        ),

        // Antigravity — Google's standalone macOS AI IDE.
        // Config: ~/.gemini/config/mcp_config.json (mcpServers.<name>.serverUrl for HTTP;
        // note: uses "serverUrl" key, not "url"). Detected via app bundle.
        // Source: docs.cloud.google.com/data-cloud-extension/antigravity
        MCPClient(
            id: "antigravity",
            displayName: "Antigravity",
            configPath: ".gemini/config/mcp_config.json",
            serverName: serverName,
            detectPath: "/Applications/Antigravity.app",
            supportsLocalHTTP: true,
            httpEntryIncludesType: false  // Antigravity uses "serverUrl" key (non-standard)
        ),

        // Kiro — Amazon's AI IDE (macOS app).
        // Config: ~/.kiro/settings/mcp.json (mcpServers.<name>.url for remote HTTP).
        // Source: kiro.dev/docs/mcp/configuration/
        MCPClient(
            id: "kiro",
            displayName: "Kiro",
            configPath: ".kiro/settings/mcp.json",
            serverName: serverName,
            detectPath: "/Applications/Kiro.app",
            supportsLocalHTTP: true,
            httpEntryIncludesType: false  // bare url field; Kiro accepts url for remote servers
        ),
    ]
}

/// Legacy stdio entry shape for `mcpServers[<serverName>]`. The current
/// installer dispatches per-client shapes (HTTP, remote, stdio, TOML, YAML);
/// this type is only referenced by its own tests.
public struct MCPServerEntry: Sendable, Equatable, Codable {
    public let command: String
    public let args: [String]
    public let env: [String: String]

    public init(command: String, args: [String] = [], env: [String: String] = [:]) {
        self.command = command
        self.args = args
        self.env = env
    }
}

public enum MCPServerEntryBuilder {

    /// Build the legacy stdio entry. Referenced only by tests; the production
    /// installer dispatches per-client shapes through `Installer.install`.
    public static func entry(binaryPath: String) -> MCPServerEntry {
        MCPServerEntry(command: binaryPath, args: [], env: [:])
    }

    /// Serialize the entry as compact JSON. Sorted keys keep the output stable
    /// across runs and friendly for diff review.
    public static func entryJSON(binaryPath: String) throws -> String {
        let encoder = JSONEncoder()
        // .withoutEscapingSlashes keeps absolute paths human-readable
        // in diffs (no "\/" in the rendered JSON). Sorted-keys keeps
        // the output stable across runs.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(entry(binaryPath: binaryPath))
        return String(decoding: data, as: UTF8.self)
    }
}
