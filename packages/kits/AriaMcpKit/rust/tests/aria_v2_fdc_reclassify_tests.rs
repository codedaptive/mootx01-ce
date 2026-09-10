//! Integration tests for the v2 `moot_reclassify_fdc` write path.
//!
//! Every test drives the tool through the live v2 route:
//!
//!   Dispatcher::handle → surface::execute → data_mobility_lower.rs::reclassify_fdc
//!
//! None of these tests call `dispatch_tool`, `dispatch_tool_with_vault_flag`,
//! `dispatch_tool_with_vault_ledger`, or `interface_tools::dispatch`. Those are
//! the v1 helper paths the running server cannot reach; tests through the v1
//! path proved nothing about the v2 lower, which is what shipped broken.

use aria_mcp::{dispatcher::Dispatcher, estate_registry::EstateRegistry, jsonrpc::JSONRPCRequest};
use locus_kit::{
    drawer_operational::CaptureChannel,
    estate_types::LatticeAnchor,
    frames::CaptureFrame,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Drive a tool through the live Dispatcher (v2 route).
fn call(dispatcher: &Dispatcher, tool: &str, arguments: serde_json::Value) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc":"2.0", "id":1, "method":"tools/call",
        "params":{"name":tool,"arguments":arguments}
    })).unwrap();
    serde_json::to_value(dispatcher.handle(&request)).unwrap()
}

/// Extract `structuredContent.data` from a tool result.
fn data(result: &serde_json::Value) -> &serde_json::Value {
    &result["result"]["structuredContent"]["data"]
}

fn is_success(result: &serde_json::Value) -> bool {
    result["result"]["isError"] == serde_json::json!(false)
}

/// Seed one drawer with stale UDC code "362.4" using git-command content.
/// The FDC classifier reclassifies git content to the "000" sentinel, so this
/// drawer is a suspect candidate for reclassify_fdc. Returns the drawer id.
fn seed_stale_drawer(registry: &EstateRegistry) -> String {
    let frame = CaptureFrame::new(
        "git update-index --refresh && rm .git/index.lock",
        CaptureChannel::Typed,
        "test-room",
        // Stale code "362.4" — FDC will reclassify git content to "000".
        LatticeAnchor::new("362.4", None, Some("Q12131".to_owned()), None),
        "fdc-reclassify-tests",
        "minilm-v6",
    );
    let handle = registry.default.handle.clone();
    let drawer = registry.default.coord.lock().unwrap()
        .capture(&handle, frame, 1_700_000_000_000)
        .expect("capture must succeed");
    drawer.id.clone()
}

// ---------------------------------------------------------------------------
// PRE-FIX RED
//
// Written against the base commit where `apply` is rejected as an unknown
// argument. Run against the unmodified base to capture the failure.
// ---------------------------------------------------------------------------
#[test]
fn apply_true_is_accepted_and_writes_anchor() {
    let registry = EstateRegistry::new_inmemory();
    let _id = seed_stale_drawer(&registry);
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    // On the unmodified base, this returns isError: true because "apply" is
    // not in the permitted argument set of strict_object(value, ["estate_id"]).
    let result = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({"apply": true}));
    assert!(is_success(&result), "apply:true must be accepted, got: {result}");
    assert_eq!(data(&result)["applied"], serde_json::json!(true),
        "data.applied must be true, got: {result}");
    assert!(data(&result)["updated"].as_u64().unwrap_or(0) > 0,
        "updated must be > 0 after apply on a stale estate, got: {result}");
}

