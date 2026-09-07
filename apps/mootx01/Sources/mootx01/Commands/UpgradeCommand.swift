// UpgradeCommand.swift
//
// Replace the installed mootx01 binary with a newer release, then restart
// both background agents. Two sources, mirroring the Rust vertical
// (rust/src/commands/upgrade.rs):
//
//   Remote (default): fetch the latest GitHub release via ReleaseDownloader
//   (SHA-256 + minisign signature verification on every platform +
//   tarball-member validation — all inside download(), before anything is
//   extracted, placed, or executed), confirm unless --yes, place, and run the
//   convergence steps (plugin rematerialization, permission-tier migration,
//   service restart).
//
//   Local (--from <path>): the developer workflow — copies a freshly built
//   binary from an explicit path (e.g. --from .build/release/mootx01).
//
// Use --check to query the latest release without downloading.

import AriaMCP
import ArgumentParser
import CorpusKit
import CorpusKitProviders
import Foundation
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import MootInstallerCore
import PersistenceKit
import PersistenceKitSQLite
import SynapseKit
import VaultKit

struct UpgradeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upgrade",
        abstract: "Upgrade mootx01 to the latest release (or from a local build).",
        discussion: """
            Without flags, upgrade downloads the latest release (SHA-256
            verified, with checksums.txt authenticated by minisign before
            anything is installed or executed), installs it, converges plugin
            packages and tool permissions, and restarts the background
            services.

            Use --from to install a local build instead of downloading:
              mootx01 upgrade --from .build/release/mootx01

            Use --check to print the latest available version without downloading:
              mootx01 upgrade --check

            Use --backfill-only to run only the data-directory migration steps
            (schema 10 → 19, kg_facts identity, shared-content reclaim, whole-record
            vacuum, ssc facts, dense pooling convergence, span encode, vector reclaim)
            against the estate resolved via MOOTX01_DATA_DIR, then exit. No network,
            no download, no plugin convergence, no encryption offer, no restartAgents
            cycle — each step quiesces and restores the daemon itself when the
            estate is the resident one, and leaves it running otherwise:
              mootx01 upgrade --backfill-only
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

    /// Run ONLY the data-directory migration steps: schema 10 → 19, kg_facts
    /// identity, shared-content reclaim, whole-record vacuum, ssc facts, dense
    /// pooling convergence, span encode, and vector reclaim. Intended for
    /// scripted and benchmark
    /// estates where the caller owns the estate via MOOTX01_DATA_DIR. No
    /// network, no download, no plugin convergence, no encryption offer, no
    /// restartAgents cycle. Each step handles its own daemon quiesce and
    /// restore so the caller need not manage service state, and quiesces only
    /// when the estate is the resident one (`MootPaths.isResidentEstate`); a
    /// cloned estate is upgraded with the daemon left running.
    ///
    /// Ordering matches `runConvergence`: the schema step first (it decides
    /// whether the estate is one this build upgrades at all; a refusal stops
    /// the sequence before any other step can open the schema), kg_facts
    /// identity second (correctness migration), shared-content reclaim third
    /// (VACUUM-backed, most I/O), whole-record vacuum fourth (the first estate
    /// open of the sequence, so the 1.6 to 1.7 capsule runs and reports here),
    /// ssc facts fifth, dense pooling convergence sixth (retrains stale-format
    /// provider bases before any other step opens the corpus), span encode
    /// seventh (needs the registry row and the corpus wired), vector reclaim
    /// last (deletes what nothing serves any more).
    @Flag(
        name: .customLong("backfill-only"),
        help: "Run only the data-directory migration steps (schema 10 → 19, kg_facts identity, shared-content reclaim, whole-record vacuum, ssc facts, dense pooling convergence, span encode, vector reclaim) then exit. No network, no download, no plugin convergence, no encryption offer, no restartAgents cycle — each step quiesces and restores the daemon itself when the estate is the resident one. Exits non-zero if any step fails; a refused schema version stops the sequence before any other step runs.")
    var backfillOnly = false

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

        // --backfill-only: headless data-dir convergence for scripted and
        // benchmark estates. Runs only the eight data-directory migration
        // steps (schema 10 → 19, kg_facts identity, shared-content reclaim,
        // whole-record vacuum, ssc facts, dense pooling convergence, span
        // encode, vector reclaim) against the estate resolved via
        // MOOTX01_DATA_DIR. No network, no download, no plugin
        // convergence, no encryption offer, no restartAgents cycle. Each step
        // owns its daemon quiesce+restore through ResidentDaemonQuiesce, which
        // touches the daemon only for the resident estate. A refused schema
        // version stops the sequence (every later step would open the schema
        // and stamp it); otherwise failures aggregate and exit non-zero,
        // matching the Rust `--backfill-only` contract.
        if backfillOnly {
            guard await runSchemaUpgrade(home: home) else { throw ExitCode.failure }
            let okKG     = await runKGFactIdentityBackfill(home: home)
            let okRecl   = await runSharedContentReclaimIfPending(home: home)
            let okVacuum = await runWholeRecordVacuum(home: home)
            let okFacts  = await runSSCFactsBackfill(home: home)
            let okDense  = await runDensePoolingConvergence(home: home)
            let okSpan   = await runSpanEncodeBackfill(home: home)
            let okVec    = await runVectorReclaim(home: home)
            guard okKG && okRecl && okVacuum && okFacts && okDense && okSpan && okVec else { throw ExitCode.failure }
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
        // local developer path (an explicit operator choice, exempt from the
        // release-signature gate); the default is the verified remote download
        // (MOOT-INSTALL-E fix 3a — ReleaseDownloader's SHA-256 + minisign
        // authentication of checksums.txt on every platform + tarball member
        // validation, all gating inside download() itself, the machinery
        // ReleaseDownloaderTests covers).
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
                if await runSchemaUpgrade(home: home) {
                    await runKGFactIdentityBackfill(home: home)
                    await runSharedContentReclaimIfPending(home: home)
                    await runWholeRecordVacuum(home: home)
                    await runSSCFactsBackfill(home: home)
                    await runDensePoolingConvergence(home: home)
                    await runSpanEncodeBackfill(home: home)
                    _ = await runVectorReclaim(home: home)
                }
                updatePluginManifestIfNeeded(home: home)
                convergeDaemonBundle(home: home)
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
        // Security ordering (UP-01): the binary executed here has already passed
        // the minisign Ed25519 verification gate inside download() — no remote
        // artifact reaches this line unverified. The Gatekeeper quarantine tag
        // is still applied only AFTER this re-exec, on purpose: executing a
        // freshly quarantined binary makes the kernel hold it pre-`main` for
        // assessment, which on an interactive machine surfaces an "app
        // downloaded from the Internet" dialog and blocks until someone clicks.
        // Tagging after the child exits keeps the upgrade unattended; the tag is
        // defense-in-depth for the operator's next run, not the verification
        // gate — the minisign check is the gate.
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

    /// Schema 10 → 19 (ENCODER_RERANK_CONTRACT §12): the one product schema
    /// migration. Reads the LocusKit ledger row RAW, before any schema open,
    /// and decides with `LocusKitSchema.upgradePath(storedVersion:)`:
    /// 10 (CE 1.0.35/1.0.37) → open the LocusKit schema, which applies the
    /// single v10 → v19 hop; 19 → nothing; no row → fresh; anything else →
    /// REFUSE, naming the version found, and return false so the caller
    /// skips every later step. The refusal must come first because
    /// PersistenceKit's runner stamps the declared version whenever no
    /// ladder entry matches: any later step's open would mark an estate at
    /// 11–18 as 19 with none of the v19 objects in place. Pre-release development
    /// estates at 18 are moved by the surgery script, never by this command.
    ///
    /// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling).
    /// Returns `true` when the estate is at 19 afterwards (or absent).
    @discardableResult
    private func runSchemaUpgrade(home: URL) async -> Bool {
        #if os(macOS)
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment, homeDirectory: home)
        let estateURL = MootPaths.estateURL(in: dataDir)
        // Absent estate means first run — serve creates new estates at 19.
        guard FileManager.default.fileExists(atPath: estateURL.path) else { return true }
        let encryption: EstateEncryptionConfig
        do {
            encryption = try EstateKeyProvider.resolveOpenPosture(for: estateURL).encryption
        } catch {
            print("  ✗ schema upgrade skipped — estate key unavailable: \(error)")
            return false
        }
        return await ResidentDaemonQuiesce.run(
            dataDirectory: dataDir,
            residentDataDirectory: MootPaths.residentDataDirectory(homeDirectory: home),
            step: "schema upgrade",
            daemon: .launchd(homeDirectory: home)
        ) { () async -> Bool in
            do {
                let configuration = EstateConfiguration(
                    estateID: UUID(),
                    backend: .sqlite(url: estateURL, busyTimeout: 5.0),
                    encryptionConfig: encryption
                )
                let storage = try SQLiteStorage(configuration: configuration)
                // The ledger row, read before any schema open (see the doc comment).
                let stored = try await storage.currentSchemaVersion(for: LocusKitSchema.kitID)
                switch LocusKitSchema.upgradePath(storedVersion: stored) {
                case .unsupported(let found):
                    print("""
                          ✗ schema upgrade refused: this estate is at LocusKit schema \(found).
                            This build upgrades schema \(LocusKitSchema.supportedUpgradeFloor) (CE 1.0.35/1.0.37) and serves schema \(LocusKitSchema.version); nothing was changed.
                            A pre-release development estate at 11–18 is moved to 19 by the schema surgery script, not by this build; a newer estate needs a newer build.
                        """)
                    await storage.close()
                    return false
                case .current:
                    print("  ✓ schema: already at LocusKit schema \(LocusKitSchema.version)")
                case .fresh:
                    print("  ✓ schema: no LocusKit ledger row; schema \(LocusKitSchema.version) is created on the first open")
                case .upgrade(let from):
                    try await storage.open(schema: LocusKitSchema.schema)
                    let after = try await storage.currentSchemaVersion(for: LocusKitSchema.kitID)
                    guard after == LocusKitSchema.version else {
                        print("  ✗ schema upgrade: expected LocusKit schema \(LocusKitSchema.version) after the hop, found \(after). Run `mootx01 upgrade` to retry.")
                        await storage.close()
                        return false
                    }
                    print("  ✓ schema: LocusKit \(from) → \(after) (encoder_models, ssc_facts, subject trio, kg_facts identity trio, operationalAND, idx_drawers_filedAt, recall_trace attribution)")
                }
                await storage.close()
                return true
            } catch {
                print("""
                      ✗ schema upgrade failed: \(error)
                        Nothing was changed. Run `mootx01 upgrade` to retry.
                    """)
                return false
            }
        } ?? false
        #else
        return true
        #endif
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
    /// Returns `true` on success or when there is nothing to backfill, `false` on failure.
    @discardableResult
    private func runKGFactIdentityBackfill(home: URL) async -> Bool {
        #if os(macOS)
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment, homeDirectory: home)
        let estateURL = MootPaths.estateURL(in: dataDir)
        // Absent estate means first run — serve creates new estates
        // post-KH; there is nothing to backfill.
        guard FileManager.default.fileExists(atPath: estateURL.path) else { return true }

        // Same key custody as serve's open path: existing key for an
        // encrypted estate, plaintext posture preserved for a plaintext
        // one. Never prompts, never migrates encryption — that is the
        // TTY-gated offer's job, below.
        let encryption: EstateEncryptionConfig
        do {
            encryption = try EstateKeyProvider.resolveOpenPosture(for: estateURL).encryption
        } catch {
            print("  ✗ kg_facts identity backfill skipped — estate key unavailable: \(error)")
            return false
        }

        // Single-writer discipline: the resident daemon is stopped around
        // the work only when this is its estate (ResidentDaemonQuiesce
        // prints why when it is not). A nil result means the daemon would
        // not stop; the step is skipped and the next upgrade retries.
        return await ResidentDaemonQuiesce.run(
            dataDirectory: dataDir,
            residentDataDirectory: MootPaths.residentDataDirectory(homeDirectory: home),
            step: "kg_facts identity backfill",
            daemon: .launchd(homeDirectory: home)
        ) { () async -> Bool in
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
                return true
            } catch {
                print("""
                      ✗ kg_facts identity backfill failed: \(error)
                        Every row remains findable in its current shape. Run `mootx01 upgrade` to retry.
                    """)
                return false
            }
        } ?? false
        #else
        return true
        #endif
    }

    /// Bring the trainable provider bases a populated estate carries
    /// (random-indexing in every build; PPMI, NMF and FDC only in a
    /// DenseFamilies build; LSA only under its own switch)
    /// onto the basis format this binary's codec writes. A basis row persisted
    /// under an earlier format version holds vectors pooled the old way; the
    /// corpus opens such a slot untrained and its open-time provider reconcile
    /// retrains it from the estate's content and re-embeds every row. This step
    /// runs that rebuild here, under the daemon quiesce, so it happens at
    /// upgrade time and is reported, rather than on the next serve open.
    ///
    /// Eligibility is a raw read of `corpus_provider_basis`: any part-0 row
    /// whose frame version byte differs from `basisFormatVersion`. An estate
    /// with no such table (it never held a trained basis) or with every row
    /// current is skipped. Idempotent: after one pass every row carries the
    /// current version and the step is a no-op. Runs BEFORE the span-encode
    /// step so that step's open does not absorb the rebuild unreported.
    ///
    /// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling).
    /// Returns `true` on success or when there is nothing to converge, `false` on failure.
    @discardableResult
    private func runDensePoolingConvergence(home: URL) async -> Bool {
        #if os(macOS)
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment, homeDirectory: home)
        let estateURL = MootPaths.estateURL(in: dataDir)
        guard FileManager.default.fileExists(atPath: estateURL.path) else { return true }
        let encryption: EstateEncryptionConfig
        do {
            encryption = try EstateKeyProvider.resolveOpenPosture(for: estateURL).encryption
        } catch {
            print("  ✗ dense pooling convergence skipped — estate key unavailable: \(error)")
            return false
        }
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0),
            encryptionConfig: encryption
        )
        // Eligibility: a single read of the basis frames, before any quiesce.
        let stale: [String]
        do {
            let storage = try SQLiteStorage(configuration: configuration)
            stale = try await Self.staleFormatBasisProviders(storage: storage)
            await storage.close()
        } catch {
            print("""
                  ✗ dense pooling convergence: could not read corpus_provider_basis: \(error)
                    Run `mootx01 upgrade` to retry.
                """)
            return false
        }
        if stale.isEmpty {
            print("  ✓ dense pooling: provider bases already at basis format v\(basisFormatVersion)")
            return true
        }
        // Single-writer discipline: the resident daemon is stopped around
        // the work only when this is its estate (ResidentDaemonQuiesce
        // prints why when it is not). A nil result means the daemon would
        // not stop; the step is skipped and the next upgrade retries.
        return await ResidentDaemonQuiesce.run(
            dataDirectory: dataDir,
            residentDataDirectory: MootPaths.residentDataDirectory(homeDirectory: home),
            step: "dense pooling convergence",
            daemon: .launchd(homeDirectory: home)
        ) { () async -> Bool in
            do {
                let storage = try SQLiteStorage(configuration: configuration)
                let owner = OwnerCredentials(ownerIdentifier: MootPaths.defaultOwnerIdentifier)
                let kit = GeniusLocusKit()
                // MOOTX01_ESTATE_LIFETIME=ephemeral is the declared throwaway
                // posture (benchmark and scripted estates): identity keys stay
                // in memory and the Keychain is never consulted, so a headless
                // run cannot stall on a Keychain consent dialog. Same rule as
                // `serve` and the shared-content reclaim step.
                let upgradeLifetimeIsEphemeral =
                    (ProcessInfo.processInfo.environment["MOOTX01_ESTATE_LIFETIME"] ?? "")
                        .lowercased() == "ephemeral"
                let handle = try await kit.open(
                    storage: storage,
                    owner: owner,
                    identityKeyStore: upgradeLifetimeIsEphemeral
                        ? InMemoryEstateIdentityKeyStore() : nil
                )
                _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: Date())
                // Wiring the corpus runs the open-time provider reconcile: every
                // slot whose persisted basis was refused for format skew opens
                // untrained, retrains from the estate's content, and re-covers
                // every row under the new basis before the wire returns.
                try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
                try await kit.close(handle)
                let remaining = try await Self.staleFormatBasisProviders(storage: storage)
                await storage.close()
                guard remaining.isEmpty else {
                    print("""
                          ✗ dense pooling convergence: \(remaining.joined(separator: ", ")) still at an earlier basis format after the rebuild.
                            Run `mootx01 upgrade` to retry.
                        """)
                    return false
                }
                print("  ✓ dense pooling convergence: \(stale.joined(separator: ", ")) retrained to basis format v\(basisFormatVersion); dense vectors re-embedded")
                return true
            } catch {
                print("""
                      ✗ dense pooling convergence failed: \(error)
                        Recall keeps serving through the lexical and stateless lanes; the stale dense slots stay untrained until the rebuild completes. Run `mootx01 upgrade` to retry.
                    """)
                return false
            }
        } ?? false
        #else
        return true
        #endif
    }

    /// Provider keys (`model_id@model_version`) whose part-0 basis row carries
    /// a frame version other than `basisFormatVersion`, sorted. Empty when the
    /// table is absent (an estate that never held a trained basis) or every
    /// row is current.
    private static func staleFormatBasisProviders(storage: any Storage) async throws -> [String] {
        let rows: [StorageRow]
        do {
            rows = try await storage.rowStore.query(
                table: "corpus_provider_basis",
                where: .eq(Column(table: "corpus_provider_basis", name: "part_index"), .int(0)),
                orderBy: [], limit: nil, offset: nil)
        } catch {
            // No basis table: the estate predates persisted bases, so there is
            // no dense lane to converge (the same skip the counts migration makes).
            return []
        }
        var stale: [String] = []
        for row in rows {
            guard case let .text(modelID)? = row["model_id"],
                  case let .text(modelVersion)? = row["model_version"],
                  case let .blob(basis)? = row["basis"] else { continue }
            if BasisBlobFrame.formatVersion(of: basis) != basisFormatVersion {
                stale.append("\(modelID)@\(modelVersion)")
            }
        }
        return stale.sorted()
    }

    /// Span encode (ENCODER_RERANK_CONTRACT §10, §12): encode spans for
    /// every drawer whose bit 27 is clear under the ACTIVE registry row, so a
    /// freshly upgraded estate reranks from its first query instead of
    /// waiting for the REM-ALPHA duty. The estate is opened through
    /// GeniusLocusKit first so `GLKMigrationCatalog.prepare` runs (it moves
    /// the vector tier's ledger rows to their SynapseKit ids before any store
    /// opens under the new id) and the corpus is wired; the batch work then
    /// runs through `SpanEncodeBackfill`, which is the duty's batch function
    /// until the NeuronKit duty lands. No active model, or a model whose
    /// directory or vocab check fails, is a clean skip: recall stays
    /// lexical-only and the next upgrade retries.
    ///
    /// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling).
    /// Upgrade never creates content: spans are derived rows, not drawers.
    /// Returns `true` on success or when there is nothing to encode.
    @discardableResult
    private func runSpanEncodeBackfill(home: URL) async -> Bool {
        #if os(macOS)
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment, homeDirectory: home)
        let estateURL = MootPaths.estateURL(in: dataDir)
        guard FileManager.default.fileExists(atPath: estateURL.path) else { return true }
        let encryption: EstateEncryptionConfig
        do {
            encryption = try EstateKeyProvider.resolveOpenPosture(for: estateURL).encryption
        } catch {
            print("  ✗ span encode skipped — estate key unavailable: \(error)")
            return false
        }
        return await ResidentDaemonQuiesce.run(
            dataDirectory: dataDir,
            residentDataDirectory: MootPaths.residentDataDirectory(homeDirectory: home),
            step: "span encode",
            daemon: .launchd(homeDirectory: home)
        ) { () async -> Bool in
            do {
                let configuration = EstateConfiguration(
                    estateID: UUID(),
                    backend: .sqlite(url: estateURL, busyTimeout: 5.0),
                    encryptionConfig: encryption
                )
                let storage = try SQLiteStorage(configuration: configuration)
                let owner = OwnerCredentials(ownerIdentifier: MootPaths.defaultOwnerIdentifier)
                let kit = GeniusLocusKit()
                let upgradeLifetimeIsEphemeral =
                    (ProcessInfo.processInfo.environment["MOOTX01_ESTATE_LIFETIME"] ?? "")
                        .lowercased() == "ephemeral"
                let handle = try await kit.open(
                    storage: storage,
                    owner: owner,
                    identityKeyStore: upgradeLifetimeIsEphemeral
                        ? InMemoryEstateIdentityKeyStore() : nil
                )
                _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: Date())
                // Migration writes the activation key: a CE 1.0.x estate arrives
                // at 19 with no `embedding_provider`, and only `provision` and
                // this upgrade step ever write it (Bob's ruling, 2026-09-06).
                // Written before wiring so this open already activates the
                // encoder; the next serve open does the same.
                if try await kit.provisionDefaultEncoderIfAbsent(for: handle) {
                    print("  ✓ encoder: span encoder is now the default recall stage (embedding_provider = encoder)")
                }
                try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
                // Closing the estate closes its storage connection with it, so
                // the backfill opens its own connection over the migrated file.
                try await kit.close(handle)
                let backfillStorage = try SQLiteStorage(configuration: configuration)
                let report = try await SpanEncodeBackfill.run(
                    storage: backfillStorage, dataDirectory: dataDir, now: Date())
                await backfillStorage.close()
                switch report {
                case .noActiveModel:
                    print("  ✓ span encode: no active encoder model registered; recall stays lexical-only")
                case .modelUnavailable(let reason):
                    print("  ✓ span encode: encoder unavailable (\(reason)); recall stays lexical-only until the model ships")
                case .encoded(let drawers, let spans, let remaining):
                    if drawers == 0 && remaining == 0 {
                        print("  ✓ span encode: every drawer is indexed under the active model")
                    } else {
                        print("  ✓ span encode: \(drawers) drawer(s), \(spans) span(s) written; \(remaining) drawer(s) still owed")
                    }
                }
                return true
            } catch {
                print("""
                      ✗ span encode failed: \(error)
                        Recall keeps serving lexical-only; the duty encodes the remaining drawers. Run `mootx01 upgrade` to retry.
                    """)
                return false
            }
        } ?? false
        #else
        return true
        #endif
    }

    /// Vacuum the whole-record float rows (`vectors` kind 1) and the
    /// `hnsw_graph` rows nothing serves any more (GENIUSLOCUSKIT_SPEC I-26).
    /// The 1.6 to 1.7 capsule does the work inside `GLKMigrationCatalog.prepare`
    /// when the estate opens (it also rebuilds the binary sidecar and releases
    /// the float representation claim), so this step counts the rows before
    /// the open, opens the estate through GeniusLocusKit, counts again, and
    /// returns the freed pages to the filesystem with a VACUUM when anything
    /// was deleted. It runs after the shared-content reclaim and before the
    /// ssc facts backfill: the first estate open of the sequence, so the
    /// capsule's work is reported here and every later step finds the estate
    /// at 1.7. Idempotent: a vacuumed estate deletes nothing and skips the
    /// VACUUM. Twin of the Rust `run_whole_record_vacuum`.
    ///
    /// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling).
    /// Returns `true` on success or when there is nothing to vacuum.
    @discardableResult
    private func runWholeRecordVacuum(home: URL) async -> Bool {
        #if os(macOS)
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment, homeDirectory: home)
        let estateURL = MootPaths.estateURL(in: dataDir)
        guard FileManager.default.fileExists(atPath: estateURL.path) else { return true }
        let encryption: EstateEncryptionConfig
        do {
            encryption = try EstateKeyProvider.resolveOpenPosture(for: estateURL).encryption
        } catch {
            print("  ✗ whole-record vacuum skipped — estate key unavailable: \(error)")
            return false
        }
        return await ResidentDaemonQuiesce.run(
            dataDirectory: dataDir,
            residentDataDirectory: MootPaths.residentDataDirectory(homeDirectory: home),
            step: "whole-record vacuum",
            daemon: .launchd(homeDirectory: home)
        ) { () async -> Bool in
            do {
                let configuration = EstateConfiguration(
                    estateID: UUID(),
                    backend: .sqlite(url: estateURL, busyTimeout: 5.0),
                    encryptionConfig: encryption
                )
                let before = try await Self.wholeRecordRowCounts(configuration: configuration)
                let storage = try SQLiteStorage(configuration: configuration)
                let owner = OwnerCredentials(ownerIdentifier: MootPaths.defaultOwnerIdentifier)
                let kit = GeniusLocusKit()
                let upgradeLifetimeIsEphemeral =
                    (ProcessInfo.processInfo.environment["MOOTX01_ESTATE_LIFETIME"] ?? "")
                        .lowercased() == "ephemeral"
                let handle = try await kit.open(
                    storage: storage,
                    owner: owner,
                    identityKeyStore: upgradeLifetimeIsEphemeral
                        ? InMemoryEstateIdentityKeyStore() : nil
                )
                // The chain runs the 1.6 to 1.7 capsule on an estate that has
                // not taken it yet; closing the estate closes its connection.
                _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: Date())
                try await kit.close(handle)
                let after = try await Self.wholeRecordRowCounts(configuration: configuration)
                let floatRows = before.floatRows - after.floatRows
                let graphRows = before.graphRows - after.graphRows
                var reclaimedBytes: Int64 = 0
                if floatRows + graphRows > 0 {
                    let maintenance = try SQLiteStorage(configuration: configuration)
                    reclaimedBytes = try await maintenance.performMaintenance().reclaimedBytes
                    await maintenance.close()
                }
                if floatRows + graphRows == 0 {
                    print("  ✓ whole-record vacuum: nothing to reclaim")
                } else {
                    print("  ✓ whole-record vacuum: \(floatRows) float row(s), \(graphRows) graph row(s) deleted; \(reclaimedBytes) bytes returned to filesystem")
                }
                return true
            } catch {
                print("""
                      ✗ whole-record vacuum failed: \(error)
                        Every serving row is untouched. Run `mootx01 upgrade` to retry.
                    """)
                return false
            }
        } ?? false
        #else
        return true
        #endif
    }

    /// The whole-record float (`vectors` kind 1) and `hnsw_graph` row counts
    /// of an estate, read through a connection of their own that is closed
    /// before the caller opens the estate. Zero when the vector tier was
    /// never registered (a Locus-only estate has no `vectors` table).
    private static func wholeRecordRowCounts(
        configuration: EstateConfiguration
    ) async throws -> (floatRows: Int, graphRows: Int) {
        let storage = try SQLiteStorage(configuration: configuration)
        do {
            guard try await storage.currentSchemaVersion(for: VectorStore.kitID) > 0 else {
                await storage.close()
                return (0, 0)
            }
            let floatRows = try await storage.rowStore.count(
                table: "vectors",
                where: .eq(Column(table: "vectors", name: "kind"),
                           .int(Int64(VectorKind.float32.rawValue))))
            let graphRows = try await storage.rowStore.count(table: "hnsw_graph", where: nil)
            await storage.close()
            return (floatRows, graphRows)
        } catch {
            await storage.close()
            throw error
        }
    }

    /// Models whose vector rows `mootx01 upgrade` reclaims: the dense
    /// distributional families the Encoder Rerank Program took dark
    /// (`MOOTX01_DENSE_FAMILIES` off). Their rows serve nothing at 19.
    static let retiredDenseFamilyModelIDs = ["lsa-v1", "nmf-v1", "ppmi-v1", "fdc-v1"]

    /// Reclaim the vector rows nothing serves at schema 19 (ENCODER_RERANK
    /// CONTRACT §12): every row of the retired dense families and every row
    /// at a non-serving generation, then a VACUUM when anything was deleted.
    /// Opened through GeniusLocusKit first for the same ledger-id reason as
    /// the span-encode step. Idempotent: a reclaimed estate deletes nothing
    /// and skips the VACUUM.
    ///
    /// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling).
    /// Returns `true` on success or when there is nothing to reclaim.
    @discardableResult
    /// Write SSC facts for every drawer that owes them and rebuild the BM25
    /// documents when any were written (Encoder Rerank contract sheet §6).
    ///
    /// A live estate never accrues facts debt: the capture path writes a
    /// drawer's facts before the drawer is encoded. An estate migrated from
    /// an earlier schema arrives with every `ssc_facts` NULL and with BM25
    /// documents composed under the earlier scheme, so this step pays the
    /// debt once (`GeniusLocusKit.backfillSSCFacts`) and, when it wrote
    /// anything, rebuilds every derived lane (`reindexCorpus`) so the
    /// supplement reaches the posting lists. A converged estate writes
    /// nothing and skips the rebuild. Runs after the schema upgrade and the
    /// shared-content reclaim, before the dense pooling convergence, so the
    /// rebuild happens once under the final schema.
    ///
    /// Returns `true` on success or when there is nothing to write.
    private func runSSCFactsBackfill(home: URL) async -> Bool {
        #if os(macOS)
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment, homeDirectory: home)
        let estateURL = MootPaths.estateURL(in: dataDir)
        guard FileManager.default.fileExists(atPath: estateURL.path) else { return true }
        let encryption: EstateEncryptionConfig
        do {
            encryption = try EstateKeyProvider.resolveOpenPosture(for: estateURL).encryption
        } catch {
            print("  ✗ ssc facts backfill skipped — estate key unavailable: \(error)")
            return false
        }
        return await ResidentDaemonQuiesce.run(
            dataDirectory: dataDir,
            residentDataDirectory: MootPaths.residentDataDirectory(homeDirectory: home),
            step: "ssc facts backfill",
            daemon: .launchd(homeDirectory: home)
        ) { () async -> Bool in
            do {
                let configuration = EstateConfiguration(
                    estateID: UUID(),
                    backend: .sqlite(url: estateURL, busyTimeout: 5.0),
                    encryptionConfig: encryption
                )
                let storage = try SQLiteStorage(configuration: configuration)
                let owner = OwnerCredentials(ownerIdentifier: MootPaths.defaultOwnerIdentifier)
                let kit = GeniusLocusKit()
                let upgradeLifetimeIsEphemeral =
                    (ProcessInfo.processInfo.environment["MOOTX01_ESTATE_LIFETIME"] ?? "")
                        .lowercased() == "ephemeral"
                let handle = try await kit.open(
                    storage: storage,
                    owner: owner,
                    identityKeyStore: upgradeLifetimeIsEphemeral
                        ? InMemoryEstateIdentityKeyStore() : nil
                )
                _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: Date())
                // The corpus must be wired for the rebuild below; the wire is
                // idempotent and does not re-stamp the manifest.
                try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
                let written = try await kit.backfillSSCFacts(handle: handle)
                if written > 0 {
                    try await kit.reindexCorpus(handle: handle, now: Date())
                }
                try await kit.close(handle)
                await storage.close()
                if written == 0 {
                    print("  ✓ ssc facts: every drawer already carries its facts")
                } else {
                    print("  ✓ ssc facts: \(written) drawer(s) written; BM25 and dense lanes rebuilt")
                }
                return true
            } catch {
                print("""
                      ✗ ssc facts backfill failed: \(error)
                        Rows already written keep their facts. Run `mootx01 upgrade` to retry.
                    """)
                return false
            }
        } ?? false
        #else
        return true
        #endif
    }

    private func runVectorReclaim(home: URL) async -> Bool {
        #if os(macOS)
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment, homeDirectory: home)
        let estateURL = MootPaths.estateURL(in: dataDir)
        guard FileManager.default.fileExists(atPath: estateURL.path) else { return true }
        let encryption: EstateEncryptionConfig
        do {
            encryption = try EstateKeyProvider.resolveOpenPosture(for: estateURL).encryption
        } catch {
            print("  ✗ vector reclaim skipped — estate key unavailable: \(error)")
            return false
        }
        return await ResidentDaemonQuiesce.run(
            dataDirectory: dataDir,
            residentDataDirectory: MootPaths.residentDataDirectory(homeDirectory: home),
            step: "vector reclaim",
            daemon: .launchd(homeDirectory: home)
        ) { () async -> Bool in
            do {
                let configuration = EstateConfiguration(
                    estateID: UUID(),
                    backend: .sqlite(url: estateURL, busyTimeout: 5.0),
                    encryptionConfig: encryption
                )
                let storage = try SQLiteStorage(configuration: configuration)
                let owner = OwnerCredentials(ownerIdentifier: MootPaths.defaultOwnerIdentifier)
                let kit = GeniusLocusKit()
                let upgradeLifetimeIsEphemeral =
                    (ProcessInfo.processInfo.environment["MOOTX01_ESTATE_LIFETIME"] ?? "")
                        .lowercased() == "ephemeral"
                let handle = try await kit.open(
                    storage: storage,
                    owner: owner,
                    identityKeyStore: upgradeLifetimeIsEphemeral
                        ? InMemoryEstateIdentityKeyStore() : nil
                )
                _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: Date())
                // Closing the estate closes its storage connection with it, so
                // the reclaim opens its own connection over the migrated file.
                try await kit.close(handle)
                let reclaimStorage = try SQLiteStorage(configuration: configuration)
                let vectors = VectorStore(storage: reclaimStorage)
                let counts = try await vectors.reclaimRetiredVectorRows(
                    retiredModelIDs: Self.retiredDenseFamilyModelIDs)
                var reclaimedBytes: Int64 = 0
                if counts.retiredModelRows + counts.nonServingRows > 0 {
                    reclaimedBytes = try await reclaimStorage.performMaintenance().reclaimedBytes
                }
                await reclaimStorage.close()
                if counts.retiredModelRows + counts.nonServingRows == 0 {
                    print("  ✓ vector reclaim: nothing to reclaim")
                } else {
                    print("  ✓ vector reclaim: \(counts.retiredModelRows) retired-family row(s), \(counts.nonServingRows) non-serving row(s) deleted; \(reclaimedBytes) bytes returned to filesystem")
                }
                return true
            } catch {
                print("""
                      ✗ vector reclaim failed: \(error)
                        Every serving row is untouched. Run `mootx01 upgrade` to retry.
                    """)
                return false
            }
        } ?? false
        #else
        return true
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
    /// Returns `true` on success or when there is nothing to reclaim, `false` on failure.
    @discardableResult
    private func runSharedContentReclaimIfPending(home: URL) async -> Bool {
        #if os(macOS)
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment, homeDirectory: home)
        let estateURL = MootPaths.estateURL(in: dataDir)
        // Absent estate means first run — serve creates new estates
        // post-cutover; there is nothing to reclaim.
        guard FileManager.default.fileExists(atPath: estateURL.path) else { return true }

        // Same key custody as serve's open path: existing key for an
        // encrypted estate, plaintext posture preserved for a plaintext one.
        let encryption: EstateEncryptionConfig
        do {
            encryption = try EstateKeyProvider.resolveOpenPosture(for: estateURL).encryption
        } catch {
            print("  ✗ shared-content reclaim skipped — estate key unavailable: \(error)")
            return false
        }

        // Single-writer discipline: the resident daemon is stopped around
        // the work only when this is its estate (ResidentDaemonQuiesce
        // prints why when it is not). A nil result means the daemon would
        // not stop; the step is skipped and the next upgrade retries.
        return await ResidentDaemonQuiesce.run(
            dataDirectory: dataDir,
            residentDataDirectory: MootPaths.residentDataDirectory(homeDirectory: home),
            step: "shared-content reclaim",
            daemon: .launchd(homeDirectory: home)
        ) { () async -> Bool in
            do {
                let configuration = EstateConfiguration(
                    estateID: UUID(),
                    backend: .sqlite(url: estateURL, busyTimeout: 5.0),
                    encryptionConfig: encryption
                )
                let storage = try SQLiteStorage(configuration: configuration)
                // Apply the shared-content migration ledger schema (CREATE TABLE IF NOT EXISTS)
                // before reading the reclaim record. An estate that never ran the
                // shared-content migration has no ledger table, and reading it would
                // throw "no such table: glk_shared_content_migration". Applying the
                // declaration is a no-op once the table exists.
                try await storage.migrate(to: SharedContentMigrationStore.schemaDeclaration)
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
                //
                // EXCEPT under the declared throwaway posture: with
                // MOOTX01_ESTATE_LIFETIME=ephemeral the identity key lives in an
                // in-memory store, same contract as ServeCommand. Without this,
                // every bulk-upgrade sweep over benchmark estates minted one
                // Keychain identity item per estate and never deleted it —
                // 247 accumulated items by 2026-08-26 (keychain pollution,
                // ACTION D5 recurrence). Benchmark estates have no federation
                // signing to lose; the marker is a declaration, never inferred.
                let upgradeLifetimeIsEphemeral =
                    (ProcessInfo.processInfo.environment["MOOTX01_ESTATE_LIFETIME"] ?? "")
                        .lowercased() == "ephemeral"
                let handle = try await kit.open(
                    storage: storage,
                    owner: owner,
                    identityKeyStore: upgradeLifetimeIsEphemeral
                        ? InMemoryEstateIdentityKeyStore() : nil
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
                return true
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
                return false
            } catch {
                // Failure before completeSharedContentReclaim commits the trim —
                // estate state is unchanged.
                print("""
                      ✗ shared-content reclaim failed: \(error)
                        The estate is unaffected. Run `mootx01 upgrade` to retry.
                    """)
                return false
            }
        } ?? false
        #else
        return true
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

        runEstateEncryptionMigration(estateURL: estateURL, dataDirectory: dataDir, home: home)
        #endif
    }

    #if os(macOS)
    /// Drive the accepted migration: provision the key, then clone → verify
    /// → swap → trash through EstateEncryptionMigrator. Every failure path
    /// leaves the plaintext original working at the canonical path; the
    /// messages below say which side of the swap the user is on.
    private func runEstateEncryptionMigration(estateURL: URL, dataDirectory: URL, home: URL) {
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

        // The migrator's daemon seam: launchd when this is the resident
        // estate, a no-op otherwise — a cloned estate is encrypted with the
        // resident daemon left running over its own estate. The resident
        // directory comes from the daemon's launchd registration; an
        // unreadable registration selects launchd (SAFETY: the copy+rename
        // never runs under a daemon that may hold this estate open).
        let residentDirectory = MootPaths.residentDataDirectory(homeDirectory: home)
        let resident = MootPaths.isResidentEstate(
            dataDirectory: dataDirectory,
            residentDataDirectory: residentDirectory)
        if !resident {
            print("  data directory \(dataDirectory.path) is not the resident estate; daemon left running")
        } else if let warning = residentDirectory.registrationWarning(for: dataDirectory) {
            print(warning)
        }
        print("Encrypting the estate\u{2026}")
        do {
            let result = try EstateEncryptionMigrator.migrate(
                estateURL: estateURL,
                key: key,
                daemon: resident ? .launchd(homeDirectory: home) : .none)
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
                // preserveRecordedPluginDisable: an upgrade is routine
                // convergence, not a user request to activate the plugin —
                // an explicitly recorded disable survives it (Finding #2).
                _ = try DepthInstaller.apply(
                    clientID: host.id, depth: .plugin, homeDirectory: home,
                    binaryPath: binaryPath, preserveRecordedPluginDisable: true
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
                // preserveRecordedPluginDisable: same posture as
                // rematerializePluginDepth — the cache refresh keeps the
                // package current without overriding a recorded disable.
                _ = try DepthInstaller.apply(
                    clientID: host.id, depth: .plugin, homeDirectory: home,
                    binaryPath: binaryPath, preserveRecordedPluginDisable: true
                )
                print("  ✓ \(host.displayName): plugin manifest updated to \(Mootx01.currentVersion)")
            } catch {
                print("  ✗ \(host.displayName): could not update plugin manifest (non-fatal): \(error)")
            }
        }
    }

    #if os(macOS)
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
        // A refused schema version skips every data step: each of them would
        // open the LocusKit schema and stamp the estate current.
        if await runSchemaUpgrade(home: home) {
            await runKGFactIdentityBackfill(home: home)
            await runSharedContentReclaimIfPending(home: home)
            await runWholeRecordVacuum(home: home)
            await runDensePoolingConvergence(home: home)
            await runSpanEncodeBackfill(home: home)
            _ = await runVectorReclaim(home: home)
        }
        convergeDaemonBundle(home: home)
        restartAgents(home: home)
    }

    // MARK: - MACD-2c2 daemon-bundle convergence (macOS)

    /// Converge the daemon provider bundle on upgrade. Once the signed bundle
    /// is present it supersedes the legacy raw-serve registration; booting the
    /// legacy job out first prevents concurrent writers during takeover.
    ///
    /// Idempotent: re-writing the same plist is the readback contract, and the
    /// census creates nothing.
    private func convergeDaemonBundle(home: URL) {
        #if os(macOS)
        // Perkins F1 census-site gate: verify the bundle executable's static code
        // signature BEFORE staging the disabled plist or running census.  The same
        // BundleSignatureVerifier used by ProviderOwnershipProbe is the single
        // authority so the three exec sites (owner-status, install-census,
        // upgrade-census) cannot diverge.
        //
        // A same-UID attacker could plant an unsigned binary at the bundle path.
        // Without this gate a planted binary would reach DaemonBundle.runReadOnlyMode
        // ("census") after only isExecutableFile — arbitrary code execution as the
        // census subprocess, with its output printed to the user.
        switch BundleSignatureVerifier.production.gate(homeDirectory: home) {
        case .absent:
            // No bundle in this release payload: nothing to converge.  Silent on
            // purpose — an upgrade from a payload without the bundle is the ordinary
            // case and not a fault.
            return
        case .unverified(let message):
            // Present but unverified: do NOT stage a plist or run census.  Skip
            // convergence and report the issue actionably.
            print("")
            print("  \(message)")
            print("    Daemon bundle convergence skipped until the signature is repaired.")
            return
        case .verified:
            break  // proceed to ownership probe and convergence below
        }

        // MACD-3B3 C2/C4: probe before registering the bundle DISABLED.
        // An authenticated healthy bundled owner means upgrade is client-only —
        // skip bundle re-registration (same gate as install, same mandate).
        // An incompatible owner surfaces the verdict verbatim and skips
        // registration; NEVER starts a second provider.
        // Absent or unauthenticated: normal convergence proceeds.
        let ownerOutcome = ProviderOwnershipProbe().detect(homeDirectory: home)
        if ownerOutcome.requiresClientOnlyInstall {
            print("\n  \u{2713} Using MOOTx01-App resident provider — daemon bundle convergence skipped (C2).")
            return
        }
        if ownerOutcome.blocksInstallByVersionMismatch {
            if case .incompatible(let verdict) = ownerOutcome {
                print("\n  \u{26A0} Provider version mismatch: \(verdict.rawValue) — daemon bundle not re-registered. Resolve the mismatch before upgrading.")
            }
            return
        }
        // .absent or .unauthenticated: converge normally.
        // For .unauthenticated: any running process is left untouched (C3).
        if case .unauthenticated = ownerOutcome {
            print("")
            print("  \u{26A0} A provider is present but could not be authenticated.")
            print("    Upgrading normally; the existing process is not stopped (C3).")
        }
        print("\nConverging the daemon provider bundle\u{2026}")
        LaunchAgent.uninstallDaemon(homeDirectory: home)
        switch LaunchAgent.activateDaemonBundleEnabled(homeDirectory: home) {
        case let .installed(plistPath, endpointURL):
            print("  \u{2713} Community daemon provider running (launchd: \(DaemonBundle.launchAgentLabel))")
            print("    MCP endpoint: \(endpointURL)")
            print("    LaunchAgent: \(plistPath)")
        case let .launchctlFailed(message):
            print("  \u{2717} Could not start the daemon provider bundle: \(message)")
            return
        case .binaryNotFound:
            print("  \u{2717} Daemon provider bundle executable is missing.")
            return
        case .installedDisabled:
            return
        }
        let census = DaemonBundle.runReadOnlyMode("census", homeDirectory: home)
        if let output = census.output, census.code == 0 {
            print("  Census (read-only, provider-reported):")
            print("    \(output)")
        } else {
            print("  \u{24D8} Census unavailable (provider exit \(census.code)).")
        }
        #endif
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

    /// The Swift remote upgrade path downloads and extracts with URLSession/tar,
    /// which does not mark files as internet downloads. Setting
    /// com.apple.quarantine on remotely installed binaries lets Gatekeeper
    /// assess them on the operator's next launch. This is best-effort
    /// defense-in-depth, not the verification gate: artifact authentication is
    /// the fail-closed minisign check inside ReleaseDownloader.download(),
    /// which has already succeeded before any placed binary reaches this tag.
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
    /// connection. Both the plugin and the direct installer use the same
    /// `"mootx01"` server key, so a user who had both wired ends up with two
    /// connections to the same estate. This step collapses them to one —
    /// but ONLY when the entry is confirmed to be the installer's own
    /// default-database wiring.
    ///
    /// The guard, ownership classification, backup, and removal all live in
    /// `Installer.cleanupRedundantCodexDirectEntry` (MootInstallerCore, where
    /// they are unit-testable): the plugin must own the connection, AND the
    /// entry must classify `.oursDefault` via `MCPEntryClassifier` — an
    /// entry scoped elsewhere (env override, `--db` estate override,
    /// non-default-port URL) or not shaped like ours is reported here and
    /// left untouched. This wrapper only prints the outcome.
    private func removeRedundantCodexDirectEntry(home: URL) {
        switch Installer.cleanupRedundantCodexDirectEntry(homeDirectory: home) {
        case .pluginNotOwner, .notPresent:
            // Nothing to reconcile — idempotent silence, matching the other
            // convergence steps' no-op posture.
            break
        case let .retainedForeign(reason):
            print("""
                  \u{24D8} Codex config: [mcp_servers.mootx01] in ~/.codex/config.toml \
                left untouched — \(reason).
                """)
        case let .failed(message):
            print("  \u{2717} \(message)")
        case .removed:
            print("  \u{2713} Removed redundant direct MCP entry from Codex config (plugin owns connection).")
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
        case .installedDisabled:
            // restart() never returns this case (it belongs to the disabled
            // bundle-form install), but the vocabulary is one enum.
            print("  \u{24D8} Daemon bundle registration is disabled-install; nothing to restart.")
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
