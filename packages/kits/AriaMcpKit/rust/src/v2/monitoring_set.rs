//! Typed v2 monitoring write operation.
//!
//! This operation owns its strict public request and typed write result. It
//! calls the monitoring control directly, then confirms the durable state with
//! one read; it never routes through the legacy mixed status runner.

use serde::Serialize;
use serde_json::Value;

use crate::{
    jsonrpc::{JSONRPCError, JsonValue},
    monitoring_control::MonitoringControl,
};

use super::{
    codec::{required_bool, strict_object, V2DecodeResult},
    operation::V2OperationEffect,
    render::{refusal, success, V2OperationalRefusal, V2ResultMeta},
};

pub const MONITORING_SET_TOOL: &str = "moot_monitoring_set";

/// The entire public write contract: one required boolean.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct V2MonitoringSetRequest {
    pub enabled: bool,
}

impl V2MonitoringSetRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["enabled"])?;
        Ok(Self {
            enabled: required_bool(object, "enabled")?,
        })
    }
}

#[derive(Serialize)]
struct MonitoringSetData {
    monitoring: &'static str,
}

/// Execute one monitoring write and return only a confirmed observed state.
///
/// `MonitoringControl::set` is best effort. A missing confirmation therefore
/// does not mean the write failed or that it is safe to retry it: it may have
/// landed after the read became unavailable.
pub fn execute(
    request: V2MonitoringSetRequest,
    control: Option<&dyn MonitoringControl>,
    meta: &V2ResultMeta,
) -> Result<Value, JSONRPCError> {
    let meta = V2ResultMeta {
        build_id: meta.build_id.clone(),
        capability_digest: meta.capability_digest.clone(),
        effect: V2OperationEffect::Write,
        completeness: meta.completeness.clone(),
    };
    let Some(control) = control else {
        return Ok(operational_refusal(
            "monitoring_unavailable",
            "monitoring control is unavailable for this transport",
            &meta,
        ));
    };

    control.set(request.enabled);
    match control.read() {
        Some(enabled) if enabled == request.enabled => {
            let state = if enabled { "enabled" } else { "disabled" };
            success(
                MONITORING_SET_TOOL,
                &MonitoringSetData { monitoring: state },
                &meta,
                &format!("monitoring: {state}"),
            )
            .map_err(jsonrpc_internal)
        }
        Some(enabled) => {
            let observed = if enabled { "enabled" } else { "disabled" };
            Ok(operational_refusal(
                "monitoring_unverified",
                &format!(
                    "monitoring write could not be confirmed; the observed state is {observed} and the write may have landed"
                ),
                &meta,
            ))
        }
        None => Ok(operational_refusal(
            "monitoring_unverified",
            "monitoring write could not be confirmed; the write may have landed",
            &meta,
        )),
    }
}

fn operational_refusal(code: &str, message: &str, meta: &V2ResultMeta) -> Value {
    let recovery = (code == "monitoring_unverified").then(|| serde_json::json!({
        "tool": "moot_monitoring_status",
        "arguments": {},
    }));
    refusal(
        MONITORING_SET_TOOL,
        &V2OperationalRefusal {
            code: code.to_owned(),
            message: message.to_owned(),
            retryable: false,
            recovery,
        },
        meta,
    )
}

fn jsonrpc_internal(error: serde_json::Error) -> JSONRPCError {
    JSONRPCError::new(
        crate::jsonrpc::JSONRPCErrorCode::INTERNAL_ERROR,
        error.to_string(),
    )
}
