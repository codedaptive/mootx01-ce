import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// One room's dismissal rate — withdrawn / (active + withdrawn), the
/// enacted "bias against."
public struct DismissalRate: Sendable, Equatable, Codable {
    public let room: String
    public let rate: Double
    public init(room: String, rate: Double) {
        self.room = room
        self.rate = rate
    }
}

/// What the estate leans toward and away from.
public struct BiasReport: Sendable {
    /// Over-represented rooms (bias > 0), most-favored first.
    public let biasedFor: [CategoryBias]
    /// Under-represented / avoided rooms (bias < 0), most-avoided last.
    public let biasedAgainst: [CategoryBias]
    /// Per-room withdrawal rate, most-dismissed first (ties by room).
    public let dismissal: [DismissalRate]
    /// Learned preference per room (Bradley-Terry over confirmations as
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

    /// UserConfirmed: all rows written via Estate.capture are stamped
    /// Confirmation.userConfirmed at write time. The state filter selects
    /// active vs withdrawn from among the confirmed set.
    private static func frame(for state: State) -> LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.userConfirmed, .state(state)])
    }

    /// The endorsement signal: rows the user confirmed (still active) —
    /// All normally-captured rows are userConfirmed; kept separate for
    /// clarity in the recipe's intent vs the state-scoped frame(for:).
    private static var confirmedFrame: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.userConfirmed, .state(.active)])
    }

    /// Room → drawer count over a recalled set.
    private static func roomCounts(_ drawers: [Drawer]) -> [String: Double] {
        drawers.reduce(into: [:]) { counts, drawer in
            counts[drawer.room, default: 0] += 1
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
        // Sorted room keys ⇒ a deterministic category order (same
        // discipline as the Rust BTree walk).
        let activeCounts = activeByRoom.keys.sorted().map { (label: $0, mass: activeByRoom[$0]!) }
        let biases = NeuronKit.representationBias(estate: activeCounts, reference: reference)
        let biasedFor = biases.filter { $0.bias > 0 }
        let biasedAgainst = biases.filter { $0.bias < 0 }

        // Dismissal: withdrawn / (active + withdrawn) per room —
        // most-dismissed first, ties by ascending room.
        let withdrawnByRoom = roomCounts(withdrawn)
        let dismissal = withdrawnByRoom
            .map { room, withdrawnCount in
                DismissalRate(
                    room: room,
                    rate: withdrawnCount / ((activeByRoom[room] ?? 0) + withdrawnCount))
            }
            .sorted { a, b in
                if a.rate != b.rate { return a.rate > b.rate }
                return a.room < b.room
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
        let records = rooms.map { room in
            (label: room,
             endorsements: Int(confirmedByRoom[room] ?? 0),
             dismissals: Int(withdrawnByRoom[room] ?? 0))
        }
        let learned = try NeuronKit.learnedPreference(records: records)

        return BiasReport(
            biasedFor: biasedFor, biasedAgainst: biasedAgainst,
            dismissal: dismissal, learned: learned)
    }
}