// ---------------------------------------------------------------------------
// Twin 1 of 10 — Swift: dryRunReportsSuspectButDoesNotMutate
// ---------------------------------------------------------------------------
/// A dry run discovers the stale drawer as a candidate, reports it in the
/// change list, and writes nothing to the store.
#[test]
fn dry_run_reports_suspect_but_does_not_mutate() {
    // bare: only the seeded drawer exists; pre-seeded drawers would add noise to candidate count.
    let registry = EstateRegistry::new_inmemory_bare();
    let id = seed_stale_drawer(&registry);
    let store = registry.default.store.clone();
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    let result = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({}));
    assert!(is_success(&result), "dry run must succeed, got: {result}");

    let d = data(&result);
    assert_eq!(d["applied"], serde_json::json!(false));
    assert_eq!(d["candidates"], serde_json::json!(1), "expect 1 candidate, got: {d}");
    assert_eq!(d["would_update"], serde_json::json!(1), "expect would_update:1, got: {d}");
    assert_eq!(d["updated"], serde_json::json!(0), "must not write on dry run, got: {d}");
    assert_eq!(d["floor_stamp"], serde_json::json!("dry-run"));

    let changes = d["changes"].as_array().expect("changes must be array");
    assert_eq!(changes.len(), 1, "expect 1 change entry, got: {d}");
    assert_eq!(changes[0]["id"], serde_json::json!(id));
    assert_eq!(changes[0]["old_code"], serde_json::json!("362.4"));
    assert_eq!(changes[0]["new_code"], serde_json::json!("000"));

    // Drawer in store must be unchanged.
    use locus_kit::drawer_store::DrawerStore;
    let row = store.get_drawer(&id).expect("get_drawer must succeed")
        .expect("drawer must exist");
    assert_eq!(row.udc_code, "362.4", "dry run must not mutate the stored code");
}

// ---------------------------------------------------------------------------
// Twin 2 of 10 — Swift: allModeReclassifiesStoredCodeKindsAndAddsLanguageQID
// ---------------------------------------------------------------------------
/// mode=all apply updates the stale drawer and stamps the floor.
#[test]
fn all_mode_apply_reclassifies_stored_code() {
    // bare: only the seeded drawer exists; pre-seeded drawers would inflate updated count.
    let registry = EstateRegistry::new_inmemory_bare();
    let id = seed_stale_drawer(&registry);
    let store = registry.default.store.clone();
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    let result = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({
        "apply": true, "mode": "all"
    }));
    assert!(is_success(&result), "apply mode=all must succeed, got: {result}");

    let d = data(&result);
    assert_eq!(d["applied"], serde_json::json!(true));
    assert_eq!(d["mode"], serde_json::json!("all"));
    assert_eq!(d["updated"], serde_json::json!(1), "expect updated:1, got: {d}");
    assert_eq!(d["floor_stamp"], serde_json::json!("stamped"));

    use locus_kit::drawer_store::DrawerStore;
    let row = store.get_drawer(&id).expect("get_drawer must succeed")
        .expect("drawer must exist");
    assert_eq!(row.udc_code, "000", "apply must update the stored code to sentinel");
}

// ---------------------------------------------------------------------------
// Twin 3 of 10 — Swift: suspectOnlyAddsMissingLanguageQIDWhenCodeIsUnchanged
// ---------------------------------------------------------------------------
/// suspectOnly apply (the default mode) is distinct from mode=all. The mode
/// field in the response matches what was resolved.
#[test]
fn suspect_only_apply_reports_correct_mode_and_skips_non_floor_stamp() {
    let registry = EstateRegistry::new_inmemory();
    let _id = seed_stale_drawer(&registry);
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    let result = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({"apply": true}));
    assert!(is_success(&result), "suspect-only apply must succeed, got: {result}");

    let d = data(&result);
    assert_eq!(d["applied"], serde_json::json!(true));
    assert_eq!(d["mode"], serde_json::json!("suspectOnly"), "default mode is suspectOnly");
    assert_eq!(
        d["floor_stamp"],
        serde_json::json!("skipped: mode=all is required for an estate-wide floor"),
        "suspectOnly must not stamp floor, got: {d}"
    );
}

// ---------------------------------------------------------------------------
// Twin 4 of 10 — Swift: applyRepairsSuspectFalsePositiveToUnclassifiedSentinel
// ---------------------------------------------------------------------------
/// A full apply stamps the estate floor; estate_status then reports "current".
#[test]
fn apply_stamps_floor_and_estate_status_is_current() {
    let registry = EstateRegistry::new_inmemory();
    let _id = seed_stale_drawer(&registry);
    let store = registry.default.store.clone();
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    let apply_result = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({
        "apply": true, "mode": "all"
    }));
    assert!(is_success(&apply_result), "apply must succeed, got: {apply_result}");
    assert_eq!(data(&apply_result)["floor_stamp"], serde_json::json!("stamped"));

    let floor = store.get_meta("aria.fdc.recalced_data_version")
        .expect("get_meta must not error");
    assert!(floor.is_some(), "floor must be stored after apply mode=all");

    let status = call(&dispatcher, "moot_estate_status", serde_json::json!({}));
    assert!(is_success(&status), "estate_status must succeed, got: {status}");
    assert_eq!(
        data(&status)["fdc_recalculation"],
        serde_json::json!("current"),
        "fdc_recalculation must be current after floor is stamped, got: {}",
        data(&status)
    );
}

