//! Integration tests for `DrawerStore::fingerprints_captured_in` and
//! `DrawerStore::fingerprint_bit_series`.
//!
//! Mirrors the Swift `TemporalReadsTests.swift` fixture so both legs
//! verify identical semantics against the same constants.
//!
//! Shared fixture (epoch seconds relative to EPOCH_NOW = 1_700_100_000):
//!   d1.event_time = EPOCH_NOW        (content: "temporal-fixture-alpha")
//!   d2.event_time = EPOCH_NOW + 100  (content: "temporal-fixture-beta")
//!   d3.event_time = EPOCH_NOW + 200  (content: "temporal-fixture-gamma")
//!
//! Bucket boundary test — ending_at = EPOCH_NOW + 300, bucket = 100 s, 3 buckets:
//!   bucket[0] = [EPOCH_NOW,       EPOCH_NOW+100)  → d1 only
//!   bucket[1] = [EPOCH_NOW+100,   EPOCH_NOW+200)  → d2 only (edge → later bucket)
//!   bucket[2] = [EPOCH_NOW+200,   EPOCH_NOW+300]  → d3 only (edge → later bucket)

use locus_kit::drawer::Drawer;
use locus_kit::drawer_fingerprint::EstateFingerprintFamilies;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::error::LocusKitError;
use substrate_types::fingerprint256::Fingerprint256;

const EPOCH_NOW: i64 = 1_700_100_000;
const CONTENT_A: &str = "temporal-fixture-alpha";
const CONTENT_B: &str = "temporal-fixture-beta";
const CONTENT_C: &str = "temporal-fixture-gamma";

// ---------------------------------------------------------------------------
// Test infrastructure
// ---------------------------------------------------------------------------

/// Deterministic UUID from a short label — mirrors `tid()` in TestStorage.swift
/// and `tid()` in `drawer_store_sqlite.rs`.
fn tid(label: &str) -> String {
    let mut bytes = [0u8; 16];
    let mut h: u64 = 0xcbf29ce484222325;
    for (i, b) in label.bytes().enumerate() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
        bytes[i % 16] ^= (h & 0xff) as u8;
        bytes[(i + 7) % 16] ^= ((h >> 32) & 0xff) as u8;
    }
    #[allow(clippy::needless_range_loop)]
    for i in 0..16 {
        h ^= bytes[i] as u64;
        h = h.wrapping_mul(0x100000001b3);
        bytes[i] = bytes[i].wrapping_add((h & 0xff) as u8);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    uuid::Uuid::from_bytes(bytes).to_string()
}

fn make_store() -> InMemoryDrawerStore {
    InMemoryDrawerStore::new(EPOCH_NOW, None).unwrap()
}

/// Read the estate UUID that the store assigned on first open.
fn estate_uuid(store: &InMemoryDrawerStore) -> String {
    store.read_manifest().unwrap().estate_uuid
}

/// Build a Drawer with a specific event_time.
fn temporal_drawer(id: &str, content: &str, event_time: i64) -> Drawer {
    let mut d = Drawer::new(
        tid(id),
        content,
        "test-parent",
        "bilby",
        EPOCH_NOW,
        "minilm-v6",
    );
    d.event_time = event_time;
    d
}

/// Insert the three-row fixture. Returns (d1, d2, d3).
fn build_fixture(store: &InMemoryDrawerStore) -> (Drawer, Drawer, Drawer) {
    let d1 = temporal_drawer("tr-d1", CONTENT_A, EPOCH_NOW);
    let d2 = temporal_drawer("tr-d2", CONTENT_B, EPOCH_NOW + 100);
    let d3 = temporal_drawer("tr-d3", CONTENT_C, EPOCH_NOW + 200);
    store.add_drawer(&d1, EPOCH_NOW).unwrap();
    store.add_drawer(&d2, EPOCH_NOW).unwrap();
    store.add_drawer(&d3, EPOCH_NOW).unwrap();
    (d1, d2, d3)
}

