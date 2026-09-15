// DreamCommand.swift
//
// On-demand REM-ALPHA dreaming cycle.
//
// `mootx01 dream` is the sibling of `mootx01 drain`. It is the detached
// dreaming finisher an stdio `serve` spawns in three situations:
//
//   1. Post-recall fork: after a recall that co-recalled ≥ 2 drawers and
//      enqueued a dreaming job, so dream sessions trigger promptly after
//      activity without waiting for the next autonomic governor tick.
//   2. On-exit: when a direct-open stdio `serve` exits and the dreaming
//      queue has pending items (mirrors the T5 drain on-exit pattern).
//   3. On-startup/first-query: when `serve` opens an estate and finds pending
//      dreaming items from a prior session (jobs in `queue.sqlite` that were
//      not processed before the previous serve exited).
//
// When run by hand it behaves identically: one REM-ALPHA cycle per invocation.
//
// Detached lifecycle:
//   - Calls `setsid()` to escape the parent's process group, surviving a
//     SIGKILL aimed at the spawning serve.
//   - Acquires the per-stream `"dreaming"` DrainLease (beside `queue.sqlite`).
//     If another dreamer holds a fresh lease it exits immediately (stampede
//     prevention — at most one dreamer per estate per stream at a time).
//   - Probes `dreamingQueuePendingCount`: if nil or 0, no work to do, exits.
//   - Runs ONE REM-ALPHA dreaming cycle via `DreamingDaemon.triggerDreamingCycle`.
//   - Releases the lease and exits.
//
// THETA/BETA/OMEGA cycles (recall-driven dreaming, /) are NOT built here.
// The seam comments below mark where they would plug in. Do not implement them
// here — those missions have their own scope and PRs.
//
// macOS-only: same constraint as `ServeCommand` and `DrainCommand`.

#if os(macOS)
import Foundation
import ArgumentParser
import AriaMCP
import GeniusLocusKit
import GeniusLocusKitMigrations
import NeuronKit
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import QueueKit
import MootInstallerCore
import MootEstateOpen
import MootFactExtractorActivation
import Darwin

