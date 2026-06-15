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

        // Remove permissions from Claude Code settings.json — only when
        // Claude Code itself is in scope.
        if clients.contains(where: { $0.id == "claude-code" }) {
            let settingsURL = MootPaths.globalClaudeSettingsURL(homeDirectory: home)
            do {
                try PermissionsWriter.remove(from: settingsURL)
            } catch {
                print("  ✗ Could not remove permissions: \(error)")
            }
        }

        // Full-teardown phase: launchd services and the placed binaries come
        // out ONLY on a full uninstall (no --target). A targeted uninstall
        // scopes to the named clients' wirings; tearing down the resident
        // daemon that OTHER still-wired clients depend on was the bug that
        // ripped a live installation out from under two-client uninstall.
        if target == nil {
            // Stop and remove the moot-mgr management console LaunchAgent BEFORE
            // deleting its binary, so the running service is booted out of launchd
            // first (otherwise launchd keeps respawning a now-missing executable).
            #if os(macOS)
            LaunchAgent.uninstall(homeDirectory: home)
            print("  ✓ Stopped and removed the management console (launchd).")
            LaunchAgent.uninstallDaemon(homeDirectory: home)
            print("  ✓ Stopped and removed the resident mootx01 daemon (launchd).")
            #endif

            // Remove the placed binaries (~/.mootx01) and the PATH symlinks
            // (~/.local/bin/mootx01, ~/.local/bin/moot-mgr). Inverse of install's
            // placeBinary/placeMgrBinary; mirrors codegraph's `--uninstall` which
            // removes both the install dir and the launcher symlink.
            do {
                try Installer.removePlacedBinary(homeDirectory: home)
                print("  ✓ Removed placed binaries and PATH symlinks.")
            } catch {
                print("  ✗ Could not remove placed binary: \(error)")
            }
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