/// Return the index (0–255) of the first set bit; returns 0 if all blocks are zero.
fn find_first_set_bit(fp: &Fingerprint256) -> usize {
    for b in 0..64usize {
        if (fp.block0 >> (b as u32)) & 1 != 0 {
            return b;
        }
    }
    for b in 0..64usize {
        if (fp.block1 >> (b as u32)) & 1 != 0 {
            return b + 64;
        }
    }
    for b in 0..64usize {
        if (fp.block2 >> (b as u32)) & 1 != 0 {
            return b + 128;
        }
    }
    for b in 0..64usize {
        if (fp.block3 >> (b as u32)) & 1 != 0 {
            return b + 192;
        }
    }
    0
}

/// Returns true when `bit` (0-based, block0 = bits 0–63) is set in `fp`.
fn is_bit_set(fp: &Fingerprint256, bit: usize) -> bool {
    match bit {
        0..=63 => (fp.block0 >> (bit as u32)) & 1 != 0,
        64..=127 => (fp.block1 >> ((bit - 64) as u32)) & 1 != 0,
        128..=191 => (fp.block2 >> ((bit - 128) as u32)) & 1 != 0,
        _ => (fp.block3 >> ((bit - 192) as u32)) & 1 != 0,
    }
}

// ---------------------------------------------------------------------------
// fingerprints_captured_in tests
// ---------------------------------------------------------------------------

#[test]
fn fingerprints_captured_full_window_returns_3() {
    let store = make_store();
    let (d1, d2, d3) = build_fixture(&store);

    let result = store
        .fingerprints_captured_in(EPOCH_NOW, EPOCH_NOW + 200)
        .unwrap();

    assert_eq!(result.len(), 3);

    // Results are in ascending id (string lexicographic) order — same sort
    // criterion as the Swift leg's ORDER BY id ASC.
    let families = EstateFingerprintFamilies::new(estate_uuid(&store));
    let fp1 = families.fingerprint(&d1);
    let fp2 = families.fingerprint(&d2);
    let fp3 = families.fingerprint(&d3);

    // Verify the set of returned fingerprints matches expectations.
    let expected: std::collections::HashSet<[u64; 4]> = [
        [fp1.block0, fp1.block1, fp1.block2, fp1.block3],
        [fp2.block0, fp2.block1, fp2.block2, fp2.block3],
        [fp3.block0, fp3.block1, fp3.block2, fp3.block3],
    ]
    .into();
    let actual: std::collections::HashSet<[u64; 4]> = result
        .iter()
        .map(|fp| [fp.block0, fp.block1, fp.block2, fp.block3])
        .collect();
    assert_eq!(actual, expected);

    // Verify ordering: results sorted by id string, same as SQL ORDER BY id ASC.
    let mut drawers_sorted = vec![&d1, &d2, &d3];
    drawers_sorted.sort_by(|a, b| a.id.cmp(&b.id));
    let expected_in_order: Vec<Fingerprint256> =
        drawers_sorted.iter().map(|d| families.fingerprint(d)).collect();
    assert_eq!(result, expected_in_order);
}

#[test]
fn fingerprints_captured_narrow_window_returns_2() {
    let store = make_store();
    build_fixture(&store);

    let result = store
        .fingerprints_captured_in(EPOCH_NOW, EPOCH_NOW + 100)
        .unwrap();

    assert_eq!(result.len(), 2);
}

#[test]
fn fingerprints_captured_single_point_returns_1() {
    let store = make_store();
    let (_, d2, _) = build_fixture(&store);

    let result = store
        .fingerprints_captured_in(EPOCH_NOW + 100, EPOCH_NOW + 100)
        .unwrap();

    assert_eq!(result.len(), 1);
    let families = EstateFingerprintFamilies::new(estate_uuid(&store));
    assert_eq!(result[0], families.fingerprint(&d2));
}

