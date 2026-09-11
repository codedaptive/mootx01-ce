
#[path = "../src/v2/estate_diagnostics.rs"]
mod estate_diagnostics;

use estate_diagnostics::{
    DiagnosticsFact, DiagnosticsLifecycle, DiagnosticsMemory, EstateDiagnosticsAuthority,
    EstateDiagnosticsContext, EstateDiagnosticsFailure, EstateDiagnosticsGrant, EstateDiagnosticsOperation,
    EstateDiagnosticsRequest, EstateDiagnosticsService, EstateDiagnosticsSnapshot, EstateDrain,
    EstateDrainState, EstateRebuildState, EstateTiming,
};
use serde_json::json;
use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
use uuid::Uuid;

fn estate_id() -> Uuid { Uuid::parse_str("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").unwrap() }

fn context() -> EstateDiagnosticsContext {
    EstateDiagnosticsContext {
        caller_binding: "caller-a".to_owned(),
        session_id: "session-a".to_owned(),
        clock_millis: 1_700_000_000_000,
        build_serial: "build-20260908".to_owned(),
    }
}

fn request() -> EstateDiagnosticsRequest { EstateDiagnosticsRequest { estate_id: Some(estate_id()) } }

fn snapshot(mounted: bool) -> EstateDiagnosticsSnapshot {
    EstateDiagnosticsSnapshot {
        estate_id: estate_id(),
        estate_name: "Test Estate".to_owned(),
        mounted,
        memories: vec![
            DiagnosticsMemory { wing: "Agents".to_owned(), room: "inbox".to_owned(), lifecycle: DiagnosticsLifecycle::CurrentClusterA, bulk_exportable: true },
            DiagnosticsMemory { wing: "Agents".to_owned(), room: "inbox".to_owned(), lifecycle: DiagnosticsLifecycle::CurrentClusterA, bulk_exportable: true },
            DiagnosticsMemory { wing: "Private".to_owned(), room: "secrets".to_owned(), lifecycle: DiagnosticsLifecycle::CurrentClusterA, bulk_exportable: false },
            DiagnosticsMemory { wing: "Archived".to_owned(), room: "old".to_owned(), lifecycle: DiagnosticsLifecycle::Other, bulk_exportable: true },
        ],
        facts: vec![
            DiagnosticsFact { lifecycle: DiagnosticsLifecycle::CurrentClusterA, bulk_exportable: true },
            DiagnosticsFact { lifecycle: DiagnosticsLifecycle::CurrentClusterA, bulk_exportable: false },
            DiagnosticsFact { lifecycle: DiagnosticsLifecycle::Other, bulk_exportable: true },
        ],
        drains: vec![EstateDrain { name: "corpus_encode".to_owned(), state: EstateDrainState::Draining, pending: 4 }],
        rebuild: EstateRebuildState::Running,
        timing: EstateTiming { watermark_ms: 1_700_000_123_456, truncated: true },
        recall_trace_count: Some(7),
        sync_state: "local-only".to_owned(),
        subjects_bearing: 1,
        subjects_eligible: 2,
        shared_content_migration: None,
        fdc_floor: None,
    }
}

struct Authority {
    snapshot: EstateDiagnosticsSnapshot,
    expected_context: EstateDiagnosticsContext,
    heavy_inventory_reads: Arc<AtomicUsize>,
}

impl Authority {
    fn new(snapshot: EstateDiagnosticsSnapshot) -> Self {
        Self::with_counter(snapshot, Arc::new(AtomicUsize::new(0)))
    }

    fn with_counter(snapshot: EstateDiagnosticsSnapshot, heavy_inventory_reads: Arc<AtomicUsize>) -> Self {
        Self { snapshot, expected_context: context(), heavy_inventory_reads }
    }

    fn verify(&self, context: &EstateDiagnosticsContext) -> Result<(), EstateDiagnosticsFailure> {
        if context != &self.expected_context {
            return Err(EstateDiagnosticsFailure::operational("access_denied", "Context binding did not match.", false));
        }
        Ok(())
    }
}

impl EstateDiagnosticsAuthority for Authority {
    fn authorize(
        &self,
        operation: EstateDiagnosticsOperation,
        requested_estate_id: Option<Uuid>,
        context: &EstateDiagnosticsContext,
    ) -> Result<EstateDiagnosticsGrant, EstateDiagnosticsFailure> {
        self.verify(context)?;
        if requested_estate_id != Some(estate_id()) {
            return Err(EstateDiagnosticsFailure::operational("access_denied", "Estate is not authorized.", false));
        }
        let _ = operation;
        Ok(EstateDiagnosticsGrant { estate_id: estate_id(), estate_name: "Test Estate".to_owned() })
    }

    fn snapshot(
        &self,
        operation: EstateDiagnosticsOperation,
        _: &EstateDiagnosticsGrant,
        context: &EstateDiagnosticsContext,
    ) -> Result<EstateDiagnosticsSnapshot, EstateDiagnosticsFailure> {
        self.verify(context)?;
        if operation != EstateDiagnosticsOperation::Ping {
            self.heavy_inventory_reads.fetch_add(1, Ordering::SeqCst);
        }
        Ok(self.snapshot.clone())
    }