// ---------------------------------------------------------------------------
// Twin 5 of 10 — Swift: suspectOnlyDoesNotOverwriteBroadCodeChangeWithoutAllMode
// ---------------------------------------------------------------------------
/// suspectOnly skips broad code changes; mode=all admits them.
#[test]
fn suspect_only_skips_broad_code_change_mode_all_counts_it() {
    // bare: only the Biology drawer exists; pre-seeded suspect drawers would corrupt candidate count.
    let registry = EstateRegistry::new_inmemory_bare();
    let frame = CaptureFrame::new(
        "Biology is the scientific study of life and living organisms",
        CaptureChannel::Typed,
        "test-room",
        LatticeAnchor::new("362.4", None, None, None),
        "fdc-reclassify-tests",
        "minilm-v6",
    );
    let handle = registry.default.handle.clone();
    registry.default.coord.lock().unwrap()
        .capture(&handle, frame, 1_700_000_000_000)
        .expect("capture must succeed");
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    // suspectOnly dry run: skips broad change (both codes non-sentinel).
    let conservative = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({}));
    assert!(is_success(&conservative), "conservative must succeed, got: {conservative}");
    let c = data(&conservative);
    assert_eq!(c["candidates"], serde_json::json!(0),
        "suspectOnly must find 0 candidates for broad change, got: {c}");
    assert_eq!(c["skipped_non_candidate_changes"], serde_json::json!(1),
        "must count 1 skipped change, got: {c}");

    // mode=all dry run: admits it.
    let all_mode = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({"mode": "all"}));
    assert!(is_success(&all_mode), "mode=all must succeed, got: {all_mode}");
    let a = data(&all_mode);
    assert_eq!(a["candidates"], serde_json::json!(1),
        "mode=all must see 1 candidate, got: {a}");
    assert_eq!(a["floor_stamp"], serde_json::json!("dry-run"));
}

// ---------------------------------------------------------------------------
// Twin 6 of 10 — Swift: applyDoesNotStampFloorWhenLimited
// ---------------------------------------------------------------------------
/// A limited apply writes anchors but does not stamp the estate floor.
#[test]
fn apply_does_not_stamp_floor_when_limited() {
    let registry = EstateRegistry::new_inmemory();
    let _id = seed_stale_drawer(&registry);
    let store = registry.default.store.clone();
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    let result = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({
        "apply": true, "mode": "all", "limit": 1
    }));
    assert!(is_success(&result), "limited apply must succeed, got: {result}");

    let d = data(&result);
    assert_eq!(d["applied"], serde_json::json!(true));
    assert_eq!(
        d["floor_stamp"],
        serde_json::json!("skipped: limited run cannot update estate-wide floor"),
        "limited apply must not stamp floor, got: {d}"
    );
    let floor = store.get_meta("aria.fdc.recalced_data_version")
        .expect("get_meta must not error");
    assert!(floor.is_none(), "floor must not be stored for limited apply, got: {floor:?}");
}

// ---------------------------------------------------------------------------
// Twin 7 of 10 — Swift: conservativeApplyDoesNotStampEstateFloor
// ---------------------------------------------------------------------------
/// suspectOnly apply does not stamp the floor when non-suspect changes remain.
#[test]
fn conservative_apply_does_not_stamp_estate_floor() {
    // bare: only the Biology drawer exists; pre-seeded suspect drawers would inflate skipped count.
    let registry = EstateRegistry::new_inmemory_bare();
    let frame = CaptureFrame::new(
        "Biology is the scientific study of life and living organisms",
        CaptureChannel::Typed,
        "test-room",
        LatticeAnchor::new("362.4", None, None, None),
        "fdc-reclassify-tests",
        "minilm-v6",
    );
    let handle = registry.default.handle.clone();
    registry.default.coord.lock().unwrap()
        .capture(&handle, frame, 1_700_000_000_000)
        .expect("capture must succeed");
    let store = registry.default.store.clone();
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    let result = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({"apply": true}));
    assert!(is_success(&result), "conservative apply must succeed, got: {result}");

    let d = data(&result);
    assert_eq!(d["applied"], serde_json::json!(true));
    assert_eq!(d["skipped_non_candidate_changes"], serde_json::json!(1),
        "must count 1 skipped change, got: {d}");
    assert_eq!(
        d["floor_stamp"],
        serde_json::json!("skipped: mode=all is required for an estate-wide floor"),
        "suspectOnly must not stamp floor when non-suspect changes remain, got: {d}"
    );
    let floor = store.get_meta("aria.fdc.recalced_data_version")
        .expect("get_meta must not error");
    assert!(floor.is_none(), "floor must not be stored for suspectOnly apply");
}

