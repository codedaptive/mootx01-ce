//! V2_RESTORE_A Unit 1 — proves the sensitivity-read-under-grant audit fires
//! on the REAL v2 core-memory operations (`execute_memory_search` /
//! `execute_memory_get`, the exact functions `surface.rs`'s
//! `SelectedSurface::execute` calls in production, backed by the exact same
//! `EstateV2MemoryService` adapter production wiring uses) against a genuine
//! in-memory estate and a genuine `SensitivityGrantLedger`.
//!
//! `dispatch_tests.rs::restricted_read_under_grant_emits_audit_entry_via_search_and_get`
//! proves the same audit-emission property through `interface_tools::dispatch`
//! — the dark v1 path the running server never calls (`dispatch.rs`'s own
//! module header: "The running server does not call it"). That test, and its
//! `normal_drawer_read_during_live_grant_does_not_emit_audit_entry` neighbor,
//! stay green and unmodified. This file drives the identical scenario through
//! the shipped v2 surface instead.

use aria_mcp::{
    estate_posture::EstatePosture,
    estate_registry::EstateRegistry,
    sensitivity_grant_ledger::SensitivityGrantLedger,
    surfaced_recall_ledger::SurfacedRecallLedger,
    v2::{
        core_memory::{
            execute_memory_search, run_file_memory, run_memory_get, V2CoreMemoryDependencies,
            V2MemorySearchRequest,
            V2CoreMemoryOperation, V2MemoryAuthorization, V2MemoryClock, V2MemoryFailure,
            V2MemoryOperationContext,
        },
        estate_memory::EstateV2MemoryService,
        operation::V2OperationEffect,
        render::V2ResultMeta,
    },
};
use genius_locus_kit::audit::{EntryUUID, UnifiedAuditVerb};
use serde_json::json;
use std::sync::atomic::{AtomicI64, Ordering};

fn arguments(value: serde_json::Value) -> aria_mcp::jsonrpc::JsonValue {
    value.into()
}

/// Ticks forward by one millisecond on every read. The audit log is a G-Set
/// (content-hash-deduplicated): a fixed clock returning the identical
/// millisecond for two `record_sensitivity_read_under_grant` calls on the
/// same row produces byte-identical `UnifiedAuditEntry` content hashes, and
/// the second collapses into the first instead of recording a second read.
/// Three independent `moot_memory_get` depth calls on one row must each
/// produce a genuinely distinct entry, so the clock must actually advance
/// between them — exactly as it does between real, separately-dispatched
/// MCP requests in production.
struct IncrementingClock(AtomicI64);
impl V2MemoryClock for IncrementingClock {
    fn now_millis(&self) -> i64 { self.0.fetch_add(1, Ordering::SeqCst) }
}

struct Allow;
impl V2MemoryAuthorization for Allow {
    fn authorize(&self, _: V2CoreMemoryOperation, _: &V2MemoryOperationContext) -> Result<(), V2MemoryFailure> {
        Ok(())
    }
}

const NOW_MS: i64 = 1_700_000_000_000;

