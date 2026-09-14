//! Public-v2 file-memory coverage for a genuinely expired sensitivity grant.
//!
//! The dispatcher uses wall time in production.  The v2 core operation takes
//! its clock as a dependency, so this test pins that same production seam to
//! prove the expiration boundary without waiting thirty-one minutes.

use aria_mcp::{
    estate_posture::EstatePosture,
    estate_registry::EstateRegistry,
    sensitivity_grant_ledger::SensitivityGrantLedger,
    surfaced_recall_ledger::SurfacedRecallLedger,
    v2::{
        core_memory::{
            run_file_memory, V2CoreMemoryDependencies, V2CoreMemoryOperation,
            V2MemoryAuthorization, V2MemoryClock, V2MemoryFailure, V2MemoryOperationContext,
        },
        estate_memory::EstateV2MemoryService,
        operation::V2OperationEffect,
        render::V2ResultMeta,
    },
};
use locus_kit::adjectives::AdjectiveSensitivity;

const NOW_MS: i64 = 1_700_000_000_000;

struct FixedClock;

impl V2MemoryClock for FixedClock {
    fn now_millis(&self) -> i64 { NOW_MS }
}

struct Allow;

impl V2MemoryAuthorization for Allow {
    fn authorize(
        &self,
        _: V2CoreMemoryOperation,
        _: &V2MemoryOperationContext,
    ) -> Result<(), V2MemoryFailure> {
        Ok(())
    }
}

#[test]
fn file_memory_expired_grant_does_not_floor() {
    let registry = EstateRegistry::new_inmemory_bare();
    let service = EstateV2MemoryService::new(&registry, EstatePosture::Live);
    let grants = SensitivityGrantLedger::new();
    // This is an actual secret grant whose fixed thirty-minute lifetime ended
    // before the production v2 file operation reads its injected clock.
    grants.grant_secret(NOW_MS - 31 * 60 * 1_000);
    assert!(!grants.is_secret_granted(NOW_MS), "fixture must be expired");
    let surfaced = SurfacedRecallLedger::new();
    let clock = FixedClock;
    let allow = Allow;
    let deps = V2CoreMemoryDependencies {
        service: &service,
        authorization: &allow,
        clock: &clock,
        sensitivity_ledger: &grants,
        surfaced_recall_ledger: &surfaced,
        caller_identity: "aria-v2-expired-file-grant-test",
        meta: V2ResultMeta::incomplete("test", "digest", V2OperationEffect::Write),
    };

    let response = run_file_memory(
        &serde_json::json!({
            "content": "ceiling-secret-expired checkpoint body",
            "subject": "ceiling-secret-expired checkpoint",
            "location": "session/ceiling-tests/checkpoint-30"
        }).into(),
        &deps,
    ).expect("v2 file-memory call must dispatch");
    assert_eq!(response["isError"], false, "expired grant must not refuse: {response}");

    let coord = registry.coord.lock().expect("coordinator lock");
    let drawer = coord
        .all_drawers(&registry.default.handle)
        .expect("all drawers")
        .into_iter()
        .find(|drawer| drawer.content.contains("ceiling-secret-expired"))
        .expect("file-memory must durably write the requested drawer");
    assert_eq!(drawer.adjective_sensitivity(), AdjectiveSensitivity::Normal,
        "an expired secret grant must not floor an omitted sensitivity");
}
