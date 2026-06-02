// theorems_tests.rs — Rust mirror of the Mission GLK-08 theorem
// demonstrations. The Swift reference is
// `Tests/GeniusLocusKitTests/TheoremsTests.swift`.
//
// Each test restates one theorem from
// `docs/specs/GENIUSLOCUS_IMPLEMENTATION_PLAN_v0.35.md` section 7 over
// the substrate primitives shipped on the Rust side
// (`UnifiedAuditLog`, `AuditProjectionFold`). The inputs and expected
// shape match the Swift fixture so a conformance audit can compare the
// two side by side.
//
// Conformance fixtures only. No production source changed.

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;

use genius_locus_kit::audit::{
    AuditProjectionFold, AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog,
    UnifiedAuditValue, UnifiedAuditVerb,
};

// MARK: - Helpers

fn hlc(step: i64) -> HLC {
    HLC::new(step, 0, 1)
}

/// Build a deterministic 16-byte row id from an index. Tests use this
/// rather than a real UUID generator so the inputs are reproducible
/// across runs and side-by-side with the Swift fixture.
fn row(index: u16) -> EntryUUID {
    let mut bytes = [0u8; 16];
    bytes[0] = (index & 0xFF) as u8;
    bytes[1] = ((index >> 8) & 0xFF) as u8;
    EntryUUID(bytes)
}

fn entry(
    step: i64,
    verb: UnifiedAuditVerb,
    row: EntryUUID,
    field_path: &str,
    after: UnifiedAuditValue,
) -> UnifiedAuditEntry {
    UnifiedAuditEntry::new(
        AuditTier::Locus,
        hlc(step),
        verb,
        row,
        field_path.to_string(),
        UnifiedAuditValue::Null,
        after,
        None,
    )
}

// MARK: - Theorem 4: Graceful degradation under model versioning

#[test]
fn theorem_4_model_version_upgrade_preserves_every_transition() {
    let row_a = row(1);
    let row_b = row(2);
    let row_c = row(3);
    let mut log = UnifiedAuditLog::new();

    log.add(entry(
        1,
        UnifiedAuditVerb::Capture,
        row_a,
        "provenance.model_version",
        UnifiedAuditValue::StringValue("v1".to_string()),
    ));
    log.add(entry(
        2,
        UnifiedAuditVerb::Capture,
        row_b,
        "provenance.model_version",
        UnifiedAuditValue::StringValue("v1".to_string()),
    ));
    log.add(entry(
        3,
        UnifiedAuditVerb::Capture,
        row_c,
        "provenance.model_version",
        UnifiedAuditValue::StringValue("v1".to_string()),
    ));

    log.add(entry(
        10,
        UnifiedAuditVerb::Migrate,
        row_a,
        "provenance.model_version",
        UnifiedAuditValue::StringValue("v2".to_string()),
    ));
    log.add(entry(
        11,
        UnifiedAuditVerb::Migrate,
        row_b,
        "provenance.model_version",
        UnifiedAuditValue::StringValue("v2".to_string()),
    ));
    log.add(entry(
        12,
        UnifiedAuditVerb::Migrate,
        row_c,
        "provenance.model_version",
        UnifiedAuditValue::StringValue("v2".to_string()),
    ));

    let pre = AuditProjectionFold::project_as_of(&log, hlc(9));
    for r in [row_a, row_b, row_c] {
        let proj = pre
            .row(AuditTier::Locus, r)
            .expect("row present pre-upgrade");
        assert_eq!(
            proj.fields.get("provenance.model_version"),
            Some(&UnifiedAuditValue::StringValue("v1".to_string()))
        );
    }

    let mid = AuditProjectionFold::project_as_of(&log, hlc(10));
    assert_eq!(
        mid.row(AuditTier::Locus, row_a)
            .and_then(|r| r.fields.get("provenance.model_version"))
            .cloned(),
        Some(UnifiedAuditValue::StringValue("v2".to_string()))
    );
    assert_eq!(
        mid.row(AuditTier::Locus, row_b)
            .and_then(|r| r.fields.get("provenance.model_version"))
            .cloned(),
        Some(UnifiedAuditValue::StringValue("v1".to_string()))
    );
    assert_eq!(
        mid.row(AuditTier::Locus, row_c)
            .and_then(|r| r.fields.get("provenance.model_version"))
            .cloned(),
        Some(UnifiedAuditValue::StringValue("v1".to_string()))
    );

    let post = AuditProjectionFold::project(&log);
    for r in [row_a, row_b, row_c] {
        let proj = post
            .row(AuditTier::Locus, r)
            .expect("row present post-upgrade");
        assert_eq!(
            proj.fields.get("provenance.model_version"),
            Some(&UnifiedAuditValue::StringValue("v2".to_string()))
        );
    }

    // Audit log preserves every transition regardless of the asOf cut.
    assert_eq!(log.count(), 6);
    for r in [row_a, row_b, row_c] {
        let entries = log.entries_for_row(r, AuditTier::Locus);
        assert_eq!(entries.len(), 2);
        assert_eq!(
            entries.iter().map(|e| e.verb).collect::<Vec<_>>(),
            vec![UnifiedAuditVerb::Capture, UnifiedAuditVerb::Migrate]
        );
    }
}