/// Files two restricted-tier drawers through the real `run_file_memory`
/// typed call, then — with a live restricted grant — reads one through
/// `execute_memory_search` and the other through `run_memory_get` at all three
/// depths (subject, distilled, full; the v2 get path fetches and audits the
/// row once per request regardless of which depth the response is projected
/// to, so three depth calls on one row independently produce three entries).
/// Asserts the resulting `sensitivity_read_under_grant` audit entries land
/// against the right rows, with the right count, and the right field_path.
#[test]
fn v2_search_and_get_emit_read_under_grant_audit_entries_on_the_real_estate_backed_service() {
    let registry = EstateRegistry::new_inmemory();
    let service = EstateV2MemoryService::new(&registry, EstatePosture::Live);
    let sensitivity_ledger = SensitivityGrantLedger::new();
    let surfaced = SurfacedRecallLedger::new();
    let clock = IncrementingClock(AtomicI64::new(NOW_MS));
    let auth = Allow;
    let deps = V2CoreMemoryDependencies {
        service: &service,
        authorization: &auth,
        clock: &clock,
        sensitivity_ledger: &sensitivity_ledger,
        surfaced_recall_ledger: &surfaced,
        caller_identity: "test-host",
        meta: V2ResultMeta::incomplete("test", "digest", V2OperationEffect::Read),
    };

    // Distinct wings for the two drawers: the lexical-only recall fallback
    // in this test harness (no embedding model directory — "recall runs
    // lexical-only") ranks every ADMITTED row rather than filtering strictly
    // to query relevance (the default in-memory estate's seeded charter
    // content shows up too), so once BOTH restricted rows are admitted by
    // the live grant, an unscoped search could surface both and inflate the
    // get-drawer's audit count with a spurious search-side hit. Scoping the
    // search call to the search-drawer's own wing keeps the two operations'
    // audit counts attributable to the right row.
    let filed_search = run_file_memory(
        &arguments(json!({
            "content": "v2-audit-search-marker restricted content",
            "subject": "v2-audit-search-marker restricted content",
            "location": "vault/plans",
            "wing": "audit-search-wing",
            "sensitivity": "restricted",
        })),
        &deps,
    ).expect("file_memory must succeed");
    let search_drawer_id = filed_search["structuredContent"]["data"]["memory_id"].as_str().unwrap().to_owned();

    let filed_get = run_file_memory(
        &arguments(json!({
            "content": "v2-audit-get-marker restricted content",
            "subject": "v2-audit-get-marker restricted content",
            "location": "vault/plans",
            "wing": "audit-get-wing",
            "sensitivity": "restricted",
        })),
        &deps,
    ).expect("file_memory must succeed");
    let get_drawer_id = filed_get["structuredContent"]["data"]["memory_id"].as_str().unwrap().to_owned();

    let contains_search_drawer = |result: &serde_json::Value| -> bool {
        result["structuredContent"]["data"]["results"].as_array()
            .map(|results| results.iter().any(|row| row["memory_id"] == json!(search_drawer_id)))
            .unwrap_or(false)
    };

    // Without a live grant neither restricted row is reachable through v2.
    let before_search = execute_memory_search(
        V2MemorySearchRequest::decode(&arguments(json!({"query": "v2-audit-search-marker", "wing": "audit-search-wing"}))).expect("decode must not fail"),
        &deps,
    ).expect("search must not throw");
    assert!(!contains_search_drawer(&before_search),
        "without a grant the restricted row must not appear in v2 search results");
    let before_get = run_memory_get(&arguments(json!({"memory_id": get_drawer_id.clone()})), &deps)
        .expect("get must not throw");
    assert_eq!(before_get["structuredContent"]["error"]["code"], "memory_not_found",
        "without a grant the restricted row must report not-found via v2 get");

    sensitivity_ledger.grant_restricted(NOW_MS);

    let after_search = execute_memory_search(
        V2MemorySearchRequest::decode(&arguments(json!({"query": "v2-audit-search-marker", "wing": "audit-search-wing"}))).expect("decode must not fail"),
        &deps,
    ).expect("search must not throw");
    assert!(contains_search_drawer(&after_search),
        "with a live grant the restricted row must appear in v2 search results");

    for depth in ["subject", "distilled", "skim", "full"] {
        let after_get = run_memory_get(
            &arguments(json!({"memory_id": get_drawer_id.clone(), "depth": depth})),
            &deps,
        ).expect("get must not throw");
        let memories = after_get["structuredContent"]["data"]["memories"].as_array().cloned().unwrap_or_default();
        assert_eq!(memories.len(), 1, "with a live grant depth:{depth} must find the drawer");
    }

    let coord = registry.coord.lock().unwrap();
    let log = coord.audit_log(&registry.default.handle).expect("audit log");
    let entries: Vec<_> = log.ordered_entries().into_iter()
        .filter(|e| e.verb == UnifiedAuditVerb::SensitivityReadUnderGrant)
        .collect();

    // UnifiedAuditEntry.row_id is EntryUUID (a 16-byte newtype, big-endian
    // u128), not uuid::Uuid directly — same conversion
    // `append_sensitivity_audit_entry` applies (coordinator.rs:
    // `EntryUUID(row_id.as_u128().to_be_bytes())`).
    let search_row = EntryUUID(uuid::Uuid::parse_str(&search_drawer_id).unwrap().as_u128().to_be_bytes());
    let get_row = EntryUUID(uuid::Uuid::parse_str(&get_drawer_id).unwrap().as_u128().to_be_bytes());
    let search_entries: Vec<_> = entries.iter().filter(|e| e.row_id == search_row).collect();
    let get_entries: Vec<_> = entries.iter().filter(|e| e.row_id == get_row).collect();

    assert_eq!(search_entries.len(), 1,
        "one v2 moot_memory_search hit on a restricted row under grant must emit exactly one audit entry");
    assert_eq!(search_entries[0].field_path, "restricted");

    assert_eq!(get_entries.len(), 4,
        "four v2 moot_memory_get depth calls on the same restricted row must each independently emit an audit entry");
    for entry in &get_entries {
        assert_eq!(entry.field_path, "restricted");
    }
}
