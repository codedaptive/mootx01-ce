//! Typed, dormant ARIA v2 estate diagnostics.
//!
//! This module has no v1 dispatch dependency and deliberately stays
//! unregistered. Selected-surface wiring must provide an
//! `EstateDiagnosticsAuthority` that calls the Rust GeniusLocus/Neuron
//! authorities directly; it must not render or reparse a legacy tool result.

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

pub const ESTATE_STATUS_TOOL: &str = "moot_estate_status";
pub const ESTATE_MAP_TOOL: &str = "moot_estate_map";
pub const ESTATE_PING_TOOL: &str = "moot_estate_ping";
pub const DRAIN_STATUS_TOOL: &str = "moot_drain_status";
pub const REBUILD_STATUS_TOOL: &str = "moot_rebuild_status";
pub const TIMING_REPORT_TOOL: &str = "moot_timing_report";

/// All six diagnostics accept precisely one optional selector. The selected
/// surface resolves a missing selector through its typed access gate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EstateDiagnosticsRequest {
    pub estate_id: Option<Uuid>,
}

impl EstateDiagnosticsRequest {
    pub fn decode(value: &Value) -> Result<Self, EstateDiagnosticsFailure> {
        let object = value.as_object().ok_or_else(|| {
            EstateDiagnosticsFailure::invalid("$", "arguments must be an object")
        })?;
        for key in object.keys() {
            if key != "estate_id" {
                return Err(EstateDiagnosticsFailure::invalid(
                    format!("$.{key}"),
                    "is not accepted by this operation",
                ));
            }
        }
        let estate_id = match object.get("estate_id") {
            None => None,
            Some(Value::String(value)) => Some(Uuid::parse_str(value).map_err(|_| {
                EstateDiagnosticsFailure::invalid("$.estate_id", "must be a UUID")
            })?),
            Some(_) => {
                return Err(EstateDiagnosticsFailure::invalid(
                    "$.estate_id",
                    "must be a UUID string",
                ));
            }
        };
        Ok(Self { estate_id })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstateDiagnosticsOperation {
    Status,
    Map,
    Ping,
    Drain,
    Rebuild,
    Timing,
}

/// Request identity is carried from selected-surface admission through the
/// direct authority call. It prevents a provider from treating diagnostics as
/// anonymous default-estate reads and pins the build serial returned by ping.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EstateDiagnosticsContext {
    pub caller_binding: String,
    pub session_id: String,
    pub clock_millis: i64,
    pub build_serial: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EstateDiagnosticsGrant {
    pub estate_id: Uuid,
    pub estate_name: String,
}

/// The only production adapter seam. An implementation resolves and
/// revalidates access, then reads current GeniusLocus/Neuron state through
/// their typed APIs. `snapshot` is purpose-built data, never a v1 runner
/// payload or text/JSON reparsing boundary.
pub trait EstateDiagnosticsAuthority: Send + Sync {
    fn authorize(
        &self,
        operation: EstateDiagnosticsOperation,
        requested_estate_id: Option<Uuid>,
        context: &EstateDiagnosticsContext,
    ) -> Result<EstateDiagnosticsGrant, EstateDiagnosticsFailure>;

    fn snapshot(
        &self,
        operation: EstateDiagnosticsOperation,
        grant: &EstateDiagnosticsGrant,
        context: &EstateDiagnosticsContext,
    ) -> Result<EstateDiagnosticsSnapshot, EstateDiagnosticsFailure>;

    fn revalidate(
        &self,
        operation: EstateDiagnosticsOperation,
        grant: &EstateDiagnosticsGrant,
        context: &EstateDiagnosticsContext,
    ) -> Result<(), EstateDiagnosticsFailure>;
}

/// Only this lifecycle is eligible for public inventory counts and maps.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiagnosticsLifecycle {
    CurrentClusterA,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticsMemory {
    pub wing: String,
    pub room: String,
    pub lifecycle: DiagnosticsLifecycle,
    pub bulk_exportable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticsFact {
    pub lifecycle: DiagnosticsLifecycle,
    pub bulk_exportable: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EstateDrainState {
    Idle,
    Draining,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EstateDrain {
    pub name: String,
    pub state: EstateDrainState,
    pub pending: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EstateRebuildState {
    Running,
    Idle,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EstateTiming {
    pub watermark_ms: i64,
    pub truncated: bool,
}

/// A current read of the selected estate. The provider must retain the fixed
/// sensitivity ceiling information for every memory/fact; this service applies
/// it before deriving any public count or structural name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EstateDiagnosticsSnapshot {
    pub estate_id: Uuid,
    pub estate_name: String,
    pub mounted: bool,
    pub memories: Vec<DiagnosticsMemory>,
    pub facts: Vec<DiagnosticsFact>,
    pub drains: Vec<EstateDrain>,
    pub rebuild: EstateRebuildState,
    pub timing: EstateTiming,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EstateDiagnosticsFailure {
    pub code: &'static str,
    pub message: String,
    pub retryable: bool,
}

impl EstateDiagnosticsFailure {
    pub fn invalid(path: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: "invalid_argument",
            message: format!("{} {}", path.into(), message.into()),
            retryable: false,
        }
    }

    pub fn operational(code: &'static str, message: impl Into<String>, retryable: bool) -> Self {
        Self { code, message: message.into(), retryable }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EstateStatusData {
    pub estate_id: String,
    pub estate_name: String,
    pub memory_count: u64,
    pub fact_count: u64,
    pub drains: Vec<EstateDrain>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EstateMapRoom {
    pub name: String,
    pub memory_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EstateMapWing {
    pub name: String,
    pub rooms: Vec<EstateMapRoom>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EstateMapData {
    pub estate_id: String,
    pub wings: Vec<EstateMapWing>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EstatePingData {
    pub estate_id: String,
    pub estate_name: String,
    pub state: &'static str,
    pub build_serial: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EstateDrainData {
    pub drains: Vec<EstateDrain>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EstateRebuildData {
    pub state: EstateRebuildState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EstateTimingData {
    pub since_ms: i64,
    pub watermark_ms: i64,
    pub truncated: bool,
}

/// Direct typed diagnostics service. Selected-surface wiring owns envelope
/// projection and advertisement; this boundary owns strict request identity,
/// access revalidation, and public aggregate filtering.
pub struct EstateDiagnosticsService<P> {
    authority: P,
}

impl<P: EstateDiagnosticsAuthority> EstateDiagnosticsService<P> {
    pub fn new(authority: P) -> Self {
        Self { authority }
    }

    pub fn status(
        &self,
        request: EstateDiagnosticsRequest,
        context: &EstateDiagnosticsContext,
    ) -> Result<EstateStatusData, EstateDiagnosticsFailure> {
        let (_, snapshot) = self.current(EstateDiagnosticsOperation::Status, request, context)?;
        let memory_count = public_memories(&snapshot).count() as u64;
        let fact_count = snapshot.facts.iter().filter(|fact| public_fact(fact)).count() as u64;
        let drains = snapshot.drains.clone();
        Ok(EstateStatusData {
            estate_id: canonical_uuid(snapshot.estate_id),
            estate_name: snapshot.estate_name,
            memory_count,
            fact_count,
            drains,
        })
    }

    pub fn map(
        &self,
        request: EstateDiagnosticsRequest,
        context: &EstateDiagnosticsContext,
    ) -> Result<EstateMapData, EstateDiagnosticsFailure> {
        let (_, snapshot) = self.current(EstateDiagnosticsOperation::Map, request, context)?;
        let mut counts: BTreeMap<String, BTreeMap<String, u64>> = BTreeMap::new();
        for memory in public_memories(&snapshot) {
            *counts.entry(memory.wing.clone()).or_default().entry(memory.room.clone()).or_default() += 1;
        }
        let wings = counts.into_iter().map(|(name, rooms)| EstateMapWing {
            name,
            rooms: rooms.into_iter().map(|(name, memory_count)| EstateMapRoom { name, memory_count }).collect(),
        }).collect();
        Ok(EstateMapData { estate_id: canonical_uuid(snapshot.estate_id), wings })
    }

    pub fn ping(
        &self,
        request: EstateDiagnosticsRequest,
        context: &EstateDiagnosticsContext,
    ) -> Result<EstatePingData, EstateDiagnosticsFailure> {
        let (_, snapshot) = self.current(EstateDiagnosticsOperation::Ping, request, context)?;
        if !snapshot.mounted {
            return Err(EstateDiagnosticsFailure::operational(
                "estate_unavailable",
                "The selected estate is not mounted.",
                true,
            ));
        }
        Ok(EstatePingData {
            estate_id: canonical_uuid(snapshot.estate_id),
            estate_name: snapshot.estate_name,
            state: "mounted",
            build_serial: context.build_serial.clone(),
        })
    }

    pub fn drain(
        &self,
        request: EstateDiagnosticsRequest,
        context: &EstateDiagnosticsContext,
    ) -> Result<EstateDrainData, EstateDiagnosticsFailure> {
        let (_, snapshot) = self.current(EstateDiagnosticsOperation::Drain, request, context)?;
        Ok(EstateDrainData { drains: snapshot.drains })
    }

    pub fn rebuild(
        &self,
        request: EstateDiagnosticsRequest,
        context: &EstateDiagnosticsContext,
    ) -> Result<EstateRebuildData, EstateDiagnosticsFailure> {
        let (_, snapshot) = self.current(EstateDiagnosticsOperation::Rebuild, request, context)?;
        Ok(EstateRebuildData { state: snapshot.rebuild })
    }

    pub fn timing(
        &self,
        request: EstateDiagnosticsRequest,
        context: &EstateDiagnosticsContext,
    ) -> Result<EstateTimingData, EstateDiagnosticsFailure> {
        let (_, snapshot) = self.current(EstateDiagnosticsOperation::Timing, request, context)?;
        Ok(EstateTimingData {
            since_ms: 0,
            watermark_ms: snapshot.timing.watermark_ms,
            truncated: snapshot.timing.truncated,
        })
    }

    fn current(
        &self,
        operation: EstateDiagnosticsOperation,
        request: EstateDiagnosticsRequest,
        context: &EstateDiagnosticsContext,
    ) -> Result<(EstateDiagnosticsGrant, EstateDiagnosticsSnapshot), EstateDiagnosticsFailure> {
        let grant = self.authority.authorize(operation, request.estate_id, context)?;
        let snapshot = self.authority.snapshot(operation, &grant, context)?;
        if snapshot.estate_id != grant.estate_id || snapshot.estate_name != grant.estate_name {
            return Err(EstateDiagnosticsFailure::operational(
                "estate_unavailable",
                "The selected estate changed during diagnostics.",
                true,
            ));
        }
        self.authority.revalidate(operation, &grant, context)?;
        Ok((grant, snapshot))
    }
}

fn canonical_uuid(value: Uuid) -> String {
    value.hyphenated().to_string()
}

fn public_memory(memory: &DiagnosticsMemory) -> bool {
    memory.lifecycle == DiagnosticsLifecycle::CurrentClusterA && memory.bulk_exportable
}

fn public_memories(snapshot: &EstateDiagnosticsSnapshot) -> impl Iterator<Item = &DiagnosticsMemory> {
    snapshot.memories.iter().filter(|memory| public_memory(memory))
}

fn public_fact(fact: &DiagnosticsFact) -> bool {
    fact.lifecycle == DiagnosticsLifecycle::CurrentClusterA && fact.bulk_exportable
}
