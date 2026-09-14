//! Public selected-v2 coverage for grant-gated federation behavior.

use std::collections::BTreeMap;

mod test_support;

use aria_mcp::{estate_registry::EstateRegistry, jsonrpc::JsonValue};
use genius_locus_kit::{CustodyMode, EstateHandle, GrantLifetime, GrantOptions, GrantScope, ReSharePermission};
use locus_kit::{adjectives::AdjectiveSensitivity, drawer_operational::CaptureChannel, estate_types::LatticeAnchor, frames::CaptureFrame};
use test_support::SelectedV2Session;

macro_rules! args {
    () => { BTreeMap::new() };
    ($( $key:expr => $value:expr ),+ $(,)?) => {{
        let mut values = BTreeMap::new();
        $(values.insert($key.to_owned(), JsonValue::from(serde_json::json!($value)));)+
        values
    }};
}

fn source_handle(registry: &EstateRegistry) -> EstateHandle {
    let default = registry.default.handle.estate_uuid;
    registry.coord.lock().expect("coordinator lock").handles().into_iter()
        .find(|handle| handle.estate_uuid != default)
        .expect("registered source handle")
}

fn registry_with_grant(
    name: &str,
    scope: GrantScope,
    lifetime: GrantLifetime,
    content_level: i64,
) -> (EstateRegistry, EstateHandle) {
    registry_with_grant_budget(name, scope, lifetime, content_level, 1.0)
}

fn registry_with_grant_budget(
    name: &str,
    scope: GrantScope,
    lifetime: GrantLifetime,
    content_level: i64,
    budget: f64,
) -> (EstateRegistry, EstateHandle) {
    let mut registry = EstateRegistry::new_inmemory();
    registry.register_inmemory(name);
    let source = source_handle(&registry);
    let grantee = uuid::Uuid::from_bytes(registry.default.handle.estate_uuid);
    let options = GrantOptions {
        grantee_estate_id: grantee,
        scope,
        custody_mode: CustodyMode::Mediated,
        lifetime,
        content_level,
        re_share_permission: ReSharePermission::None,
    };
    let mut coordinator = registry.coord.lock().expect("coordinator lock");
    let grant = coordinator.issue_grant(&source, options, &[0xBB; 32], 0.0)
        .expect("grant issue");
    coordinator.grant_store_mut(&source).expect("grant store")
        .set_budget(grant.grant.id, budget).expect("grant budget");
    drop(coordinator);
    (registry, source)
}

#[test]
fn selected_federated_recall_refuses_an_exhausted_grant_without_disclosure() {
    let (registry, source) = registry_with_grant_budget(
        "exhausted-source", GrantScope::WholeEstate, GrantLifetime::Permanent, 0, 0.0,
    );
    seed(&registry, &source, "exhausted private content", "exhausted-subject", "room", AdjectiveSensitivity::Normal);
    let session = SelectedV2Session::new(registry);

    let response = session.call("moot_federated_recall", &args![]).expect("public response");
    assert_eq!(response["isError"], true, "exhausted grant must refuse: {response}");
    assert!(!response.to_string().contains("exhausted private content"), "refusal leaked source content: {response}");
}

fn seed(
    registry: &EstateRegistry,
    source: &EstateHandle,
    content: &str,
    subject: &str,
    room: &str,
    sensitivity: AdjectiveSensitivity,
) {
    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        room,
        LatticeAnchor::udc("004"),
        "aria-v2-federation-tests",
        "default",
    );
    frame.subject = Some(subject.to_owned());
    frame.sensitivity = sensitivity;
    registry.coord.lock().expect("coordinator lock")
        .capture(source, frame, aria_mcp::dispatch::wall_now())
        .expect("source capture");
}

fn data(response: &serde_json::Value) -> &serde_json::Value {
    &response["structuredContent"]["data"]
}

#[test]
fn selected_federated_recall_refuses_an_expired_grant_without_disclosure() {
    let (registry, source) = registry_with_grant(
        "expired-source", GrantScope::WholeEstate, GrantLifetime::Until(1.0), 0,
    );
    seed(&registry, &source, "expired private content", "expired-subject", "room", AdjectiveSensitivity::Normal);
    let session = SelectedV2Session::new(registry);

    let response = session.call("moot_federated_recall", &args![]).expect("public response");
    assert_eq!(response["isError"], true, "expired grant must refuse: {response}");
    assert!(!response.to_string().contains("expired private content"), "refusal leaked source content: {response}");
}

#[test]
fn selected_federated_recall_enforces_room_scope_and_content_level() {
    let (registry, source) = registry_with_grant(
        "room-source", GrantScope::Room("allowed".to_owned()), GrantLifetime::Permanent, 0,
    );
    seed(&registry, &source, "allowed full content", "allowed-subject", "allowed", AdjectiveSensitivity::Normal);
    seed(&registry, &source, "other full content", "other-subject", "other", AdjectiveSensitivity::Normal);
    seed(&registry, &source, "elevated full content", "elevated-subject", "allowed", AdjectiveSensitivity::Elevated);
    let session = SelectedV2Session::new(registry);

    let response = session.call("moot_federated_recall", &args![]).expect("public response");
    assert_eq!(response["isError"], false, "authorized source must succeed: {response}");
    let subjects = data(&response)["results"].as_array().expect("results")
        .iter().filter_map(|row| row["subject"].as_str()).collect::<Vec<_>>();
    assert_eq!(subjects, vec!["allowed-subject"], "scope and sensitivity must both filter: {response}");
}

#[test]
fn selected_federated_recall_bitmap_hydration_omits_excerpt_and_bad_shape_refuses() {
    let (registry, source) = registry_with_grant(
        "hydration-source", GrantScope::WholeEstate, GrantLifetime::Permanent, 0,
    );
    seed(&registry, &source, "private excerpt body", "safe-subject", "room", AdjectiveSensitivity::Normal);
    let session = SelectedV2Session::new(registry);

    let bitmap = session.call("moot_federated_recall", &args!["hydration_level" => "bitmapOnly"])
        .expect("bitmap response");
    assert_eq!(bitmap["isError"], false, "bitmap hydration must be admitted: {bitmap}");
    let rows = data(&bitmap)["results"].as_array().expect("results");
    assert!(!rows.is_empty(), "bitmap hydration must return the admitted fixture row: {bitmap}");
    assert!(rows.iter()
        .all(|row| row["excerpt"].is_null()), "bitmap hydration must omit excerpts: {bitmap}");

    let malformed = session.call("moot_federated_recall", &args!["hydration_level" => 1_i64])
        .expect_err("non-string hydration level must be rejected at the public decoder");
    assert_eq!(malformed.code, aria_mcp::jsonrpc::JSONRPCErrorCode::INVALID_PARAMS);
}
