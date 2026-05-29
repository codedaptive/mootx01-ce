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
// into Claude and "other clients." Monday's tracked clients are
// the four widely-used MCP hosts: Claude Desktop, Claude Code,
// Cursor, Cline, and Continue. Each entry uses the stdio transport;
// the command is the absolute path the installer writes the
// binary to. Args are empty — mootx01-mcp reads MOOTX01_DATA_DIR
// from the environment if the user wants a non-default location.

import Foundation

/// One MCP client the installer targets. The `configPath` is the
/// macOS-relative path the installer merges the entry into;
/// `serverName` is the key used inside the JSON config's
/// `mcpServers` object.
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

    public init(id: String, displayName: String, configPath: String, serverName: String) {
        self.id = id
        self.displayName = displayName
        self.configPath = configPath
        self.serverName = serverName
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
    public static let supported: [MCPClient] = [
        MCPClient(
            id: "claude-desktop",
            displayName: "Claude Desktop",
            configPath: "Library/Application Support/Claude/claude_desktop_config.json",
            serverName: serverName
        ),
        MCPClient(
            id: "claude-code",
            displayName: "Claude Code",
            configPath: ".claude.json",
            serverName: serverName
        ),
        MCPClient(
            id: "cursor",
            displayName: "Cursor",
            configPath: ".cursor/mcp.json",
            serverName: serverName
        ),
        MCPClient(
            id: "cline",
            displayName: "Cline",
            configPath: "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
            serverName: serverName
        ),
        MCPClient(
            id: "continue",
            displayName: "Continue",
            configPath: ".continue/mcpServers/mootx01.yaml",
            serverName: serverName
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