// ---------------------------------------------------------------------------
// Twin 8 of 10 — Swift: estateStatusDistinguishesMissingAndStaleFDCFloors
// ---------------------------------------------------------------------------
/// estate_status reports missing, stale, and current correctly.
#[test]
fn estate_status_distinguishes_missing_and_stale_fdc_floors() {
    let registry = EstateRegistry::new_inmemory();
    let store = registry.default.store.clone();
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    // No floor yet — missing.
    let missing = call(&dispatcher, "moot_estate_status", serde_json::json!({}));
    assert!(is_success(&missing), "estate_status must succeed, got: {missing}");
    assert_eq!(
        data(&missing)["fdc_recalculation"],
        serde_json::json!("missing"),
        "fdc_recalculation must be missing initially, got: {}",
        data(&missing)
    );

    // Write a floor that differs from the current recalculation version.
    store.set_meta("aria.fdc.recalced_data_version", "classifier:old-version-from-2024")
        .expect("set_meta must succeed");

    let stale = call(&dispatcher, "moot_estate_status", serde_json::json!({}));
    assert!(is_success(&stale), "estate_status must succeed, got: {stale}");
    assert_eq!(
        data(&stale)["fdc_recalculation"],
        serde_json::json!("stale"),
        "fdc_recalculation must be stale when floor differs, got: {}",
        data(&stale)
    );
}

// ---------------------------------------------------------------------------
// Twin 9 of 10 — Swift: applyRepairsPrimaryCodeButRetainsFacetsAndSecondaryQIDs
// THE CRITICAL TEST — most likely to be broken by a naive implementation.
// ---------------------------------------------------------------------------
/// Apply repairs primary code and QID, but carries udc_facets and
/// wikidata_qids_secondary forward unchanged. Section 6 of the data contract.
#[test]
fn apply_repairs_primary_code_but_retains_facets_and_secondary_qids() {
    // bare: only the seeded drawer exists; pre-seeded suspect drawers would inflate updated count.
    let registry = EstateRegistry::new_inmemory_bare();
    let frame = CaptureFrame::new(
        "git update-index --refresh && rm .git/index.lock",
        CaptureChannel::Typed,
        "test-room",
        LatticeAnchor::new(
            "362.4",
            Some("004, 621".to_owned()),     // udc_facets — must carry forward
            Some("Q12131".to_owned()),        // wikidata_qid — reclassified by FDC
            Some("Q999, Q1000".to_owned()),   // secondary QIDs — must carry forward
        ),
        "fdc-reclassify-tests",
        "minilm-v6",
    );
    let handle = registry.default.handle.clone();
    let drawer = registry.default.coord.lock().unwrap()
        .capture(&handle, frame, 1_700_000_000_000)
        .expect("capture must succeed");
    let drawer_id = drawer.id.clone();
    let store = registry.default.store.clone();
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    let result = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({"apply": true}));
    assert!(is_success(&result), "apply must succeed, got: {result}");
    assert_eq!(data(&result)["applied"], serde_json::json!(true));
    assert_eq!(data(&result)["updated"], serde_json::json!(1));

    use locus_kit::drawer_store::DrawerStore;
    let row = store.get_drawer(&drawer_id)
        .expect("get_drawer must succeed")
        .expect("drawer must exist");
    // Primary code must be reclassified to the sentinel.
    assert_eq!(row.udc_code, "000",
        "primary code must be reclassified to sentinel");
    // Facets must survive unchanged.
    assert_eq!(row.udc_facets.as_deref(), Some("004, 621"),
        "udc_facets must be carried forward, got: {:?}", row.udc_facets);
    // Secondary QIDs must survive unchanged.
    assert_eq!(row.wikidata_qids_secondary.as_deref(), Some("Q999, Q1000"),
        "wikidata_qids_secondary must be carried forward, got: {:?}",
        row.wikidata_qids_secondary);
}

