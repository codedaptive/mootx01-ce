// audit_parity.rs — Conformance vectors for the unified audit log
// against the Swift reference (mission GLK-03).
//
// Each vector is shared with the Swift counterpart in
// `UnifiedAuditLogTests.swift`. When a vector changes here it must
// change there too, and vice versa. The conformance contract:
// identical inputs produce identical content hashes and identical
// projections.

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
use substrate_types::hlc::HLC;

use genius_locus_kit::audit::{
    sha256, AuditProjectionFold, AuditRecovery, AuditTier, EntryUUID, UnifiedAuditEntry,
    UnifiedAuditLog, UnifiedAuditValue, UnifiedAuditVerb,
};

const ROW_A: EntryUUID = EntryUUID([
    0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa,
]);
const ROW_B: EntryUUID = EntryUUID([
    0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb,
]);

fn entry(
    tier: AuditTier,
    time: i64,
    row: EntryUUID,
    field: &str,
    value: UnifiedAuditValue,
    verb: UnifiedAuditVerb,
) -> UnifiedAuditEntry {
    UnifiedAuditEntry::new(
        tier,
        HLC::new(time, 0, 1),
        verb,
        row,
        field,
        UnifiedAuditValue::Null,
        value,
        None,
    )
}

// FIPS 180-4 §B.1 test vector for SHA-256("abc").
#[test]
fn sha256_abc_vector_matches_fips() {
    let hash = sha256(b"abc");
    let expected: [u8; 32] = [
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22,
        0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00,
        0x15, 0xad,
    ];
    assert_eq!(hash, expected);
}

#[test]
fn sha256_empty_vector_matches_fips() {
    let hash = sha256(b"");
    let expected: [u8; 32] = [
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9,
        0x24, 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52,
        0xb8, 0x55,
    ];
    assert_eq!(hash, expected);
}

#[test]
fn entry_id_is_deterministic() {
    let a = entry(
        AuditTier::Locus,
        1000,
        ROW_A,
        "adjective.state",
        UnifiedAuditValue::Bitmap(0x01),
        UnifiedAuditVerb::Capture,
    );
    let b = entry(
        AuditTier::Locus,
        1000,
        ROW_A,
        "adjective.state",
        UnifiedAuditValue::Bitmap(0x01),
        UnifiedAuditVerb::Capture,
    );
    assert_eq!(a.id, b.id);
    assert_eq!(a.id.len(), 32);
}

#[test]
fn entry_id_differs_when_tier_differs() {
    let l = entry(
        AuditTier::Locus,
        1000,
        ROW_A,
        "adjective.state",
        UnifiedAuditValue::Bitmap(0x01),
        UnifiedAuditVerb::Capture,
    );
    let r = entry(
        AuditTier::Rag,
        1000,
        ROW_A,
        "adjective.state",
        UnifiedAuditValue::Bitmap(0x01),
        UnifiedAuditVerb::Capture,
    );
    assert_ne!(l.id, r.id);
}

#[test]
fn add_is_idempotent() {
    let mut log = UnifiedAuditLog::new();
    let e = entry(
        AuditTier::Locus,
        1,
        ROW_A,
        "f",
        UnifiedAuditValue::Integer(1),
        UnifiedAuditVerb::Capture,
    );
    log.add(e.clone());
    log.add(e.clone());
    log.add(e);
    assert_eq!(log.count(), 1);
}

#[test]
fn merge_is_commutative_and_idempotent() {
    let e1 = entry(
        AuditTier::Locus,
        1,
        ROW_A,
        "f",
        UnifiedAuditValue::Integer(1),
        UnifiedAuditVerb::Capture,
    );
    let e2 = entry(
        AuditTier::Rag,
        2,
        ROW_B,
        "g",
        UnifiedAuditValue::Integer(2),
        UnifiedAuditVerb::Capture,
    );
    let e3 = entry(
        AuditTier::Locus,
        3,
        ROW_A,
        "f",
        UnifiedAuditValue::Integer(3),
        UnifiedAuditVerb::Mutate,
    );

    let a = UnifiedAuditLog::with_entries([e1.clone(), e2.clone()]);
    let b = UnifiedAuditLog::with_entries([e2.clone(), e3.clone()]);

    let mut a_plus_b = a.clone();
    a_plus_b.merge(&b);
    let mut b_plus_a = b.clone();
    b_plus_a.merge(&a);
    assert_eq!(a_plus_b, b_plus_a);

    let mut a2 = a;
    a2.merge(&b);
    a2.merge(&b);
    assert_eq!(a2.count(), 3);
}