// MARK: - Theorem 6: Empirically-tunable storage fidelity

#[test]
fn theorem_6_storage_fidelity_round_trip_reversibility() {
    let mut log = UnifiedAuditLog::new();
    for i in 0..16u16 {
        log.add(entry(
            (i as i64) + 1,
            UnifiedAuditVerb::Capture,
            row(i),
            "tag_bits",
            UnifiedAuditValue::Bitmap(1u64 << (i % 8)),
        ));
    }

    let full_fidelity = AuditProjectionFold::project(&log);
    let reprojected = AuditProjectionFold::project(&log);
    assert_eq!(
        full_fidelity, reprojected,
        "discarding and reprojecting is bit-for-bit reversible"
    );

    // Re-fold the entries in reverse insertion order. Convergence
    // states the projection depends only on the set of entries, not
    // on insertion order. The two projections must be equal.
    let mut permuted = UnifiedAuditLog::new();
    let mut ordered = log.ordered_entries();
    ordered.reverse();
    for e in ordered {
        permuted.add(e);
    }
    let permuted_projection = AuditProjectionFold::project(&permuted);
    assert_eq!(full_fidelity, permuted_projection);
}

// MARK: - Theorem 7: First-class memory corrections

#[test]
fn theorem_7_first_class_corrections_four_version_lifecycle() {
    let target = row(1);
    let mut log = UnifiedAuditLog::new();

    log.add(entry(
        1,
        UnifiedAuditVerb::Capture,
        target,
        "provenance",
        UnifiedAuditValue::StringValue("captured".to_string()),
    ));
    log.add(entry(
        2,
        UnifiedAuditVerb::Mutate,
        target,
        "provenance",
        UnifiedAuditValue::StringValue("user-confirmed".to_string()),
    ));
    log.add(entry(
        3,
        UnifiedAuditVerb::Mutate,
        target,
        "provenance",
        UnifiedAuditValue::StringValue("user-corrected".to_string()),
    ));
    log.add(entry(
        4,
        UnifiedAuditVerb::Mutate,
        target,
        "provenance",
        UnifiedAuditValue::StringValue("agent-contested".to_string()),
    ));

    assert_eq!(log.count(), 4);
    assert_eq!(log.entries_for_row(target, AuditTier::Locus).len(), 4);

    let current = AuditProjectionFold::project(&log);
    assert_eq!(
        current
            .row(AuditTier::Locus, target)
            .and_then(|r| r.fields.get("provenance"))
            .cloned(),
        Some(UnifiedAuditValue::StringValue(
            "agent-contested".to_string()
        ))
    );

    let expected = [
        (1i64, "captured"),
        (2, "user-confirmed"),
        (3, "user-corrected"),
        (4, "agent-contested"),
    ];
    for (step, label) in expected {
        let snap = AuditProjectionFold::project_as_of(&log, hlc(step));
        assert_eq!(
            snap.row(AuditTier::Locus, target)
                .and_then(|r| r.fields.get("provenance"))
                .cloned(),
            Some(UnifiedAuditValue::StringValue(label.to_string())),
            "asOf step {} should read '{}'",
            step,
            label
        );
    }

    let verbs: Vec<_> = log
        .entries_for_row(target, AuditTier::Locus)
        .iter()
        .map(|e| e.verb)
        .collect();
    assert_eq!(
        verbs,
        vec![
            UnifiedAuditVerb::Capture,
            UnifiedAuditVerb::Mutate,
            UnifiedAuditVerb::Mutate,
            UnifiedAuditVerb::Mutate,
        ]
    );
}

