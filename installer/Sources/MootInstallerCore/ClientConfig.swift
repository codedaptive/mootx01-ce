// ClientConfig.swift
//
// Builds the `mcpServers` entries the bash installer merges into
// each MCP client's configuration file. The merge itself runs in
// Python from install.sh (Python ships with macOS, jq does not) —
// this file is the source of truth for the entry shape and the
// list of clients the installer touches, so the data and the
// install logic stay aligned.
//
// LAUNCH_PLAN.md §"The Monday cut": the installer wires the MCP
// into Claude and "other clients." Tracked clients are five widely-used
// MCP hosts: Claude Desktop, Claude Code, Cursor, Cline, and Continue.
// Entry transport is PER-CLIENT (see ADR-LOOPBACKHTTP-001): HTTP for Claude Code,
// Cursor, Cline, and Continue — wired to the resident daemon's loopback
// endpoint so concurrent clients share the one running daemon + Brain
// pump. Claude Desktop stays stdio (its native local-HTTP needs an
// mcp-remote bridge); its command is the absolute placed binary path.
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
    /// running daemon + Brain pump) instead of a stdio `command` entry that
    /// spawns its own ephemeral instance. `false` → stdio (e.g. Claude Desktop,
    /// whose native local-HTTP needs an mcp-remote bridge). See ADR-LOOPBACKHTTP-001.
    public let supportsLocalHTTP: Bool

    /// For JSON HTTP clients, whether the entry carries an explicit
    /// `"type": "http"` field. Claude Code and Cline require it; Cursor infers
    /// HTTP from a bare `url`. Ignored for stdio clients and for Continue (YAML,
    /// handled separately). See ADR-LOOPBACKHTTP-001.
    public let httpEntryIncludesType: Bool

    public init(
        id: String,
        displayName: String,
        configPath: String,
        serverName: String,
        detectPath: String? = nil,
        localConfigPath: String? = nil,
        supportsLocalHTTP: Bool = false,
        httpEntryIncludesType: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.configPath = configPath
        self.serverName = serverName
        self.detectPath = detectPath
        self.localConfigPath = localConfigPath
        self.supportsLocalHTTP = supportsLocalHTTP
        self.httpEntryIncludesType = httpEntryIncludesType
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
    public static let supported: [MCPClient] = [
        // Transport per client (see ADR-LOOPBACKHTTP-001): clients are wired to the resident
        // daemon over HTTP where their config schema accepts a local HTTP/url
        // entry, so concurrent clients share the one running daemon + Brain pump.
        // Claude Desktop stays stdio — its native local-HTTP needs an mcp-remote
        // bridge, so the stdio `command` entry is the reliable path.
        MCPClient(
            id: "claude-desktop",
            displayName: "Claude Desktop",
            configPath: "Library/Application Support/Claude/claude_desktop_config.json",
            serverName: serverName,
            detectPath: "/Applications/Claude.app",
            supportsLocalHTTP: false  // local-HTTP needs an mcp-remote bridge → stdio
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
            displayName: "Continue",
            configPath: ".continue/mcpServers/mootx01.yaml",
            serverName: serverName,
            detectPath: ".continue",
            supportsLocalHTTP: true  // YAML: type: streamable-http (installContinue)
        ),
    ]
}

/// The JSON-Object shape that lands inside a client's
/// `mcpServers[<serverName>]` slot. Same shape for every client
/// per MCP stdio convention.
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

    /// Build the entry the installer writes into each client's
    /// JSON config. `binaryPath` is the absolute path install.sh
    /// places the `mootx01-mcp` executable at.
    public static func entry(binaryPath: String) -> MCPServerEntry {
        MCPServerEntry(command: binaryPath, args: [], env: [:])
    }

    /// Serialize the entry as compact JSON for emission by the
    /// `--print-entry` mode used by install.sh's Python merge.
    /// Sorted keys keep the output stable across runs and friendly
    /// for diff review.
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
