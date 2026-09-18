// EstatePreference.swift
//
// The generic estate-preference vocabulary: the USER-OWNED switches a user
// can turn off per estate, each stored as a plain string under its own
// manifest key. `GeniusLocusKit.provisionPreference(_:_:for:)` writes a
// preference; `GeniusLocusKit.provisionedPreference(_:for:)` reads it back.
//
// The six on/off switches are ON unless the manifest holds `"off"`. This
// inverts the fail-quiet contract of the other provisioned-manifest members
// (`provisionDoorConfig`, `provisionModesConfig`, `provisionRecallTuning`,
// `provisionLaneWeights`, `provisionEmbeddingProvider`), where absent means
// nil or the spec default. Here absent means the key's `defaultValue`: ON for
// the six switches, `nuextract` for `fact_extractor`. The seeding capsules
// write `"on"` explicitly for the six switches so a later default change
// cannot silently flip an estate already in use. A stored value that is
// neither in `key.allowedValues` also reads as `key.defaultValue` — the same
// fail-quiet contract `provisionedDoorConfig` applies to unrecognised JSON.

// MARK: - EstatePreferenceKey

/// The estate-wide preferences a user can configure. Every key reads as its
/// `defaultValue` when absent or when the manifest holds an unrecognised string.
///
/// The raw value is the estate-manifest key the preference is stored under.
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
    /// Which extractor the fact-extraction duty uses: `nuextract` (default) or
    /// `apple`; `fact_extraction` is the on/off master switch.
    case factExtractor = "fact_extractor"
    /// ADR-027 D2: the contradiction hunt's third candidate lane, a probe's
    /// container-mates. Off by default and never seeded: the 1.1 benchmark
    /// measures it off and on against one artifact set.
    case chestContradictionCandidates = "chest_contradiction_candidates"
    /// ADR-027 D3: the recall diversity rerank treats two candidates in one
    /// container as one topic. Off by default and never seeded; a call may
    /// override it (`GLKRecallRequest.chestDiversity`).
    case chestRecallDiversity = "chest_recall_diversity"

    /// The values this key accepts. The switches take on/off; the
    /// extractor choice takes the engine names.
    public var allowedValues: [EstatePreferenceValue] {
        self == .factExtractor ? [.nuextract, .apple] : [.on, .off]
    }

    /// What an absent or unrecognised manifest value reads as: on for the
    /// six seeded switches, off for the two chest switches, `nuextract`
    /// for the extractor choice.
    public var defaultValue: EstatePreferenceValue {
        switch self {
        case .factExtractor: return .nuextract
        case .chestContradictionCandidates, .chestRecallDiversity: return .off
        default: return .on
        }
    }
}

// MARK: - EstatePreferenceValue

/// The states of an estate preference. On/off switches use `.on` and `.off`;
/// the `fact_extractor` key uses `.nuextract` and `.apple`. Round-trips
/// through `EstatePreferenceValue(rawValue:)`.
public enum EstatePreferenceValue: String, Sendable, Equatable, CaseIterable {
    /// The switch is enabled. Default for the six on/off keys when absent.
    case on
    /// The switch is disabled; the consumer of that key skips its work.
    case off
    /// Use the NuExtract model for fact extraction. Default for `fact_extractor`.
    case nuextract
    /// Use the Apple on-device model for fact extraction.
    case apple
}
