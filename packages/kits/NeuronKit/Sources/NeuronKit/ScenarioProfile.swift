// ScenarioProfile.swift
//
// Persisted preference signal carried alongside a tournament outcome,
// per NEURONKIT_SPEC § 4.6.
//
// `tournamentReport: TournamentReport?` is a runtime-only field.
// `TournamentReport` carries `any BranchHandle`, which is not `Codable`,
// so the field is excluded from JSON persistence via custom `CodingKeys`.
// The JSON wire shape therefore never contains a `tournamentReport` key.
// Callers that receive a `ScenarioProfile` via the NeuronKit verb layer
// may inspect `tournamentReport` in memory; it is not reconstructed on
// decode. This matches the spec § 4.6 intent: the report is advisory,
// not part of the durable preference signal.
//
// Bool-storage note (CLAUDE.md hard rule): the schema-invariants rule
// forbids `public var x: Bool` *stored* properties on entities whose
// boolean state lives in SQLite bitmap columns. ScenarioProfile is
// not such an entity — NeuronKit never executes SQL (B-1), and
// ScenarioProfile is a NeuronKit value type persisted through the
// estate manifest's opaque storage path. `trainingEligible: Bool` is
// the spec's own signature (§ 4.6) and is carried verbatim. If a
// later mission wraps ScenarioProfile into a SQLite-backed bitmap
// noun owned by LocusKit, the bitmap encoding lives there; the
// NeuronKit-facing value type stays Bool to match the spec.

import Foundation

/// Persisted preference signal produced by `saveScenarioProfile` over
/// a tournament outcome. Stored in the estate manifest under
/// `scenario_profiles`; survives migration per spec § 4.6.
///
/// `tournamentReport` is a runtime-only field (not serialised to JSON):
/// see the file header for the Codable exclusion rationale.
public struct ScenarioProfile: Sendable, Equatable, Codable {

    /// Stable identifier — caller-supplied or generated at save time.
    public let profileID: UUID

    /// Human-readable name. Free-form.
    public let name: String

    /// Framing parameter snapshot. Stored as a stable JSON-shaped
    /// dictionary of string-keyed string values; the spec's
    /// `[String: Any]` is narrowed to `[String: String]` here for
    /// Codable conformance and bit-identical Rust round-trip. Callers
    /// serialising structured data store the JSON-encoded payload as
    /// the value.
    public let framingParameters: [String: String]

    /// Per-signal breakdown of the tournament's scoring. Keys are the
    /// signal names (e.g., "averageReward"); values are the numeric
    /// score the tournament observed.
    public let scoringBreakdown: [String: Double]

    /// User-tunable preference weights applied on top of the scoring
    /// breakdown. Spec § 4.6 — saved here so future runs can replay
    /// the preference signal without rebuilding it.
    public let preferenceWeights: [String: Double]

    /// Wall-clock at which the profile was saved. Carried by the
    /// caller; the substrate stores it as ISO8601 TEXT per the fleet
    /// rule. Never derived from `Date()` inside this value type —
    /// the caller passes `now`.
    public let createdAt: Date

    /// Gates whether this profile's signals can be exported for
    /// tiny-model training. Boolean per spec § 4.6 signature; see
    /// the file header for the Bool-storage rule discussion.
    public let trainingEligible: Bool

    /// Advisory tournament outcome attached at profile-save time
    /// (NEURONKIT_SPEC § 4.6). Runtime-only: not serialised to JSON
    /// (see the file header). `nil` on profiles decoded from persisted
    /// storage; populated by `saveScenarioProfile` at the moment of
    /// creation.
    public let tournamentReport: TournamentReport?

    // MARK: - Codable

    /// CodingKeys excludes `tournamentReport` because `TournamentReport`
    /// carries `any BranchHandle`, which is not `Codable`. The JSON wire
    /// shape is stable and does not contain that key.
    private enum CodingKeys: String, CodingKey {
        case profileID
        case name
        case framingParameters
        case scoringBreakdown
        case preferenceWeights
        case createdAt
        case trainingEligible
    }

    /// Decode from JSON. `tournamentReport` is always `nil` after decode —
    /// it is a runtime-only advisory value that is not part of the wire shape.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try c.decode(UUID.self, forKey: .profileID)
        name = try c.decode(String.self, forKey: .name)
        framingParameters = try c.decode([String: String].self, forKey: .framingParameters)
        scoringBreakdown = try c.decode([String: Double].self, forKey: .scoringBreakdown)
        preferenceWeights = try c.decode([String: Double].self, forKey: .preferenceWeights)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        trainingEligible = try c.decode(Bool.self, forKey: .trainingEligible)
        // Never decoded — runtime-only advisory value, not part of wire shape.
        tournamentReport = nil
    }

    // MARK: - Equatable

    /// Custom `Equatable` because `TournamentReport` embeds
    /// `any BranchHandle`, which is not `Equatable`. Two profiles are
    /// equal when all their persisted fields are equal; `tournamentReport`
    /// is excluded from equality (runtime-only, advisory).
    public static func == (lhs: ScenarioProfile, rhs: ScenarioProfile) -> Bool {
        lhs.profileID == rhs.profileID
            && lhs.name == rhs.name
            && lhs.framingParameters == rhs.framingParameters
            && lhs.scoringBreakdown == rhs.scoringBreakdown
            && lhs.preferenceWeights == rhs.preferenceWeights
            && lhs.createdAt == rhs.createdAt
            && lhs.trainingEligible == rhs.trainingEligible
    }

    public init(
        profileID: UUID = UUID(),
        name: String,
        framingParameters: [String: String],
        scoringBreakdown: [String: Double],
        preferenceWeights: [String: Double],
        createdAt: Date,
        trainingEligible: Bool = false,
        tournamentReport: TournamentReport? = nil
    ) {
        self.profileID = profileID
        self.name = name
        self.framingParameters = framingParameters
        self.scoringBreakdown = scoringBreakdown
        self.preferenceWeights = preferenceWeights
        self.createdAt = createdAt
        self.trainingEligible = trainingEligible
        self.tournamentReport = tournamentReport
    }
}