#[test]
fn cross_tier_convergence() {
    // Mirrors `testCrossTierConvergence` in the Swift suite.
    let locus_cap_a = entry(
        AuditTier::Locus,
        10,
        ROW_A,
        "adjective.state",
        UnifiedAuditValue::Bitmap(0b0001),
        UnifiedAuditVerb::Capture,
    );
    let rag_cap_b = entry(
        AuditTier::Rag,
        20,
        ROW_B,
        "chunk.tokens",
        UnifiedAuditValue::Integer(512),
        UnifiedAuditVerb::Capture,
    );
    let rag_mut_b = entry(
        AuditTier::Rag,
        30,
        ROW_B,
        "chunk.tokens",
        UnifiedAuditValue::Integer(384),
        UnifiedAuditVerb::Mutate,
    );
    let locus_mut_a = entry(
        AuditTier::Locus,
        25,
        ROW_A,
        "adjective.state",
        UnifiedAuditValue::Bitmap(0b0011),
        UnifiedAuditVerb::Mutate,
    );

    let mut r1 = UnifiedAuditLog::new();
    r1.add(locus_cap_a.clone());
    r1.add(rag_cap_b.clone());
    r1.add(rag_mut_b);
    let mut r2 = UnifiedAuditLog::new();
    r2.add(locus_cap_a);
    r2.add(locus_mut_a);
    r2.add(rag_cap_b);

    r1.merge(&r2);
    r2.merge(&r1);

    let p1 = AuditProjectionFold::project(&r1);
    let p2 = AuditProjectionFold::project(&r2);
    assert_eq!(p1, p2);

    let locus_row = p1.row(AuditTier::Locus, ROW_A).expect("locus row");
    assert_eq!(
        locus_row.fields.get("adjective.state"),
        Some(&UnifiedAuditValue::Bitmap(0b0011))
    );
    assert_eq!(locus_row.last_verb, UnifiedAuditVerb::Mutate);

    let rag_row = p1.row(AuditTier::Rag, ROW_B).expect("rag row");
    assert_eq!(
        rag_row.fields.get("chunk.tokens"),
        Some(&UnifiedAuditValue::Integer(384))
    );
    assert_eq!(rag_row.last_verb, UnifiedAuditVerb::Mutate);
}

#[test]
fn projection_independent_of_arrival_order() {
    let events = vec![
        entry(
            AuditTier::Locus,
            10,
            ROW_A,
            "f",
            UnifiedAuditValue::Integer(1),
            UnifiedAuditVerb::Capture,
        ),
        entry(
            AuditTier::Rag,
            20,
            ROW_B,
            "g",
            UnifiedAuditValue::Integer(2),
            UnifiedAuditVerb::Capture,
        ),
        entry(
            AuditTier::Locus,
            30,
            ROW_A,
            "f",
            UnifiedAuditValue::Integer(3),
            UnifiedAuditVerb::Mutate,
        ),
        entry(
            AuditTier::Rag,
            40,
            ROW_B,
            "g",
            UnifiedAuditValue::Integer(4),
            UnifiedAuditVerb::Mutate,
        ),
    ];
    let p1 = AuditProjectionFold::project(&UnifiedAuditLog::with_entries(events.clone()));
    let mut reversed = events.clone();
    reversed.reverse();
    let p2 = AuditProjectionFold::project(&UnifiedAuditLog::with_entries(reversed));
    let shuffled = vec![
        events[2].clone(),
        events[0].clone(),
        events[3].clone(),
        events[1].clone(),
    ];
    let p3 = AuditProjectionFold::project(&UnifiedAuditLog::with_entries(shuffled));
    assert_eq!(p1, p2);
    assert_eq!(p2, p3);
}

