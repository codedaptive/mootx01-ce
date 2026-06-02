//! The output of the deterministic linguistic pipeline (per
//! MISSION_AE_01_LINGUISTIC_PIPELINE.md). Pure data; identical
//! shape to the Swift version's `LatticeAnchorInference` struct so
//! callers can serialize and conformance-test cross-language.
//!
//! Consumed by GeniusLocusKit's capture verb path and by the
//! standing-signal enrichment scheduler (GLK-04). The enrichment
//! status bits are OR'd into the provenance column's bits 36-41
//! per cookbook section 2.5.

use serde::{Deserialize, Serialize};

/// The result of inferring a lattice anchor from a drawer's
/// content. Carries the MDCC code, the optional Wikidata Q-ID, a
/// confidence score, and the provenance enrichment-status bit
/// transition the caller should apply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LatticeAnchorInference {
    /// The MDCC code at the deepest level the classifier reached
    /// with sufficient evidence. Empty string means
    /// classification failed; the caller should leave the
    /// drawer's anchor code unset or fall back to a default.
    pub code: String,

    /// The Wikidata Q-ID for the drawer's primary concept, or
    /// `None` if the resolver could not find a confident match.
    /// When `None`, the enrichment status records `QidPending`
    /// so a later enrichment pass can retry.
    pub wikidata_qid: Option<String>,

    /// Confidence in the inference, packed into the 6-bit
    /// provenance confidence field's value set (0=null, 16=low,
    /// 32=medium, 48=high, 56=verified). Reported as a `u8` so
    /// the caller can OR it into the provenance bitmap directly.
    pub confidence: u8,

    /// The value to OR into bits 36-41 of the provenance column
    /// to record the enrichment status. Values per cookbook
    /// section 2.5: 0=none, 1=qid_pending, 2=qid_completed,
    /// 3=closure_cached, 4-63 reserved.
    pub enrichment_status_bits: u8,

    /// The pipeline mode that produced this inference. The Rust
    /// version is always `DeterministicReference`; the Swift version
    /// may also report `AppleNLAccel` per MISSION_AE_02.
    pub pipeline_mode: LinguisticPipelineMode,
}

/// The compile-time mode of the linguistic pipeline. Recorded in
/// the estate manifest so callers can audit and federate
/// accordingly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum LinguisticPipelineMode {
    /// Deterministic in-tree pipeline. Cross-language
    /// conformance guaranteed against the Swift version.
    /// Federation-compatible.
    DeterministicReference,

    /// Apple NaturalLanguage acceleration path. Swift-only.
    /// Federation-disabled. The Rust version never produces this
    /// mode; it appears only on anchors produced by an
    /// Apple-accelerated Swift build.
    AppleNlAccel,
}

/// Confidence values mapped to the 6-bit provenance confidence
/// field's value set. Provided as a convenience for the
/// linguistic pipeline implementation; mirrors cookbook section
/// 2.5.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum AnchorConfidence {
    Null = 0,
    Low = 16,
    Medium = 32,
    High = 48,
    Verified = 56,
}

impl AnchorConfidence {
    pub const fn raw(self) -> u8 {
        self as u8
    }
}

/// Enrichment status values for bits 36-41 of the provenance
/// column. Mirrors cookbook section 2.5.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum EnrichmentStatus {
    /// The drawer has not been processed by the enrichment
    /// pipeline yet.
    None = 0,

    /// UDC resolved; Q-ID resolution pending (the resolver did
    /// not find a confident match and the maintenance daemon
    /// should retry).
    QidPending = 1,

    /// UDC and Q-ID both resolved.
    QidCompleted = 2,

    /// Q-ID resolved and the Wikidata subclass closure has been
    /// cached for graph-distance queries.
    ClosureCached = 3,
}

impl EnrichmentStatus {
    pub const fn raw(self) -> u8 {
        self as u8
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inference_roundtrips_through_json() {
        let inference = LatticeAnchorInference {
            code: "004.42".to_string(),
            wikidata_qid: Some("Q21198".to_string()),
            confidence: AnchorConfidence::Medium.raw(),
            enrichment_status_bits: EnrichmentStatus::QidCompleted.raw(),
            pipeline_mode: LinguisticPipelineMode::DeterministicReference,
        };
        let json = serde_json::to_string(&inference).expect("serialize");
        let decoded: LatticeAnchorInference = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded, inference);
    }

    #[test]
    fn confidence_levels_match_provenance_field_values() {
        assert_eq!(AnchorConfidence::Null.raw(), 0);
        assert_eq!(AnchorConfidence::Low.raw(), 16);
        assert_eq!(AnchorConfidence::Medium.raw(), 32);
        assert_eq!(AnchorConfidence::High.raw(), 48);
        assert_eq!(AnchorConfidence::Verified.raw(), 56);
    }

    #[test]
    fn enrichment_status_values_match_cookbook_section_2_5() {
        assert_eq!(EnrichmentStatus::None.raw(), 0);
        assert_eq!(EnrichmentStatus::QidPending.raw(), 1);
        assert_eq!(EnrichmentStatus::QidCompleted.raw(), 2);
        assert_eq!(EnrichmentStatus::ClosureCached.raw(), 3);
    }

    #[test]
    fn pipeline_mode_serializes_kebab_case() {
        let m = LinguisticPipelineMode::DeterministicReference;
        let s = serde_json::to_string(&m).expect("serialize");
        assert_eq!(s, "\"deterministic-reference\"");

        let m2 = LinguisticPipelineMode::AppleNlAccel;
        let s2 = serde_json::to_string(&m2).expect("serialize");
        assert_eq!(s2, "\"apple-nl-accel\"");
    }
}
