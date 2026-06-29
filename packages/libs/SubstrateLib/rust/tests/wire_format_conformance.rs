//! Rust↔Swift JSON wire-format conformance gate for SubstrateLib.
//!
//! Mirror of `WireFormatConformanceTests.swift`. Tests
//! value-equivalence (not byte-identity — see the Swift file's
//! header for the reasoning). Most types have a round-trip test
//! and a key-name fixture test; later types (`AuditValue`,
//! `AuditEntry`, `GSetAuditLog`) have additional coverage tests,
//! and `HyperplaneFamily` has only a key-name fixture.
//!
//! Gated on the `serde-support` feature; compiles to nothing
//! otherwise.

#![cfg(feature = "serde-support")]

use substrate_types::count_vector::CountVector256;
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hlc::HLC;
use substrate_types::hyperplane::{Hyperplane, HyperplaneFamily};
use substrate_types::gset::AuditVerb;
use substrate_lib::row_state::{RowState, RowVerb};

// ============================================================
// Fingerprint256
// ============================================================

#[test]
fn fingerprint256_round_trip() {
    let fp = Fingerprint256 { block0: 1, block1: 2, block2: 3, block3: 4 };
    let data = serde_json::to_string(&fp).unwrap();
    let back: Fingerprint256 = serde_json::from_str(&data).unwrap();
    assert_eq!(fp, back);
}

#[test]
fn fingerprint256_key_names() {
    let json = r#"{"block0":1,"block1":2,"block2":3,"block3":4}"#;
    let fp: Fingerprint256 = serde_json::from_str(json).unwrap();
    assert_eq!(fp.block0, 1);
    assert_eq!(fp.block1, 2);
    assert_eq!(fp.block2, 3);
    assert_eq!(fp.block3, 4);
}

// ============================================================
// HLC — physicalTime / logicalCount / nodeID
// ============================================================

#[test]
fn hlc_round_trip() {
    let hlc = HLC::new(1_700_000_000_000, 7, 42);
    let data = serde_json::to_string(&hlc).unwrap();
    let back: HLC = serde_json::from_str(&data).unwrap();
    assert_eq!(hlc, back);
}

#[test]
fn hlc_key_names() {
    let json = r#"{"physicalTime":1700000000000,"logicalCount":7,"nodeID":42}"#;
    let hlc: HLC = serde_json::from_str(json).unwrap();
    assert_eq!(hlc.physical_time, 1_700_000_000_000);
    assert_eq!(hlc.logical_count, 7);
    assert_eq!(hlc.node_id, 42);
}

// ============================================================
// RowState — encoded as raw u8 integer via serde_repr.
// ============================================================

#[test]
fn row_state_round_trip() {
    for state in [
        RowState::Active, RowState::Pending, RowState::Contested, RowState::Accepted,
        RowState::Superseded, RowState::Decayed, RowState::Withdrawn, RowState::Expired,
        RowState::Rejected, RowState::Tombstoned,
    ] {
        let data = serde_json::to_string(&state).unwrap();
        let back: RowState = serde_json::from_str(&data).unwrap();
        assert_eq!(state, back);
    }
}

#[test]
fn row_state_raw_value_encoding() {
    assert_eq!(serde_json::to_string(&RowState::Active).unwrap(), "0");
    assert_eq!(serde_json::to_string(&RowState::Accepted).unwrap(), "3");
    assert_eq!(serde_json::to_string(&RowState::Withdrawn).unwrap(), "18");
    assert_eq!(serde_json::to_string(&RowState::Tombstoned).unwrap(), "33");

    let w: RowState = serde_json::from_str("18").unwrap();
    assert_eq!(w, RowState::Withdrawn);
}

// ============================================================
// RowVerb — encoded as camelCase string variant name.
// ============================================================

