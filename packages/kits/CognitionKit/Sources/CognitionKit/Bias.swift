import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// One parentNodeId's dismissal rate — withdrawn / (active + withdrawn),
/// the enacted "bias against."
public struct DismissalRate: Sendable, Equatable, Codable {
    public let nodeId: String
    public let rate: Double
    public init(nodeId: String, rate: Double) {
        self.nodeId = nodeId
        self.rate = rate
    }
}

/// What the estate leans toward and away from.
public struct BiasReport: Sendable {
    /// Over-represented rooms (bias > 0), most-favored first.
    public let biasedFor: [CategoryBias]
    /// Under-represented / avoided rooms (bias < 0), most-avoided last.
    public let biasedAgainst: [CategoryBias]
    /// Per-parentNodeId withdrawal rate, most-dismissed first (ties by
    /// ascending nodeId).
    public let dismissal: [DismissalRate]
    /// Learned preference per parentNodeId (Bradley-Terry over confirmations as
    /// endorsements and withdrawals as dismissals), re-centered on
    /// neutral — strongest first. `strength > 0` = preferred by
    /// curation, `< 0` = disfavored, `≈ 0` = no curation signal yet.
    public let learned: [PreferenceStrength]

    public init(
        biasedFor: [CategoryBias], biasedAgainst: [CategoryBias],
        dismissal: [DismissalRate], learned: [PreferenceStrength]
    ) {
        self.biasedFor = biasedFor
        self.biasedAgainst = biasedAgainst
        self.dismissal = dismissal
        self.learned = learned
    }
}

/// Bias — the conscious "what you lean toward and away from" recipe
/// (Lens 4, Preference & judgment). Three honest signals over the
/// estate:
///   - REPRESENTATION: each room's share of the active set vs a
///     reference, signed (NeuronKit `representationBias`) —
///     over-weighted = bias FOR, under-weighted/absent = bias AGAINST.
///   - DISMISSAL: each room's withdrawal rate — what you actively take
///     back. A high dismissal rate is "bias against" you enacted, not
///     just absence.
///   - LEARNED PREFERENCE: a Bradley-Terry utility per room fitted from
///     actual CURATION choices — confirmations as endorsements,
///     withdrawals as dismissals (NeuronKit `learnedPreference`). This
///     is preference REVEALED BY CURATION, distinct from
///     representation's capture-volume share: a room captured heavily
///     but never confirmed ranks high in representation yet low here —
///     "what you actually keep vs what merely accumulates."
///
/// Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — three
/// recalls via GLK (active + confirmed + withdrawn) + NeuronKit
/// `representationBias` and `learnedPreference`. Read-only (B-6, I-6).
/// Swift version of `run_bias`.
public enum Bias {

    /// Unconfirmed admits freshly-captured rows (suppresses the default
    /// user-confirmed ceiling); the state filter selects active vs
    /// withdrawn.
    private static func frame(for state: State) -> LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.unconfirmed, .state(state)])
    }

    /// The endorsement signal: rows the user confirmed (still active) —
    /// the complement of the unconfirmed frame above.
    private static var confirmedFrame: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.userConfirmed, .state(.active)])
    }

    /// ParentNodeId → drawer count over a recalled set.
    private static func roomCounts(_ drawers: [Drawer]) -> [String: Double] {
        drawers.reduce(into: [:]) { counts, drawer in
            counts[drawer.parentNodeId, default: 0] += 1
        }
    }

    /// Compute the estate's representation bias (active rooms vs
    /// `reference`), dismissal rates (withdrawn rooms), and learned
    /// preference (Bradley-Terry over confirmations vs withdrawals).
    /// Read-only; a recall failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        reference: [(label: String, mass: Double)]
    ) async throws -> BiasReport {
        let active = try await kit.recall(handle, frame(for: .active))
        let confirmed = try await kit.recall(handle, confirmedFrame)
        let withdrawn = try await kit.recall(handle, frame(for: .withdrawn))

        let activeByRoom = roomCounts(active)
        // Sorted parentNodeId keys ⇒ a deterministic category order
        // (same discipline as the Rust BTree walk).
        let activeCounts = activeByRoom.keys.sorted().map { (label: $0, mass: activeByRoom[$0]!) }
        let biases = NeuronKit.representationBias(estate: activeCounts, reference: reference)
        let biasedFor = biases.filter { $0.bias > 0 }
        let biasedAgainst = biases.filter { $0.bias < 0 }

        // Dismissal: withdrawn / (active + withdrawn) per parentNodeId
        // — most-dismissed first, ties by ascending nodeId.
        let withdrawnByRoom = roomCounts(withdrawn)
        let dismissal = withdrawnByRoom
            .map { nodeId, withdrawnCount in
                DismissalRate(
                    nodeId: nodeId,
                    rate: withdrawnCount / ((activeByRoom[nodeId] ?? 0) + withdrawnCount))
            }
            .sorted { a, b in
                if a.rate != b.rate { return a.rate > b.rate }
                return a.nodeId < b.nodeId
            }

        // Learned preference: per-room curation record (confirmations as
        // endorsements, withdrawals as dismissals) over the union of
        // every room that appears in any of the three sets — so an
        // active-but-uncurated room is reported at neutral rather than
        // omitted.
        let confirmedByRoom = roomCounts(confirmed)
        let rooms = Set(activeByRoom.keys)
            .union(confirmedByRoom.keys)
            .union(withdrawnByRoom.keys)
            .sorted()
        var records = rooms.map { room in
            (label: room,
             endorsements: Int(confirmedByRoom[room] ?? 0),
             dismissals: Int(withdrawnByRoom[room] ?? 0))
        }
        // DoS guard: the distinct-room count is attacker-influenceable (rooms
        // are set at capture time), and every room becomes a Bradley-Terry
        // competitor in a dense O(n²) fit. Cap at maxPreferenceRooms, keeping
        // the highest-signal rooms (most endorsements+dismissals) — the ones
        // the preference model is about — with the room name as a
        // deterministic tie-break so the truncation is stable across runs.
        if records.count > NeuronKit.maxPreferenceRooms {
            records.sort {
                let sa = $0.endorsements + $0.dismissals
                let sb = $1.endorsements + $1.dismissals
                return sa != sb ? sa > sb : $0.label < $1.label
            }
            records = Array(records.prefix(NeuronKit.maxPreferenceRooms))
        }
        let learned = try NeuronKit.learnedPreference(records: records)

        return BiasReport(
            biasedFor: biasedFor, biasedAgainst: biasedAgainst,
            dismissal: dismissal, learned: learned)
    }
}
