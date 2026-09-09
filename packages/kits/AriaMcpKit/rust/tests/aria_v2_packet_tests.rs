//! Dormant qualification for the typed ARIA v2 packet module.
//!
//! The selected-surface registry owns the `v2` module declaration and dispatch
//! wiring.  Keeping this feature-gated makes that integration explicit while
//! retaining the source-faithful packet cases beside the implementation unit.

#![cfg(feature = "aria-v2")]

use std::collections::BTreeMap;

use aria_mcp::{
    estate_registry::EstateRegistry,
    sensitivity_grant_ledger::SensitivityGrantLedger,
    v2::packets::{
        FilePacketRequest, GetPacketRequest, LineageRequest, ListPacketsRequest,
        PacketToolService, WorkPacket,
    },
};
use serde_json::{json, Value};

const NOW: i64 = 1_700_000_000_123;

fn args(value: Value) -> BTreeMap<String, Value> {
    value.as_object().expect("test arguments are objects").clone().into_iter().collect()
}

fn file_args(objective: &str) -> BTreeMap<String, Value> {
    args(json!({
        "objective": objective,
        "model": "test-model",
        "agent": "test-agent",
    }))
}

#[test]
fn file_decoder_is_strict_and_uses_the_live_grant_floor() {
    let mut request = file_args("qualify packet capture");
    request.insert("sensitivity".to_string(), json!("normal"));
    let error = FilePacketRequest::decode(
        &request,
        NOW,
        Some(locus_kit::adjectives::AdjectiveSensitivity::Restricted),
    ).expect_err("a value below the live grant must be refused");
    assert_eq!(error.code, "operation_failed");

    request.remove("sensitivity");
    request.insert("unknown".to_string(), json!(true));
    let error = FilePacketRequest::decode(&request, NOW, None)
        .expect_err("unknown MCP arguments must reject before execution");
    assert_eq!(error.code, "invalid_argument");
    assert_eq!(error.path, "unknown");
}

#[test]
fn packet_json_preserves_unknown_members_and_normalizes_uuid_and_dates() {
    let packet = WorkPacket::decode_storage(
        r#"{
            "schemaVersion":2,
            "id":"A0B1C2D3-E4F5-4678-9ABC-DEF012345678",
            "objective":"future packet",
            "sources":[], "claims":[], "uncertainties":[], "nextSteps":[], "lineageLinks":[],
            "provenance":{"model":"m","agent":"a","createdAt":"2023-11-14T22:13:20+01:00","updatedAt":"2023-11-14T22:13:20Z"},
            "futureField":{"survives":true}
        }"#,
    ).expect("a forward schema retains unknown members");
    assert!(packet.is_future_schema());
    assert_eq!(packet.id, "a0b1c2d3-e4f5-4678-9abc-def012345678");
    assert_eq!(packet.additional_fields["futureField"]["survives"], json!(true));
    let encoded: Value = serde_json::from_str(&packet.encode_storage().unwrap()).unwrap();
    assert_eq!(encoded["futureField"]["survives"], json!(true));
    assert!(encoded["provenance"]["createdAt"].as_str().unwrap().ends_with('Z'));
}

#[test]
fn decoder_rejects_invalid_confidence_and_canonicalizes_lineage_uuid() {
    let mut request = file_args("strict claim");
    request.insert("claims".to_string(), json!([{"statement":"bad", "confidence":1.01}]));
    let error = FilePacketRequest::decode(&request, NOW, None).expect_err("confidence above one rejects");
    assert_eq!(error.path, "claims[0].confidence");

    request.insert("claims".to_string(), json!([{"statement":"good", "confidence":0.0}]));
    request.insert("lineage_links".to_string(), json!([
        {"kind":"derivesFrom", "targetPacketID":"A0B1C2D3-E4F5-4678-9ABC-DEF012345678"}
    ]));
    let decoded = FilePacketRequest::decode(&request, NOW, None).unwrap();
    assert_eq!(decoded.packet.lineage_links[0].target_packet_id, "a0b1c2d3-e4f5-4678-9abc-def012345678");
}

#[test]
fn list_and_lineage_bounds_reject_instead_of_clamping() {
    let error = ListPacketsRequest::decode(&args(json!({"limit":101}))).unwrap_err();
    assert_eq!(error.path, "limit");
    let error = LineageRequest::decode(&args(json!({
        "drawer_id":"a0b1c2d3-e4f5-4678-9abc-def012345678", "max_depth":51
    }))).unwrap_err();
    assert_eq!(error.path, "max_depth");
}

