import Foundation
import LocusKit
import QueueKit

/// Dreaming substrate reads — the three estate-handle-scoped reads the
/// dreaming daemon's substrate reader seam performs (NEURONKIT_SPEC § 3.1
/// steps 1, 2, 5). They follow the same B-1 pattern as `recallTunnels`:
/// GLK resolves the handle, delegates to LocusKit.Estate, returns the
/// result. NeuronKit's `EstateDreamingReader` calls these through the
/// public GeniusLocusKit surface rather than reaching LocusKit directly.
public extension GeniusLocusKit {

    /// Recall-trace rows whose `recalledAt` falls in `[since, now]`.
    ///
    /// The dreaming daemon calls this in step 1 to build its reward map:
    /// rows in the window are scored through the `RewardSource` seam and
    /// accumulated per drawer target. `since` is `now − tickInterval`;
    /// `now` is the deterministic clock the caller supplies.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    func recentRecallTraces(
        in handle: EstateHandle,
        since: Date,
        now: Date
    ) async throws -> [RecallTraceItem] {
        let estate = try estate(for: handle)
        return try await estate.recentRecallTraces(since: since, now: now)
    }

    /// All non-tombstoned tunnels across all wings of the addressed estate.
    ///
    /// The dreaming daemon calls this in step 5 to build the tunnel-key
    /// set used for duplicate suppression — a candidate whose drawer pair
    /// is already linked by a Tunnel is dropped before scoring. Delegates
    /// to `Estate.allTunnels()`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    func allTunnels(in handle: EstateHandle) async throws -> [Tunnel] {
        let estate = try estate(for: handle)
        return try await estate.allTunnels()
    }

    /// All non-tombstoned, non-retired tunnels across all wings (T13 / ADR-021 Phase 7).
    ///
    /// OMEGA uses this to enumerate the active dreamed-tunnel population before
    /// applying its retire predicate (`isDreamed AND not reinforced`). Retired
    /// tunnels are excluded so that a re-proposed tunnel that was previously
    /// retired does not appear in the active set until a new `associate` verb
    /// promotes it from proposal to confirmed tunnel. Delegates to
    /// `Estate.allActiveTunnels()`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    func allActiveTunnels(in handle: EstateHandle) async throws -> [Tunnel] {
        let estate = try estate(for: handle)
        return try await estate.allActiveTunnels()
    }

    /// Retire a tunnel by flipping bit 13 of its `operationalBitmap` (T13 / ADR-021 Phase 7).
    ///
    /// Called by OMEGA through the GLK seam (B-1: NeuronKit reaches the substrate
    /// only through GLK verb surface, never directly). Delegates to
    /// `Estate.retireTunnel(id:changedBy:now:)`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale;
    ///   `LocusKitError.tunnelNotFound` if no non-tombstoned tunnel with `tunnelId` exists.
    func retireTunnel(
        in handle: EstateHandle,
        id tunnelId: String,
        changedBy: String,
        now: Date
    ) async throws {
        let estate = try estate(for: handle)
        try await estate.retireTunnel(id: tunnelId, changedBy: changedBy, now: now)
    }

    /// All non-tombstoned drawers in the addressed estate.
    ///
    /// The dreaming daemon's co-occurrence builder calls this to derive
    /// latent candidate pairs from the drawer graph. This is the same
    /// estate-wide walk `GLK.feedAuditLog` and the audit-log recovery use;
    /// the dreaming adapter is a second consumer. Delegates to
    /// `Estate.allDrawers()`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    func allDrawers(in handle: EstateHandle) async throws -> [Drawer] {
        let estate = try estate(for: handle)
        return try await estate.allDrawers()
    }

    /// Up to `limit` drawers in the addressed estate (including tombstoned
    /// rows), in `filedAt`-ascending order, fully hydrated.
    ///
    /// The bounded counterpart to `allDrawers(in:)`. The maintenance reader
    /// uses this so the health scan reads O(min(N_estate, limit)) rows at the
    /// storage tier rather than pulling the full corpus and truncating in
    /// process — the Swift parity of the Rust coordinator's
    /// `all_drawers_bounded`. Passing `nil` reads the full corpus, identical
    /// to `allDrawers(in:)`. Delegates to `Estate.allDrawers(limit:)`.
    ///
    /// B-10a: internal read — no `traceLimit` is set, so no recall-trace rows
    /// are written.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    func allDrawers(in handle: EstateHandle, limit: Int?) async throws -> [Drawer] {
        let estate = try estate(for: handle)
        return try await estate.allDrawers(limit: limit)
    }

    /// Delete recall-trace rows whose `recalledAt` is strictly before
    /// `cutoff` in the addressed estate. Returns the number of rows deleted.
    ///
    /// Called after the dreaming daemon reward sweep to keep the
    /// recall_trace table bounded. The cutoff must be derived from the
    /// caller's deterministic `now`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    @discardableResult
    func pruneRecallTraces(in handle: EstateHandle, olderThan cutoff: Date) async throws -> Int {
        let estate = try estate(for: handle)
        return try await estate.pruneRecallTraces(olderThan: cutoff)
    }

    // MARK: - Corpus growth probe (auto-reindex support)

    /// Return the maintained vocabulary anchor for the Corpus registered against
    /// `handle` — the maximum maintained vocabulary size across its trainable
    /// providers.
    ///
    /// Called by the dreaming daemon's `CorpusGrowthProbe` adapter to measure
    /// VOCABULARY growth since the last basis retrain (P3, item 5): the
    /// distributional bases freeze their vocabulary at training time, so the
    /// retrain trigger fires on vocabulary drift, not raw chunk count. Returns 0
    /// when no Corpus is registered (e.g. a `.locusOnly` estate) or no trainable
    /// provider is present, so the growth gate never fires on un-wired estates —
    /// a safe and correct default.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    func corpusVocabAnchor(handle: EstateHandle) async throws -> Int {
        guard registry[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        guard let corpus = corpusKits[handle] else {
            // No Corpus registered for this estate (LocusOnly kind) — growth
            // gate should never fire; return 0 so the growth delta stays zero.
            return 0
        }
        return await corpus.maintainedVocabAnchor()
    }

    /// Drain all currently-pending dreaming jobs for the estate addressed by
    /// `handle` and return one drawer-id array per drained job.
    ///
    /// Each inner array is the set of drawer ids from one `DreamingItem` — a
    /// single recall event that co-recalled ≥ 2 distinct drawers (T6 spec §12.2).
    /// The caller (NeuronKit's `EstateDreamingReader`) forms co-recall pairs from
    /// these windows and bumps the per-pair count on the dreaming daemon.
    ///
    /// A single pass is performed over the currently-available dreaming jobs.
    /// The drain is non-exclusive (no DrainLease is held — that is T9 / REM-ALPHA).
    /// Each claimed job is replied Done immediately so it does not re-appear on
    /// the next drain. If the dreaming queue has not been mounted for this estate
    /// yet (no external recall fired since open), returns an empty array.
    ///
    /// Errors from individual `reply` calls are captured and logged, never thrown —
    /// an already-completed job is a benign idempotency case.
    ///
    /// - Parameter handle: The open estate to drain.
    /// - Returns: An array of drawer-id arrays, one per drained dreaming job.
    ///   Empty when the queue is not mounted or has no pending jobs.
    func drainDreamingItems(for handle: EstateHandle) async throws -> [[String]] {
        // Guard: queue must be mounted (ensureDreamingQueue is internal to GLK;
        // the queue is mounted lazily on the first external recall).
        guard dreamingQueues[handle] != nil else { return [] }
        let queue = dreamingQueues[handle]!

        // Drain the "dreaming" stream — claims available pending jobs.
        let streamID = StreamID(rawValue: "dreaming")
        let leases: [(job: Job, sessionID: SessionID)]
        do {
            leases = try await queue.drain(stream: streamID)
        } catch {
            // drain failure is non-fatal: no items returned, caller gets empty windows.
            Self.dreamLog.error(
                "DreamingReads: drain failed for estate \(handle.estateUUID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }

        guard !leases.isEmpty else { return [] }

        // Decode payloads and collect Job IDs for batch reply-Done.
        var windows: [[String]] = []
        var completions: [(jobID: JobID, status: ObservationStatus)] = []
        completions.reserveCapacity(leases.count)

        let decoder = JSONDecoder()
        for (job, _) in leases {
            if let item = try? decoder.decode(DreamingItem.self, from: job.payload) {
                windows.append(item.drawerIds)
            } else {
                // Corrupt payload: skip but still reply Done to consume the job.
                Self.dreamLog.error(
                    "DreamingReads: failed to decode DreamingItem payload for job \(job.id.rawValue, privacy: .public)"
                )
            }
            completions.append((jobID: job.id, status: .done))
        }

        // Batch reply-Done: one pass over all claimed jobs.
        do {
            try await queue.reply(batch: completions)
        } catch {
            Self.dreamLog.error(
                "DreamingReads: batch reply-Done failed for estate \(handle.estateUUID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        return windows
    }

    /// Trigger a full Corpus basis retrain for the estate addressed by `handle`.
    ///
    /// Called by the dreaming daemon's `CorpusGrowthProbe` adapter when corpus
    /// growth since the last retrain crosses the auto-reindex threshold. Delegates
    /// to `Corpus.reindex(now:)`, which retrains every trainable provider on the
    /// full corpus snapshot and re-embeds all chunks so dense vocabulary stays
    /// current.
    ///
    /// This is a Brain-layer operation: the daemon triggers it through the
    /// `CorpusGrowthProbe` seam (B-1 compliant), never by calling CorpusKit
    /// directly. The operation is intentionally synchronous from the daemon's
    /// perspective — the daemon awaits it, so it runs to completion before the
    /// cycle returns. This is appropriate because reindex is expensive and must
    /// not race with a concurrent ingest drain; actor isolation serialises the
    /// GLK actor's accesses.
    ///
    /// A no-op when no Corpus is registered for `handle` (`.locusOnly` estates).
    ///
    /// - Parameters:
    ///   - handle: The open estate whose Corpus to retrain. Must be in the registry.
    ///   - now: Deterministic timestamp for the basis `trained_at` stamp and
    ///     re-embedded vector filing timestamps. Must be passed by the caller;
    ///     never call `Date()` inside the engine (CLAUDE.md determinism rule).
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale;
    ///   a `CorpusKitError` if the retrain or re-embed fails.
    func reindexCorpus(handle: EstateHandle, now: Date) async throws {
        guard registry[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        guard let corpus = corpusKits[handle] else {
            // No Corpus registered — LocusOnly estate; nothing to reindex.
            return
        }
        try await corpus.reindex(now: now)
    }
}