    fn revalidate(
        &self,
        _: EstateDiagnosticsOperation,
        _: &EstateDiagnosticsGrant,
        context: &EstateDiagnosticsContext,
    ) -> Result<(), EstateDiagnosticsFailure> {
        self.verify(context)
    }
}

#[test]
fn request_accepts_only_optional_estate_id() {
    let decoded = EstateDiagnosticsRequest::decode(&json!({"estate_id": estate_id().to_string()})).unwrap();
    assert_eq!(decoded.estate_id, Some(estate_id()));
    assert!(EstateDiagnosticsRequest::decode(&json!({"since_ms": 0})).is_err());
    assert!(EstateDiagnosticsRequest::decode(&json!({"estate_id": 7})).is_err());
}

#[test]
fn status_and_map_apply_cluster_a_and_public_bulk_ceiling() {
    let service = EstateDiagnosticsService::new(Authority::new(snapshot(true)));
    let status = service.status(request(), &context()).unwrap();
    assert_eq!(status.estate_id, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    assert_eq!(status.estate_name, "Test Estate");
    assert_eq!(status.memory_count, 2);
    assert_eq!(status.fact_count, 1);
    assert_eq!(status.drains.len(), 1);
    assert_eq!(status.fdc_recalculation, "missing");
    assert_eq!(serde_json::to_value(&status).unwrap(), json!({
        "estate_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "estate_name": "Test Estate",
        "memory_count": 2,
        "fact_count": 1,
        "fdc_recalculation": "missing",
        "drains": [{"name": "corpus_encode", "state": "draining", "pending": 4}],
        // recall_trace_count is present because the fixture supplies one.
        // shared_content_migration is ABSENT, which is the shape an estate
        // that never ran detection returns — omitted, not null.
        "recall_trace_count": 7,
        "sync_state": "local-only",
        "subjects_bearing": 1,
        "subjects_eligible": 2,
    }));

    let map = service.map(request(), &context()).unwrap();
    assert_eq!(map.wings.len(), 1);
    assert_eq!(map.wings[0].name, "Agents");
    assert_eq!(map.wings[0].rooms[0].name, "inbox");
    assert_eq!(map.wings[0].rooms[0].memory_count, 2);
    assert_eq!(serde_json::to_value(&map).unwrap(), json!({
        "estate_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "wings": [{"name": "Agents", "rooms": [{"name": "inbox", "memory_count": 2}]}],
    }));
}

#[test]
fn ping_refuses_nonmounted_and_binds_build_context() {
    let heavy_inventory_reads = Arc::new(AtomicUsize::new(0));
    let authority = Authority::with_counter(snapshot(true), Arc::clone(&heavy_inventory_reads));
    let live = EstateDiagnosticsService::new(authority);
    let ping = live.ping(request(), &context()).unwrap();
    assert_eq!(ping.state, "mounted");
    assert_eq!(ping.build_serial, "build-20260908");
    assert_eq!(heavy_inventory_reads.load(Ordering::SeqCst), 0,
        "ping must not request an inventory snapshot");
    assert_eq!(serde_json::to_value(&ping).unwrap(), json!({
        "estate_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "estate_name": "Test Estate",
        "state": "mounted",
        "build_serial": "build-20260908",
    }));

    let offline = EstateDiagnosticsService::new(Authority::new(snapshot(false)));
    let error = offline.ping(request(), &context()).unwrap_err();
    assert_eq!(error.code, "estate_unavailable");

    let mut wrong_context = context();
    wrong_context.session_id = "other-session".to_owned();
    let error = live.status(request(), &wrong_context).unwrap_err();
    assert_eq!(error.code, "access_denied");
}

#[test]
fn snapshot_seam_receives_the_operation_before_data_collection() {
    let heavy_inventory_reads = Arc::new(AtomicUsize::new(0));
    let authority = Authority::with_counter(snapshot(true), Arc::clone(&heavy_inventory_reads));
    let service = EstateDiagnosticsService::new(authority);
    service.status(request(), &context()).unwrap();
    assert_eq!(heavy_inventory_reads.load(Ordering::SeqCst), 1);
}

#[test]
fn drain_rebuild_and_timing_use_the_frozen_data_shapes() {
    let service = EstateDiagnosticsService::new(Authority::new(snapshot(true)));
    let drains = service.drain(request(), &context()).unwrap();
    assert_eq!(drains.drains, vec![EstateDrain {
        name: "corpus_encode".to_owned(), state: EstateDrainState::Draining, pending: 4,
    }]);
    let rebuild = service.rebuild(request(), &context()).unwrap();
    assert_eq!(rebuild.state, EstateRebuildState::Running);
    let timing = service.timing(request(), &context()).unwrap();
    assert_eq!(timing.since_ms, 0);
    assert_eq!(timing.watermark_ms, 1_700_000_123_456);
    assert!(timing.truncated);
    assert_eq!(serde_json::to_value(&drains).unwrap(), json!({
        "drains": [{"name": "corpus_encode", "state": "draining", "pending": 4}],
    }));
    assert_eq!(serde_json::to_value(&rebuild).unwrap(), json!({"state": "running"}));
    assert_eq!(serde_json::to_value(&timing).unwrap(), json!({
        "since_ms": 0,
        "watermark_ms": 1_700_000_123_456i64,
        "truncated": true,
    }));
}
