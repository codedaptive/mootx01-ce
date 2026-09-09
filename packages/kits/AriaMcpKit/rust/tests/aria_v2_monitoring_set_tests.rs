use std::{
    collections::{BTreeMap, VecDeque},
    sync::Mutex,
};

mod jsonrpc {
    pub use aria_mcp::jsonrpc::*;
}

mod monitoring_control {
    pub use aria_mcp::monitoring_control::*;
}

#[path = "../src/v2/codec.rs"]
mod codec;
#[path = "../src/v2/operation.rs"]
mod operation;
#[path = "../src/v2/render.rs"]
mod render;
#[path = "../src/v2/monitoring_set.rs"]
mod monitoring_set;

use aria_mcp::jsonrpc::JsonValue;
use monitoring_control::MonitoringControl;
use monitoring_set::{execute, V2MonitoringSetRequest, MONITORING_SET_TOOL};
use operation::V2OperationEffect;
use render::V2ResultMeta;

struct Probe {
    reads: Mutex<VecDeque<Option<bool>>>,
    writes: Mutex<Vec<bool>>,
}

impl Probe {
    fn new(reads: impl IntoIterator<Item = Option<bool>>) -> Self {
        Self {
            reads: Mutex::new(reads.into_iter().collect()),
            writes: Mutex::new(Vec::new()),
        }
    }
}

impl MonitoringControl for Probe {
    fn read(&self) -> Option<bool> {
        self.reads.lock().expect("read lock").pop_front().flatten()
    }

    fn set(&self, enabled: bool) {
        self.writes.lock().expect("write lock").push(enabled);
    }
}

fn arguments(entries: impl IntoIterator<Item = (&'static str, JsonValue)>) -> JsonValue {
    JsonValue::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect::<BTreeMap<_, _>>(),
    )
}

fn meta() -> V2ResultMeta {
    V2ResultMeta::incomplete("test-build", "test-digest", V2OperationEffect::Read)
}

#[test]
fn request_accepts_exactly_one_boolean_enabled_argument() {
    assert_eq!(
        V2MonitoringSetRequest::decode(&arguments([("enabled", JsonValue::Bool(true))])),
        Ok(V2MonitoringSetRequest { enabled: true }),
    );

    let missing = V2MonitoringSetRequest::decode(&arguments([])).expect_err("enabled is required");
    assert_eq!(missing.path, "$.enabled");
    assert_eq!(missing.message, "is required");

    let wrong_type = V2MonitoringSetRequest::decode(&arguments([("enabled", JsonValue::String("true".to_owned()))]))
        .expect_err("enabled must be boolean");
    assert_eq!(wrong_type.path, "$.enabled");
    assert_eq!(wrong_type.message, "must be a boolean");

    let unknown = V2MonitoringSetRequest::decode(&arguments([
        ("enabled", JsonValue::Bool(true)),
        ("extra", JsonValue::Bool(false)),
    ]))
    .expect_err("unknown arguments reject before execution");
    assert_eq!(unknown.path, "$.extra");
    assert_eq!(unknown.allowed, Some(vec!["enabled".to_owned()]));

    let non_object = V2MonitoringSetRequest::decode(&JsonValue::Bool(true))
        .expect_err("arguments must be an object");
    assert_eq!(non_object.path, "$");
    assert_eq!(non_object.message, "must be an object");
}

#[test]
fn confirmed_write_projects_the_actual_enabled_and_disabled_states() {
    for (requested, expected) in [(true, "enabled"), (false, "disabled")] {
        let probe = Probe::new([Some(requested)]);
        let result = execute(
            V2MonitoringSetRequest { enabled: requested },
            Some(&probe),
            &meta(),
        )
        .expect("typed result");

        assert_eq!(result["isError"], false);
        assert_eq!(result["structuredContent"]["tool"], MONITORING_SET_TOOL);
        assert_eq!(result["structuredContent"]["data"]["monitoring"], expected);
        assert_eq!(result["structuredContent"]["meta"]["effect"], "write");
        assert_eq!(*probe.writes.lock().expect("write lock"), vec![requested]);
    }
}

#[test]
fn unavailable_control_refuses_without_a_write() {
    let result = execute(V2MonitoringSetRequest { enabled: true }, None, &meta())
        .expect("typed refusal");

    assert_eq!(result["isError"], true);
    assert_eq!(result["structuredContent"]["error"]["code"], "monitoring_unavailable");
    assert_eq!(result["structuredContent"]["error"]["retryable"], false);
}

#[test]
fn failed_confirmation_is_unverified_without_a_blind_retry_instruction() {
    let probe = Probe::new([None]);
    let result = execute(
        V2MonitoringSetRequest { enabled: true },
        Some(&probe),
        &meta(),
    )
    .expect("typed refusal");

    assert_eq!(result["isError"], true);
    assert_eq!(result["structuredContent"]["error"]["code"], "monitoring_unverified");
    assert_eq!(result["structuredContent"]["error"]["retryable"], false);
    assert_eq!(
        result["structuredContent"]["error"]["recovery"],
        serde_json::json!({"tool":"moot_monitoring_status","arguments":{}}),
    );
    assert!(result["structuredContent"]["error"]["message"]
        .as_str()
        .expect("message")
        .contains("may have landed"));
    assert_eq!(*probe.writes.lock().expect("write lock"), vec![true]);
}

#[test]
fn mismatched_confirmation_is_also_unverified() {
    let probe = Probe::new([Some(false)]);
    let result = execute(
        V2MonitoringSetRequest { enabled: true },
        Some(&probe),
        &meta(),
    )
    .expect("typed refusal");

    assert_eq!(result["structuredContent"]["error"]["code"], "monitoring_unverified");
    assert!(result["structuredContent"]["error"]["message"]
        .as_str()
        .expect("message")
        .contains("observed state is disabled"));
    assert_eq!(*probe.writes.lock().expect("write lock"), vec![true]);
}
