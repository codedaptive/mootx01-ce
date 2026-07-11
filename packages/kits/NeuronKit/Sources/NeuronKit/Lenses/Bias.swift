// Preference lenses (SPEC § 7.3, Lens 4). Two halves of "what the estate leans
// toward / away from": representationBias is the DISTRIBUTIONAL half (a signed
// share difference, honest about being exactly that); learnedPreference is the
// LEARNED half (a Bradley-Terry utility fitted from curation choices via the
// anchor reduction). Pure and side-effect-free (I-18). learnedPreference
// surfaces NeuronKit's gated `bradleyTerry` fitter — it owns no fitting math
// (I-17), only the anchor construction and baseline re-centring.

/// One category's representation bias: its estate share, reference share, and
/// the signed difference. Positive = over-represented; negative = avoided.
public struct CategoryBias: Sendable, Equatable, Codable {
    public let label: String
    public let estateShare: Double
    public let referenceShare: Double
    public let bias: Double            // estateShare − referenceShare
    public init(label: String, estateShare: Double, referenceShare: Double, bias: Double) {
        self.label = label
        self.estateShare = estateShare
        self.referenceShare = referenceShare
        self.bias = bias
    }
}

/// One room's learned preference strength on the Bradley-Terry log scale,
/// re-centred so the neutral baseline reads 0. Positive = preferred relative to
/// neutral; the curation counts that produced it are carried through.
public struct PreferenceStrength: Sendable, Equatable, Codable {
    public let label: String
    public let strength: Double
    public let confidenceLow: Double
    public let confidenceHigh: Double
    public let endorsements: Int
    public let dismissals: Int
    public init(label: String, strength: Double, confidenceLow: Double,
                confidenceHigh: Double, endorsements: Int, dismissals: Int) {
        self.label = label
        self.strength = strength
        self.confidenceLow = confidenceLow
        self.confidenceHigh = confidenceHigh
        self.endorsements = endorsements
        self.dismissals = dismissals
    }
}

extension NeuronKit {
    /// The reserved name for the shared neutral baseline competitor in the
    /// anchor reduction. A curation record literally named this collides with
    /// the synthetic baseline and surfaces as `MOOTx01Error.selfPairing`.
    public static let preferenceBaselineSentinel = "PREFERENCE_BASELINE"

    /// Maximum number of preference records (rooms) the dense Bradley-Terry
    /// fitter will accept. Each record becomes a competitor; the fitter
    /// allocates O(n²) matrices and runs O(n²) sweeps, so an unbounded room
    /// count is a CPU/memory-exhaustion vector (rooms are attacker-creatable
    /// via capture). 200 is far above any legitimate estate's distinct-room
    /// cardinality while keeping the dense fit bounded. `Bias.run` truncates
    /// to the highest-signal rooms before calling; this guard also protects
    /// direct callers. Mirrors Rust `MAX_PREFERENCE_ROOMS`.
    public static let maxPreferenceRooms = 200

    /// Signed representation bias of `estate` against `reference`, per category
    /// over the UNION of both label sets. Each side's mass is normalised to a
    /// share; a category present only in the reference gets estate share 0
    /// (strongly negative = avoided). Sorted by bias descending — most
    /// over-represented first, most avoided last, ties by ascending label.
    /// Both empty ⇒ empty (C-16).
    public static func representationBias(estate: [(label: String, mass: Double)],
                                          reference: [(label: String, mass: Double)]) -> [CategoryBias] {
        let estateShareByLabel = shares(of: estate)
        let referenceShareByLabel = shares(of: reference)

        var labels = Set(estateShareByLabel.keys)
        labels.formUnion(referenceShareByLabel.keys)
        guard !labels.isEmpty else { return [] }

        let result = labels.map { label -> CategoryBias in
            let e = estateShareByLabel[label] ?? 0
            let r = referenceShareByLabel[label] ?? 0
            return CategoryBias(label: label, estateShare: e, referenceShare: r, bias: e - r)
        }
        return result.sorted { lhs, rhs in
            lhs.bias == rhs.bias ? lhs.label < rhs.label : lhs.bias > rhs.bias
        }
    }