#[test]
fn as_of_reconstruction_spans_both_tiers() {
    let t10 = HLC::new(10, 0, 1);
    let t20 = HLC::new(20, 0, 1);
    let t30 = HLC::new(30, 0, 1);
    let log = UnifiedAuditLog::with_entries([
        UnifiedAuditEntry::new(
            AuditTier::Locus,
            t10,
            UnifiedAuditVerb::Capture,
            ROW_A,
            "adjective.state",
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Bitmap(0b0001),
            None,
        ),
        UnifiedAuditEntry::new(
            AuditTier::Rag,
            t20,
            UnifiedAuditVerb::Capture,
            ROW_B,
            "chunk.tokens",
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Integer(100),
            None,
        ),
        UnifiedAuditEntry::new(
            AuditTier::Locus,
            t30,
            UnifiedAuditVerb::Mutate,
            ROW_A,
            "adjective.state",
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Bitmap(0b0011),
            None,
        ),
    ]);

    let as_of_20 = AuditProjectionFold::project_as_of(&log, t20);
    assert_eq!(
        as_of_20
            .row(AuditTier::Locus, ROW_A)
            .unwrap()
            .fields
            .get("adjective.state"),
        Some(&UnifiedAuditValue::Bitmap(0b0001))
    );
    assert_eq!(
        as_of_20
            .row(AuditTier::Rag, ROW_B)
            .unwrap()
            .fields
            .get("chunk.tokens"),
        Some(&UnifiedAuditValue::Integer(100))
    );

    let as_of_30 = AuditProjectionFold::project_as_of(&log, t30);
    assert_eq!(
        as_of_30
            .row(AuditTier::Locus, ROW_A)
            .unwrap()
            .fields
            .get("adjective.state"),
        Some(&UnifiedAuditValue::Bitmap(0b0011))
    );

    let as_of_zero = AuditProjectionFold::project_as_of(&log, HLC::ZERO);
    assert!(as_of_zero.is_empty());
}

#[test]
fn recovery_reproduces_live_projection() {
    let events = vec![
        entry(
            AuditTier::Locus,
            10,
            ROW_A,
            "f",
            UnifiedAuditValue::Integer(1),
            UnifiedAuditVerb::Capture,
        ),
        entry(
            AuditTier::Rag,
            15,
            ROW_B,
            "g",
            UnifiedAuditValue::Integer(2),
            UnifiedAuditVerb::Capture,
        ),
        entry(
            AuditTier::Locus,
            20,
            ROW_A,
            "f",
            UnifiedAuditValue::Integer(3),
            UnifiedAuditVerb::Mutate,
        ),
        entry(
            AuditTier::Rag,
            25,
            ROW_B,
            "g",
            UnifiedAuditValue::Integer(7),
            UnifiedAuditVerb::Mutate,
        ),
    ];
    let log = UnifiedAuditLog::with_entries(events);
    let live = AuditProjectionFold::project(&log);

    let result = AuditRecovery::rebuild(&log);
    assert_eq!(result.entries_replayed, 4);
    assert_eq!(result.rows_rebuilt, 2);
    assert_eq!(result.locus_rows, 1);
    assert_eq!(result.rag_rows, 1);
    assert_eq!(result.projection, live);

    let divergence = AuditRecovery::verify(&result.projection, &live);
    assert!(divergence.is_empty());
}

#[test]
fn streaming_replay_matches_batch() {
    let events = vec![
        entry(
            AuditTier::Locus,
            10,
            ROW_A,
            "f",
            UnifiedAuditValue::Integer(1),
            UnifiedAuditVerb::Capture,
        ),
        entry(
            AuditTier::Rag,
            20,
            ROW_B,
            "g",
            UnifiedAuditValue::Integer(2),
            UnifiedAuditVerb::Capture,
        ),
        entry(
            AuditTier::Locus,
            30,
            ROW_A,
            "f",
            UnifiedAuditValue::Integer(3),
            UnifiedAuditVerb::Mutate,
        ),
    ];
    let batch = AuditRecovery::rebuild(&UnifiedAuditLog::with_entries(events.clone()));
    let streamed = AuditRecovery::rebuild_streaming(events);
    assert_eq!(streamed.projection, batch.projection);
}