#[test]
fn row_verb_round_trip() {
    for verb in [
        RowVerb::Capture, RowVerb::Observe, RowVerb::Mutate, RowVerb::Retract,
        RowVerb::Promote, RowVerb::Reject, RowVerb::Supersede, RowVerb::Decay,
        RowVerb::Expire, RowVerb::Contest, RowVerb::ResolveContest, RowVerb::Tombstone,
    ] {
        let data = serde_json::to_string(&verb).unwrap();
        let back: RowVerb = serde_json::from_str(&data).unwrap();
        assert_eq!(verb, back);
    }
}

#[test]
fn row_verb_raw_value_encoding() {
    assert_eq!(serde_json::to_string(&RowVerb::Capture).unwrap(), r#""capture""#);
    assert_eq!(serde_json::to_string(&RowVerb::ResolveContest).unwrap(),
               r#""resolveContest""#);
    let r: RowVerb = serde_json::from_str(r#""resolveContest""#).unwrap();
    assert_eq!(r, RowVerb::ResolveContest);
}

// ============================================================
// CountVector256
// ============================================================

#[test]
fn count_vector_256_round_trip_zero() {
    let cv = CountVector256::zero();
    let data = serde_json::to_string(&cv).unwrap();
    let back: CountVector256 = serde_json::from_str(&data).unwrap();
    assert_eq!(cv, back);
}

#[test]
fn count_vector_256_key_names() {
    let json = format!(
        r#"{{"counts":[{}],"n":0}}"#,
        std::iter::repeat("0").take(256).collect::<Vec<_>>().join(",")
    );
    let cv: CountVector256 = serde_json::from_str(&json).unwrap();
    assert_eq!(cv.counts(), &[0u32; 256]);
    assert_eq!(cv.n(), 0);
}

// ============================================================
// Hyperplane + HyperplaneFamily
// ============================================================

#[test]
fn hyperplane_round_trip() {
    let h = Hyperplane::new(vec![255], vec![170], 8);
    let data = serde_json::to_string(&h).unwrap();
    let back: Hyperplane = serde_json::from_str(&data).unwrap();
    assert_eq!(h, back);
}

#[test]
fn hyperplane_key_names() {
    let json = r#"{"positiveMask":[255],"negativeMask":[170],"bitLength":8}"#;
    let h: Hyperplane = serde_json::from_str(json).unwrap();
    assert_eq!(h.positive_mask, vec![255]);
    assert_eq!(h.negative_mask, vec![170]);
    assert_eq!(h.bit_length, 8);
}

#[test]
fn hyperplane_family_key_names() {
    let json = r#"{"blockIndex":0,"inputBitLength":8,"planes":[{"positiveMask":[1],"negativeMask":[2],"bitLength":8}]}"#;
    let f: HyperplaneFamily = serde_json::from_str(json).unwrap();
    assert_eq!(f.block_index, 0);
    assert_eq!(f.input_bit_length, 8);
    assert_eq!(f.planes.len(), 1);
}

// ============================================================
// AuditVerb
// ============================================================

#[test]
fn audit_verb_round_trip() {
    for v in [
        AuditVerb::Capture, AuditVerb::Mutate, AuditVerb::Retract, AuditVerb::Sync,
        AuditVerb::Pair, AuditVerb::Unpair, AuditVerb::Derive, AuditVerb::Decay,
        AuditVerb::Promote, AuditVerb::Migrate, AuditVerb::DreamCompact,
    ] {
        let data = serde_json::to_string(&v).unwrap();
        let back: AuditVerb = serde_json::from_str(&data).unwrap();
        assert_eq!(v, back);
    }
}

#[test]
fn audit_verb_raw_value_encoding() {
    assert_eq!(serde_json::to_string(&AuditVerb::Capture).unwrap(),
               r#""capture""#);
    assert_eq!(serde_json::to_string(&AuditVerb::DreamCompact).unwrap(),
               r#""dreamCompact""#);
    let d: AuditVerb = serde_json::from_str(r#""dreamCompact""#).unwrap();
    assert_eq!(d, AuditVerb::DreamCompact);
}

// ============================================================
// F16.B — AuditValue, AuditEntry, GSetAuditLog
// ============================================================

use substrate_types::gset::{AuditEntry, AuditValue, GSetAuditLog};
// RowId is the canonical newtype (struct RowId(pub u128)) from substrate_types::row.
// The alias `RowID` was removed; import directly from the re-export root.
use substrate_types::RowId;

// AuditValue ----------------------------------------------------

#[test]
fn audit_value_round_trip_bitmap() {
    let v = AuditValue::Bitmap(0xCAFE_BABE_DEAD_BEEF);
    let data = serde_json::to_string(&v).unwrap();
    let back: AuditValue = serde_json::from_str(&data).unwrap();
    assert_eq!(v, back);
}

#[test]
fn audit_value_round_trip_string() {
    let v = AuditValue::String("hello, world".into());
    let data = serde_json::to_string(&v).unwrap();
    let back: AuditValue = serde_json::from_str(&data).unwrap();
    assert_eq!(v, back);
}

#[test]
fn audit_value_round_trip_fingerprint() {
    let fp = Fingerprint256 { block0: 1, block1: 2, block2: 3, block3: 4 };
    let v = AuditValue::Fingerprint(fp);
    let data = serde_json::to_string(&v).unwrap();
    let back: AuditValue = serde_json::from_str(&data).unwrap();
    assert_eq!(v, back);
}

#[test]
fn audit_value_round_trip_integer() {
    let v = AuditValue::Integer(-42);
    let data = serde_json::to_string(&v).unwrap();
    let back: AuditValue = serde_json::from_str(&data).unwrap();
    assert_eq!(v, back);
}

#[test]
fn audit_value_wire_format() {
    // Default serde with `rename_all = "camelCase"` produces
    // externally-tagged single-key objects. Matches Swift's
    // custom Codable in GSetAuditLog.swift.
    assert_eq!(serde_json::to_string(&AuditValue::Bitmap(42)).unwrap(),
               r#"{"bitmap":42}"#);
    assert_eq!(serde_json::to_string(&AuditValue::String("hi".into())).unwrap(),
               r#"{"string":"hi"}"#);
    assert_eq!(serde_json::to_string(&AuditValue::Integer(-1)).unwrap(),
               r#"{"integer":-1}"#);
}

#[test]
fn audit_value_decode_from_known_fixture() {
    let cases: &[(&str, AuditValue)] = &[
        (r#"{"bitmap":42}"#, AuditValue::Bitmap(42)),
        (r#"{"string":"hello"}"#, AuditValue::String("hello".into())),
        (r#"{"integer":-1}"#, AuditValue::Integer(-1)),
    ];
    for (json, expected) in cases {
        let v: AuditValue = serde_json::from_str(json).unwrap();
        assert_eq!(&v, expected);
    }
}

// AuditEntry ----------------------------------------------------

fn sample_audit_entry(
    before_value: Option<AuditValue>,
    after_value: Option<AuditValue>,
    origin_row_id: Option<RowId>,
) -> AuditEntry {
    AuditEntry {
        id: [0xAB; 32],
        hlc: HLC::new(1_700_000_000_000, 0, 1),
        verb: substrate_types::gset::AuditVerb::Mutate,
        // UUID 550E8400-E29B-41D4-A716-446655440000 as a u128
        // big-endian: 0x550E8400_E29B41D4_A7164466_55440000.
        row_id: RowId(0x550E8400_E29B41D4_A7164466_55440000_u128),
        field_path: "adjective.state".into(),
        before_value,
        after_value,
        origin_row_id,
    }
}

#[test]
fn audit_entry_round_trip_mutate() {
    let entry = sample_audit_entry(
        Some(AuditValue::Integer(1)),
        Some(AuditValue::Integer(2)),
        None,
    );
    let data = serde_json::to_string(&entry).unwrap();
    let back: AuditEntry = serde_json::from_str(&data).unwrap();
    assert_eq!(entry, back);
}

#[test]
fn audit_entry_round_trip_capture_boundary() {
    let entry = sample_audit_entry(None, Some(AuditValue::Integer(5)), None);
    let data = serde_json::to_string(&entry).unwrap();
    let back: AuditEntry = serde_json::from_str(&data).unwrap();
    assert_eq!(entry, back);
    assert!(back.before_value.is_none());
}

#[test]
fn audit_entry_round_trip_retract_boundary() {
    let entry = sample_audit_entry(Some(AuditValue::Integer(7)), None, None);
    let data = serde_json::to_string(&entry).unwrap();
    let back: AuditEntry = serde_json::from_str(&data).unwrap();
    assert_eq!(entry, back);
    assert!(back.after_value.is_none());
}

#[test]
fn audit_entry_round_trip_with_origin() {
    let origin: RowId = RowId(0xDEADBEEF_DEADBEEF_DEADBEEF_DEADBEEF_u128);
    let entry = sample_audit_entry(
        Some(AuditValue::Integer(1)),
        Some(AuditValue::Integer(2)),
        Some(origin),
    );
    let data = serde_json::to_string(&entry).unwrap();
    let back: AuditEntry = serde_json::from_str(&data).unwrap();
    assert_eq!(entry, back);
    assert_eq!(back.origin_row_id, Some(origin));
}

#[test]
fn audit_entry_row_id_is_uppercase_uuid_string() {
    // The Rust row_id_uuid serde helper produces UPPERCASE
    // hyphenated UUID strings matching Swift's UUID Codable
    // default. The byte sequence 550E8400-E29B-41D4-A716-446655440000
    // must appear verbatim in the encoded JSON.
    let entry = sample_audit_entry(
        Some(AuditValue::Integer(1)),
        Some(AuditValue::Integer(2)),
        None,
    );
    let data = serde_json::to_string(&entry).unwrap();
    assert!(
        data.contains(r#""rowID":"550E8400-E29B-41D4-A716-446655440000""#),
        "rowID must be encoded as uppercase UUID string. Got: {data}"
    );
}

// GSetAuditLog --------------------------------------------------

#[test]
fn gset_audit_log_round_trip_empty() {
    let log = GSetAuditLog::new();
    let data = serde_json::to_string(&log).unwrap();
    assert_eq!(data, r#"{"entries":[]}"#);
    let back: GSetAuditLog = serde_json::from_str(&data).unwrap();
    assert_eq!(back.len(), 0);
}

#[test]
fn gset_audit_log_round_trip_multiple_sorted() {
    let mut low_id = [0x10u8; 32]; low_id[31] = 0x01;
    let mut high_id = [0x10u8; 32]; high_id[31] = 0x02;
    let hlc = HLC::new(1, 0, 1);

    let e_high = AuditEntry {
        id: high_id, hlc, verb: substrate_types::gset::AuditVerb::Mutate,
        row_id: RowId(0), field_path: "f".into(),
        before_value: None, after_value: Some(AuditValue::Integer(2)),
        origin_row_id: None,
    };
    let e_low = AuditEntry {
        id: low_id, hlc, verb: substrate_types::gset::AuditVerb::Mutate,
        row_id: RowId(0), field_path: "f".into(),
        before_value: None, after_value: Some(AuditValue::Integer(1)),
        origin_row_id: None,
    };

    let log = GSetAuditLog::from_entries(vec![e_high.clone(), e_low.clone()]);
    let data = serde_json::to_string(&log).unwrap();

    // Entries appear sorted by id byte-lex regardless of insertion order.
    // low_id (...0x01) precedes high_id (...0x02), so e_low comes first.
    let low_pos = data.find("\"integer\":1").expect("e_low afterValue not found");
    let high_pos = data.find("\"integer\":2").expect("e_high afterValue not found");
    assert!(low_pos < high_pos,
        "entries must be sorted by id byte-lex in wire output");

    let back: GSetAuditLog = serde_json::from_str(&data).unwrap();
    assert_eq!(back.len(), 2);
}
