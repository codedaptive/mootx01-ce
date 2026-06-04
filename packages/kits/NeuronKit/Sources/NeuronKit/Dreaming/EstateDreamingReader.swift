import Foundation
import GeniusLocusKit

/// Production adapter that binds `DreamingSubstrateReader` to a live
/// GeniusLocusKit estate (NEURONKIT_SPEC § 3.1).
///
/// `DreamingSubstrateReader` is the read seam the daemon uses during a
/// cycle. This adapter satisfies it by delegating to the three substrate
/// reads GLK exposes through `recentRecallTraces(in:since:now:)`,
/// `allDrawers(in:)`, and `allTunnels(in:)` — all B-1-compliant calls
/// through the public GeniusLocusKit verb surface.
///
/// ── Why this lives in NeuronKit, not GeniusLocusKit ──────────────────
/// `DreamingSubstrateReader` is declared here in NeuronKit. A conforming
/// type must import NeuronKit. GeniusLocusKit is a dependency of NeuronKit
/// (GLK sits below NK in the stack), so GLK cannot import NK without
/// creating a circular package dependency. NeuronKit is the only package
/// that can see both the protocol and the GLK estate surface, making it
/// the natural home for this adapter.
///
/// ── Co-occurrence algorithm (v1) ─────────────────────────────────────
/// v1 derives co-occurrence candidates from the drawer graph: drawers
/// that share a room are latent co-occurrence pairs. For each room with
/// ≥ 2 drawers, the adapter emits one `CoOccurrenceObservation` per
/// pair. `attempts` is set to the room's drawer count as a proxy for
/// how much evidence the room accumulates. `evidenceTargets` are the
/// two drawer IDs so the daemon can look them up in its reward map.
///
/// The full NMF-based builder is a follow-on mission; v1 intentionally
/// uses only the structure the estate already exposes.
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

    /// Latent co-occurrence candidates derived from the drawer graph (v1).
    ///
    /// Groups all non-tombstoned drawers by (wing, room). For every room
    /// with ≥ 2 drawers, emits one `CoOccurrenceObservation` per pair.
    /// Pairs are enumerated in stable lexicographic order of drawer IDs
    /// so the daemon's EWC++ consolidation is deterministic across cycles
    /// over the same estate state.
    public func coOccurrenceObservations() async throws -> [CoOccurrenceObservation] {
        let drawers = try await kit.allDrawers(in: handle)
        return Self.buildObservations(from: drawers)
    }

    /// Existing tunnels for duplicate suppression.
    /// Delegates to `GeniusLocusKit.allTunnels(in:)`.
    public func existingTunnels() async throws -> [Tunnel] {
        try await kit.allTunnels(in: handle)
    }

    // MARK: - Co-occurrence builder (package-internal for testing)

    /// Build co-occurrence observations from a drawer snapshot.
    ///
    /// Exposed as `internal` so tests can exercise the algorithm
    /// deterministically without needing a live estate.
    static func buildObservations(from drawers: [Drawer]) -> [CoOccurrenceObservation] {
        // Group non-tombstoned drawers by their (wing, room) location.
        var byRoom: [RoomKey: [String]] = [:]
        for drawer in drawers where drawer.tombstonedAt == nil {
            let key = RoomKey(wing: drawer.wing, room: drawer.room)
            byRoom[key, default: []].append(drawer.id)
        }

        var observations: [CoOccurrenceObservation] = []
        for (_, ids) in byRoom {
            guard ids.count >= 2 else { continue }
            // Sort for determinism, then enumerate all pairs.
            let sorted = ids.sorted()
            let roomCount = sorted.count
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    observations.append(
                        CoOccurrenceObservation(
                            endpointA: sorted[i],
                            endpointB: sorted[j],
                            // roomCount is a proxy for evidence density in this room.
                            attempts: roomCount,
                            evidenceTargets: [sorted[i], sorted[j]]
                        )
                    )
                }
            }
        }
        // Stable output order: sort by (endpointA, endpointB) so cycles over
        // unchanged state always present candidates in the same sequence.
        return observations.sorted {
            $0.endpointA == $1.endpointA
                ? $0.endpointB < $1.endpointB
                : $0.endpointA < $1.endpointA
        }
    }
}

// MARK: - Private helpers

/// Hashable (wing, room) pair used as the grouping key.
private struct RoomKey: Hashable {
    let wing: String
    let room: String
}
