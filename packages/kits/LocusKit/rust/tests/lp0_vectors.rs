//! LP-0 conformance vector runner for the LocusKit Rust port.
//!
//! Reads the four JSON vector files from
//! `[REDACTED]/test-harness/vectors/locuskit/`
//! and replays each case against a fresh in-memory Estate, asserting
//! that the Rust port produces identical observable behaviour to the
//! Swift reference implementation.
//!
//! ## Vector schema
//!
//! Each file contains `cases[]`; each case has:
//! - `inputs.ops[]`: a sequence of operations to replay in order
//! - `expected_output.observations[]`: a sequence of assertions to
//!   verify in order, consuming one observation per operation result
//!
//! ## Runner semantics
//!
//! Each case gets a fresh estate (InMemoryStorage + InMemoryDrawerStore +
//! Estate::create). A `Vec<Drawer>` tracks captured drawers so
//! `drawerIndex` ops can reference them by position. A typed
//! `Arc<InMemoryDrawerStore>` is kept alongside the `Estate` for direct
//! store access (tunnels, kg_facts, peek) — mirrors the Swift test runner
//! which holds both `estate` and `store` separately.
//!
//! Timestamps: `now` is 1_700_000_000 (a fixed epoch value) incremented
//! by 1 for each op to give a strict ordering without system-clock calls
//! (deterministic-clock rule per CLAUDE.md).

use locus_kit::adjectives::State;
use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate::Estate;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;
use locus_kit::kg_fact::KGFact;
use locus_kit::tunnel::Tunnel;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Arc;
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Test entry points — one per vector file
// ---------------------------------------------------------------------------

#[test]
fn lp0_drawer_lifecycle() {
    run_vector_file("drawer_lifecycle.json");
}

#[test]
fn lp0_tunnel_traverse() {
    run_vector_file("tunnel_traverse.json");
}

#[test]
fn lp0_kgfact_temporal() {
    run_vector_file("kgfact_temporal.json");
}

