//! The generic estate-preference vocabulary: the USER-OWNED preferences a user
//! can configure per estate, each stored as a plain string under its own
//! manifest key. `EstateCoordinator::provision_preference` writes a preference;
//! `EstateCoordinator::provisioned_preference` reads it back. Rust twin of
//! Swift `EstatePreference.swift`.
//!
//! The six on/off switches are ON unless the manifest holds `"off"`. This
//! inverts the fail-quiet contract of the other provisioned-manifest members
//! (`provision_door_config`, `provision_modes_config`, `provision_recall_tuning`,
//! `provision_lane_weights`, `provision_embedding_provider`), where absent
//! means `None` or the spec default. Here absent means the key's `default_value`:
//! `On` for the six switches, `Nuextract` for `fact_extractor`. The seeding
//! capsules write `"on"` explicitly for the six switches so a later default
//! change cannot silently flip an estate already in use. A stored value outside
//! `key.allowed_values()` also reads as `key.default_value()` — the same
//! fail-quiet contract `provisioned_door_config` applies to unrecognised JSON.

/// The estate-wide preferences a user can configure. Every key reads as its
/// `default_value()` when absent or when the manifest holds an unrecognised string.
///
/// `as_str` is the estate-manifest key the preference is stored under. Mirrors
/// Swift `EstatePreferenceKey` (raw value = manifest key).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EstatePreferenceKey {
    /// Whether the fact-extraction duty runs on ingested drawers. Seeded on
    /// populated estates by the 1.7 → 1.8 migration capsule
    /// (GENIUSLOCUSKIT_SPEC I-27).
    FactExtraction,
    /// Whether the consolidation daemon runs.
    Consolidation,
    /// Whether the contradiction sweep runs.
    ContradictionSweep,
    /// Whether the cross-encoder recall route may fire. The same string as
    /// `CROSS_ENCODER_ROUTE.preference_key`, which the recall router reads
    /// through the director's preference map.
    CrossEncoderRouting,
    /// Whether the maintenance daemon runs.
    Maintenance,
    /// Whether adaptive recall may adjust the recall recipe.
    AdaptiveRecall,
    /// Which extractor the fact-extraction duty uses: `Nuextract` (default)
    /// or `Apple`; `FactExtraction` is the on/off master switch.
    FactExtractor,
}

impl EstatePreferenceKey {
    /// Every key, in declaration order. Mirrors Swift `CaseIterable.allCases`.
    pub const ALL: [Self; 7] = [
        Self::FactExtraction,
        Self::Consolidation,
        Self::ContradictionSweep,
        Self::CrossEncoderRouting,
        Self::Maintenance,
        Self::AdaptiveRecall,
        Self::FactExtractor,
    ];

    /// The estate-manifest key this switch is stored under. Mirrors Swift
    /// `rawValue`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::FactExtraction => "fact_extraction",
            Self::Consolidation => "consolidation",
            Self::ContradictionSweep => "contradiction_sweep",
            Self::CrossEncoderRouting => "cross_encoder_routing",
            Self::Maintenance => "maintenance",
            Self::AdaptiveRecall => "adaptive_recall",
            Self::FactExtractor => "fact_extractor",
        }
    }

    /// The values this key accepts. The six switches take `On`/`Off`; the
    /// extractor choice takes the engine names.
    pub fn allowed_values(self) -> &'static [EstatePreferenceValue] {
        match self {
            Self::FactExtractor => &[EstatePreferenceValue::Nuextract, EstatePreferenceValue::Apple],
            _ => &[EstatePreferenceValue::On, EstatePreferenceValue::Off],
        }
    }

    /// What an absent or unrecognised manifest value reads as. `On` for the six
    /// switches; `Nuextract` for the extractor choice.
    pub fn default_value(self) -> EstatePreferenceValue {
        match self {
            Self::FactExtractor => EstatePreferenceValue::Nuextract,
            _ => EstatePreferenceValue::On,
        }
    }

    /// Decode a manifest key. Returns `None` for a string that names no
    /// preference. Mirrors the Swift `init(rawValue:)` fallible initialiser.
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|key| key.as_str() == s)
    }
}

/// The states of an estate preference. On/off switches use `On` and `Off`;
/// the `fact_extractor` key uses `Nuextract` and `Apple`. Round-trips through
/// `as_str` / `from_str`. Mirrors Swift `EstatePreferenceValue`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EstatePreferenceValue {
    /// The switch is enabled. Default for the six on/off keys when absent.
    #[default]
    On,
    /// The switch is disabled; the consumer of that key skips its work.
    Off,
    /// Use the NuExtract model for fact extraction. Default for `FactExtractor`.
    Nuextract,
    /// Use the Apple on-device model for fact extraction.
    Apple,
}

impl EstatePreferenceValue {
    /// The stored string for this value. Mirrors Swift `rawValue`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::On => "on",
            Self::Off => "off",
            Self::Nuextract => "nuextract",
            Self::Apple => "apple",
        }
    }

    /// Decode a stored string. Returns `None` for unrecognised values;
    /// callers fall back to `key.default_value()`.
    /// Mirrors the Swift `init(rawValue:)` fallible initialiser.
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "on" => Some(Self::On),
            "off" => Some(Self::Off),
            "nuextract" => Some(Self::Nuextract),
            "apple" => Some(Self::Apple),
            _ => None,
        }
    }
}
