// DreamingQueueAPI.swift — per-estate dreaming queue lifecycle (ADR-021 Phase 2b).
//
// T6 is ENQUEUE-ONLY. This file owns:
//   - `ensureDreamingQueue(for:)` — lazy-mount the per-estate dreaming queue.
//   - `enqueueDreamingItem(drawers:handle:now:)` — guard (≥ 2 distinct ids)
//     and enqueue. Enqueue failures are non-fatal: logged via OSLog, recall
//     result is returned unchanged.
//
// Backend selection mirrors `SignalAPI.ensureScheduler` (T5):
//   - SQLite estate → shared encrypted queue.sqlite beside the estate.
//   - InMemory estate → transient PersistenceKitBackend (no disk needed).
//
// HLC node_id derivation mirrors T5: first four UUID bytes big-endian → UInt32
// bit-cast to Int32. Both ports use the same formula so HLC streams are
// distinguishable and deterministic across restarts.
//
// No DrainLease is acquired here — the lease is a drainer concern (T9/REM-ALPHA).
// No drain loop. Just `queue.send(_:)`.

import Foundation
import OSLog
import PersistenceKit
import PersistenceKitSQLite
import PersistenceKitInMemory
import QueueKit
import SubstrateTypes
import LocusKit

internal extension GeniusLocusKit {

    /// Logger for dreaming queue events (fleet-standard subsystem/category).
    /// `internal` so DreamingReads.swift (same module, different file) can
    /// reference `Self.dreamLog` without a per-file logger duplicate.
    static var dreamLog: Logger {
        Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
    }

    // MARK: - Lazy mount

    /// Lazy-mount the per-estate dreaming queue and its HLC generator.
    ///
    /// Called on the first external recall for an estate. Subsequent calls
    /// return the cached queue immediately (the GLK actor serialises access).
    ///
    /// Backend selection (mirrors `ensureScheduler` for signals, T5):
    ///   - SQLite estate → `cfg.queueSibling("queue.sqlite")` backed by
    ///     `SQLiteStorage` → `PersistenceKitBackend`. Same encrypted sibling
    ///     the encode and signals streams already share — one queue, three streams.
    ///   - InMemory (or absent) estate → transient `InMemoryStorage`-backed backend.
    ///
    /// HLC nodeID derivation (mirrors `ensureScheduler`):
    ///   Assemble the first four UUID bytes big-endian into a UInt32, then
    ///   bit-cast to Int32. The Rust mirror does the byte-identical
    ///   `u32::from_be_bytes([b0,b1,b2,b3]) as i32`.
    ///
    /// - Throws: Storage open or schema errors are not thrown — any failure
    ///   falls back to a transient in-memory backend with an OSLog error entry.
    ///   The dreaming enqueue degrades silently so recall is never interrupted.
    internal func ensureDreamingQueue(for handle: EstateHandle) async throws -> (queue: QueueKit, hlc: HLCGenerator) {
        if let q = dreamingQueues[handle], let h = dreamingHLCs[handle] {
            return (q, h)
        }

        // Derive the HLC nodeID from the estate handle UUID (same formula as
        // SignalAPI.ensureScheduler — first four bytes big-endian → Int32).
        let b = handle.estateUUID.uuid
        let nodeID = Int32(bitPattern:
            (UInt32(b.0) << 24) | (UInt32(b.1) << 16) | (UInt32(b.2) << 8) | UInt32(b.3))
        let hlc = HLCGenerator(nodeID: nodeID)

        let cfg = storages[handle]?.configuration
        let queue: QueueKit

        if case .sqlite = cfg?.backend {
            // Persistent estate: open the shared queue.sqlite sibling (same file
            // the encode and signals streams use). One queue, many streams per ADR-021
            // Decision 7. The sibling cfg carries the estate's encryption key so the
            // dreaming payloads (which include drawer ids) are encrypted at rest.
            do {
                let siblingCfg = try cfg!.queueSibling(filename: "queue.sqlite")
                let qs = try SQLiteStorage(configuration: siblingCfg)
                try await PersistenceKitBackend.openSchema(on: qs)
                let backend = PersistenceKitBackend(storage: qs)
                queue = QueueKit(backend: backend)
                queue.estateTag = "dreaming"
            } catch {
                // SQLite open or schema failure: degrade to transient in-memory backend.
                // The dreaming lane becomes non-durable for this session; the recall
                // result is unaffected. The next open() will retry.
                Self.dreamLog.error(
                    "DreamingQueueAPI: failed to open queue.sqlite for dreaming (estate \(handle.estateUUID, privacy: .public)): \(error.localizedDescription, privacy: .public) — degrading to transient backend"
                )
                let storeID = cfg?.estateID ?? handle.estateUUID
                let qs = InMemoryStorage(configuration: EstateConfiguration(
                    estateID: storeID, backend: .inMemory))
                try await PersistenceKitBackend.openSchema(on: qs)
                let backend = PersistenceKitBackend(storage: qs)
                queue = QueueKit(backend: backend)
                queue.estateTag = "dreaming_inmemory"
            }
        } else {
            // InMemory estate or absent storage: transient backend, no crash recovery,
            // no cross-process concerns. Use the estate's own UUID as the store ID for
            // diagnostic correlation, avoiding nondeterministic UUID() at mount time.
            let storeID = cfg?.estateID ?? handle.estateUUID
            let qs = InMemoryStorage(configuration: EstateConfiguration(
                estateID: storeID, backend: .inMemory))
            try await PersistenceKitBackend.openSchema(on: qs)
            let backend = PersistenceKitBackend(storage: qs)
            queue = QueueKit(backend: backend)
            queue.estateTag = "dreaming_inmemory"
        }

        dreamingQueues[handle] = queue
        dreamingHLCs[handle] = hlc
        return (queue, hlc)
    }

