// UninstallCommand.swift
//
// Reverse of InstallCommand: removes mootx01 config entries, permission
// grants, and optionally estate databases from all configured clients.
//
// A FULL uninstall (no --target) then offers to remove the user's data —
// the estate databases (default + named) and the moot-mgr history store —
// behind an explicit typed-'yes' confirmation, and moves it to the Trash
// rather than hard-deleting, so the user has a recovery window. `--purge`
// pre-selects removal for automation; `--purge --yes` skips the prompt
// entirely. A targeted uninstall never touches data. Mirrors
// commands/uninstall.rs in the Rust vertical.

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

    @Flag(name: .long, help: "Also remove all estate databases and the moot-mgr history (moved to the Trash after a typed confirmation; --yes skips the prompt).")
    var purge: Bool = false

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let clients = try AgentPicker.pick(yes: yes, target: target, homeDirectory: home)
        guard !clients.isEmpty else {
            print("No clients selected.")
            return
        }

        if purge, target != nil {
            // --purge with --target is contradictory: purge destroys the
            // data the untargeted clients still depend on. Refuse loudly.
            print("--purge requires a full uninstall (drop --target).")
            throw ExitCode.failure
        }

        print("\nUninstalling mootx01 from \(clients.count) client(s)...")

        for client in clients {
            do {
                // ADR-024 §4: ownership-aware for JSON-format clients — a
                // `.foreign` entry (env override, e.g. a development rig) is
                // reported and left untouched rather than silently removed.
                let outcome = try Installer.uninstall(
                    client: client,
                    homeDirectory: home,
                    workingDirectory: cwd,
                    local: false
                )
                switch outcome {
                case .notPresent:
                    print("  ⓘ \(client.displayName): no entry present")
                case .removed:
                    print("  ✓ \(client.displayName)")
                case let .retainedForeign(reason, path):
                    print("  ⚠ \(client.displayName): a non-default mootx01 entry at \(path) (\(reason)) was left untouched — remove it by hand if intended")
                }
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

            // Remove the placed binaries (~/.mootx01) and the PATH wrappers
            // (~/.local/bin/mootx01, ~/.local/bin/moot-mgr). Inverse of install's
            // placeBinary/placeMgrBinary.
            do {
                try Installer.removePlacedBinary(homeDirectory: home)
                print("  ✓ Removed placed binaries and PATH entries.")
            } catch {
                print("  ✗ Could not remove placed binary: \(error)")
            }
        }

        // Data-retention phase: only a FULL uninstall may touch user data
        // (the --purge/--target contradiction was already rejected above).
        // Runs AFTER the launchd teardown so nothing is holding the stores
        // open when they move to the Trash.
        if target == nil {
            try removeUserData()
        }

        print("\nDone. Restart your MCP client to apply changes.")
    }

    /// Offer/confirm/trash the data directory. The decision matrix lives in
    /// `DataRetention.decideDataRemoval` (unit-tested); this wrapper owns
    /// the prompts and the exit codes.
    private func removeUserData() throws {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDir = MootPaths.resolveDataDirectory(environment: environment, homeDirectory: home)
        guard let inventory = DataRetention.dataInventory(in: dataDir) else { return }

        let decision = DataRetention.decideDataRemoval(
            purge: purge,
            yes: yes,
            interactive: isatty(STDIN_FILENO) != 0,
            offer: {
                print("\nYour data is still in place at \(dataDir.path):")
                print("  \(inventory)")
                print("Remove it too? [y/N]: ", terminator: "")
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                return answer == "y" || answer == "yes"
            },
            confirm: {
                print("WARNING: this DESTROYS all MOOTx01 memory data (\(inventory)).")
                print("It will be moved to \(DataRetention.trashName) (recoverable until you empty it).")
                print("Type 'yes' to confirm: ", terminator: "")
                return readLine()?.trimmingCharacters(in: .whitespaces) == "yes"
            }
        )

        switch decision {
        case let .leave(reason):
            print("  ⓘ \(reason): \(dataDir.path)")
        case .aborted:
            print("Aborted — data left in place: \(dataDir.path)")
            throw ExitCode.failure
        case .trash:
            do {
                try DataRetention.trashDataDirectory(dataDir)
                print("  ✓ Data moved to \(DataRetention.trashName): \(dataDir.path)")
            } catch {
                print("  ✗ Could not move \(dataDir.path) to \(DataRetention.trashName): \(error)")
                print("    Data left in place.")
                throw ExitCode.failure
            }
        }
    }
}
