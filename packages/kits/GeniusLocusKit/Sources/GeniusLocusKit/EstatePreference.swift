// EstatePreference.swift
//
// The generic estate-preference vocabulary: the USER-OWNED switches a user
// can turn off per estate, each stored as the plain string `"on"` or `"off"`
// under its own manifest key. `GeniusLocusKit.provisionPreference(_:_:for:)`
// writes a switch; `GeniusLocusKit.provisionedPreference(_:for:)` reads it
// back.
//
// Every switch is ON unless the manifest holds `"off"`. This inverts the
// fail-quiet contract of the other provisioned-manifest members
// (`provisionDoorConfig`, `provisionModesConfig`, `provisionRecallTuning`,
// `provisionLaneWeights`, `provisionEmbeddingProvider`), where absent means
// nil or the spec default. Here absent means ON: ON is the ruled product
// behaviour for every key in this family, and the seeding capsules write
// `"on"` explicitly so a later change to the default cannot silently flip an
// estate already in use. A stored value that is neither `"on"` nor `"off"`
// also reads as ON — the same fail-quiet contract `provisionedDoorConfig`
// applies to unrecognised JSON.

// MARK: - EstatePreferenceKey

/// The estate-wide preferences a user can turn off. Every key is ON unless the
/// manifest holds "off"; an absent or unrecognised value reads as ON.
///
/// The raw value is the estate-manifest key the switch is stored under.
public enum EstatePreferenceKey: String, CaseIterable, Sendable {
    /// Whether the fact-extraction duty runs on ingested drawers. Seeded on
    /// populated estates by the 1.7 → 1.8 migration capsule (GENIUSLOCUSKIT_SPEC I-27).
    case factExtraction = "fact_extraction"
    /// Whether the consolidation daemon runs.
    case consolidation
    /// Whether the contradiction sweep runs.
    case contradictionSweep = "contradiction_sweep"
    /// Whether the cross-encoder recall route may fire. The same string as
    /// `crossEncoderRoute.preferenceKey`, which the recall router reads through
    /// `provisionedRecallRoutePreferences(estate:)`.
    case crossEncoderRouting = "cross_encoder_routing"
    /// Whether the maintenance daemon runs.
    case maintenance
    /// Whether adaptive recall may adjust the recall recipe.
    case adaptiveRecall = "adaptive_recall"
}

// MARK: - EstatePreferenceValue

/// The two states of an estate preference, stored as the raw string `"on"`
/// or `"off"`. Round-trips through `EstatePreferenceValue(rawValue:)`.
public enum EstatePreferenceValue: String, Sendable, Equatable, CaseIterable {
    /// The switch is enabled. This is what an absent or unrecognised manifest
    /// value reads as.
    case on
    /// The switch is disabled; the consumer of that key skips its work.
    case off

    /// The value applied when the manifest key is absent or holds an
    /// unrecognised string: `.on`.
    public static let `default`: EstatePreferenceValue = .on
}
