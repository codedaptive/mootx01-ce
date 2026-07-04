// UpgradeCommand.swift
//
// Replace the installed mootx01 binary with a newer release, then restart
// both background agents. Upgrade installs only from a local binary:
//
//   Local (--from <path>): mirrors the original developer workflow — copies a
//   freshly built binary from an explicit path or searches .build/release/
//   and .build/debug/ relative to the current directory.
//
// Use --check to query the latest release without downloading.

import AriaMCP
import ArgumentParser
import Foundation
import MootInstallerCore

struct UpgradeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upgrade",
        abstract: "Upgrade mootx01 from a local build.",
        discussion: """
            Upgrade installs a local binary and restarts background services.
            Without --from, it searches the local build tree
            (.build/release/mootx01, .build/debug/mootx01).

            Use --from to install from a specific path:
              mootx01 upgrade --from .build/release/mootx01

            Use --check to print the latest available version without downloading:
              mootx01 upgrade --check
            """
    )

    @Option(name: .long, help: "Path to the new binary to install (skips online check).")
    var from: String?

    @Flag(name: .customLong("check"), help: "Print the latest available version and exit without downloading.")
    var checkOnly: Bool = false

    @Flag(name: .long, help: "Deprecated; online binary installation is disabled.")
    var yes: Bool = false

    @Flag(name: .long, help: "Copy the binary but skip restarting the background agents.")
    var noRestart: Bool = false

    // run() is intentionally inline: --check terminates early, then the local-build
    // path copies the selected binary and restarts services. Extracting single-use
    // helpers would scatter closely-related error-handling logic without reducing
    // actual complexity.
    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cwd  = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // --check: query GitHub and print the latest tag without downloading.
        if checkOnly {
            let downloader = ReleaseDownloader(
                repo: "codedaptive/mootx01-ee",
                currentVersion: Mootx01.currentVersion)
            if let tag = try await downloader.latestTag() {
                print("New version available: \(tag) (current: \(Mootx01.currentVersion))")
            } else {
                print("Already up to date (\(Mootx01.currentVersion)).")
            }
            return
        }

        // Local path: resolve from --from flag or search .build/ tree (original behavior).
        let sourcePath = try resolveSource(cwd: cwd)
        print("Upgrading from: \(sourcePath)")

        let binaryPath: String
        do {
            binaryPath = try Installer.placeBinary(
                sourcePath: sourcePath, homeDirectory: home, force: true)
            print("Installed:      \(binaryPath)")
        } catch {
            print("Could not place binary: \(error)")
            throw error
        }

        // Update the moot-mgr sibling if it is found beside the source binary.
        let mgrSource = URL(fileURLWithPath: sourcePath)
            .deletingLastPathComponent()
            .appendingPathComponent("moot-mgr").path
        if FileManager.default.isExecutableFile(atPath: mgrSource) {
            if let mgrPath = try Installer.placeMgrBinary(
                sourceMgrPath: mgrSource, homeDirectory: home) {
                print("Updated:        \(mgrPath)")
            }
        }

        // ADR-024 Wave 3, Defect 1: an upgrade alone never touches
        // ~/.claude/mootx01-plugin or Claude Code's plugin cache — without
        // this, a machine upgraded via `mootx01 upgrade` keeps a stranded
        // plugin package (and Claude Code keeps a stranded cached snapshot)
        // indefinitely. Rematerialize plugin-depth packages for every host
        // that already has one on disk (never CREATES a new plugin-depth
        // install for a host that never had one — upgrade only converges
        // existing installs), and refresh Claude Code's cache the same way
        // `mootx01 install` does.
        rematerializePluginDepth(home: home, binaryPath: binaryPath)

        // Bob's re-tier ruling (2026-07-04): converge an EXISTING Claude
        // Code integration's tool-permission tiering onto the current
        // default the same way rematerializePluginDepth converges the
        // plugin package above — never CREATES `~/.claude/settings.json`
        // or a mootx01 integration for a user who never selected Claude
        // Code as an install target. Gated on hasAnyMootEntries so a user
        // who never ran `mootx01 install` with Claude Code selected sees no
        // side effect at all from `mootx01 upgrade`.
        migratePermissionTiers(home: home)

        restartAgents(home: home)
        print("\nUpgrade complete. Run `mootx01 status` to confirm.")
    }

    /// See the call site's doc comment. The gating (which hosts qualify —
    /// plugin-capable AND already has a plugin directory on disk) lives in
    /// `DepthInstaller.hostsWithExistingPluginDirectory`, directly unit-
    /// tested from `MootInstallerCoreTests` (Adams wave-3 coverage finding).
    /// This loop reruns `DepthInstaller.apply(depth: .plugin, ...)` for each
    /// gated host so the on-disk package (and, for Claude Code, the plugin
    /// cache) converge on whatever the CURRENT embedded bundle carries, and
    /// prints the per-host CLI result. `vaultOff` is not tracked across
    /// upgrades — passing `false` here is safe regardless: every
    /// plugin-capable host's package is HTTP-shaped today (ADR-024 §2), so
    /// `vaultOff` has no effect on rematerialization (Defect 2); the vault
    /// posture that matters lives in the resident daemon's own launchd
    /// environment, which `mootx01 upgrade` does not touch (it restarts the
    /// daemon from its EXISTING plist via `LaunchAgent.restart`, never
    /// rewriting it).
    private func rematerializePluginDepth(home: URL, binaryPath: String) {
        for host in DepthInstaller.hostsWithExistingPluginDirectory(homeDirectory: home) {
            do {
                _ = try DepthInstaller.apply(
                    clientID: host.id, depth: .plugin, homeDirectory: home, binaryPath: binaryPath
                )
                print("  ✓ \(host.displayName): plugin package rematerialized")
            } catch {
                print("  ✗ \(host.displayName): could not rematerialize plugin package: \(error)")
            }
        }
    }

    /// See the call site's doc comment. Only touches
    /// `~/.claude/settings.json` when it already carries at least one of
    /// our permission entries (`PermissionsWriter.hasAnyMootEntries`) — an
    /// upgrade never creates a Claude Code integration that was never
    /// installed. When gated in, runs the same two-pass composition
    /// `mootx01 install` runs: `migrateTiers` re-tiers anything already
    /// present but stale, then `mergeTiered` adds anything still missing
    /// (e.g. a tool added to the surface since the last install/upgrade,
    /// such as moot_memory_get).
    private func migratePermissionTiers(home: URL) {
        let settingsURL = MootPaths.globalClaudeSettingsURL(homeDirectory: home)
        guard PermissionsWriter.hasAnyMootEntries(at: settingsURL) else { return }
        let toolNames = ToolProjection.tools().map(\.name)
        do {
            let moved = try PermissionsWriter.migrateTiers(at: settingsURL, toolNames: toolNames)
            if moved > 0 {
                print("  ✓ Re-tiered \(moved) existing ARIA tool permission(s) to the current default")
            }
            let added = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)
            if added.allow + added.ask + added.deny > 0 {
                print("  ✓ Added \(added.allow + added.ask + added.deny) new ARIA tool permission(s)")
            }
        } catch {
            print("  ✗ Could not migrate Claude Code tool permissions: \(error)")
        }
    }

    /// Restart the installed background agents after a binary replacement.
    ///
    /// macOS: uses launchctl via LaunchAgent.restart().
    /// Linux: attempts `systemctl restart mootx01`; prints a manual-restart
    /// message when systemd is absent or the call fails.
    private func restartAgents(home: URL) {
        guard !noRestart else { return }
        print("\nRestarting background services\u{2026}")
        #if os(macOS)
        switch LaunchAgent.restart(homeDirectory: home) {
        case .installed(_, let dashboardURL):
            print("  \u{2713} Daemon and management console restarted.")
            print("  \u{2713} Dashboard: \(dashboardURL)")
        case let .launchctlFailed(msg):
            print("  \u{2717} launchctl error: \(msg)")
            print("    Restart manually: launchctl kickstart -k gui/$(id -u)/com.mootx01.daemon")
        case .binaryNotFound:
            print("  \u{24D8} No launchd agents found \u{2014} run `mootx01 install` first.")
        }
        #elseif os(Linux)
        // systemd restart; falls back to a manual-restart message if systemd is absent.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/systemctl")
        proc.arguments = ["restart", "mootx01"]
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                print("  \u{24D8} Restart the daemon manually: systemctl restart mootx01")
            }
        } catch {
            print("  \u{24D8} Restart the daemon manually: systemctl restart mootx01")
        }
        #else
        print("  \u{24D8} Non-macOS/Linux: restart the daemon manually.")
        #endif
    }

    private func resolveSource(cwd: URL) throws -> String {
        // Explicit --from takes priority.
        if let explicit = from {
            let url = URL(fileURLWithPath: explicit, relativeTo: cwd).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw ValidationError("Binary not found or not executable: \(url.path)")
            }
            return url.path
        }

        // Search build outputs relative to CWD.
        let candidates = [
            cwd.appendingPathComponent(".build/release/mootx01").path,
            cwd.appendingPathComponent(".build/debug/mootx01").path,
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        throw ValidationError("""
            Could not find a new binary to install.
            Build first, then upgrade:
              swift build -c release
              mootx01 upgrade
            Or specify the path explicitly:
              mootx01 upgrade --from .build/release/mootx01
            """)
    }
}