#[test]
fn fingerprints_captured_empty_window_returns_empty() {
    let store = make_store();
    build_fixture(&store);

    let result = store
        .fingerprints_captured_in(EPOCH_NOW - 1000, EPOCH_NOW - 1)
        .unwrap();

    assert!(result.is_empty());
}

// ---------------------------------------------------------------------------
// fingerprint_bit_series tests
// ---------------------------------------------------------------------------

#[test]
fn bit_series_zero_bucket_count_returns_empty() {
    let store = make_store();
    build_fixture(&store);

    let result = store
        .fingerprint_bit_series(0, 100, 0, EPOCH_NOW + 300)
        .unwrap();

    assert!(result.is_empty());
}

#[test]
fn bit_series_bit_256_returns_error() {
    let store = make_store();

    let err = store
        .fingerprint_bit_series(256, 100, 3, EPOCH_NOW + 300)
        .unwrap_err();

    assert!(matches!(err, LocusKitError::InvalidContent(_)));
}

#[test]
fn bit_series_zero_bucket_seconds_returns_error() {
    let store = make_store();

    let err = store
        .fingerprint_bit_series(0, 0, 3, EPOCH_NOW + 300)
        .unwrap_err();

    assert!(matches!(err, LocusKitError::InvalidContent(_)));
}

#[test]
fn bit_series_no_drawers_in_window_all_false() {
    let store = make_store();
    build_fixture(&store);

    // ending_at is 10 000 s before the fixture — no drawers in range.
    let result = store
        .fingerprint_bit_series(0, 100, 3, EPOCH_NOW - 10_000)
        .unwrap();

    assert_eq!(result, vec![false, false, false]);
}

#[test]
fn bit_series_bucket_edge_semantics() {
    // A capture exactly on a bucket edge belongs to the later (higher-time) bucket.
    //
    // 3 buckets × 100 s, ending_at = EPOCH_NOW + 300:
    //   bucket[0] = [EPOCH_NOW,       EPOCH_NOW+100)  → contains d1 only
    //   bucket[1] = [EPOCH_NOW+100,   EPOCH_NOW+200)  → contains d2 (edge → later bucket)
    //   bucket[2] = [EPOCH_NOW+200,   EPOCH_NOW+300]  → contains d3 (edge → later bucket)
    let store = make_store();
    let (d1, d2, d3) = build_fixture(&store);
    let families = EstateFingerprintFamilies::new(estate_uuid(&store));
    let fp1 = families.fingerprint(&d1);
    let fp2 = families.fingerprint(&d2);
    let fp3 = families.fingerprint(&d3);
    let ending_at = EPOCH_NOW + 300;

    // Query a bit set in d1 and verify per-bucket presence.
    let b1 = find_first_set_bit(&fp1);
    let series1 = store
        .fingerprint_bit_series(b1, 100, 3, ending_at)
        .unwrap();
    assert_eq!(series1.len(), 3);
    assert_eq!(series1[0], is_bit_set(&fp1, b1));
    assert_eq!(series1[1], is_bit_set(&fp2, b1));
    assert_eq!(series1[2], is_bit_set(&fp3, b1));

    // Query a bit set in d2 — must appear in bucket[1], not bucket[0].
    let b2 = find_first_set_bit(&fp2);
    let series2 = store
        .fingerprint_bit_series(b2, 100, 3, ending_at)
        .unwrap();
    assert_eq!(series2[0], is_bit_set(&fp1, b2));
    assert_eq!(series2[1], is_bit_set(&fp2, b2));
    assert_eq!(series2[2], is_bit_set(&fp3, b2));

    // Query a bit set in d3 — must appear in bucket[2].
    let b3 = find_first_set_bit(&fp3);
    let series3 = store
        .fingerprint_bit_series(b3, 100, 3, ending_at)
        .unwrap();
    assert_eq!(series3[0], is_bit_set(&fp1, b3));
    assert_eq!(series3[1], is_bit_set(&fp2, b3));
    assert_eq!(series3[2], is_bit_set(&fp3, b3));
}
