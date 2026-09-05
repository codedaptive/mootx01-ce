//! SYN-1 shared conformance vector for the binary (Hamming) lane's top-K
//! boundary: ../Tests/Conformance/hamming_topk_boundary_ties.json.
//!
//! The vector holds 300 fingerprints built around one probe so that a large
//! tie group straddles the K-th position: K=10 cuts inside a 45-way tie at
//! distance 2, K=80 cuts inside a 50-way tie at distance 4 (four byte-identical
//! payload pairs inside that group exercise the item_id backstop). Insertion
//! order is a deterministic shuffle, so an engine that keeps the first-arrived
//! members of the tie group, or a heap that drops the secondary keys, returns
//! a different subset than the expected list.
//!
//! Every engine in this port must return exactly the expected ordered list per
//! SYNAPSEKIT_SPEC B-6 — distance ASC, vec_hash ASC (FNV-1a 64 over the 32
//! wire bytes), item_id ASC:
//!   • BruteForceIndex (the oracle),
//!   • MIHIndex at m=16 and m=4,
//!   • VectorStore::find_nearest on the brute-force tier and on the MIH tier
//!     (MIH forced active below the default threshold via mih_threshold = 1).
//! The Swift twin (Tests/SynapseKitTests/HammingTopKBoundaryTiesConformanceTests.swift)
//! asserts the same file, so the two ports are pinned to one list, not to
//! each other.

use engram_lib::{Engram, EngramLib};
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Arc;
use synapsekit::engine::mih::{MIHBandCount, MIHIndex};
use synapsekit::{BruteForceIndex, DenseIndex, DenseMetric, VectorPayload, VectorRecordKey, VectorStore};
use uuid::Uuid;

// ── Fixture ──────────────────────────────────────────────────────────────────

struct Candidate {
    item_id: String,
    engram: Engram,
}

struct Expected {
    item_id: String,
    distance: i32,
    vec_hash: u64,
}

struct Case {
    k: usize,
    boundary_distance: i32,
    tie_group_size: usize,
    expected: Vec<Expected>,
}

struct Fixture {
    model_id: String,
    model_version: String,
    probe: Engram,
    candidates: Vec<Candidate>,
    cases: Vec<Case>,
}

/// The fixture writes every 64-bit block and hash as a "0x…" hex string so no
/// JSON parser's number range is in play.
fn hex64(v: &Value) -> u64 {
    let s = v.as_str().expect("hex field must be a string");
    assert!(s.starts_with("0x"), "hex field must start with 0x: {s}");
    u64::from_str_radix(&s[2..], 16).expect("hex field must parse")
}

fn engram(v: &Value) -> Engram {
    let blocks = v.as_array().expect("blocks must be an array");
    assert_eq!(blocks.len(), 4);
    Engram::new(hex64(&blocks[0]), hex64(&blocks[1]), hex64(&blocks[2]), hex64(&blocks[3]))
}

fn load_fixture() -> Fixture {
    // CARGO_MANIFEST_DIR is SynapseKit/rust/; the fixture lives one level up
    // under Tests/Conformance/ (same layout as GeniusLocusKit's fixtures).
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/Conformance/hamming_topk_boundary_ties.json");
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    let root: Value = serde_json::from_str(&raw).expect("fixture JSON must parse");
    let candidates = root["candidates"]
        .as_array()
        .expect("candidates")
        .iter()
        .map(|c| Candidate {
            item_id: c["item_id"].as_str().expect("item_id").to_string(),
            engram: engram(&c["blocks"]),
        })
        .collect();
    let cases = root["cases"]
        .as_array()
        .expect("cases")
        .iter()
        .map(|c| Case {
            k: c["k"].as_u64().expect("k") as usize,
            boundary_distance: c["boundary_distance"].as_i64().expect("boundary_distance") as i32,
            tie_group_size: c["tie_group_size"].as_u64().expect("tie_group_size") as usize,
            expected: c["expected"]
                .as_array()
                .expect("expected")
                .iter()
                .map(|e| Expected {
                    item_id: e["item_id"].as_str().expect("item_id").to_string(),
                    distance: e["distance"].as_i64().expect("distance") as i32,
                    vec_hash: hex64(&e["vec_hash"]),
                })
                .collect(),
        })
        .collect();
    Fixture {
        model_id: root["model_id"].as_str().expect("model_id").to_string(),
        model_version: root["model_version"].as_str().expect("model_version").to_string(),
        probe: engram(&root["probe"]),
        candidates,
        cases,
    }
}

/// FNV-1a 64 as SPEC B-6 defines the vec_hash tie key: offset basis
/// 0xcbf29ce484222325, prime 0x100000001b3, over the 32 little-endian wire
/// bytes. Written out here (not imported) so the test pins the definition,
/// not the crate's private helper.
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn record_key(item_id: &str, f: &Fixture) -> VectorRecordKey {
    VectorRecordKey::new(item_id, 0, f.model_id.as_str(), f.model_version.as_str())
}