struct DreamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dream",
        abstract: "Run one REM-ALPHA dreaming cycle for an estate, then exit (detached background finisher)."
    )

    @Option(name: .long, help: "Estate to dream on: a registered name, or <dir>/<name> for a transient estate. Default: the active estate.")
    var db: String?

    func run() async throws {
        // Detach into our own session (mirrors DrainCommand). A spawned child
        // already survives the parent's death; setsid hardens against group signals
        // so a SIGKILL aimed at the spawning stdio serve does not reach us.
        setsid()

        // The catalog resolves `--db` exactly as serve did when it launched us:
        // a registered name, or a transient estate by its directory.
        let estate: EstateRecord
        do {
            estate = try EstateOpen.catalog(selecting: db).active
        } catch {
            Logging.stderr.log("mootx01 dream fatal: \(error)")
            throw ExitCode.failure
        }
        let estateName = estate.name
        let estateURL = estate.databaseURL
        // No estate file → nothing to dream on.
        guard FileManager.default.fileExists(atPath: estateURL.path) else {
            Logging.stderr.log("mootx01 dream: estate file does not exist — exiting")
            return
        }

        // The dreaming lease file lives in the estate directory, keyed by stream
        // name "dreaming". This is independent of the encode ("encode.drain.lease")
        // lease — both can be held simultaneously (recall-driven dreaming:
        // per-(estate, stream) leases).
        let leaseDir = estate.directory
        let instanceToken = UUID().uuidString
        let lease = DrainLease(
            directory: leaseDir,
            stream: "dreaming",
            instanceToken: instanceToken
        )

        // Acquire the dreaming lease. If another dreamer holds a fresh lease,
        // exit immediately — stampede prevention; the other dreamer will process
        // the queue. We do not wait; a single concurrent dreamer is sufficient.
        let now = Date()
        guard lease.tryAcquire(now: now) else {
            Logging.stderr.log("mootx01 dream: dreaming lease held by another process — exiting (another dreamer is running)")
            return
        }
        // Registered cleanup: release the lease on any exit path so the next
        // dreamer can take over immediately rather than waiting out the TTL.
        defer { lease.release() }

        // Open the estate and wire the GLK semantic layer (corpus + vector store
        // + encode queue), exactly as DrainCommand does. wireGLKSubstores is
        // idempotent on reopen.
        // At-rest posture — the SAME shared decision serve and drain use, so the
        // three commands cannot drift.
        let encryption: EstateEncryptionConfig
        do {
            let resolved = try EstateOpenPosture.resolve(for: estate)
            encryption = resolved.encryption
        } catch {
            Logging.stderr.log("mootx01 dream fatal: estate encryption key unavailable: \(error)")
            throw ExitCode.failure
        }

        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0),
            encryptionConfig: encryption
        )
        let storage: SQLiteStorage
        do {
            storage = try SQLiteStorage(configuration: configuration)
        } catch {
            Logging.stderr.log("mootx01 dream fatal: SQLite open failed: \(error)")
            throw ExitCode.failure
        }

        let owner = OwnerCredentials(ownerIdentifier: MootPaths.defaultOwnerIdentifier)
        let kit = GeniusLocusKit()
        let handle: EstateHandle
        do {
            // A transient estate never touches the Keychain: identity in memory,
            // no federation. A registered one resolves its store per backend.
            handle = try await kit.open(
                storage: storage, owner: owner,
                identityKeyStore: estate.kind == .registered ? nil : InMemoryEstateIdentityKeyStore(),
                federate: estate.kind == .registered)
            let preparation = try await GLKMigrationCatalog.prepare(
                kit: kit, handle: handle, now: Date())
            // The manifest must say what is on disk: after a migration, or for an
            // estate that predates manifests, rewrite estate.json.
            if try EstateManifestRefresh.afterPrepare(
                preparation, estate: estate, encryption: encryption, now: Date()) {
                Logging.stderr.log("mootx01 dream: estate manifest refreshed (format \(preparation.format), schema \(GeniusLocusKitSchema.version))")
            }
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
        } catch {
            Logging.stderr.log("mootx01 dream fatal: estate open/wiring failed: \(error)")
            throw ExitCode.failure
        }

        // The detached/on-demand finisher owns one bounded Signal 14 pass while
        // the estate is open. This runs before the REM queue gate so fact debt
        // progresses even when no recall-driven dreaming job is pending.
        let factExtractionSetting = try? await kit.provisionedPreference(
            .factExtraction, for: handle)
        let factExtractorSetting = try? await kit.provisionedPreference(
            .factExtractor, for: handle)
        let factSettingsDirectory = estate.kind == .registered
            ? EstateCatalog.configurationDirectory : estate.directory
        if let extractor = FactExtractorBuilder.build(
            masterSetting: factExtractionSetting ?? .off,
            extractorSetting: factExtractorSetting ?? .nuextract,
            settingsDirectory: factSettingsDirectory,
            workerExecutableURL: URL(fileURLWithPath: CommandLine.arguments[0]))
        {
            let spec = extractor.spec
            let recipeID = "\(spec.providerID):\(spec.modelID):\(spec.modelVersion)"
            do {
                _ = try await kit.activateFactExtractor(
                    extractor, recipeID: recipeID, for: handle)
                let result = try await kit.runFactExtractionBatch(
                    handle, limit: 16, now: Date())
                Logging.stderr.log(
                    "mootx01 dream: fact extraction cycle complete — " +
                    "\(result.factsFiled) fact(s) filed")
            } catch {
                Logging.stderr.log(
                    "mootx01 dream warning: fact extraction cycle failed: \(error)")
            }
        }

        // Force-mount the dreaming queue so that `dreamingQueuePendingCount`
        // returns a real count from the persistent queue.sqlite rather than nil
        // (nil = "not mounted in this session", not "definitely empty"). This is
        // the correct path after a process restart: prior recall events populated
        // queue.sqlite, but the in-memory queue registry starts empty.
        await kit.mountDreamingQueue(for: handle)

        // On-mount crash recovery: reclaim any stale "dreaming" cur jobs left by
        // a prior dream process that died mid-cycle before replying Done. We just
        // acquired the dreaming lease (try_acquire succeeded), which guarantees the
        // prior holder is dead — so every "dreaming" cur row is an orphan. Resetting
        // them to "new" means the dreaming cycle below will re-process them.
        // Safety: tryAcquire above succeeded, so no live dreamer holds the lease.
        await kit.reclaimStaleDreamingJobs(for: handle)

        // §12.2 REM-ALPHA gate: only proceed if the dreaming queue has pending items.
        // nil → queue could not be mounted (estate has never had a qualifying recall)
        // 0   → queue is mounted but empty (all items processed in a prior cycle)
        // In both cases there is nothing to dream on.
        let pending = await kit.dreamingQueuePendingCount(for: handle)
        guard let pendingCount = pending, pendingCount > 0 else {
            Logging.stderr.log("mootx01 dream: dreaming queue is empty for estate '\(estateName)' — nothing to process")
            return
        }
        Logging.stderr.log("mootx01 dream: \(pendingCount) dreaming job(s) pending for estate '\(estateName)' — running REM-ALPHA cycle")

        // Build the DreamingDaemon with all four seam adapters, mirroring
        // AutonomicGovernor construction. `growthProbe: nil` disables the
        // auto-reindex corpus basis retrain — this is a one-shot command, not the
        // resident governor that tracks vocab growth over time.
        let reader = EstateDreamingReader(handle: handle, kit: kit)
        let sink = EstateDreamingSink(handle: handle, kit: kit)
        let policyStore = EstateManifestDreamingPolicyStore(handle: handle, kit: kit)
        let dreaming = DreamingDaemon(
            reader: reader,
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: policyStore,
            growthProbe: nil
        )

        // Restore persisted policy, bandit state, and cycle memory.
        // This ensures the one-shot dreamer picks up any prior cycle's learning
        // (minAttempts gate, proposed-key idempotency, EWC++ consolidation).
        do {
            try await dreaming.loadPersistedPolicy()
        } catch {
            // Non-fatal: policy load failure leaves the daemon at spec defaults.
            // Log the failure and continue so the cycle still runs.
            Logging.stderr.log("mootx01 dream warning: policy restore failed: \(error) — using spec defaults")
        }

        // Run one REM-ALPHA cycle against the pending dreaming queue.
        // No heartbeat task: one dreaming cycle is fast (subsecond for normal
        // estates) and well within the 15-second lease TTL. The resident
        // AutonomicGovernor heartbeats its lease because it holds it for minutes;
        // the one-shot dream command does not need to.
        // `triggerDreamingCycle(now:)` bypasses the timer-interval gate so this
        // on-demand invocation runs unconditionally — unlike `pump(now:)` which
        // would return nil if the interval has not elapsed.
        //
        // THETA cycle (T11) — seam: replace the runCycle call with the THETA
        //   variant when T11 lands, or add a second cycle call below.
        // BETA cycle (T12) — seam: add after REM-ALPHA; NOT implemented here.
        // OMEGA cycle (T13) — seam: add after BETA; NOT implemented here.
        let cycleNow = Date()
        do {
            let report = try await dreaming.triggerDreamingCycle(now: cycleNow)
            Logging.stderr.log(
                "mootx01 dream: REM-ALPHA cycle complete — " +
                "\(report.proposalsEmitted.count) proposal(s) emitted, " +
                "\(report.candidatesConsidered) candidate(s) considered, " +
                "\(report.suppressedDuplicates) suppressed for estate '\(estateName)'"
            )
            // Subject backfill dispatch (rider-default ruling, 2026-08-02):
            // dreaming pays subject debt when a producer is registered (the
            // serve layer registers the Apple rider by default). One bounded
            // batch per cycle; settled-skip converges across cycles. No
            // rider → silent skip; a sweep error is non-fatal like the
            // cycle error above.
            if await kit.subjectProducerPipeline(for: handle) != nil {
                do {
                    let debt = try await kit.estate(for: handle).countSubjectDebt()
                    if debt > 0 {
                        // 256 items per cycle: the miniLLM writes subjects subsecond per item;
                        // 32 was far below practical throughput and caused post-upgrade debt
                        // to converge over days rather than hours on large estates.
                        let sweep = try await kit.subjectBackfillSweep(
                            handle, batchLimit: 256, now: cycleNow)
                        Logging.stderr.log(
                            "mootx01 dream: subject backfill — \(sweep.written) written, "
                            + "\(sweep.skippedInadmissible) skipped, \(sweep.remainingDebt) remaining")
                    }
                } catch {
                    Logging.stderr.log("mootx01 dream warning: subject backfill error: \(error) — continuing")
                }
            }
        } catch {
            // A cycle error is non-fatal at the command level: the dreaming queue
            // was drained (or partially drained), which is forward progress even if
            // the cycle threw. Log and exit cleanly so the spawning serve is not
            // blocked on this process's exit code.
            Logging.stderr.log("mootx01 dream warning: dreaming cycle error: \(error) — continuing")
        }

        // Release the lease explicitly (the defer also does this, but being
        // explicit here makes the lifecycle contract clear in code review).
        lease.release()
        Logging.stderr.log("mootx01 dream: REM-ALPHA cycle finished for estate '\(estateName)' — exiting")
    }
}
#endif
