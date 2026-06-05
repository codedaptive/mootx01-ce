// InstallCommand.swift
//
// Wire mootx01 into one or more MCP clients and grant ARIA tool permissions.
// Mirrors the install surface of popular MCP server CLIs (e.g. @modelcontextprotocol).

import ArgumentParser
import Foundation
import MootInstallerCore

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Wire mootx01 into MCP clients and grant tool permissions."
    )

    @Option(name: .long, help: "Comma-separated client ids to install (e.g. claude,cursor). Default: interactive picker.")
    var target: String?

    @Option(name: .long, help: "Config scope: 'global' (default) or 'local' (project .mcp.json for Claude Code).")
    var location: String = "global"

    @Flag(name: .shortAndLong, help: "Skip prompts; auto-detect and install all present clients.")
    var yes: Bool = false

    @Flag(name: .long, help: "Skip writing to settings.json (do not grant tool permissions).")
    var noPermissions: Bool = false

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let local = location == "local"

        // Resolve binary path: use the running binary's own path so the
        // config entry always points at the installed mootx01 binary.
        let binaryPath = CommandLine.arguments.first ?? "/usr/local/bin/mootx01"

        let clients = try AgentPicker.pick(yes: yes, target: target, homeDirectory: home)
        guard !clients.isEmpty else {
            print("No clients selected. Run `mootx01 install --target <id>` to install a specific client.")
            return
        }

        print("\nInstalling mootx01 into \(clients.count) client(s)...")

        var installed: [String] = []
        var skipped: [String] = []

        for client in clients {
            do {
                try Installer.install(
                    client: client,
                    binaryPath: binaryPath,
                    homeDirectory: home,
                    workingDirectory: cwd,
                    local: local
                )
                installed.append(client.displayName)
            } catch {
                print("  ✗ \(client.displayName): \(error)")
                skipped.append(client.displayName)
            }
        }

        // Write tool permissions into Claude Code settings.json.
        if !noPermissions {
            let settingsURL = local
                ? MootPaths.localClaudeSettingsURL(workingDirectory: cwd)
                : MootPaths.globalClaudeSettingsURL(homeDirectory: home)
            do {
                try PermissionsWriter.merge(into: settingsURL)
                print("  ✓ Granted \(PermissionsWriter.permissionEntries.count) ARIA tool permissions in \(settingsURL.path)")
            } catch {
                print("  ✗ Could not write permissions: \(error)")
            }
        }

        // Write MOOT.md instructions file for Claude Code.
        do {
            try Installer.writeMOOTmd(homeDirectory: home, local: local, workingDirectory: cwd)
        } catch {
            // Non-fatal: MOOT.md is advisory.
        }

        print("")
        if !installed.isEmpty {
            print("Installed: \(installed.joined(separator: ", "))")
        }
        if !skipped.isEmpty {
            print("Skipped (errors): \(skipped.joined(separator: ", "))")
        }
        print("")
        print("Run `mootx01 status` to confirm your setup.")
    }
}