#[test]
fn lp0_recall_stream() {
    run_vector_file("recall_stream.json");
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

/// Run all cases in the given vector file.
fn run_vector_file(file_name: &str) {
    let path = vectors_path(file_name);
    let json_text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read vector file {:?}: {}", path, e));
    let root: Value = serde_json::from_str(&json_text)
        .unwrap_or_else(|e| panic!("JSON parse error in {:?}: {}", path, e));

    let cases = root["cases"]
        .as_array()
        .unwrap_or_else(|| panic!("no 'cases' array in {:?}", path));

    for case in cases {
        let case_id = case["id"].as_str().unwrap_or("?");
        let description = case["description"].as_str().unwrap_or("");
        run_case(case_id, description, &case["inputs"]["ops"], &case["expected_output"]["observations"]);
    }
}

/// Replay one case against a fresh estate. The `ops` and `observations`
/// arrays must have matching lengths (one observation per op result, but
/// the schema allows ops that produce no observation — we track a cursor).
fn run_case(case_id: &str, description: &str, ops: &Value, observations: &Value) {
    // Fresh estate for each case.
    let storage: Arc<dyn persistence_kit::storage::Storage> =
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<InMemoryDrawerStore> =
        Arc::new(InMemoryDrawerStore::new(Arc::clone(&storage), 1_700_000_000, None).unwrap());
    let estate = Estate::create(
        Arc::clone(&store) as Arc<dyn DrawerStore>,
        OwnerCredentials::new("owner"),
        None,
    )
    .unwrap();

    let ops = ops.as_array().unwrap_or_else(|| panic!("[{}] ops is not an array", case_id));
    let obs = observations
        .as_array()
        .unwrap_or_else(|| panic!("[{}] observations is not an array", case_id));

    // Captured drawers — indexed by position in the order of capture ops.
    let mut captured: Vec<Drawer> = Vec::new();
    // Observation cursor — consumed in order.
    let mut obs_cursor: usize = 0;

    // Base timestamp incremented per op so every op has a distinct `now`.
    let mut now: i64 = 1_700_000_001;

    for op_val in ops {
        let op_kind = op_val["op"]
            .as_str()
            .unwrap_or_else(|| panic!("[{}] op has no 'op' field", case_id));

        match op_kind {
            "capture" => {
                let content = str_field(op_val, "content", case_id);
                let room = str_field(op_val, "room", case_id);
                let udc = str_field(op_val, "udc", case_id);
                let added_by = str_field(op_val, "addedBy", case_id);
                let embed = str_field(op_val, "embeddingModelID", case_id);

                let frame = CaptureFrame::new(
                    content,
                    CaptureChannel::Typed,
                    room,
                    LatticeAnchor::udc(udc),
                    added_by,
                    embed,
                );
                let drawer = estate
                    .capture(frame, now)
                    .unwrap_or_else(|e| {
                        panic!("[{}] capture failed: {:?}", case_id, e)
                    });

                // Assert the expected_output.observations entry for this capture.
                let obs_entry = &obs[obs_cursor];
                obs_cursor += 1;
                assert_eq!(
                    obs_entry["kind"].as_str().unwrap_or(""),
                    "captured",
                    "[{}] observation kind mismatch at cursor {}; desc={}",
                    case_id, obs_cursor - 1, description
                );
                assert_eq!(
                    drawer.content,
                    obs_entry["expectContent"].as_str().unwrap_or(""),
                    "[{}] captured content mismatch", case_id
                );
                assert_eq!(
                    drawer.room,
                    obs_entry["expectRoom"].as_str().unwrap_or(""),
                    "[{}] captured room mismatch", case_id
                );
                assert_eq!(
                    drawer.udc_code,
                    obs_entry["expectUDC"].as_str().unwrap_or(""),
                    "[{}] captured udc_code mismatch", case_id
                );
                let expect_active = obs_entry["expectStateActive"].as_bool().unwrap_or(true);
                let state = State::from_raw(drawer.adjective_bitmap & 0xF);
                assert_eq!(
                    state == State::Active,
                    expect_active,
                    "[{}] captured state active={} expected={}", case_id, state == State::Active, expect_active
                );

                captured.push(drawer);
            }

            "peek" => {
                let idx = usize_field(op_val, "drawerIndex", case_id);
                let drawer_id = &captured[idx].id;
                let result = store.get_drawer(drawer_id)
                    .unwrap_or_else(|e| panic!("[{}] peek store error: {:?}", case_id, e));

                let obs_entry = &obs[obs_cursor];
                obs_cursor += 1;
                assert_eq!(
                    obs_entry["kind"].as_str().unwrap_or(""),
                    "peeked",
                    "[{}] observation kind mismatch at cursor {}", case_id, obs_cursor - 1
                );
                let expect_found = obs_entry["found"].as_bool().unwrap_or(true);
                assert_eq!(
                    result.is_some(),
                    expect_found,
                    "[{}] peek found={} expected={}", case_id, result.is_some(), expect_found
                );
                if let Some(d) = &result {
                    if let Some(expected_content) = obs_entry["expectContent"].as_str() {
                        assert_eq!(
                            d.content, expected_content,
                            "[{}] peek content mismatch", case_id
                        );
                    }
                    if let Some(expect_active) = obs_entry["expectStateActive"].as_bool() {
                        let state = State::from_raw(d.adjective_bitmap & 0xF);
                        assert_eq!(
                            state == State::Active,
                            expect_active,
                            "[{}] peek state active={} expected={}", case_id, state == State::Active, expect_active
                        );
                    }
                }
            }

            "withdraw" => {
                let idx = usize_field(op_val, "drawerIndex", case_id);
                let drawer_id = captured[idx].id.clone();
                let reason = op_val["reason"].as_str();
                estate
                    .withdraw(&drawer_id, reason, now)
                    .unwrap_or_else(|e| panic!("[{}] withdraw failed: {:?}", case_id, e));

                let obs_entry = &obs[obs_cursor];
                obs_cursor += 1;
                assert_eq!(
                    obs_entry["kind"].as_str().unwrap_or(""),
                    "withdrew",
                    "[{}] observation kind mismatch at cursor {}", case_id, obs_cursor - 1
                );
            }

            "recallAll" => {
                let room = str_field(op_val, "room", case_id);
                let frame = RecallFrame::new(vec![
                    Filter::InRoom(room.to_string()),
                    Filter::CurrentlyBelieve,
                    Filter::Unconfirmed,
                ]);
                let stream = estate.recall(frame, now);
                let rows = stream.collect_all();

                let obs_entry = &obs[obs_cursor];
                obs_cursor += 1;
                assert_eq!(
                    obs_entry["kind"].as_str().unwrap_or(""),
                    "recalled",
                    "[{}] observation kind mismatch at cursor {}", case_id, obs_cursor - 1
                );
                let expect_count = usize_field(obs_entry, "expectCount", case_id);
                assert_eq!(
                    rows.len(), expect_count,
                    "[{}] recallAll count: got {} expected {}", case_id, rows.len(), expect_count
                );
                if let Some(first_content) = obs_entry["expectFirstContent"].as_str() {
                    assert!(
                        !rows.is_empty(),
                        "[{}] recallAll expectFirstContent but rows empty", case_id
                    );
                    assert_eq!(
                        rows[0].content, first_content,
                        "[{}] recallAll first content mismatch", case_id
                    );
                }
            }

            "recallPaged" => {
                let room = str_field(op_val, "room", case_id);
                let page_size = usize_field(op_val, "pageSize", case_id);
                let mut frame = RecallFrame::new(vec![
                    Filter::InRoom(room.to_string()),
                    Filter::CurrentlyBelieve,
                    Filter::Unconfirmed,
                ]);
                frame.limit = Some(page_size);
                let stream = estate.recall(frame, now);
                // Drain all pages and concatenate into one flat list.
                let rows = stream.collect_all();

                let obs_entry = &obs[obs_cursor];
                obs_cursor += 1;
                assert_eq!(
                    obs_entry["kind"].as_str().unwrap_or(""),
                    "recallPaged",
                    "[{}] observation kind mismatch at cursor {}", case_id, obs_cursor - 1
                );
                let expect_total = usize_field(obs_entry, "expectTotal", case_id);
                assert_eq!(
                    rows.len(), expect_total,
                    "[{}] recallPaged total: got {} expected {}", case_id, rows.len(), expect_total
                );
                if let Some(expect_contents) = obs_entry["expectContents"].as_array() {
                    let got_contents: Vec<&str> = rows.iter().map(|d| d.content.as_str()).collect();
                    let want_contents: Vec<&str> = expect_contents
                        .iter()
                        .map(|v| v.as_str().unwrap_or(""))
                        .collect();
                    assert_eq!(
                        got_contents, want_contents,
                        "[{}] recallPaged contents ordering mismatch", case_id
                    );
                }
            }

            "addTunnel" => {
                let id = str_field(op_val, "id", case_id);
                let source_wing = str_field(op_val, "sourceWing", case_id);
                let source_room = str_field(op_val, "sourceRoom", case_id);
                let target_wing = str_field(op_val, "targetWing", case_id);
                let target_room = str_field(op_val, "targetRoom", case_id);
                let label = str_field(op_val, "label", case_id);
                let added_by = str_field(op_val, "addedBy", case_id);
                let filed_at = op_val["filedAtEpoch"]
                    .as_i64()
                    .unwrap_or(now);

                let tunnel = Tunnel::new(
                    id.to_string(),
                    source_wing.to_string(),
                    source_room.to_string(),
                    target_wing.to_string(),
                    target_room.to_string(),
                    label.to_string(),
                    added_by.to_string(),
                    filed_at,
                );
                store
                    .add_tunnel(&tunnel)
                    .unwrap_or_else(|e| panic!("[{}] addTunnel failed: {:?}", case_id, e));

                let obs_entry = &obs[obs_cursor];
                obs_cursor += 1;
                assert_eq!(
                    obs_entry["kind"].as_str().unwrap_or(""),
                    "tunnelAdded",
                    "[{}] observation kind mismatch at cursor {}", case_id, obs_cursor - 1
                );
                let expect_id = obs_entry["id"].as_str().unwrap_or("");
                assert_eq!(tunnel.id, expect_id, "[{}] tunnelAdded id mismatch", case_id);
            }

            "tunnelsFromRoom" => {
                let source_wing = str_field(op_val, "sourceWing", case_id);
                let source_room = str_field(op_val, "sourceRoom", case_id);
                let tunnels = store
                    .tunnels_from_wing_room(source_wing, source_room)
                    .unwrap_or_else(|e| panic!("[{}] tunnelsFromRoom failed: {:?}", case_id, e));

                let obs_entry = &obs[obs_cursor];
                obs_cursor += 1;
                assert_eq!(
                    obs_entry["kind"].as_str().unwrap_or(""),
                    "traversed",
                    "[{}] observation kind mismatch at cursor {}", case_id, obs_cursor - 1
                );
                let empty_arr: Vec<Value> = vec![];
                let expect_ids: Vec<&str> = obs_entry["expectIds"]
                    .as_array()
                    .unwrap_or(&empty_arr)
                    .iter()
                    .map(|v| v.as_str().unwrap_or(""))
                    .collect();
                let got_ids: Vec<&str> = tunnels.iter().map(|t| t.id.as_str()).collect();
                assert_eq!(
                    got_ids, expect_ids,
                    "[{}] tunnelsFromRoom ids mismatch", case_id
                );
            }

            "tunnelsFromWing" => {
                let source_wing = str_field(op_val, "sourceWing", case_id);
                let tunnels = store
                    .tunnels_from_wing(source_wing)
                    .unwrap_or_else(|e| panic!("[{}] tunnelsFromWing failed: {:?}", case_id, e));

                let obs_entry = &obs[obs_cursor];
                obs_cursor += 1;
                assert_eq!(
                    obs_entry["kind"].as_str().unwrap_or(""),
                    "traversed",
                    "[{}] observation kind mismatch at cursor {}", case_id, obs_cursor - 1
                );
                let empty_arr: Vec<Value> = vec![];
                let expect_ids: Vec<&str> = obs_entry["expectIds"]
                    .as_array()
                    .unwrap_or(&empty_arr)
                    .iter()
                    .map(|v| v.as_str().unwrap_or(""))
                    .collect();
                let got_ids: Vec<&str> = tunnels.iter().map(|t| t.id.as_str()).collect();
                assert_eq!(
                    got_ids, expect_ids,
                    "[{}] tunnelsFromWing ids mismatch", case_id
                );
            }

            "tunnelsToWing" => {
                let target_wing = str_field(op_val, "targetWing", case_id);
                let tunnels = store
                    .tunnels_to_wing(target_wing)
                    .unwrap_or_else(|e| panic!("[{}] tunnelsToWing failed: {:?}", case_id, e));

                let obs_entry = &obs[obs_cursor];
                obs_cursor += 1;
                assert_eq!(
                    obs_entry["kind"].as_str().unwrap_or(""),
                    "traversed",
                    "[{}] observation kind mismatch at cursor {}", case_id, obs_cursor - 1
                );
                let empty_arr: Vec<Value> = vec![];
                let expect_ids: Vec<&str> = obs_entry["expectIds"]
                    .as_array()
                    .unwrap_or(&empty_arr)
                    .iter()
                    .map(|v| v.as_str().unwrap_or(""))
                    .collect();
                let got_ids: Vec<&str> = tunnels.iter().map(|t| t.id.as_str()).collect();
                assert_eq!(
                    got_ids, expect_ids,
                    "[{}] tunnelsToWing ids mismatch", case_id
                );
            }

            "addKGFact" => {
                let id = str_field(op_val, "id", case_id);
                let subject = str_field(op_val, "subject", case_id);
                let predicate = str_field(op_val, "predicate", case_id);
                let object = str_field(op_val, "object", case_id);
                let src_idx = usize_field(op_val, "sourceDrawerIndex", case_id);
                let filed_at = op_val["filedAtEpoch"].as_i64().unwrap_or(now);

                let source_drawer_id = captured[src_idx].id.clone();
                let fact = KGFact::new(
                    id.to_string(),
                    subject.to_string(),
                    predicate.to_string(),
                    object.to_string(),
                    source_drawer_id,
                    filed_at,
                );
                store
                    .add_kg_fact(&fact)
                    .unwrap_or_else(|e| panic!("[{}] addKGFact failed: {:?}", case_id, e));

                let obs_entry = &obs[obs_cursor];
                obs_cursor += 1;
                assert_eq!(
                    obs_entry["kind"].as_str().unwrap_or(""),
                    "kgFactAdded",
                    "[{}] observation kind mismatch at cursor {}", case_id, obs_cursor - 1
                );
                let expect_id = obs_entry["id"].as_str().unwrap_or("");
                assert_eq!(fact.id, expect_id, "[{}] kgFactAdded id mismatch", case_id);
            }

            "kgFactsForDrawer" => {
                let src_idx = usize_field(op_val, "sourceDrawerIndex", case_id);
                let source_drawer_id = &captured[src_idx].id;
                let facts = store
                    .kg_facts_for_drawer(source_drawer_id)
                    .unwrap_or_else(|e| panic!("[{}] kgFactsForDrawer failed: {:?}", case_id, e));

                let obs_entry = &obs[obs_cursor];
                obs_cursor += 1;
                assert_eq!(
                    obs_entry["kind"].as_str().unwrap_or(""),
                    "kgFactList",
                    "[{}] observation kind mismatch at cursor {}", case_id, obs_cursor - 1
                );
                let empty_arr: Vec<Value> = vec![];
                let expect_ids: Vec<&str> = obs_entry["expectIds"]
                    .as_array()
                    .unwrap_or(&empty_arr)
                    .iter()
                    .map(|v| v.as_str().unwrap_or(""))
                    .collect();
                let got_ids: Vec<&str> = facts.iter().map(|f| f.id.as_str()).collect();
                assert_eq!(
                    got_ids, expect_ids,
                    "[{}] kgFactsForDrawer ids mismatch", case_id
                );
            }

            unknown => {
                panic!("[{}] unknown op kind '{}'", case_id, unknown);
            }
        }

        // Advance the deterministic clock per op.
        now += 1;
    }

    // All observations must have been consumed.
    assert_eq!(
        obs_cursor,
        obs.len(),
        "[{}] {} observations unconsumed after replay; desc={}",
        case_id,
        obs.len() - obs_cursor,
        description
    );
}

// ---------------------------------------------------------------------------
// Path resolver
// ---------------------------------------------------------------------------

/// Resolve the canonical path to the LP-0 vector files.
///
/// The crate manifest is at `packages/kits/LocusKit/rust/Cargo.toml`. Walking
/// up four levels from `CARGO_MANIFEST_DIR` lands at the repo root; from there
/// the path is
/// `docs/validation/substrate_math_performance/test-harness/vectors/locuskit/`.
fn vectors_path(file_name: &str) -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // manifest_dir = <repo>/packages/kits/LocusKit/rust
    // ../ = LocusKit  ../../ = kits  ../../../ = packages  ../../../../ = <repo>
    let repo_root = manifest_dir
        .parent() // LocusKit
        .and_then(|p| p.parent()) // kits
        .and_then(|p| p.parent()) // packages
        .and_then(|p| p.parent()) // repo root
        .expect("cannot resolve repo root from CARGO_MANIFEST_DIR");
    repo_root
        .join("docs")
        .join("validation")
        .join("substrate_math_performance")
        .join("test-harness")
        .join("vectors")
        .join("locuskit")
        .join(file_name)
}

// ---------------------------------------------------------------------------
// JSON field helpers
// ---------------------------------------------------------------------------

/// Extract a required string field from a JSON object.
fn str_field<'a>(v: &'a Value, field: &str, case_id: &str) -> &'a str {
    v[field]
        .as_str()
        .unwrap_or_else(|| panic!("[{}] missing string field '{}'", case_id, field))
}

/// Extract a required usize field from a JSON object.
fn usize_field(v: &Value, field: &str, case_id: &str) -> usize {
    v[field]
        .as_u64()
        .unwrap_or_else(|| panic!("[{}] missing numeric field '{}'", case_id, field))
        as usize
}
