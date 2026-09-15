//! The generic estate-preference vocabulary: the USER-OWNED switches a user
//! can turn off per estate, each stored as the plain string `"on"` or `"off"`
//! under its own manifest key. `EstateCoordinator::provision_preference`
//! writes a switch; `EstateCoordinator::provisioned_preference` reads it back.
//! Rust twin of Swift `EstatePreference.swift`.
//!
//! Every switch is ON unless the manifest holds `"off"`. This inverts the
//! fail-quiet contract of the other provisioned-manifest members
//! (`provision_door_config`, `provision_modes_config`, `provision_recall_tuning`,
//! `provision_lane_weights`, `provision_embedding_provider`), where absent
//! means `None` or the spec default. Here absent means ON: ON is the ruled
//! product behaviour for every key in this family, and the seeding capsules
//! write `"on"` explicitly so a later change to the default cannot silently
//! flip an estate already in use. A stored value that is neither `"on"` nor
//! `"off"` also reads as ON — the same fail-quiet contract
//! `provisioned_door_config` applies to unrecognised JSON.

/// The estate-wide preferences a user can turn off. Every key is ON unless the
/// manifest holds `"off"`; an absent or unrecognised value reads as ON.
///
/// `as_str` is the estate-manifest key the switch is stored under. Mirrors
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
}

impl EstatePreferenceKey {
    /// Every key, in declaration order. Mirrors Swift `CaseIterable.allCases`.
    pub const ALL: [Self; 6] = [
        Self::FactExtraction,
        Self::Consolidation,
        Self::ContradictionSweep,
        Self::CrossEncoderRouting,
        Self::Maintenance,
        Self::AdaptiveRecall,
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
        }
    }

    /// Decode a manifest key. Returns `None` for a string that names no
    /// preference. Mirrors the Swift `init(rawValue:)` fallible initialiser.
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|key| key.as_str() == s)
    }
}

/// The two states of an estate preference, stored as the plain string `"on"`
/// or `"off"`. Round-trips through `as_str` / `from_str`. Mirrors Swift
/// `EstatePreferenceValue`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EstatePreferenceValue {
    /// The switch is enabled. This is what an absent or unrecognised manifest
    /// value reads as.
    #[default]
    On,
    /// The switch is disabled; the consumer of that key skips its work.
    Off,
}

impl EstatePreferenceValue {
    /// The stored string for this value. Mirrors Swift `rawValue`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::On => "on",
            Self::Off => "off",
        }
    }

    /// Decode a stored string. Returns `None` for unrecognised values —
    /// callers fall back to `EstatePreferenceValue::default()` (`On`).
    /// Mirrors the Swift `init(rawValue:)` fallible initialiser.
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "on" => Some(Self::On),
            "off" => Some(Self::Off),
            _ => None,
        }
    }
}
