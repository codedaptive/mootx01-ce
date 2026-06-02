// ScenarioProfile.swift
//
// Persisted preference signal carried alongside a tournament outcome,
// per NEURONKIT_SPEC § 4.6.
//
// Mission-scope deviation from the spec signature, recorded in
// MISSION_NK_1A_REASONING_SURFACE Known Ambiguity 2: the spec's
// `tournamentReport: TournamentReport` field is intentionally absent
// in this v0.1 shape. `TournamentReport` references `BranchHandle`,
// which does not exist in either version today. The tournament mission
// adds the field once branching ships; no placeholder type is
// invented here. ScenarioProfile is otherwise complete and round-trips
// the rest of § 4.6 verbatim.
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
/// The `tournamentReport` field defined in spec § 4.6 is deferred to
/// the tournament mission (see Mission Known Ambiguity 2).
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
    public let scoringBreakdown: [String: Float]

    /// User-tunable preference weights applied on top of the scoring
    /// breakdown. Spec § 4.6 — saved here so future runs can replay
    /// the preference signal without rebuilding it.
    public let preferenceWeights: [String: Float]

    /// Wall-clock at which the profile was saved. Carried by the
    /// caller; the substrate stores it as ISO8601 TEXT per the fleet
    /// rule. Never derived from `Date()` inside this value type —
    /// the caller passes `now`.
    public let createdAt: Date

    /// Gates whether this profile's signals can be exported for
    /// tiny-model training. Boolean per spec § 4.6 signature; see
    /// the file header for the Bool-storage rule discussion.
    public let trainingEligible: Bool

    public init(
        profileID: UUID = UUID(),
        name: String,
        framingParameters: [String: String],
        scoringBreakdown: [String: Float],
        preferenceWeights: [String: Float],
        createdAt: Date,
        trainingEligible: Bool = false
    ) {
        self.profileID = profileID
        self.name = name
        self.framingParameters = framingParameters
        self.scoringBreakdown = scoringBreakdown
        self.preferenceWeights = preferenceWeights
        self.createdAt = createdAt
        self.trainingEligible = trainingEligible
    }
}