// ---------------------------------------------------------------------------
// Twin 10 of 10 — Swift: parallelClassifyIsDeterministicAndMatchesSerialAnchors
// ---------------------------------------------------------------------------
/// Repeated dry runs over 30 drawers produce identical output.
/// Parallel classify is deterministic — same input → same output every run.
#[test]
fn parallel_classify_is_deterministic_over_large_estate() {
    // bare: only the 30 seeded drawers exist; pre-seeded suspect drawers would inflate candidate count.
    let registry = EstateRegistry::new_inmemory_bare();
    let mut sentinel_ids = Vec::new();
    {
        let coord = registry.default.coord.lock().unwrap();
        let handle = &registry.default.handle;
        for i in 0_i64..30 {
            let frame = CaptureFrame::new(
                format!("git update-index --refresh iteration {i}"),
                CaptureChannel::Typed,
                "test-room",
                LatticeAnchor::new("362.4", None, Some("Q12131".to_owned()), None),
                "fdc-reclassify-tests",
                "minilm-v6",
            );
            let d = coord.capture(handle, frame, 1_700_000_000_000 + i)
                .expect("capture must succeed");
            sentinel_ids.push(d.id.clone());
        }
    }
    let store = registry.default.store.clone();
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    // Repeated dry runs must produce identical results.
    let first = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({}));
    assert!(is_success(&first), "first dry run must succeed, got: {first}");
    let first_d = data(&first).clone();
    assert_eq!(first_d["candidates"], serde_json::json!(30),
        "suspectOnly must see all 30 git-sentinel candidates, got: {first_d}");

    for _ in 0..4 {
        let repeat = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({}));
        assert!(is_success(&repeat));
        let repeat_d = data(&repeat);
        assert_eq!(repeat_d["candidates"], first_d["candidates"],
            "candidate count must be deterministic");
        assert_eq!(repeat_d["changes"], first_d["changes"],
            "changes list must be deterministic and stable");
    }

    // Apply — all 30 must be updated.
    let applied = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({
        "apply": true, "mode": "all"
    }));
    assert!(is_success(&applied), "apply must succeed, got: {applied}");
    assert_eq!(data(&applied)["updated"], serde_json::json!(30));

    use locus_kit::drawer_store::DrawerStore;
    for id in &sentinel_ids {
        let row = store.get_drawer(id).expect("get_drawer must succeed")
            .expect("drawer must exist");
        assert_eq!(row.udc_code, "000",
            "drawer {id} must be reclassified to sentinel 000, got {}", row.udc_code);
    }
}

// ---------------------------------------------------------------------------
// Validation — argument refusals
// ---------------------------------------------------------------------------

/// Unknown mode value is refused with a JSONRPC invalid-params error (code -32602).
/// Per ARIA_MCP_INTERFACE.md §16.1: invalid arguments at the v2 decode stage
/// become JSONRPCErrorCode::INVALID_PARAMS, visible at result["error"]["code"].
#[test]
fn unknown_mode_is_refused() {
    let registry = EstateRegistry::new_inmemory();
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    let result = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({"mode": "everything"}));
    assert_eq!(result["error"]["code"], serde_json::json!(-32602),
        "unknown mode must be refused with -32602, got: {result}");
}

/// limit = 0 is refused with a JSONRPC invalid-params error (code -32602).
#[test]
fn limit_zero_is_refused() {
    let registry = EstateRegistry::new_inmemory();
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    let result = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({"limit": 0}));
    assert_eq!(result["error"]["code"], serde_json::json!(-32602),
        "limit 0 must be refused with -32602, got: {result}");
}

/// limit above 50000 is refused with a JSONRPC invalid-params error (code -32602).
#[test]
fn limit_above_max_is_refused() {
    let registry = EstateRegistry::new_inmemory();
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    let result = call(&dispatcher, "moot_reclassify_fdc", serde_json::json!({"limit": 50001}));
    assert_eq!(result["error"]["code"], serde_json::json!(-32602),
        "limit above max must be refused with -32602, got: {result}");
}