#[test]
fn file_get_list_and_lineage_use_drawer_identity_and_breadth_first_order() {
    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SensitivityGrantLedger::new();
    let coordinator = registry.default.coord.lock().unwrap();
    let service = PacketToolService::new(&coordinator, &registry.default.handle, &ledger, NOW);

    let parent = service.file(FilePacketRequest::decode(&file_args("parent"), NOW, None).unwrap()).unwrap();
    let mut child_args = file_args("child");
    child_args.insert("lineage_links".to_string(), json!([
        {"kind":"derivesFrom", "targetPacketID":parent.drawer_id}
    ]));
    let later_service = PacketToolService::new(&coordinator, &registry.default.handle, &ledger, NOW + 1);
    let child = later_service.file(FilePacketRequest::decode(&child_args, NOW + 1, None).unwrap()).unwrap();
    assert_ne!(child.drawer_id, child.packet_id, "estate drawer identity is distinct from packet identity");

    let get = later_service.get(GetPacketRequest::decode(&args(json!({"drawer_id":child.drawer_id}))).unwrap()).unwrap();
    assert_eq!(get.packet.objective, "child");
    let listed = later_service.list(ListPacketsRequest::decode(&args(json!({}))).unwrap()).unwrap();
    assert_eq!(listed.packets.len(), 2);
    assert_eq!(listed.packets[0].drawer_id, child.drawer_id, "newest first");
    let lineage = later_service.lineage(LineageRequest::decode(&args(json!({"drawer_id":child.drawer_id}))).unwrap()).unwrap();
    assert_eq!(lineage.antecedents, vec![parent.drawer_id]);
}

#[test]
fn hidden_and_missing_packet_share_one_not_found_shape() {
    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SensitivityGrantLedger::new();
    let coordinator = registry.default.coord.lock().unwrap();
    let service = PacketToolService::new(&coordinator, &registry.default.handle, &ledger, NOW);
    let hidden = service.file(FilePacketRequest::decode(
        &args(json!({"objective":"restricted", "model":"m", "agent":"a", "sensitivity":"restricted"})), NOW, None,
    ).unwrap()).unwrap();
    let hidden_error = service.get(GetPacketRequest::decode(&args(json!({"drawer_id":hidden.drawer_id}))).unwrap()).unwrap_err();
    let missing_error = service.get(GetPacketRequest::decode(&args(json!({
        "drawer_id":"a0b1c2d3-e4f5-4678-9abc-def012345678"
    }))).unwrap()).unwrap_err();
    assert_eq!(hidden_error.code, "packet_not_found");
    assert_eq!(hidden_error, missing_error);
}

#[test]
fn nondefault_wing_packet_ids_resolve_without_weakening_explicit_scope() {
    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SensitivityGrantLedger::new();
    let coordinator = registry.default.coord.lock().unwrap();
    let service = PacketToolService::new(&coordinator, &registry.default.handle, &ledger, NOW);
    let mut parent_args = file_args("parent");
    parent_args.insert("wing".to_owned(), json!("Lab"));
    let parent = service.file(FilePacketRequest::decode(&parent_args, NOW, None).unwrap()).unwrap();
    let mut child_args = file_args("child");
    child_args.insert("wing".to_owned(), json!("Lab"));
    child_args.insert("lineage_links".to_owned(), json!([{"kind":"derivesFrom","targetPacketID":parent.drawer_id}]));
    let child = service.file(FilePacketRequest::decode(&child_args, NOW, None).unwrap()).unwrap();
    let get = service.get(GetPacketRequest::decode(&args(json!({"drawer_id":child.drawer_id}))).unwrap()).unwrap();
    assert_eq!(get.packet.objective,"child");
    let lineage = service.lineage(LineageRequest::decode(&args(json!({"drawer_id":child.drawer_id}))).unwrap()).unwrap();
    assert_eq!(lineage.antecedents,vec![parent.drawer_id]);
    for tool in ["get","lineage"] {
        let input=args(json!({"drawer_id":child.drawer_id,"wing":"Wrong"}));
        let code=if tool=="get" { service.get(GetPacketRequest::decode(&input).unwrap()).unwrap_err().code }
            else { service.lineage(LineageRequest::decode(&input).unwrap()).unwrap_err().code };
        assert_eq!(code,"packet_not_found");
    }
    child_args.insert("sensitivity".to_owned(),json!("restricted"));
    let hidden=service.file(FilePacketRequest::decode(&child_args,NOW,None).unwrap()).unwrap();
    assert_eq!(service.get(GetPacketRequest::decode(&args(json!({"drawer_id":hidden.drawer_id}))).unwrap()).unwrap_err().code,"packet_not_found");
}