/// Compare an engine's ordered (item_id, distance) list against the expected
/// list; on divergence, name the first differing position with both sides so
/// the failure reads as a tie-order diagnosis, not a bare inequality.
fn assert_ordered_list(got: &[(String, i32)], expected: &[Expected], context: &str) {
    assert_eq!(
        got.len(),
        expected.len(),
        "{context}: returned {} hits, expected exactly K={}",
        got.len(),
        expected.len()
    );
    for (pos, (g, e)) in got.iter().zip(expected.iter()).enumerate() {
        assert!(
            g.0 == e.item_id && g.1 == e.distance,
            "{context}: first divergence at position {pos}: got {} d={}, expected {} d={}",
            g.0, g.1, e.item_id, e.distance
        );
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

/// The fixture's own consistency: every expected entry's vec_hash equals this
/// port's FNV-1a 64 over the candidate's 32 wire bytes, every expected
/// distance equals the kernel-gated Hamming distance to the probe, and each
/// case's tie group is at least 40 wide at the boundary. A drift here means
/// the two ports no longer hash the same bytes.
#[test]
fn fixture_hashes_and_distances_are_this_ports_values() {
    let f = load_fixture();
    assert_eq!(f.candidates.len(), 300);
    let by_id: std::collections::HashMap<&str, &Engram> =
        f.candidates.iter().map(|c| (c.item_id.as_str(), &c.engram)).collect();
    for c in &f.cases {
        assert!(c.tie_group_size >= 40, "k={}: tie group at the boundary must be ≥40 wide", c.k);
        assert_eq!(c.expected.len(), c.k);
        assert_eq!(c.expected.last().map(|e| e.distance), Some(c.boundary_distance));
        for e in &c.expected {
            let engram = by_id[e.item_id.as_str()];
            assert_eq!(fnv1a64(&engram.wire_bytes()), e.vec_hash, "k={}: vec_hash drift for {}", c.k, e.item_id);
            assert_eq!(EngramLib::distance(&f.probe, engram) as i32, e.distance,
                       "k={}: distance drift for {}", c.k, e.item_id);
        }
    }
}

/// BruteForceIndex — the oracle — returns exactly the expected lists.
#[test]
fn brute_force_index_returns_expected_ordered_top_k() {
    let f = load_fixture();
    let mut index = BruteForceIndex::new();
    for c in &f.candidates {
        index.add(record_key(&c.item_id, &f), VectorPayload::from_engram(&c.engram)).expect("add");
    }
    for c in &f.cases {
        let hits = index
            .search(&VectorPayload::from_engram(&f.probe), DenseMetric::HAMMING, c.k, None)
            .expect("search");
        let got: Vec<(String, i32)> = hits.iter().map(|h| (h.key.item_id.clone(), h.raw_distance)).collect();
        assert_ordered_list(&got, &c.expected, &format!("BruteForceIndex k={}", c.k));
    }
}

/// MIHIndex at m=16 (the production band count) and m=4 returns the same
/// lists as the oracle — the progressive-radius heap must keep the
/// (distance, vec_hash, key) order at the K-th boundary.
#[test]
fn mih_index_returns_expected_ordered_top_k() {
    let f = load_fixture();
    for band_count in [MIHBandCount::M16, MIHBandCount::M4] {
        let mut index = MIHIndex::new(band_count);
        for c in &f.candidates {
            index.add(record_key(&c.item_id, &f), VectorPayload::from_engram(&c.engram)).expect("add");
        }
        for c in &f.cases {
            let hits = index
                .search(&VectorPayload::from_engram(&f.probe), DenseMetric::HAMMING, c.k, None)
                .expect("search");
            let got: Vec<(String, i32)> = hits.iter().map(|h| (h.key.item_id.clone(), h.raw_distance)).collect();
            assert_ordered_list(&got, &c.expected, &format!("MIHIndex m={} k={}", band_count as u32, c.k));
        }
    }
}

/// VectorStore::find_nearest on both index tiers: the brute-force tier
/// (threshold above the corpus size) and the MIH tier (mih_threshold = 1
/// promotes to MIH as soon as one live binary vector exists). Both must serve
/// exactly the expected lists through the public seam.
#[test]
fn vector_store_find_nearest_returns_expected_ordered_top_k() {
    let f = load_fixture();
    for mih_threshold in [1_000_000u32, 1u32] {
        let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        storage.open(&VectorStore::schema_declaration()).expect("open schema");
        let store = VectorStore::new_with_threshold(storage, None, mih_threshold, MIHBandCount::M16);
        for c in &f.candidates {
            store
                .add_payload(&c.item_id, 0, &VectorPayload::from_engram(&c.engram),
                             &f.model_id, &f.model_version, 1_700_000_000)
                .expect("add_payload");
        }
        for c in &f.cases {
            let matches = store.find_nearest(&f.probe, &f.model_id, c.k).expect("find_nearest");
            let got: Vec<(String, i32)> = matches.iter().map(|m| (m.item_id.clone(), m.distance)).collect();
            assert_ordered_list(&got, &c.expected,
                                &format!("VectorStore(mih_threshold={mih_threshold}) k={}", c.k));
        }
    }
}
