import Foundation
import GeniusLocusKit

/// Production adapter that binds `DreamingSubstrateReader` to a live
/// GeniusLocusKit estate (NEURONKIT_SPEC § 3.1).
///
/// `DreamingSubstrateReader` is the read seam the daemon uses during a
/// cycle. This adapter satisfies it by delegating to the three substrate
/// reads GLK exposes through `recentRecallTraces(in:since:now:)`,
/// `drainDreamingItems(for:)`, and `allTunnels(in:)` — all B-1-compliant
/// calls through the public GeniusLocusKit verb surface.
///
/// ── Why this lives in NeuronKit, not GeniusLocusKit ──────────────────
/// `DreamingSubstrateReader` is declared here in NeuronKit. A conforming
/// type must import NeuronKit. GeniusLocusKit is a dependency of NeuronKit
/// (GLK sits below NK in the stack), so GLK cannot import NK without
/// creating a circular package dependency. NeuronKit is the only package
/// that can see both the protocol and the GLK estate surface, making it
/// the natural home for this adapter.
///
/// ── Co-occurrence algorithm (v2, drain-fed) ──────────────────────────
/// v2 derives co-recall pairs from the estate's dreaming queue rather
/// than the drawer graph. Each drained window is the drawer-ID set from
/// one recall event that co-recalled ≥ 2 drawers (a `DreamingItem`
/// payload written by the recall verb when it enqueues the dreaming job).
/// The daemon enumerates unordered pairs within each window and bumps
/// `coRecallCounts` once per pair per window (not per cycle) so counts
/// accumulate across drain events. `drainDreamingWindow()` delegates to
/// `GeniusLocusKit.drainDreamingItems(for:)`, which drains the queue and
/// replies Done to consumed jobs before returning.
public struct EstateDreamingReader: DreamingSubstrateReader {

    private let handle: EstateHandle
    private let kit: GeniusLocusKit

    /// Construct an adapter over the addressed estate.
    ///
    /// - Parameters:
    ///   - handle: the estate to read from.
    ///   - kit: the GeniusLocusKit actor that owns the estate registry.
    public init(handle: EstateHandle, kit: GeniusLocusKit) {
        self.handle = handle
        self.kit = kit
    }

    // MARK: - DreamingSubstrateReader

    /// Recall-trace rows in the `[since, now]` reward window.
    /// Delegates to `GeniusLocusKit.recentRecallTraces(in:since:now:)`.
    public func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem] {
        try await kit.recentRecallTraces(in: handle, since: since, now: now)
    }

    /// Drained dreaming-queue windows for the estate.
    ///
    /// Each inner array is the set of drawer IDs from one `DreamingItem`
    /// (one recall event that co-recalled ≥ 2 drawers). Returns an empty
    /// array when the dreaming queue has not been mounted for this estate
    /// yet (no recall has fired since open). Delegates to
    /// `GeniusLocusKit.drainDreamingItems(for:)`.
    public func drainDreamingWindow() async throws -> [[String]] {
        try await kit.drainDreamingItems(for: handle)
    }

    /// Existing tunnels for duplicate suppression.
    /// Delegates to `GeniusLocusKit.allTunnels(in:)`.
    public func existingTunnels() async throws -> [Tunnel] {
        try await kit.allTunnels(in: handle)
    }

    /// All non-retired dreamed tunnels (T13 / ADR-021 Phase 7).
    ///
    /// Fetches the active-tunnel set from GLK and filters to those with
    /// `isDreamed == true`. Declared tunnels (`isDreamed == false`) are never
    /// returned so OMEGA can never retire them (§ 12.8 guard). Delegates to
    /// `GeniusLocusKit.allActiveTunnels(in:)`.
    public func dreamedActiveTunnels() async throws -> [Tunnel] {
        let active = try await kit.allActiveTunnels(in: handle)
        return active.filter { $0.isDreamed }
    }
}
