// UninstallCommand.swift
//
// Reverse of InstallCommand: removes mootx01 config entries, permission
// grants, and optionally estate databases from all configured clients.
//
// Default: never touches user data. Requires --purge to delete estates.

import ArgumentParser
import Foundation
import MootInstallerCore

struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove mootx01 from MCP clients."
    )

    @Option(name: .long, help: "Comma-separated client ids to uninstall. Default: all detected.")
    var target: String?

    @Flag(name: .shortAndLong, help: "Skip prompts; uninstall from all detected clients.")
    var yes: Bool = false

    @Flag(name: .long, help: "Also delete all estate databases. Irreversible.")
    var purge: Bool = false

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let clients = try AgentPicker.pick(yes: yes, target: target, homeDirectory: home)
        guard !clients.isEmpty else {
            print("No clients selected.")
            return
        }

        if purge {
            print("WARNING: --purge will permanently delete all estate databases.")
            if !yes {
                print("Type 'yes' to confirm: ", terminator: "")
                guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else {
                    print("Aborted.")
                    return
                }
            }
        }

        print("\nUninstalling mootx01 from \(clients.count) client(s)...")

        for client in clients {
            do {
                try Installer.uninstall(
                    client: client,
                    homeDirectory: home,
                    workingDirectory: cwd,
                    local: false
                )
                print("  ✓ \(client.displayName)")
            } catch {
                print("  ✗ \(client.displayName): \(error)")
            }
        }

        // Remove permissions from Claude Code settings.json.
        let settingsURL = MootPaths.globalClaudeSettingsURL(homeDirectory: home)
        do {
            try PermissionsWriter.remove(from: settingsURL)
        } catch {
            print("  ✗ Could not remove permissions: \(error)")
        }

        // Remove the placed binary (~/.mootx01) and the PATH symlink
        // (~/.local/bin/mootx01). Inverse of install's placeBinary; mirrors
        // codegraph's `--uninstall` which removes both the install dir and
        // the launcher symlink.
        do {
            try Installer.removePlacedBinary(homeDirectory: home)
            print("  ✓ Removed placed binary and PATH symlink.")
        } catch {
            print("  ✗ Could not remove placed binary: \(error)")
        }

        // Purge estate databases if requested.
        if purge {
            let environment = ProcessInfo.processInfo.environment
            let dataDir = MootPaths.resolveDataDirectory(environment: environment, homeDirectory: home)
            do {
                try DatabaseManager.purgeDefaultEstate(in: dataDir)
                // Also remove all named estates.
                for name in DatabaseManager.listEstates(in: dataDir) where name != "default" {
                    try? DatabaseManager.deleteEstate(name: name, in: dataDir)
                }
                print("  ✓ Estate databases purged.")
            } catch {
                print("  ✗ Could not purge estates: \(error)")
            }
        }

        print("\nDone. Restart your MCP client to apply changes.")
    }
}