// MARK: - Theorem 8: First-class memory provenance

/// Same bit assignment as the Swift fixture so the conformance audit
/// can compare the two implementations against the same input.
const CONFIRMED_BIT: u64 = 0x1;

#[test]
fn theorem_8_provenance_confirmed_bit_selects_exactly_confirmed_rows() {
    let mut log = UnifiedAuditLog::new();
    let mut confirmed_rows: Vec<EntryUUID> = Vec::new();
    let mut unconfirmed_rows: Vec<EntryUUID> = Vec::new();

    // Ten unconfirmed observations.
    for i in 0..10u16 {
        let r = row(i);
        unconfirmed_rows.push(r);
        log.add(entry(
            (i as i64) + 1,
            UnifiedAuditVerb::Capture,
            r,
            "provenance.bits",
            UnifiedAuditValue::Bitmap(0),
        ));
    }
    // Ten user-confirmed directives — capture clear, mutate sets the
    // confirmed bit.
    for i in 0..10u16 {
        let r = row(100 + i);
        confirmed_rows.push(r);
        log.add(entry(
            100 + (i as i64) * 2,
            UnifiedAuditVerb::Capture,
            r,
            "provenance.bits",
            UnifiedAuditValue::Bitmap(0),
        ));
        log.add(entry(
            100 + (i as i64) * 2 + 1,
            UnifiedAuditVerb::Mutate,
            r,
            "provenance.bits",
            UnifiedAuditValue::Bitmap(CONFIRMED_BIT),
        ));
    }

    let projection = AuditProjectionFold::project(&log);
    let live: Vec<_> = projection
        .rows
        .values()
        .filter(|r| !r.withdrawn && !r.expunged)
        .collect();
    assert_eq!(live.len(), 20);

    let confirmed: Vec<_> = live
        .iter()
        .filter(|row| match row.fields.get("provenance.bits") {
            Some(UnifiedAuditValue::Bitmap(bits)) => (bits & CONFIRMED_BIT) != 0,
            _ => false,
        })
        .collect();
    assert_eq!(
        confirmed.len(),
        10,
        "exactly the ten confirmed rows match the bitmap predicate"
    );

    let confirmed_ids: std::collections::BTreeSet<_> = confirmed.iter().map(|r| r.row_id).collect();
    let expected_confirmed: std::collections::BTreeSet<_> =
        confirmed_rows.iter().copied().collect();
    assert_eq!(confirmed_ids, expected_confirmed);

    let unconfirmed: Vec<_> = live
        .iter()
        .filter(|row| match row.fields.get("provenance.bits") {
            Some(UnifiedAuditValue::Bitmap(bits)) => (bits & CONFIRMED_BIT) == 0,
            _ => true,
        })
        .collect();
    assert_eq!(unconfirmed.len(), 10);

    let unconfirmed_ids: std::collections::BTreeSet<_> =
        unconfirmed.iter().map(|r| r.row_id).collect();
    let expected_unconfirmed: std::collections::BTreeSet<_> =
        unconfirmed_rows.iter().copied().collect();
    assert_eq!(unconfirmed_ids, expected_unconfirmed);
}
