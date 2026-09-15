// FactExtractionSetting.swift
//
// The USER-OWNED fact-extraction toggle stored as a plain string under the
// `"fact_extraction"` manifest key per estate. The user (or an operator
// tool) provisions it via `GeniusLocusKit.provisionFactExtraction(_:for:)`.
// No consumer reads this setting yet; once one is wired, it will call
// `GeniusLocusKit.provisionedFactExtraction(for:)` to read it back.
//
// Default is ON — an absent key returns `.on`. This inverts the fail-quiet
// contract of the other members of this family, where absent means "use the
// default" and the default happens to be off or nil. Here the default is
// explicitly `.on`: ON is the ruled product behaviour as of the feature's
// introduction, and the seeding capsule (GLKMigrationV1_7ToV1_8) writes
// `"on"` explicitly so that a later change to the default cannot silently
// flip the value for an estate a user has already been running.
//
// A stored value that is neither `"on"` nor `"off"` returns `.on` — the same
// fail-quiet contract `provisionedDoorConfig` applies to unrecognised JSON.
//
// Part of the same provisioned-manifest family as `provisionDoorConfig`,
// `provisionModesConfig`, `provisionRecallTuning`, `provisionLaneWeights`,
// and `provisionEmbeddingProvider`. Seeded on populated estates through the
// 1.7 → 1.8 migration capsule (GENIUSLOCUSKIT_SPEC I-27).

// MARK: - FactExtractionSetting

/// The fact-extraction toggle governing whether a future consumer runs
/// extraction on ingested drawers. No consumer reads this setting yet.
///
/// Default is `.on` — an estate that carries no `fact_extraction` key, or
/// one whose stored value is not recognised, is treated as `.on`. The
/// absent-means-on contract is the only member of this setting family with
/// this sense; see the file header for the rationale.
///
/// Stored as the raw string `"on"` or `"off"` under the
/// `"fact_extraction"` estate-manifest key. Round-trips through
/// `FactExtractionSetting(rawValue:)`.
public enum FactExtractionSetting: String, Sendable, Equatable, CaseIterable {
    /// Fact extraction is enabled. This is the default when no value is
    /// stored: the accessor returns `.on` for an absent or unrecognised key.
    case on = "on"
    /// Fact extraction is disabled; when a consumer reads this setting,
    /// it will skip the extraction step. Previously extracted facts are retained.
    case off = "off"

    /// The default value — `.on` — applied when the manifest key is absent
    /// or holds an unrecognised string.
    ///
    /// Note: absent key means ON, not OFF. ON is the ruled product behaviour
    /// for this feature; the capsule seeds the value explicitly so a later
    /// change to the default cannot silently flip an estate already in use.
    public static let `default`: FactExtractionSetting = .on
}