#[test]
fn recovery_as_of_reconstructs_historical_state() {
    let t10 = HLC::new(10, 0, 1);
    let t30 = HLC::new(30, 0, 1);
    let log = UnifiedAuditLog::with_entries([
        UnifiedAuditEntry::new(
            AuditTier::Locus,
            t10,
            UnifiedAuditVerb::Capture,
            ROW_A,
            "f",
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Integer(1),
            None,
        ),
        UnifiedAuditEntry::new(
            AuditTier::Rag,
            t30,
            UnifiedAuditVerb::Capture,
            ROW_B,
            "g",
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Integer(2),
            None,
        ),
    ]);
    let as_of_t20 = AuditRecovery::rebuild_as_of(&log, HLC::new(20, 0, 1));
    assert_eq!(as_of_t20.entries_replayed, 1);
    assert_eq!(as_of_t20.rows_rebuilt, 1);
    assert_eq!(as_of_t20.locus_rows, 1);
    assert_eq!(as_of_t20.rag_rows, 0);
}

#[test]
fn withdraw_and_expunge_are_sticky_tombstones() {
    let events = vec![
        entry(
            AuditTier::Locus,
            10,
            ROW_A,
            "f",
            UnifiedAuditValue::Bitmap(1),
            UnifiedAuditVerb::Capture,
        ),
        entry(
            AuditTier::Locus,
            20,
            ROW_A,
            "f",
            UnifiedAuditValue::Bitmap(2),
            UnifiedAuditVerb::Withdraw,
        ),
        entry(
            AuditTier::Locus,
            30,
            ROW_A,
            "f",
            UnifiedAuditValue::Bitmap(3),
            UnifiedAuditVerb::Expunge,
        ),
        entry(
            AuditTier::Locus,
            40,
            ROW_A,
            "f",
            UnifiedAuditValue::Bitmap(9),
            UnifiedAuditVerb::Mutate,
        ),
    ];
    let p = AuditProjectionFold::project(&UnifiedAuditLog::with_entries(events));
    let row = p.row(AuditTier::Locus, ROW_A).unwrap();
    assert!(row.withdrawn);
    assert!(row.expunged);
}

#[test]
fn row_scoping_honors_tier() {
    let shared = EntryUUID([0x99; 16]);
    let events = vec![
        UnifiedAuditEntry::new(
            AuditTier::Locus,
            HLC::new(10, 0, 1),
            UnifiedAuditVerb::Capture,
            shared,
            "f",
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Integer(1),
            None,
        ),
        UnifiedAuditEntry::new(
            AuditTier::Rag,
            HLC::new(20, 0, 1),
            UnifiedAuditVerb::Capture,
            shared,
            "g",
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Integer(2),
            None,
        ),
    ];
    let p = AuditProjectionFold::project(&UnifiedAuditLog::with_entries(events));
    assert_eq!(p.count(), 2);
    assert!(p.row(AuditTier::Locus, shared).is_some());
    assert!(p.row(AuditTier::Rag, shared).is_some());
}

