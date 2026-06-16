import Foundation
import LocusKit

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
}
