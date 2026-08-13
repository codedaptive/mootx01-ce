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
import GeniusLocusKit
import GeniusLocusKitMigrations
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

    /// Internal: run ONLY the post-install convergence steps, skipping the
    /// download and the binary placement.
    ///
    /// `mootx01 upgrade` re-executes the binary it just installed with this flag
    /// so the convergence steps run the NEW code. Without it every post-install
    /// step — plugin rematerialization, permission tiering, the kg_facts
    /// backfill, and the shared-content reclaim — executed in the ALREADY-RUNNING
    /// image, i.e. the version being replaced. A fix to any of them could never
    /// apply on the run that installed it, so operators had to run
    /// `mootx01 upgrade` twice; worse, the messages they read came from the old
    /// binary, which is how a beta shipped a corrected reclaim message and still
    /// printed the stale one.
    ///
    /// Hidden because it is not an operator-facing mode: running it by hand
    /// converges against whatever binary is currently installed, which the plain
    /// `mootx01 upgrade` no-op path already does.
    @Flag(name: .customLong("converge-only"), help: .hidden)
    var convergeOnly: Bool = false

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

        // --converge-only: we ARE the freshly installed binary, re-executed by the
        // upgrade that placed us. Run the convergence steps and nothing else.
        if convergeOnly {
            await runConvergence(
                home: home,
                binaryPath: MootPaths.installedBinaryURL(homeDirectory: home).path)
            return
        }

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
                // No new binary was placed, so there is no newer code to
                // re-execute into and converging in THIS image is correct.
                // Full plugin rematerialization and permission tiering are
                // skipped here — those converge the install onto a NEW binary's
                // shape and are handled by the binary-placement paths.
                // Plugin manifest cache refresh IS included: a prior upgrade
                // may have placed a new binary but left the Claude Code plugin
                // cache stale (version_skew advisory firing on every ping).
                await runKGFactIdentityBackfill(home: home)
                await runSharedContentReclaimIfPending(home: home)
                updatePluginManifestIfNeeded(home: home)
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
            if let hint = Installer.permissionRepairHint(for: error, homeDirectory: home) {
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
        // Gatekeeper quarantine is applied AFTER convergence, not here — see the
        // re-exec comment below.

        // Targeted plugin manifest cache refresh before the main convergence.
        // Covers the case where the binary being replaced already had a stale
        // plugin cache (version_skew advisory firing before this upgrade);
        // updatePluginManifestIfNeeded is a no-op when the cache is current.
        // The main convergence below also rematerializes the full plugin package
        // for the newly placed binary, so this is an additive safety step only.
        updatePluginManifestIfNeeded(home: home)
        // Convergence runs in the binary we JUST INSTALLED, not in this image.
        // Re-execute the new binary with --converge-only and let it do the work;
        // otherwise every step below would run the version being replaced (see
        // the --converge-only flag comment).
        //
        // This happens BEFORE the Gatekeeper quarantine tag is applied on
        // purpose: executing a freshly quarantined binary makes the kernel hold
        // it pre-`main` for assessment, which on an interactive machine surfaces
        // an "app downloaded from the Internet" dialog and blocks until someone
        // clicks. Tagging after the child exits keeps the assessment where it
        // belongs — the operator's next run — and keeps the upgrade unattended.
        let converged = await runConvergenceInNewBinary(
            binaryPath: binaryPath, home: home)
        if !converged {
            // The new binary could not be executed, or exited non-zero. Fall
            // back to converging in THIS image: the pre-existing behaviour, so a
            // failed re-exec never leaves an upgrade less converged than before.
            print("Note: converging with the previous binary — the installed one could not run.")
            await runConvergence(home: home, binaryPath: binaryPath)
        }

        #if os(macOS)
        if isRemoteDownload {
            applyGatekeeperQuarantine(paths: [
                binaryPath,
                MootPaths.installedMgrBinaryURL(homeDirectory: home).path,
            ])
        }
        #endif

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

    /// P5 of the shared-content 1.0→1.1 migration: WAL checkpoint + VACUUM
    /// for any estate stranded in the `reclaimPending` state — typically
    /// because a previous `mootx01 upgrade` was interrupted before physical
    /// reclamation completed. Idempotent: estates already at `complete` (or
    /// not yet migrated) are silently skipped. Retryable on failure.
    ///
    /// Opens the estate through GeniusLocusKit rather than raw storage because
    /// `completeSharedContentReclaim` accesses the estate via the GLK
    /// migration-host seam, which requires an open GLK handle.
    private func runSharedContentReclaimIfPending(home: URL) async {
        #if os(macOS)
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment, homeDirectory: home)
        let estateURL = MootPaths.estateURL(in: dataDir)
        // Absent estate means first run — serve creates new estates
        // post-cutover; there is nothing to reclaim.
        guard FileManager.default.fileExists(atPath: estateURL.path) else { return }

        // Same key custody as serve's open path: existing key for an
        // encrypted estate, plaintext posture preserved for a plaintext one.
        let encryption: EstateEncryptionConfig
        do {
            encryption = try EstateKeyProvider.resolveOpenPosture(for: estateURL).encryption
        } catch {
            print("  ✗ shared-content reclaim skipped — estate key unavailable: \(error)")
            return
        }

        // Quiesce before VACUUM (single-writer discipline). The daemon is
        // restarted by restartAgents(), the very next step in run().
        if LaunchAgent.isDaemonRunning() && !LaunchAgent.stopDaemon() {
            print("  ✗ shared-content reclaim skipped — the resident daemon would not stop; run `mootx01 upgrade` again")
            return
        }

        do {
            let configuration = EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: estateURL, busyTimeout: 5.0),
                encryptionConfig: encryption
            )
            let storage = try SQLiteStorage(configuration: configuration)
            let kit = GeniusLocusKit()
            // The upgrade tool is not the estate's real owner; the substrate
            // validates only that ownerIdentifier is non-empty, so this
            // sentinel is sufficient.
            let owner = OwnerCredentials(ownerIdentifier: "mootx01-upgrade")
            // Durable estate: pass nil so LocusKit resolves the backend default
            // (SQLite -> KeychainEstateIdentityKeyStore). Injecting an in-memory
            // store here lets Estate.open mint an Ed25519 keypair, persist only
            // the public half to the manifest, and drop the private half at
            // process exit -- permanently disabling grant/federation signing for
            // any estate whose identity had not yet been established.
            let handle = try await kit.open(
                storage: storage,
                owner: owner,
                identityKeyStore: nil
            )
            let report = try await kit.completeSharedContentReclaim(
                handle: handle, now: Date())
            try await kit.close(handle)
            if let report {
                if report.reclaimedBytes > 0 {
                    print("  ✓ shared-content reclaim: \(report.reclaimedBytes) bytes returned to filesystem")
                } else {
                    print("  ✓ shared-content reclaim: complete (maintenance ran, no pages to reclaim)")
                }
            } else {
                print("  ✓ shared-content reclaim: not pending")
            }
        } catch let err as StorageMaintenanceError {
            // The inventory trim committed before performMaintenance ran — the
            // estate IS affected: legacyVectorKeys are cleared, the freelist has
            // grown, but the freed pages are not yet returned to the filesystem.
            // State remains reclaimPending, so the next `mootx01 upgrade` retries.
            print("""
                  ✗ shared-content reclaim: VACUUM failed — \(err)
                    The inventory trim completed (legacy vector keys cleared).
                    Freed pages are on the freelist and not yet returned to the filesystem.
                    Run `mootx01 upgrade` again to retry the VACUUM.
                """)
        } catch {
            // Failure before completeSharedContentReclaim commits the trim —
            // estate state is unchanged.
            print("""
                  ✗ shared-content reclaim failed: \(error)
                    The estate is unaffected. Run `mootx01 upgrade` to retry.
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

    /// Refresh the Claude Code plugin cache if the installed plugin version lags the
    /// current binary version. This targets the case where a prior upgrade placed a
    /// new binary but left the Claude Code plugin cache stale — causing the
    /// version_skew advisory to fire on every estate ping until the cache is refreshed.
    ///
    /// The plugin ID "mootx01@mootx01" is the Claude Code plugin namespace used in
    /// installed_plugins.json; it is distinct from the MCP server name. The check
    /// reads installedVersion from installed_plugins.json; nil means the plugin is
    /// not registered in any Claude Code client — silently skipped.
    ///
    /// Non-fatal: the upgrade continues if the refresh fails (same posture as the
    /// other convergence steps). Hosts with no plugin directory on disk are silently
    /// skipped — never creates a plugin-depth install for a host that never had one.
    ///
    /// Testing: direct unit tests are architecturally infeasible — `PluginDetector`,
    /// `DepthInstaller`, and `MootPaths` are all static with no injectable seams,
    /// matching the constraint that applies to every other private helper in this
    /// command class. The three helper functions this method calls are independently
    /// covered in MootInstallerCoreTests (InstallDepthTests, PluginDedupeTests).
    private func updatePluginManifestIfNeeded(home: URL) {
        let pluginVersion = PluginDetector.installedVersion(
            pluginID: "mootx01@mootx01", homeDirectory: home)
        guard let pluginVersion else { return }
        guard pluginVersion != Mootx01.currentVersion else {
            print("  ✓ plugin manifest: already current (\(Mootx01.currentVersion))")
            return
        }
        let binaryPath = MootPaths.installedBinaryURL(homeDirectory: home).path
        for host in DepthInstaller.hostsWithExistingPluginDirectory(homeDirectory: home) {
            do {
                _ = try DepthInstaller.apply(
                    clientID: host.id, depth: .plugin, homeDirectory: home, binaryPath: binaryPath
                )
                print("  ✓ \(host.displayName): plugin manifest updated to \(Mootx01.currentVersion)")
            } catch {
                print("  ✗ \(host.displayName): could not update plugin manifest (non-fatal): \(error)")
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
    /// The post-install convergence sequence, in order.
    ///
    /// Extracted so it has exactly one definition shared by two callers: the
    /// re-executed `--converge-only` pass (the normal route) and the fallback
    /// when that re-exec cannot run. The "already up to date" path runs a
    /// deliberately narrower sequence — see the comment there.
    ///
    /// Ordering is load-bearing: the kg_facts backfill and the shared-content
    /// reclaim both need a quiesced estate and run BEFORE `restartAgents`, so the
    /// restarted daemon hydrates migrated rows rather than serving the
    /// pre-migration shape from RAM until its next restart.
    private func runConvergence(home: URL, binaryPath: String) async {
        rematerializePluginDepth(home: home, binaryPath: binaryPath)
        migratePermissionTiers(home: home)
        removeRedundantCodexDirectEntry(home: home)
        await runKGFactIdentityBackfill(home: home)
        await runSharedContentReclaimIfPending(home: home)
        restartAgents(home: home)
    }

    /// Re-execute the freshly installed binary to run `runConvergence` in the NEW
    /// code. Returns false when the child could not be launched or exited
    /// non-zero, so the caller can fall back to converging in this image.
    ///
    /// stdout/stderr are inherited, so the child's progress lines appear inline
    /// and the operator sees one continuous upgrade transcript. `--yes` is passed
    /// because the convergence pass must never wait on a prompt; `--no-restart`
    /// is forwarded so the flag keeps its meaning across the boundary.
    private func runConvergenceInNewBinary(binaryPath: String, home: URL) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else { return false }
        var arguments = ["upgrade", "--converge-only", "--yes"]
        if noRestart { arguments.append("--no-restart") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        // A child that inherits this process's environment inherits
        // MOOTX01_DATA_DIR too, so a redirected data directory keeps applying
        // across the re-exec.
        process.environment = ProcessInfo.processInfo.environment
        // Flush before handing the fd to the child. `print` writes to a
        // block-buffered stdout whenever it is not a TTY (a redirect, a log file,
        // CI), so the parent's "Installed: ..." lines would otherwise sit in this
        // process's buffer until exit and land AFTER the child's output —
        // producing a transcript that reads as though convergence happened before
        // the install. The child writes to the inherited descriptor directly.
        fflush(stdout)
        do {
            try process.run()
        } catch {
            print("Note: could not execute the installed binary (\(error)).")
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            print("Note: the installed binary exited \(process.terminationStatus) during convergence.")
            return false
        }
        return true
    }

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

    /// Remove the redundant direct `[mcp_servers.mootx01]` entry from
    /// `~/.codex/config.toml` when the MOOT Codex plugin owns the MCP
    /// connection. Both the plugin and the direct installer now use the same
    /// `"mootx01"` server key, so a user who had both wired ends up with two
    /// connections to the same estate. This step collapses them to one.
    ///
    /// Guard: `PluginDetector.ownsCodexConnection` must return `true` before
    /// any write happens — the plugin is installed and enabled, so removing
    /// the direct entry leaves the plugin wiring as the sole connection.
    ///
    /// Backup: copies the file to `config.toml.mootx01-backup` before
    /// modification so the user can restore if needed.
    ///
    /// Idempotent: if `[mcp_servers.mootx01]` is absent the function prints
    /// nothing and returns without touching the file.
    private func removeRedundantCodexDirectEntry(home: URL) {
        let pluginID = "mootx01@mootx01"
        guard PluginDetector.ownsCodexConnection(pluginID: pluginID, homeDirectory: home) else {
            return
        }
        let configURL = home.appendingPathComponent(".codex/config.toml")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return }
        // Quick scan: is [mcp_servers.mootx01] even present?
        let header = "[mcp_servers.mootx01]"
        guard text.components(separatedBy: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == header
        }) else { return }

        // Backup before modification.
        let backupURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("config.toml.mootx01-backup")
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: configURL, to: backupURL)
        } catch {
            print("  \u{2717} Could not back up Codex config: \(error) — skipping cleanup")
            return
        }

        do {
            try Installer.removeFromTOMLConfig(at: configURL, serverName: "mootx01")
            print("  \u{2713} Removed redundant direct MCP entry from Codex config (plugin owns connection).")
        } catch {
            print("  \u{2717} Could not clean up Codex config: \(error)")
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
