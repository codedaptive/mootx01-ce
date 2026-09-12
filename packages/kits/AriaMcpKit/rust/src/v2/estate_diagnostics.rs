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

// lattice_lib provides the pinned FDC recalculation version string used to
// determine whether the estate floor is current, stale, or missing.
use lattice_lib;

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
    /// Plugin/binary version-skew advisory. Empty string means no skew to
    /// report; a non-empty value is included as `version_skew` in the
    /// structured data of `moot_estate_ping` and `moot_estate_status`.
    /// Mirrors Swift `AriaV2EstateDiagnosticsContext.versionSkewAdvisory`.
    pub version_skew: String,
    /// Upstream-release advisory, evaluated from the host provider for
    /// `moot_estate_ping` and `moot_estate_status` only. `None` for all
    /// other operations and when no provider is wired. Mirrors Swift
    /// `AriaV2EstateDiagnosticsContext.updateAdvisoryProvider` (evaluated
    /// at call time rather than stored as a closure because Rust's sync
    /// surface evaluates in `surface::execute_estate_diagnostics` before
    /// building the context).
    pub update_advisory: Option<String>,
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
    /// Stored value of `aria.fdc.recalced_data_version` from the estate meta
    /// table. `None` means the key has never been written (no floor set yet).
    /// Read by `Status`; left `None` by `Ping`, `Map`, and other operations.
    pub fdc_floor: Option<String>,
    /// Recall-trace depth, or `None` when the count could not be read.
    ///
    /// `None` is NOT zero, and the distinction is the point: a fabricated
    /// zero is indistinguishable from a genuinely empty trace table and would
    /// lie about how deep the reward pipeline is.
    pub recall_trace_count: Option<u64>,
    /// Sync backend state, or `local-only` when no engine is wired.
    pub sync_state: String,
    /// Subject debt, counted over the sensitivity-visible, non-empty set.
    pub subjects_bearing: u64,
    pub subjects_eligible: u64,
    /// Present only once a migration record exists.
    pub shared_content_migration: Option<SharedContentMigration>,
}

/// Shared-content reclaim progress, reported by `moot_estate_status` when a
/// migration record exists.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SharedContentMigration {
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimated_reclaimable_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reclaimed_bytes: Option<u64>,
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
    /// One of `"current"`, `"missing"`, or `"stale"`. Computed from the
    /// stored `aria.fdc.recalced_data_version` meta key versus the pinned
    /// FDC recalculation version. Per data contract §5.
    pub fdc_recalculation: String,
    pub drains: Vec<EstateDrain>,
    /// Omitted rather than zeroed when unreadable; see the snapshot field.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recall_trace_count: Option<u64>,
    pub sync_state: String,
    pub subjects_bearing: u64,
    pub subjects_eligible: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shared_content_migration: Option<SharedContentMigration>,
    /// Plugin/binary version-skew advisory. Omitted from the serialized
    /// object when no advisory was injected (mirrors `EstatePingData.version_skew`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version_skew: Option<String>,
    /// Upstream-release advisory. Omitted when no provider is wired or the
    /// provider returned `None`. Mirrors Swift `AriaV2EstateStatusData.updateAdvisory`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub update_available: Option<String>,
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
    /// Plugin/binary version-skew advisory. Omitted from the serialized
    /// object when no advisory was injected (matches Swift's optional
    /// `versionSkewAdvisory` on `AriaV2EstatePingData`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version_skew: Option<String>,
    /// Upstream-release advisory. Omitted from the serialized object when
    /// no provider was wired or the provider returned `None`. Mirrors
    /// Swift `AriaV2EstatePingData.updateAdvisory`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub update_available: Option<String>,
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
        // Compute the fdc_recalculation field from the stored floor versus
        // the pinned recalculation version. Mirrors Swift ToolDispatch.swift:3564.
        let current_recalc = lattice_lib::Fdc::recalculation_version();
        let fdc_recalculation = match snapshot.fdc_floor.as_deref() {
            Some(floor) if floor == current_recalc.as_str() => "current".to_owned(),
            None => "missing".to_owned(),
            Some(_) => "stale".to_owned(),
        };
        Ok(EstateStatusData {
            estate_id: canonical_uuid(snapshot.estate_id),
            estate_name: snapshot.estate_name,
            memory_count,
            fact_count,
            fdc_recalculation,
            drains,
            recall_trace_count: snapshot.recall_trace_count,
            sync_state: snapshot.sync_state,
            subjects_bearing: snapshot.subjects_bearing,
            subjects_eligible: snapshot.subjects_eligible,
            shared_content_migration: snapshot.shared_content_migration,
            version_skew: if context.version_skew.is_empty() { None } else { Some(context.version_skew.clone()) },
            update_available: context.update_advisory.clone(),
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
            version_skew: if context.version_skew.is_empty() { None } else { Some(context.version_skew.clone()) },
            update_available: context.update_advisory.clone(),
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
