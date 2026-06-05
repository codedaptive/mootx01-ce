// Installer.swift
//
// Swift reimplementation of the config-merge logic that was previously in
// bash + embedded Python (installer/install.sh). Writes the mootx01 MCP
// server entry into each selected client's config file.
//
// JSON clients (Claude Desktop, Claude Code, Cursor, Cline):
//   Reads the existing config, merges `mcpServers.mootx01` in place,
//   writes back atomically. Idempotent: a second run with the same
//   binary path leaves the file byte-identical.
//
// Continue (YAML):
//   Continue's per-server MCP config lives at .continue/mcpServers/mootx01.yaml.
//   The YAML is a simple two-key object; we write it directly rather than
//   round-tripping a full YAML parser.
//
// Local mode (--location local):
//   For Claude Code only, the target path switches from `~/.claude.json` to
//   `.mcp.json` in the working directory. All other clients are global-only.
//
// MOOT.md instructions file:
//   After wiring clients, the installer writes a brief MOOT.md into the
//   Claude Code instructions path so agents know MOOT is available.

import Foundation

/// Writes and removes MCP server config entries for each supported client.
public enum Installer {

    // MARK: - Install

    /// Wire the mootx01 MCP server into a client's config file.
    ///
    /// - Parameters:
    ///   - client: the client to configure.
    ///   - binaryPath: absolute path to the `mootx01` binary.
    ///   - homeDirectory: user's home directory.
    ///   - workingDirectory: CWD at install time (for --local Claude Code).
    ///   - local: when true and client is Claude Code, write to `.mcp.json`
    ///     in `workingDirectory` instead of the global config.
    /// - Throws: filesystem or JSON errors.
    public static func install(
        client: MCPClient,
        binaryPath: String,
        homeDirectory: URL,
        workingDirectory: URL,
        local: Bool
    ) throws {
        let configURL = resolveConfigURL(
            client: client,
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory,
            local: local
        )

        if client.id == "continue" {
            try installContinue(configURL: configURL, binaryPath: binaryPath)
        } else {
            try installJSON(
                configURL: configURL,
                serverName: client.serverName,
                binaryPath: binaryPath
            )
        }
    }

    /// Write MOOT.md into the Claude Code agent instructions path so agents
    /// automatically know the MOOT server is available.
    ///
    /// - Parameters:
    ///   - homeDirectory: user's home directory.
    ///   - local: when true, write into the working directory's `.claude/` instead.
    ///   - workingDirectory: CWD at install time.
    /// - Throws: filesystem errors.
    public static func writeMOOTmd(
        homeDirectory: URL,
        local: Bool,
        workingDirectory: URL
    ) throws {
        let dir: URL
        if local {
            dir = workingDirectory.appendingPathComponent(".claude", isDirectory: true)
        } else {
            dir = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mootMD = dir.appendingPathComponent("MOOT.md", isDirectory: false)
        // Only write if absent — preserve any user edits on re-install.
        guard !FileManager.default.fileExists(atPath: mootMD.path) else { return }
        let content = """
        # MOOT is available

        This environment has the MOOT MCP server wired. You can use MOOT tools to
        file and recall information across sessions. Start with `moot_drawer_recall`
        to see what is already stored, or `moot_capture_drawer` to file a new item.
        Run `mootx01 status` in the terminal to see the active estate and server state.
        """
        try content.write(to: mootMD, atomically: true, encoding: .utf8)
    }

    // MARK: - Uninstall

    /// Remove the mootx01 MCP server entry from a client's config file.
    ///
    /// - Parameters:
    ///   - client: the client to unconfigure.
    ///   - homeDirectory: user's home directory.
    ///   - workingDirectory: CWD at uninstall time.
    ///   - local: when true and client is Claude Code, target `.mcp.json`.
    /// - Throws: filesystem or JSON errors.
    public static func uninstall(
        client: MCPClient,
        homeDirectory: URL,
        workingDirectory: URL,
        local: Bool
    ) throws {
        let configURL = resolveConfigURL(
            client: client,
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory,
            local: local
        )

        guard FileManager.default.fileExists(atPath: configURL.path) else { return }

        if client.id == "continue" {
            try? FileManager.default.removeItem(at: configURL)
        } else {
            try uninstallJSON(configURL: configURL, serverName: client.serverName)
        }
    }

    // MARK: - JSON client helpers

    private static func installJSON(
        configURL: URL,
        serverName: String,
        binaryPath: String
    ) throws {
        var root: [String: Any]
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } else {
            root = [:]
        }

        // Merge: root["mcpServers"]["mootx01"] = {command, args, env}
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        mcpServers[serverName] = ["command": binaryPath, "args": [], "env": [:] as [String: String]]
        root["mcpServers"] = mcpServers

        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: configURL, options: .atomic)
    }

    private static func uninstallJSON(configURL: URL, serverName: String) throws {
        let data = try Data(contentsOf: configURL)
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        mcpServers.removeValue(forKey: serverName)
        if mcpServers.isEmpty {
            root.removeValue(forKey: "mcpServers")
        } else {
            root["mcpServers"] = mcpServers
        }
        let updated = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try updated.write(to: configURL, options: .atomic)
    }

    // MARK: - Continue YAML helper

    private static func installContinue(configURL: URL, binaryPath: String) throws {
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Continue expects a minimal YAML structure for each MCP server config.
        // We write only the fields it requires; the format is stable per Continue docs.
        let yaml = """
        command: \(binaryPath)
        args: []
        """
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Config URL resolution

    private static func resolveConfigURL(
        client: MCPClient,
        homeDirectory: URL,
        workingDirectory: URL,
        local: Bool
    ) -> URL {
        // Local mode: Claude Code only (localConfigPath is non-nil).
        if local, let localPath = client.localConfigPath {
            return workingDirectory.appendingPathComponent(localPath, isDirectory: false)
        }
        return homeDirectory.appendingPathComponent(client.configPath, isDirectory: false)
    }
}