// Security regression (codex a477800): verify-on-ingress rejects forged entries.
#[test]
fn audit_log_rejects_forged_content_id() {
    // Construct an honest entry; new() computes the correct SHA-256 id.
    let hlc = HLC::new(9999, 0, 42);
    let row = EntryUUID([0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]);
    let honest = UnifiedAuditEntry::new(
        AuditTier::Locus,
        hlc,
        UnifiedAuditVerb::Capture,
        row,
        "sec.test",
        UnifiedAuditValue::Null,
        UnifiedAuditValue::Integer(42),
        None,
    );

    let mut log = UnifiedAuditLog::new();
    log.add(honest.clone());
    assert_eq!(log.count(), 1, "honest entry must be inserted");
    assert_eq!(log.rejected_count(), 0, "no rejection yet");

    // Forge: steal the honest entry's id but inject different content.
    // The recomputed SHA-256 of this entry's wire bytes will not match
    // the stolen id, so the log must reject it.
    let forged = UnifiedAuditEntry {
        id: honest.id,                          // stolen — does NOT match wire below
        tier: AuditTier::Locus,
        hlc,
        verb: UnifiedAuditVerb::Capture,
        row_id: row,
        field_path: "sec.test".to_string(),
        before_value: UnifiedAuditValue::Null,
        after_value: UnifiedAuditValue::Integer(999), // different content
        origin_row_id: None,
    };

    // add path: forged entry must be silently rejected.
    log.add(forged.clone());
    assert_eq!(log.count(), 1, "forged entry on add must not increase count");
    // AUDIT-ALERT-RESTORE (2026-07-09): the rejection is no longer
    // silent-only — `rejected_count` observes it at the same ingress
    // choke point that drops the entry.
    assert_eq!(log.rejected_count(), 1, "rejected-entry count observes the add-boundary rejection");

    // The honest entry's value is retained — not overwritten by the forged one.
    let retained = log.ordered_entries();
    assert_eq!(retained.len(), 1);
    assert_eq!(
        retained[0].after_value,
        UnifiedAuditValue::Integer(42),
        "honest entry value must be preserved after forged-add attempt"
    );

    // merge path: a log containing a forged entry (bypassing add via
    // with_entries which also validates) — since forged entries are
    // rejected at all ingress points, build the source log honestly,
    // then verify merge passes only honest entries through.
    let mut source = UnifiedAuditLog::new();
    source.add(forged.clone()); // rejected at source too
    assert_eq!(source.count(), 0, "forged entry rejected in source log before merge");
    assert_eq!(source.rejected_count(), 1, "the source log's own ingress observes its own rejection");
    log.merge(&source); // merging empty log is a no-op
    assert_eq!(log.count(), 1, "count unchanged after merging log with forged entry");
    // `merge` only re-adds entries that survived the SOURCE log's own
    // ingress (source.entries is empty), so the destination's
    // rejected_count is untouched by the source's earlier rejection —
    // merge does not double-count.
    assert_eq!(log.rejected_count(), 1, "merge does not replay the source log's rejection into the destination's count");
    assert_eq!(
        log.ordered_entries()[0].after_value,
        UnifiedAuditValue::Integer(42),
        "honest entry value must be preserved after forged-merge attempt"
    );

    // Idempotent add of the honest entry leaves count unchanged.
    log.add(honest);
    assert_eq!(log.count(), 1, "re-adding honest entry must remain idempotent");
    assert_eq!(log.rejected_count(), 1, "re-adding an honest entry is not a rejection");
}

// ── rejected_count surfacing (AUDIT-ALERT-RESTORE, 2026-07-09) ────────
//
// Feed/snapshot seam mirror of the Swift
// `rejectedEntryCountAccumulatesAndIsExcludedFromEquality` test: a fresh
// log accumulates one count per rejected `add` call, regardless of how
// many honest entries are interleaved, and structural equality (`==`)
// ignores the counter.
#[test]
fn rejected_count_accumulates_and_is_excluded_from_equality() {
    let honest_a = entry(AuditTier::Locus, 1, ROW_A, "f", UnifiedAuditValue::Integer(1), UnifiedAuditVerb::Capture);
    let honest_b = entry(AuditTier::Locus, 2, ROW_B, "g", UnifiedAuditValue::Integer(2), UnifiedAuditVerb::Capture);

    let forge = |honest: &UnifiedAuditEntry, ms: i64, row: EntryUUID| UnifiedAuditEntry {
        id: honest.id,
        tier: AuditTier::Locus,
        hlc: HLC::new(ms, 0, 1),
        verb: UnifiedAuditVerb::Capture,
        row_id: row,
        field_path: "tampered".to_string(),
        before_value: UnifiedAuditValue::Null,
        after_value: UnifiedAuditValue::Integer(-1),
        origin_row_id: None,
    };

    let mut log = UnifiedAuditLog::new();
    log.add(honest_a.clone());
    log.add(forge(&honest_a, 3, ROW_A));
    log.add(honest_b.clone());
    log.add(forge(&honest_b, 4, ROW_B));

    assert_eq!(log.count(), 2, "two honest entries admitted");
    assert_eq!(log.rejected_count(), 2, "two rejections counted, interleaved with honest adds");

    let clean = UnifiedAuditLog::with_entries([honest_a, honest_b]);
    assert_eq!(clean.rejected_count(), 0);
    assert_eq!(log, clean, "structural equality compares entries only, not the rejection telemetry");
}

#[test]
fn hlc_lexicographic_order() {
    let a = HLC::new(1, 0, 0);
    let b = HLC::new(1, 1, 0);
    let c = HLC::new(1, 1, 5);
    let d = HLC::new(2, 0, 0);
    assert!(a < b);
    assert!(b < c);
    assert!(c < d);
    assert_eq!(a.wire_bytes().len(), 16);
}
