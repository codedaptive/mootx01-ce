
use aria_mcp::v2::estate_diagnostics::{
    DiagnosticsFact, DiagnosticsLifecycle, DiagnosticsMemory, EstateDiagnosticsAuthority,
    EstateDiagnosticsContext, EstateDiagnosticsFailure, EstateDiagnosticsGrant,
    EstateDiagnosticsOperation, EstateDiagnosticsRequest, EstateDiagnosticsService,
    EstateDiagnosticsSnapshot, EstateRebuildState, EstateTiming,
};
use serde_json::Value;
use uuid::Uuid;

fn estate_id() -> Uuid {
    Uuid::parse_str("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb").unwrap()
}

fn request() -> EstateDiagnosticsRequest {
    EstateDiagnosticsRequest { estate_id: Some(estate_id()) }
}

fn snapshot() -> EstateDiagnosticsSnapshot {
    EstateDiagnosticsSnapshot {
        estate_id: estate_id(),
        estate_name: "Skew Estate".to_owned(),
        mounted: true,
        memories: vec![DiagnosticsMemory {
            wing: "W".to_owned(),
            room: "R".to_owned(),
            lifecycle: DiagnosticsLifecycle::CurrentClusterA,
            bulk_exportable: true,
        }],
        facts: vec![DiagnosticsFact {
            lifecycle: DiagnosticsLifecycle::CurrentClusterA,
            bulk_exportable: true,
        }],
        drains: vec![],
        rebuild: EstateRebuildState::Idle,
        timing: EstateTiming { watermark_ms: 0, truncated: false },
        recall_trace_count: None,
        sync_state: "local-only".to_owned(),
        subjects_bearing: 0,
        subjects_eligible: 0,
        shared_content_migration: None,
        fdc_floor: None,
    }
}

struct StubAuthority {
    snapshot: EstateDiagnosticsSnapshot,
}

impl EstateDiagnosticsAuthority for StubAuthority {
    fn authorize(
        &self,
        _op: EstateDiagnosticsOperation,
        _estate_id: Option<Uuid>,
        _ctx: &EstateDiagnosticsContext,
    ) -> Result<EstateDiagnosticsGrant, EstateDiagnosticsFailure> {
        Ok(EstateDiagnosticsGrant {
            estate_id: self.snapshot.estate_id,
            estate_name: self.snapshot.estate_name.clone(),
        })
    }

    fn snapshot(
        &self,
        _op: EstateDiagnosticsOperation,
        _grant: &EstateDiagnosticsGrant,
        _ctx: &EstateDiagnosticsContext,
    ) -> Result<EstateDiagnosticsSnapshot, EstateDiagnosticsFailure> {
        Ok(self.snapshot.clone())
    }

    fn revalidate(
        &self,
        _op: EstateDiagnosticsOperation,
        _grant: &EstateDiagnosticsGrant,
        _ctx: &EstateDiagnosticsContext,
    ) -> Result<(), EstateDiagnosticsFailure> {
        Ok(())
    }
}

fn service() -> EstateDiagnosticsService<StubAuthority> {
    EstateDiagnosticsService::new(StubAuthority { snapshot: snapshot() })
}

fn context_with_skew(advisory: &str) -> EstateDiagnosticsContext {
    EstateDiagnosticsContext {
        caller_binding: "test-caller".to_owned(),
        session_id: "test-session".to_owned(),
        clock_millis: 1_700_000_000_000,
        build_serial: "build-skew-test".to_owned(),
        version_skew: advisory.to_owned(),
        update_advisory: None,
    }
}

fn context_without_skew() -> EstateDiagnosticsContext {
    context_with_skew("")
}

/// Gate: `version_skew` surfaces in `moot_estate_ping` structured data when
/// a non-empty advisory is injected into the context. Neuter this assertion
/// to prove the test discriminates.
#[test]
fn test_version_skew_advisory_surfaces_in_ping() {
    let advisory = "plugin 1.0.15 expects binary ≥ 1.0.15; binary is 1.0.11 — run `mootx01 upgrade`";
    let ctx = context_with_skew(advisory);
    let data = service().ping(request(), &ctx).expect("ping must succeed when estate is mounted");
    assert_eq!(
        data.version_skew.as_deref(),
        Some(advisory),
        "moot_estate_ping must surface the injected advisory in version_skew; got {:?}",
        data.version_skew,
    );
    // Serialized output must also carry the key.
    let json = serde_json::to_value(&data).expect("must serialize");
    assert_eq!(
        json.get("version_skew").and_then(Value::as_str),
        Some(advisory),
        "serialized ping data must carry version_skew; got {json}",
    );
}

/// Gate: `version_skew` surfaces in `moot_estate_status` structured data when
/// a non-empty advisory is injected.
#[test]
fn test_version_skew_advisory_surfaces_in_status() {
    let advisory = "plugin 1.0.15 expects binary ≥ 1.0.15; binary is 1.0.11 — run `mootx01 upgrade`";
    let ctx = context_with_skew(advisory);
    let data = service().status(request(), &ctx).expect("status must succeed");
    assert_eq!(
        data.version_skew.as_deref(),
        Some(advisory),
        "moot_estate_status must surface the injected advisory in version_skew; got {:?}",
        data.version_skew,
    );
    let json = serde_json::to_value(&data).expect("must serialize");
    assert_eq!(
        json.get("version_skew").and_then(Value::as_str),
        Some(advisory),
        "serialized status data must carry version_skew; got {json}",
    );
}

/// Gate: `version_skew` is absent from `moot_estate_ping` when no advisory
/// was injected (empty string context). The JSON key must not appear at all.
#[test]
fn test_no_version_skew_advisory_omits_field_from_ping() {
    let ctx = context_without_skew();
    let data = service().ping(request(), &ctx).expect("ping must succeed");
    assert!(
        data.version_skew.is_none(),
        "version_skew must be None in ping when no advisory was injected; got {:?}",
        data.version_skew,
    );
    let json = serde_json::to_value(&data).expect("must serialize");
    assert!(
        json.get("version_skew").is_none(),
        "version_skew key must be absent from serialized ping data when no advisory; got {json}",
    );
}

/// Gate: `version_skew` is absent from `moot_estate_status` when no advisory
/// was injected (empty string context). The JSON key must not appear at all.
#[test]
fn test_no_version_skew_advisory_omits_field_from_status() {
    let ctx = context_without_skew();
    let data = service().status(request(), &ctx).expect("status must succeed");
    assert!(
        data.version_skew.is_none(),
        "version_skew must be None in status when no advisory was injected; got {:?}",
        data.version_skew,
    );
    let json = serde_json::to_value(&data).expect("must serialize");
    assert!(
        json.get("version_skew").is_none(),
        "version_skew key must be absent from serialized status data when no advisory; got {json}",
    );
}
