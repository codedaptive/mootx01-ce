// UpgradeCommand.swift
//
// Replace the installed mootx01 binary with a newer release, then restart
// both background agents. Two sources, mirroring the Rust vertical
// (rust/src/commands/upgrade.rs):
//
//   Remote (default): fetch the latest GitHub release via ReleaseDownloader
//   (SHA-256 + minisign on Linux/POSIX + tarball-member validation), confirm
//   unless --yes, place, and run the convergence steps (plugin rematerialization,
//   permission-tier migration, service restart).
//
//   Local (--from <path>): the developer workflow — copies a freshly built
//   binary from an explicit path (e.g. --from .build/release/mootx01).
//
// Use --check to query the latest release without downloading.

import AriaMCP
import ArgumentParser
import Foundation
import LocusKit
import MootInstallerCore
import PersistenceKit
import PersistenceKitSQLite
import VaultKit

struct UpgradeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upgrade",
        abstract: "Upgrade mootx01 to the latest release (or from a local build).",
        discussion: """
            Without flags, upgrade downloads the latest release (SHA-256
            verified, with checksums.txt authenticated by minisign on
            Linux/POSIX), installs it, converges plugin packages and tool
            permissions, and restarts the background services.

            Use --from to install a local build instead of downloading:
              mootx01 upgrade --from .build/release/mootx01

            Use --check to print the latest available version without downloading:
              mootx01 upgrade --check
            """
    )

    @Option(name: .long, help: "Path to the new binary to install (skips online check).")
    var from: String?

    /// Install a specific release tag instead of the newest stable.
    ///
    /// Load-bearing for candidate builds: `latestTag()` queries GitHub's
    /// `/releases/latest`, which EXCLUDES prereleases by definition, so plain
    /// `mootx01 upgrade` can never install a `X.Y.Z-beta-NN` build — it
    /// silently installs the newest stable instead. A user told to "run
    /// mootx01 upgrade" to pick up a beta fix stayed broken because of this.
    ///
    /// Same name and semantics as `MOOTX01_VERSION` in install.sh / install.ps1,
    /// and the exact string every candidate release note already prints. The
    /// download path needs no change: `download(tag:)` uses the tag verbatim to
    /// build the asset name and URL, which already matches what the candidate
    /// pipeline publishes.
    @Option(
        name: .long,
        help: "Install this exact release tag (e.g. 1.1.0-beta-08) instead of the newest stable. Also settable via MOOTX01_VERSION.")
    var version: String?

    @Flag(name: .customLong("check"), help: "Print the latest available version and exit without downloading.")
    var checkOnly: Bool = false

    @Flag(name: .long, help: "Skip the download confirmation prompt.")
    var yes: Bool = false

    @Flag(name: .long, help: "Copy the binary but skip restarting the background agents.")
    var noRestart: Bool = false

    /// GitHub repo slug the upgrade queries and downloads from.
    ///
    /// Defaults to the public CE repo; MOOTX01_REPO overrides it — the same
    /// env override install.sh honors — so internal (ee) builds can point at
    /// their private repo. The previous HARDCODED "codedaptive/mootx01-ee"
    /// slug arrived with the EE→CE shared-code merge (39c274fe) and made
    /// `upgrade --check` a dead flag for every public user: no ee access,
    /// so GitHub answered 404 instead of version info (MOOT-INSTALL-E
    /// defect 2).
    static func repoSlug() -> String {
        ProcessInfo.processInfo.environment["MOOTX01_REPO"] ?? "codedaptive/mootx01-ce"
    }

    // run() is intentionally inline: --check terminates early, then the remote
    // or local-build path places the selected binary and restarts services.
    // Extracting single-use helpers would scatter closely-related
    // error-handling logic without reducing actual complexity.
    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cwd  = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let downloader = ReleaseDownloader(
            repo: Self.repoSlug(),
            currentVersion: Mootx01.currentVersion)

        // --check: query GitHub and print the latest tag without downloading.
        // Query-only by contract, so the encryption offer does not run here.
        if checkOnly {
            if let tag = try await downloader.latestTag() {
                print("New version available: \(tag) (current: \(Mootx01.currentVersion))")
            } else if let remote = try await downloader.latestTagIgnoringOrder() {
                // latestTag() returns nil for BOTH "you are current" and "the
                // newest release is older than what you run". Conflating them
                // told a beta tester "Already up to date (1.1.0-beta-08)" while
                // the release feed sat at stable 1.0.38 — technically true,
                // actively misleading, and the same class of silent wrongness
                // as the prerelease exclusion itself.
                let current = Mootx01.currentVersion
                if remote == current || remote == "v\(current)" {
                    print("Already up to date (\(current)).")
                } else {
                    print("""
                        Running \(current); newest published release is \(remote).
                        Nothing to upgrade to — you are ahead of the release feed. \
                        Prereleases are not listed here; install one explicitly with \
                        `mootx01 upgrade --version <tag>`.
                        """)
                }
            } else {
                print("Already up to date (\(Mootx01.currentVersion)).")
            }
            return
        }

        // Source resolution, mirroring the Rust vertical: --from is the
        // local developer path; the default is the verified remote download
        // (MOOT-INSTALL-E fix 3a — ReleaseDownloader's SHA-256 + independent
        // checksums.txt authentication + tarball member validation, the
        // machinery ReleaseDownloaderTests covers).
        let sourcePath: String
        var downloadTmpDir: URL?
        let isRemoteDownload: Bool
        if from != nil {
            sourcePath = try resolveSource(cwd: cwd)
            isRemoteDownload = false
        } else if let pinned = version ?? ProcessInfo.processInfo.environment["MOOTX01_VERSION"],
                  !pinned.trimmingCharacters(in: .whitespaces).isEmpty {
            // Pinned tag: skip release-feed resolution entirely. This is the
            // only path that can reach a prerelease, because /releases/latest
            // never lists one.
            let tag = pinned.trimmingCharacters(in: .whitespaces)
            print("Installing pinned release \(tag) (current: \(Mootx01.currentVersion)).")
            // A pin is also a downgrade vector, so confirm when the target is
            // not newer than what is installed. --yes still skips it, matching
            // the ordinary download gate.
            if !yes, !ReleaseDownloader.isVersion(
                tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                newerThan: Mootx01.currentVersion) {
                print("""
                    \(tag) is not newer than the installed \(Mootx01.currentVersion) — \
                    this will REPLACE your binary with an older or equal build.
                    """)
                print("Install \(tag) anyway? Type 'yes' to confirm: ", terminator: "")
                guard readLine()?.trimmingCharacters(in: .whitespaces) == "yes" else {
                    print("Aborted.")
                    throw ExitCode.failure
                }
            } else if !yes {
                print("Download and install \(tag)? Type 'yes' to confirm: ", terminator: "")
                guard readLine()?.trimmingCharacters(in: .whitespaces) == "yes" else {
                    print("Aborted.")
                    throw ExitCode.failure
                }
            }
            let binaryURL: URL
            do {
                binaryURL = try await downloader.download(tag: tag)
            } catch {
                // Candidate tags are pruned to the last few by the release
                // pipeline, so a documented beta tag goes 404 after a handful
                // of pushes. Say that, rather than emitting a bare failure.
                print("""
                    Could not download \(tag): \(error)
                    If this is a candidate build, it may have been pruned from the \
                    release feed — candidates are kept only for the most recent few. \
                    Check the available tags on the releases page.
                    """)
                throw ExitCode.failure
            }
            downloadTmpDir = binaryURL.deletingLastPathComponent()
            sourcePath = binaryURL.path
            isRemoteDownload = true
        } else {
            let tag: String?
            do {
                tag = try await downloader.latestTag()
            } catch {
                print("""
                    Cannot reach the release feed (\(error)).
                    For a local build use `mootx01 upgrade --from <path>`.
                    """)
                throw ExitCode.failure
            }
            guard let tag else {
                print("Already up to date (\(Mootx01.currentVersion)).")
                // Bob's ruling: `mootx01 upgrade` is the ONLY migration
                // vehicle, and it converges whether or not a new version is
                // available — so the up-to-date early return still backfills
                // and offers. The backfill may quiesce the daemon, so restore
                // the installed agents before returning, as below.
                await runKGFactIdentityBackfill(home: home)
                restartAgents(home: home)
                offerEstateEncryptionIfNeeded(home: home)
                return
            }
            print("New version available: \(tag) (current: \(Mootx01.currentVersion))")
            // Typed confirmation before replacing the installed binary,
            // skipped by --yes — same gate as the Rust vertical. A non-TTY
            // caller without --yes reads EOF and aborts, never blocks.
            if !yes {
                print("Download and install \(tag)? Type 'yes' to confirm: ", terminator: "")
                guard readLine()?.trimmingCharacters(in: .whitespaces) == "yes" else {
                    print("Aborted.")
                    throw ExitCode.failure
                }
            }
            let binaryURL = try await downloader.download(tag: tag)
            // The tarball unpacks moot-mgr beside mootx01 in the same temp
            // directory, so the existing mgr-sibling pickup below applies to
            // the remote path unchanged.
            downloadTmpDir = binaryURL.deletingLastPathComponent()
            sourcePath = binaryURL.path
            isRemoteDownload = true
        }
        defer {
            if let downloadTmpDir {
                try? FileManager.default.removeItem(at: downloadTmpDir)
            }
        }
        print("Upgrading from: \(sourcePath)")

        let binaryPath: String
        do {
            binaryPath = try Installer.placeBinary(
                sourcePath: sourcePath, homeDirectory: home, force: true)
            print("Installed:      \(binaryPath)")
        } catch {
            print("Could not place binary: \(error)")
            // Same root-owned ~/.local/bin defect the install path explains; an
            // upgrade hits it identically because it also replaces the symlink.
            if let hint = permissionRepairHint(for: error, homeDirectory: home) {
                print(hint)
            }
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
        #if os(macOS)
        if isRemoteDownload {
            applyGatekeeperQuarantine(paths: [binaryPath, MootPaths.installedMgrBinaryURL(homeDirectory: home).path])
        }
        #endif

        // an upgrade alone never touches
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

        // MXE-MI: converge pre-MXE-KH kg_facts rows whose sourceDrawerID
        // holds a host identity, foreign palace key, or triple id into the
        // identity columns those values belong in. Unattended, like the
        // permission-tier migration above — a correctness migration with no
        // user choice in it. Runs BEFORE restartAgents so the restarted
        // daemon hydrates the migrated rows instead of serving the pre-
        // migration shape from RAM until its next restart.
        await runKGFactIdentityBackfill(home: home)

        restartAgents(home: home)
        print("\nUpgrade complete. Run `mootx01 status` to confirm.")

        // The encryption offer runs AFTER the services are back up so a
        // decline leaves a fully converged install, and an accept owns the
        // whole stop → migrate → restart sequence itself.
        offerEstateEncryptionIfNeeded(home: home)
    }

    /// MXE-MI: move pre-MXE-KH `kg_facts.sourceDrawerID` identity values
    /// into the columns MXE-KH created for them (`addedBy`,
    /// `foreignSourceKey`, `foreignRecordID`), via LocusKit's
    /// `KGFactIdentityBackfill`. `mootx01 upgrade` is the ONLY migration
    /// vehicle (Bob's ruling) — this is that vehicle; no detection or
    /// prompting lives anywhere else. Unattended and non-interactive:
    /// unlike the encryption offer (an opt-in posture change), a
    /// correctness migration must also converge launchd/scripted upgrades.
    ///
    /// Failure posture inherits the EstateEncryptionMigrator invariant —
    /// every failure path leaves a working estate at the canonical path.
    /// The backfill's moves are per-row atomic UPDATEs, so a partial run
    /// leaves every row in one of two readable shapes (the palace dedup
    /// anchor serves both) and the next upgrade completes it. The estate
    /// opens through the SUBSTRATE path on purpose: the schema ladder's
    /// v12 → v13 migration is what adds the identity columns to estates
    /// that predate them.
    private func runKGFactIdentityBackfill(home: URL) async {
        #if os(macOS)
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment, homeDirectory: home)
        let estateURL = MootPaths.estateURL(in: dataDir)
        // Absent estate means first run — serve creates new estates
        // post-KH; there is nothing to backfill.
        guard FileManager.default.fileExists(atPath: estateURL.path) else { return }

        // Same key custody as serve's open path: existing key for an
        // encrypted estate, plaintext posture preserved for a plaintext
        // one. Never prompts, never migrates encryption — that is the
        // TTY-gated offer's job, below.
        let encryption: EstateEncryptionConfig
        do {
            encryption = try EstateKeyProvider.resolveOpenPosture(for: estateURL).encryption
        } catch {
            print("  ✗ kg_facts identity backfill skipped — estate key unavailable: \(error)")
            return
        }

        // Quiesce first (single-writer discipline, same direction as the
        // encryption migration): if the daemon will not stop, skip —
        // nothing is half-done, and the next `mootx01 upgrade` retries.
        // restartAgents (the very next step in run()) starts the daemon
        // again over the migrated estate, so there is no start here.
        if LaunchAgent.isDaemonRunning() && !LaunchAgent.stopDaemon() {
            print("  ✗ kg_facts identity backfill skipped — the resident daemon would not stop; run `mootx01 upgrade` again")
            return
        }

        do {
            let configuration = EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: estateURL, busyTimeout: 5.0),
                encryptionConfig: encryption
            )
            let storage = try SQLiteStorage(configuration: configuration)
            // The class-B resolver is VaultKit's stable-source-key hash,
            // injected here because LocusKit sits below VaultKit and must
            // not import it.
            let report = try await KGFactIdentityBackfill.run(
                storage: storage,
                resolveForeignKey: DrawerMapping.lineageID(forStableSourceKey:))
            await storage.close()
            if report.scanned == 0 {
                print("  ✓ kg_facts identity columns: nothing to backfill")
            } else {
                print("""
                      ✓ kg_facts identity backfill: \(report.scanned) scanned — \
                    addedBy \(report.hostIdentities), foreignSourceKey \(report.foreignPalaceKeys), \
                    foreignRecordID \(report.tripleIDs), local anchors kept \(report.localDrawerIDs) \
                    (sensitivity inherited \(report.inheritanceApplied)), unclassified \(report.unclassified)
                    """)
            }
        } catch {
            print("""
                  ✗ kg_facts identity backfill failed: \(error)
                    Every row remains findable in its current shape. Run `mootx01 upgrade` to retry.
                """)
        }
        #endif
    }

    /// CE-1.0.35-08: offer to encrypt an unencrypted default estate.
    ///
    /// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling): no
    /// detection or prompting lives anywhere else — not serve, not install,
    /// not the App, not an MCP tool. The offer is macOS-only (Linux/Windows
    /// ship the Rust binary and are already encrypted) and TTY-gated: a
    /// non-interactive invocation (launchd, scripts, piped stdin) never
    /// prompts and never migrates. Declining is a clean no-op; users who
    /// stay unencrypted are assumed to have chosen that.
    private func offerEstateEncryptionIfNeeded(home: URL) {
        #if os(macOS)
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment, homeDirectory: home)
        let estateURL = MootPaths.estateURL(in: dataDir)

        // Only a readable plaintext estate qualifies. Absent means first run
        // (serve creates new estates encrypted); ciphertext means done.
        guard EstateKeyProvider.detectEstateFileState(at: estateURL) == .plaintext else { return }

        // Non-TTY invocations skip the offer silently and never migrate.
        guard isatty(fileno(stdin)) == 1 else { return }

        print("""

            Your memory estate at \(estateURL.path)
            is not encrypted at rest. mootx01 can encrypt it now: the estate is
            cloned into an encrypted copy, verified row-for-row, and swapped in
            at the same path. Your original is moved to the Trash afterwards.
            """)
        print("Encrypt the estate now? Type 'yes' to proceed: ", terminator: "")
        guard readLine()?.trimmingCharacters(in: .whitespaces) == "yes" else {
            print("Leaving the estate as it is. Run `mootx01 upgrade` again any time to encrypt it.")
            return
        }

        runEstateEncryptionMigration(estateURL: estateURL, home: home)
        #endif
    }

    #if os(macOS)
    /// Drive the accepted migration: provision the key, then clone → verify
    /// → swap → trash through EstateEncryptionMigrator. Every failure path
    /// leaves the plaintext original working at the canonical path; the
    /// messages below say which side of the swap the user is on.
    private func runEstateEncryptionMigration(estateURL: URL, home: URL) {
        let key: Data
        do {
            // EstateKeyProvider owns key custody: returns the existing key
            // for this estate or mints one in the Keychain. On failure
            // nothing has been touched.
            key = try EstateKeyProvider.provideKey(for: estateURL)
        } catch {
            print("""
                Could not provision an encryption key (\(error)).
                Nothing was changed; the estate is untouched.
                """)
            return
        }

        print("Encrypting the estate\u{2026}")
        do {
            let result = try EstateEncryptionMigrator.migrate(
                estateURL: estateURL,
                key: key,
                daemon: .launchd(homeDirectory: home))
            print("  \u{2713} Estate encrypted in place at \(estateURL.path)")
            print("  \u{2713} Verified: \(result.counts)")
            if result.swap.daemonWasRunning {
                if result.swap.daemonRestarted {
                    print("  \u{2713} Daemon restarted over the encrypted estate.")
                } else {
                    print("""
                          \u{2717} The daemon did not restart cleanly. Restart it manually:
                            launchctl kickstart -k gui/$(id -u)/com.mootx01.daemon
                        """)
                }
            }
            if let untrashed = result.swap.untrashedOriginalPath {
                print("""
                      \u{2717} The plaintext original could not be moved to the Trash.
                        It is STILL UNENCRYPTED at: \(untrashed)
                        Delete it yourself to finish the migration.
                    """)
            } else {
                print("""
                      \u{2713} Your original estate was moved to the Trash. That copy is
                        STILL UNENCRYPTED \u{2014} emptying the Trash is the final step
                        of this migration, not optional cleanup.
                    """)
            }
        } catch {
            print("""
                Migration failed: \(error)
                Your estate is still the plaintext original at \(estateURL.path) and
                remains fully usable. Run `mootx01 upgrade` to try again.
                """)
        }
    }
    #endif

    /// See the call site's doc comment. The gating (which hosts qualify —
    /// plugin-capable AND already has a plugin directory on disk) lives in
    /// `DepthInstaller.hostsWithExistingPluginDirectory`, directly unit-
    /// tested from `MootInstallerCoreTests` (Adams wave-3 coverage finding).
    /// This loop reruns `DepthInstaller.apply(depth: .plugin, ...)` for each
    /// gated host so the on-disk package (and, for Claude Code, the plugin
    /// cache) converge on whatever the CURRENT embedded bundle carries, and
    /// prints the per-host CLI result. `vaultOff` is not tracked across
    /// upgrades — passing `false` here is safe regardless: every
    /// plugin-capable host's package is HTTP-shaped today, so
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

    #if os(macOS)
    /// The Swift remote upgrade path downloads and extracts with URLSession/tar,
    /// which does not mark files as internet downloads. Restore the shell
    /// installer's trust split by setting com.apple.quarantine on remotely
    /// installed binaries so Gatekeeper assesses Developer ID/notarization on
    /// first launch. This is best-effort, matching install.sh's non-fatal xattr
    /// behavior.
    private func applyGatekeeperQuarantine(paths: [String]) {
        let qts = String(Int(Date().timeIntervalSince1970), radix: 16)
        let qval = "0083;\(qts);mootx01-upgrade;"
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            process.arguments = ["-w", "com.apple.quarantine", qval, path]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    print("Quarantine xattr set on \(path) (Gatekeeper will assess on first run)")
                } else {
                    print("Note: could not set quarantine xattr on \(path) — Gatekeeper assessment skipped (non-fatal)")
                }
            } catch {
                print("Note: xattr not found — skipping Gatekeeper quarantine tagging (non-fatal)")
                return
            }
        }
    }
    #endif

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

    /// Validate the explicit `--from` path. The old bare-invocation search
    /// of `.build/release` / `.build/debug` is gone: a bare `mootx01
    /// upgrade` now takes the verified remote path (matching the Rust
    /// vertical), and developers name their build explicitly with `--from`.
    private func resolveSource(cwd: URL) throws -> String {
        guard let explicit = from else {
            throw ValidationError("resolveSource requires --from (remote path handles the default)")
        }
        let url = URL(fileURLWithPath: explicit, relativeTo: cwd).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ValidationError("Binary not found or not executable: \(url.path)")
        }
        return url.path
    }
}