    // MARK: - Enqueue

    /// Enqueue a dreaming item for the surfaced drawer set, if the set qualifies.
    ///
    /// Guard (spec §12.2): enqueue only when the deduplicated drawer id set has
    /// ≥ 2 distinct ids (a single drawer makes no pair). Fewer than 2 → no-op.
    ///
    /// On success: one `Job` with `stream_id = "dreaming"` is committed to the
    /// estate's queue.sqlite (or transient backend). One item per recall call.
    ///
    /// On enqueue failure: log via OSLog (error level) and return. A transient
    /// storage error does NOT propagate — recall must never fail because the
    /// dreaming side-effect failed. Mirrors the T5 `fire_signal` error handling.
    ///
    /// `now` is the caller's wall-clock snapshot (Date). No Date() call inside
    /// this engine — determinism rule per CLAUDE.md.
    ///
    /// - Parameters:
    ///   - drawers: The drawers surfaced by the recall. Order is preserved in the
    ///     payload (result order = deterministic).
    ///   - handle: The estate the recall ran against. Must be open.
    ///   - now: The wall-clock instant at which the recall completed.
    internal func enqueueDreamingItem(drawers: [Drawer], handle: EstateHandle, now: Date) async {
        // Deduplicate ids while preserving result order (first occurrence wins).
        // The guard is strictly >1 distinct ids — a set of one makes no pair.
        var seen = Set<String>()
        var distinctIds: [String] = []
        for d in drawers {
            if seen.insert(d.id).inserted {
                distinctIds.append(d.id)
            }
        }
        guard distinctIds.count >= 2 else {
            // Fewer than 2 distinct drawer ids: no pair possible, skip enqueue.
            return
        }

        // Lazy-mount the dreaming queue. Failures here are non-fatal; ensureDreamingQueue
        // already degraded to an in-memory backend on SQLite failure and logged the error.
        // `var` is required: HLCGenerator.send(_:) is a mutating method (it advances the
        // logical clock), so the tuple must be mutable to call it.
        var queueHandle: (queue: QueueKit, hlc: HLCGenerator)
        do {
            queueHandle = try await ensureDreamingQueue(for: handle)
        } catch {
            Self.dreamLog.error(
                "DreamingQueueAPI: ensureDreamingQueue failed (estate \(handle.estateUUID, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        // Build the payload. recallEventId groups this co-recalled set in the drainer.
        // Uses the same 32-hex JobID shape so the drainer reads a consistent format.
        let item = DreamingItem(
            recallEventId: JobID.generate().rawValue,
            drawerIds: distinctIds
        )
        let payload: Data
        do {
            payload = try JSONEncoder().encode(item)
        } catch {
            // DreamingItem encoding cannot fail (all fields are String / [String]),
            // but surface the error rather than crash if something unexpected happens.
            Self.dreamLog.error(
                "DreamingQueueAPI: DreamingItem encoding failed (estate \(handle.estateUUID, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        // HLC stamp. Physical time is milliseconds-since-epoch (substrate convention).
        let physMillis = Int64(now.timeIntervalSince1970 * 1000)
        let stamp = queueHandle.hlc.send(now: physMillis)
        // Write the mutated HLC back to the stored dictionary. HLCGenerator is a
        // value type and send(now:) is mutating: the mutation above advances the
        // LOCAL copy only. Without this write-back, every enqueue call restarts from
        // the same initial HLC state (the logical clock never advances), producing
        // duplicate or out-of-order timestamps in the dreaming queue.
        dreamingHLCs[handle] = queueHandle.hlc

        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "dreaming"),
            submittedAt: stamp,
            priority: 50,
            payload: payload,
            extensions: [:]
        )

        do {
            try await queueHandle.queue.send(job)
        } catch {
            // Enqueue failure is non-fatal — the recall result is already prepared.
            // Log at error level so operators can trace queue.sqlite health issues.
            Self.dreamLog.error(
                "DreamingQueueAPI: dreaming enqueue failed (estate \(handle.estateUUID, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

}

// MARK: - Pending-count probe (REM-ALPHA gate, ADR-021 Phase 4)

public extension GeniusLocusKit {

    /// Non-claiming peek at the dreaming queue depth for `handle`.
    ///
    /// Returns the number of jobs pending on the `"dreaming"` stream, or `nil`
    /// if the dreaming queue has not yet been mounted for this estate (no
    /// external-origin recall has fired yet, so the queue file is not open).
    ///
    /// Used by `AutonomicGovernor.tick()` as the §12.2 cheap trigger (ADR-021
    /// Phase 4): `nil` or `0` ⇒ skip the dreaming cycle entirely — no reader,
    /// no estate scan, no drain. Only a positive count proceeds to the full
    /// dreaming-daemon pump. This makes idle cycles and bulk-import cycles
    /// (where the dreaming queue was never populated) true no-ops.
    ///
    /// Non-claiming: does NOT drain or acknowledge any jobs. A query failure
    /// (storage error) is treated as `nil` — the gate defaults to skip,
    /// which is the safe direction (no spurious wasted work).
    ///
    /// Mirrors Rust `EstateCoordinator.dreaming_queue_pending_count_for_gate`.
    func dreamingQueuePendingCount(for handle: EstateHandle) async -> Int? {
        // If the dreaming queue is not mounted, the estate has never had a
        // qualifying external-origin recall — return nil (not mounted ≠ 0).
        guard let queue = dreamingQueues[handle] else { return nil }
        // Non-claiming peek: pendingCount(stream:) does not drain or claim any job.
        return try? await queue.pendingCount(stream: StreamID(rawValue: "dreaming"))
    }

    /// Force-mount the dreaming queue for `handle` so that `dreamingQueuePendingCount`
    /// returns a real count rather than `nil` on a fresh open.
    ///
    /// The dreaming queue is normally lazy-mounted on the first external-origin
    /// recall event (via `enqueueDreamingItem`). This method mounts it eagerly
    /// so the `mootx01 dream` command can probe the persistent `queue.sqlite`
    /// backlog immediately after opening the estate — before any recall has fired
    /// in this session. Idempotent: a second call returns immediately when the
    /// queue is already mounted.
    ///
    /// On mount failure (e.g. `queue.sqlite` cannot be opened), the method
    /// degrades silently to an in-memory backend (same fallback as
    /// `ensureDreamingQueue`) and logs via OSLog. The dreaming command should
    /// treat a subsequent `dreamingQueuePendingCount` of `nil` or `0` as "nothing
    /// to process" — the lease check is still correct.
    ///
    /// Mirrors Rust `EstateCoordinator.ensure_dreaming_queue` (public variant for
    /// external callers, ADR-021 Phase 5).
    func mountDreamingQueue(for handle: EstateHandle) async {
        // Guard: already mounted — nothing to do.
        guard dreamingQueues[handle] == nil else { return }
        // Delegate to the internal lazy-mount helper. Discards the returned
        // tuple — the side effect (populating `dreamingQueues[handle]`) is what
        // we need. Errors degrade to an in-memory backend inside `ensureDreamingQueue`.
        _ = try? await ensureDreamingQueue(for: handle)
    }

    /// Reclaim stale "dreaming" cur jobs for `handle` after acquiring the dreaming
    /// DrainLease.
    ///
    /// Called by the `mootx01 dream` command immediately after it acquires the
    /// dreaming lease via `tryAcquire`. A successful acquire means the prior holder
    /// is dead (lease absent or stale > TTL = 15 s), so every "dreaming" cur row in
    /// the shared `queue.sqlite` is an orphan from a crashed prior dreamer. This
    /// method resets them to "new" so the REM-ALPHA cycle below re-processes them.
    ///
    /// Safety argument: `tryAcquire` succeeded, guaranteeing no OTHER drainer holds
    /// a fresh lease for the "dreaming" stream — so no live dreamer is processing
    /// these cur rows. The lease-TTL gate (15 s) is the structural guarantee; the
    /// caller must NEVER invoke this method without a prior successful `tryAcquire`.
    ///
    /// Non-fatal: a reclaim failure is logged but does not abort the dreaming cycle.
    /// The worst case is that orphaned jobs are not re-attempted in this run; the
    /// next dream invocation will find them still in "cur" and reclaim them then.
    ///
    /// Mirrors Rust `EstateCoordinator.reclaim_stale_dreaming_jobs`.
    func reclaimStaleDreamingJobs(for handle: EstateHandle) async {
        guard let queue = dreamingQueues[handle] else { return }
        do {
            let n = try await queue.reclaimInFlight(stream: StreamID(rawValue: "dreaming"))
            if n > 0 {
                Self.dreamLog.info(
                    "DreamingQueueAPI: reclaimed \(n) orphaned dreaming job(s) for estate \(handle.estateUUID, privacy: .public) — prior dreamer died mid-cycle")
            }
        } catch {
            Self.dreamLog.error(
                "DreamingQueueAPI: reclaimInFlight failed for estate \(handle.estateUUID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Periodic GC sweep: reclaim stale in-flight jobs for streams whose drainer
    /// has died without the daemon restarting (the mid-run worker death case).
    ///
    /// Called by `AutonomicGovernor.tick()` on each GC cadence interval (default
    /// one governor tick ≈ 5 s). For each stream on the estate's queue:
    ///   1. Probe whether the stream's DrainLease is stale (no live holder).
    ///   2. If stale AND cur jobs exist for that stream, reset them to "new".
    ///
    /// The safety guarantee is the same as on-mount reclaim: a stale lease means
    /// the prior holder's heartbeat has not been refreshed within the TTL (15 s),
    /// so the holder is presumed dead. A live drainer refreshes its lease every 5 s
    /// (well inside TTL), so `isHeldByOther` returning false is never a false alarm
    /// for a healthy drainer. The probe uses a fresh ephemeral DrainLease (owner =
    /// "gc-probe-<handle-uuid>") which is never written — it is read-only.
    ///
    /// Covered streams:
    ///   - "dreaming": the `mootx01 dream` one-shot process acquires a dreaming
    ///     lease per run; a killed dream process leaves its lease stale after TTL.
    ///   - "signals": the resident `StandingSignalScheduler` holds the signals lease;
    ///     checked here for completeness (the single-process in-memory variant
    ///     never needs reclaim; the SQLite variant may on a rare multi-process restart).
    ///
    /// The "encode" stream is NOT swept here: the encode drainer is a background
    /// task inside the same resident process (CorpusKit's `runIngestDrainLoop`).
    /// When it dies, the process restarts entirely, triggering the on-mount reclaim
    /// in `mountIngestQueue`. A mid-run encode-worker death in a live process would
    /// mean the entire actor crashed, which also restarts. No separate periodic
    /// sweep needed for encode.
    ///
    /// Non-fatal: sweep errors are logged and never propagate to the governor tick.
    ///
    /// Mirrors Rust `EstateCoordinator.sweep_stale_in_flight_jobs`.
    func sweepStaleInFlightJobs(for handle: EstateHandle, now: Date) async {
        // Derive the estate directory for probe lease files (same location as the
        // real drain leases). Only applicable to SQLite-backed estates — in-memory
        // estates are single-process and never have stale leases.
        //
        // `queueSibling(filename:)` returns an `EstateConfiguration` whose `.backend`
        // is `.sqlite(url:busyTimeout:)`. We extract the URL via the local
        // `BackendConfiguration.sqliteURL` helper (private to this file, at the bottom).
        let cfg = storages[handle]?.configuration
        guard case .sqlite = cfg?.backend,
              let siblingCfg = try? cfg?.queueSibling(filename: "queue.sqlite"),
              let estateDir = siblingCfg.backend.sqliteURL?.deletingLastPathComponent()
        else { return }

        // Stable probe owner token: a GC probe never heartbeats, so its unique
        // identity across calls is fine. Using the handle UUID makes the token
        // deterministic for the same estate across ticks (no UUID() per tick).
        let probeOwner = "gc-probe-\(handle.estateUUID.uuidString)"

        // ── "dreaming" stream ──────────────────────────────────────────────────
        // A `mootx01 dream` process that is killed mid-cycle leaves its "dreaming"
        // lease stale after TTL = 15 s. Probe whether any live dreamer holds the
        // lease; if not and cur rows exist, reclaim them.
        if let dreamQueue = dreamingQueues[handle] {
            let dreamProbe = DrainLease(directory: estateDir, stream: "dreaming",
                                       instanceToken: probeOwner)
            // `isHeldByOther` reads the lease file and returns true only when
            // ANOTHER owner's heartbeat is within TTL. If false: either no lease
            // file exists (never had a dreamer) or the lease is stale (dreamer
            // died) or this probe IS the holder (impossible — we never wrote it).
            // In all three cases it is safe to reclaim.
            if !dreamProbe.isHeldByOther(now: now) {
                do {
                    let n = try await dreamQueue.reclaimInFlight(
                        stream: StreamID(rawValue: "dreaming"))
                    if n > 0 {
                        Self.dreamLog.info(
                            "DreamingQueueAPI GC sweep: reclaimed \(n) orphaned dreaming job(s) for estate \(handle.estateUUID, privacy: .public) — prior dreamer lease stale")
                    }
                } catch {
                    Self.dreamLog.error(
                        "DreamingQueueAPI GC sweep: dreaming reclaim failed for estate \(handle.estateUUID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // ── "signals" stream ───────────────────────────────────────────────────
        // The StandingSignalScheduler holds a signals DrainLease when the estate is
        // SQLite-backed. If the scheduler's process crashes, its lease goes stale.
        // In a resident process the scheduler is long-lived, so this is only a guard
        // for the edge case where the scheduler task is stopped without process exit.
        if let signalQueue = schedulers[handle]?.queue {
            let signalProbe = DrainLease(directory: estateDir, stream: "signals",
                                        instanceToken: probeOwner)
            if !signalProbe.isHeldByOther(now: now) {
                do {
                    let n = try await signalQueue.reclaimInFlight(
                        stream: StreamID(rawValue: "signals"))
                    if n > 0 {
                        Self.dreamLog.info(
                            "DreamingQueueAPI GC sweep: reclaimed \(n) orphaned signals job(s) for estate \(handle.estateUUID, privacy: .public) — signals lease stale")
                    }
                } catch {
                    Self.dreamLog.error(
                        "DreamingQueueAPI GC sweep: signals reclaim failed for estate \(handle.estateUUID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

// MARK: - BackendConfiguration helper (DreamingQueueAPI-local)

private extension BackendConfiguration {
    /// Extract the SQLite file URL from a `.sqlite` backend configuration.
    /// Returns nil for `.inMemory` and `.postgres` backends.
    ///
    /// Mirrors the same helper in `SignalAPI.swift` and `CorpusIngestQueue.swift`.
    /// Each file keeps its own private copy so the property is scoped to its
    /// file — Swift `private` extensions are file-scoped, not module-scoped.
    var sqliteURL: URL? {
        if case let .sqlite(url, _) = self { return url }
        return nil
    }
}
