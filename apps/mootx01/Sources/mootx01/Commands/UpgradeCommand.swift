// UpgradeCommand.swift
//
// Replace the installed mootx01 binary with a newer release, then restart
// both background agents. Two upgrade paths:
//
//   Online (default): hit GitHub releases API, download the platform asset,
//   verify SHA-256, extract, and replace the installed binary. Falls back to
//   the local-build path if the network call fails.
//
//   Local (--from <path>): mirrors the original developer workflow — copies a
//   freshly built binary from an explicit path or searches .build/release/
//   and .build/debug/ relative to the current directory.
//
// Use --check to query the latest release without downloading.
// Use --yes to skip the confirmation prompt in the online path.

import ArgumentParser
import Foundation
import MootInstallerCore

struct UpgradeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upgrade",
        abstract: "Upgrade mootx01 to the latest release or a local build.",
        discussion: """
            Without arguments, upgrade downloads the latest release from GitHub,
            verifies the SHA-256 checksum, installs the binary, and restarts
            background services. Falls back to searching the local build tree
            (.build/release/mootx01, .build/debug/mootx01) if the network call fails.

            Use --from to skip the online check and install from a specific path:
              mootx01 upgrade --from .build/release/mootx01

            Use --check to print the latest available version without downloading:
              mootx01 upgrade --check

            Use --yes to skip the download confirmation prompt:
              mootx01 upgrade --yes
            """
    )

    @Option(name: .long, help: "Path to the new binary to install (skips online check).")
    var from: String?

    @Flag(name: .customLong("check"), help: "Print the latest available version and exit without downloading.")
    var checkOnly: Bool = false

    @Flag(name: .long, help: "Skip the confirmation prompt before downloading a new release.")
    var yes: Bool = false

    @Flag(name: .long, help: "Copy the binary but skip restarting the background agents.")
    var noRestart: Bool = false

    // run() is intentionally inline: three mutually exclusive paths (--check, online,
    // local-build) each terminate with an early return or throw. Extracting three
    // single-use helpers that each return immediately would scatter closely-related
    // prompt / fallback / error-handling logic without reducing actual complexity.
    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cwd  = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // --check: query GitHub and print the latest tag without downloading.
        if checkOnly {
            let downloader = ReleaseDownloader(
                repo: "codedaptive/mootx01-ce",
                currentVersion: Mootx01.currentVersion)
            if let tag = try await downloader.latestTag() {
                print("New version available: \(tag) (current: \(Mootx01.currentVersion))")
            } else {
                print("Already up to date (\(Mootx01.currentVersion)).")
            }
            return
        }

        // Online path: attempt a GitHub release download when --from is not given.
        if from == nil {
            let downloader = ReleaseDownloader(
                repo: "codedaptive/mootx01-ce",
                currentVersion: Mootx01.currentVersion)
            do {
                guard let tag = try await downloader.latestTag() else {
                    print("Already up to date (\(Mootx01.currentVersion)).")
                    return
                }
                print("New version available: \(Mootx01.currentVersion) \u{2192} \(tag)")
                if !yes {
                    print("Download and install \(tag)? [y/N] ", terminator: "")
                    let response = readLine() ?? ""
                    guard response.lowercased() == "y" || response.lowercased() == "yes" else {
                        print("Upgrade cancelled.")
                        return
                    }
                }
                let newBinary  = try await downloader.download(tag: tag)
                let binaryPath = try downloader.replace(newBinary: newBinary, homeDirectory: home)
                print("Installed:      \(binaryPath)")
                restartAgents(home: home)
                print("\nUpgraded to \(tag). Run `mootx01 status` to confirm.")
                return
            } catch {
                // Network failure or bad checksum: fall through to the local-build search.
                print("Online upgrade failed (\(error)). Falling back to local build search\u{2026}")
            }
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

        restartAgents(home: home)
        print("\nUpgrade complete. Run `mootx01 status` to confirm.")
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
