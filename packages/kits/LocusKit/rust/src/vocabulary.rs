//! LocusKit's contribution to the substrate write-gate vocabulary —
//! mirror of `LocusKitVocabulary.swift`. Operational + provenance slots
//! with their cookbook §2.4 / §2.5 legal values; the substrate basis is
//! supplied by the gate. Frozen at open via `audit_gate::freeze`.

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_lib::audit_gate::{freeze, Column, FieldSlot, Vocabulary, VocabularyError};

/// Operational + provenance slots (bitset/flag fields carry no value set).
pub fn union_slots() -> Vec<FieldSlot> {
    vec![
        // operational bitmap (cookbook §2.4)
        FieldSlot::with_values(
            Column::Operational,
            0,
            6,
            "capture_channel",
            &[0, 1, 2, 3, 4, 5],
        ),
        FieldSlot::with_values(
            Column::Operational,
            6,
            6,
            "content_kind",
            &[0, 1, 2, 3, 4, 5, 6],
        ),
        FieldSlot::new(Column::Operational, 12, 12, "feature_flags"),
        FieldSlot::new(Column::Operational, 24, 1, "state_extension"),
        FieldSlot::new(Column::Operational, 25, 1, "lineage_clustering"),
        // provenance bitmap (cookbook §2.5)
        FieldSlot::with_values(
            Column::Provenance,
            0,
            6,
            "source_type",
            &[0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        ),
        FieldSlot::with_values(
            Column::Provenance,
            6,
            6,
            "channel",
            &[0, 1, 2, 3, 4, 5, 6, 7, 8, 15, 16],
        ),
        FieldSlot::with_values(
            Column::Provenance,
            12,
            6,
            "prov_capture_channel",
            &[0, 1, 2, 3, 4, 5],
        ),
        FieldSlot::with_values(Column::Provenance, 18, 6, "confirmation", &[0, 1, 2, 3, 4]),
        FieldSlot::with_values(
            Column::Provenance,
            24,
            6,
            "confidence",
            &[0, 16, 32, 48, 56],
        ),
        FieldSlot::with_values(
            Column::Provenance,
            30,
            6,
            "sensitivity_at_capture",
            &[0, 16, 32, 48],
        ),
        FieldSlot::with_values(
            Column::Provenance,
            36,
            6,
            "enrichment_status",
            &[0, 1, 2, 3, 4],
        ),
    ]
}

/// Freeze the union into a `Vocabulary` for arming the gate.
pub fn frozen() -> Result<Vocabulary, VocabularyError> {
    freeze(union_slots())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vocabulary_freezes_clean() {
        assert!(
            frozen().is_ok(),
            "LocusKit union must freeze without overlap/collision"
        );
    }
}