    /// Fit a Bradley-Terry preference over rooms from per-room curation records
    /// `(label, endorsements, dismissals)`, re-centred on a neutral baseline and
    /// returned strongest first (ties by ascending label). Labels must be
    /// unique. Empty input ⇒ empty output.
    ///
    /// The anchor reduction: every room competes against one shared neutral
    /// baseline, beating it once per endorsement and losing once per dismissal,
    /// with a uniform +1 pseudo-win added in EACH direction between every room
    /// and the baseline. That minimal symmetric prior makes the directed win
    /// graph strongly connected — so the fit is finite even for a one-sided room
    /// and `disconnectedComparisonGraph` cannot arise — and shrinks
    /// little-curated rooms toward the baseline. The baseline's fitted strength
    /// is subtracted from every room so the baseline reads exactly 0.
    ///
    /// - Throws: `MOOTx01Error.selfPairing` only if a room is literally named
    ///   the baseline sentinel.
    public static func learnedPreference(records: [(label: String, endorsements: Int,
                                                    dismissals: Int)]) throws -> [PreferenceStrength] {
        guard !records.isEmpty else { return [] }
        // Bound the dense fitter: reject an over-large competitor set rather
        // than allocate O(n²) matrices and run O(n²) sweeps over it (DoS guard).
        guard records.count <= maxPreferenceRooms else {
            throw MOOTx01Error.tooManyCompetitors(count: records.count)
        }

        let baseline = preferenceBaselineSentinel

        // Build the anchor-reduction tally. Each room vs the baseline:
        //   +1 pseudo-win each direction (the symmetric prior),
        //   +endorsements room-beats-baseline, +dismissals baseline-beats-room.
        //
        // Guard: clamp endorsements and dismissals to ≥ 0 before adding the +1
        // prior. Curation counts are stored as Int and should always be
        // non-negative, but corrupted records or misrouted callbacks could
        // produce negative values. A negative + 1 still yields a negative
        // PairwiseOutcome.count, which contributes no tally weight (per
        // PairwiseOutcome spec) while still adding the competitor to the
        // connected-graph check — silently defeating the neutral prior and
        // potentially producing infinite or NaN Bradley-Terry scores. Clamping
        // to max(0, x) ensures the minimum effective count is always 1 (the
        // prior alone), so every room has at least one win and one loss against
        // the baseline regardless of the incoming data quality.
        var outcomes: [PairwiseOutcome] = []
        for record in records {
            // A room named the baseline would pair with itself in the tally;
            // surface it rather than silently merge (§ 6).
            if record.label == baseline {
                throw MOOTx01Error.selfPairing(competitor: baseline)
            }
            outcomes.append(PairwiseOutcome(winner: record.label, loser: baseline,
                                            count: max(0, record.endorsements) + 1))
            outcomes.append(PairwiseOutcome(winner: baseline, loser: record.label,
                                            count: max(0, record.dismissals) + 1))
        }

        // Surface the gated fitter (I-17): it does the MM iteration, gauge-fix,
        // and CI bounds.
        let fitted = try bradleyTerry(outcomes: outcomes)

        // Re-centre on the baseline's fitted strength so the baseline reads 0
        // and each room's sign is its preference relative to neutral.
        let baselineStrength = fitted.first { $0.competitorID == baseline }?.strength ?? 0
        // Aggregate duplicate labels by summing their counts. The Bradley-Terry
        // fitter already treats repeated records of one label as a single
        // competitor (identity is the label), so the per-label display counts
        // are the totals across those records. Plain Dictionary(uniqueKeysWith‌‌:)
        // would instead TRAP the process on a duplicate label; summing matches
        // the Rust leg and the fitter's own competitor aggregation.
        let countsByLabel = Dictionary(
            records.map { ($0.label, ($0.endorsements, $0.dismissals)) },
            uniquingKeysWith: { lhs, rhs in (lhs.0 + rhs.0, lhs.1 + rhs.1) })

        let rooms = fitted.compactMap { score -> PreferenceStrength? in
            guard score.competitorID != baseline else { return nil }
            let counts = countsByLabel[score.competitorID] ?? (0, 0)
            return PreferenceStrength(
                label: score.competitorID,
                strength: score.strength - baselineStrength,
                confidenceLow: score.confidenceLow - baselineStrength,
                confidenceHigh: score.confidenceHigh - baselineStrength,
                endorsements: counts.0,
                dismissals: counts.1)
        }
        return rooms.sorted { lhs, rhs in
            lhs.strength == rhs.strength ? lhs.label < rhs.label : lhs.strength > rhs.strength
        }
    }

    /// Normalise `(label, mass)` pairs to shares summing to 1 (a side with no
    /// mass yields an empty map ⇒ all shares 0). Internal shaping helper.
    private static func shares(of items: [(label: String, mass: Double)]) -> [String: Double] {
        let total = items.reduce(0) { $0 + $1.mass }
        guard total > 0 else { return [:] }
        var out = [String: Double](minimumCapacity: items.count)
        for item in items { out[item.label, default: 0] += item.mass / total }
        return out
    }
}
