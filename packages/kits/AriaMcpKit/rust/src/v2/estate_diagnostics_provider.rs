//! Direct selected-surface adapter for typed estate diagnostics.
//!
//! Each snapshot branch opens only the lower-kit reads needed by that one
//! operation. In particular, liveness uses `mount_state` alone: it never
//! scans drawers, facts, or the audit log.

use crate::estate_registry::EstateRegistry;
use crate::v2::estate_diagnostics::{
    DiagnosticsFact, DiagnosticsLifecycle, DiagnosticsMemory, EstateDiagnosticsAuthority,
    EstateDiagnosticsContext, EstateDiagnosticsFailure, EstateDiagnosticsGrant,
    EstateDiagnosticsOperation, EstateDiagnosticsSnapshot, EstateDrain, EstateDrainState,
    EstateRebuildState, EstateTiming,
};
use uuid::Uuid;

const SESSION_ID: &str = "selected-v2-public";
const TIMING_WINDOW_MAX_EVENTS: usize = 262_144;
const TIMING_PAGE_SIZE: usize = 4096;

/// Selected-v2's fixed authority. It intentionally has no route to registry
/// extras: only the default handle is admitted and revalidated.
pub struct SelectedEstateDiagnosticsAuthority<'a> {
    registry: &'a EstateRegistry,
}

impl<'a> SelectedEstateDiagnosticsAuthority<'a> {
    pub fn new(registry: &'a EstateRegistry) -> Self { Self { registry } }

    fn estate_id(&self) -> Uuid { Uuid::from_bytes(self.registry.default.handle.estate_uuid) }

    fn grant(&self) -> EstateDiagnosticsGrant {
        EstateDiagnosticsGrant {
            estate_id: self.estate_id(),
            estate_name: self.registry.default.estate_name.clone(),
        }
    }

    fn validate_context(&self, context: &EstateDiagnosticsContext) -> Result<(), EstateDiagnosticsFailure> {
        if context.caller_binding != self.registry.server_identity || context.session_id != SESSION_ID {
            return Err(EstateDiagnosticsFailure::operational(
                "access_denied",
                "The selected diagnostics context is not authorized.",
                false,
            ));
        }
        Ok(())
    }

    fn base_snapshot(&self, mounted: bool) -> EstateDiagnosticsSnapshot {
        EstateDiagnosticsSnapshot {
            estate_id: self.estate_id(),
            estate_name: self.registry.default.estate_name.clone(),
            mounted,
            memories: Vec::new(),
            facts: Vec::new(),
            drains: Vec::new(),
            rebuild: EstateRebuildState::Idle,
            timing: EstateTiming { watermark_ms: 0, truncated: false },
        }
    }

    fn map_error(operation: &'static str, error: impl std::fmt::Debug) -> EstateDiagnosticsFailure {
        EstateDiagnosticsFailure::operational(
            "estate_unavailable",
            format!("The selected estate could not complete {operation}: {error:?}"),
            true,
        )
    }

    fn drains(
        coord: &genius_locus_kit::EstateCoordinator,
        handle: &genius_locus_kit::EstateHandle,
    ) -> Result<Vec<EstateDrain>, EstateDiagnosticsFailure> {
        let mut drains: Vec<_> = coord
            .drain_statuses(handle)
            .map_err(|error| Self::map_error("drain status", error))?
            .into_iter()
            .map(|status| {
                let state = if status.is_draining() { EstateDrainState::Draining } else { EstateDrainState::Idle };
                EstateDrain { name: status.name, state, pending: status.pending as u64 }
            })
            .collect();
        drains.sort_by(|left, right| left.name.cmp(&right.name));
        Ok(drains)
    }

    fn lifecycle(active: bool) -> DiagnosticsLifecycle {
        if active { DiagnosticsLifecycle::CurrentClusterA } else { DiagnosticsLifecycle::Other }
    }

    fn timing(
        coord: &genius_locus_kit::EstateCoordinator,
        handle: &genius_locus_kit::EstateHandle,
    ) -> Result<EstateTiming, EstateDiagnosticsFailure> {
        let mut events = Vec::new();
        let mut cursor = None;
        let mut truncated = false;
        while events.len() < TIMING_WINDOW_MAX_EVENTS {
            let page = coord
                .audit_events(handle, cursor, TIMING_PAGE_SIZE)
                .map_err(|error| Self::map_error("timing report", error))?;
            let remaining = TIMING_WINDOW_MAX_EVENTS - events.len();
            let page_len = page.len();
            let last_hlc = page.last().map(|event| event.hlc);
            events.extend(page.into_iter().take(remaining).map(|event| {
                neuron_kit::timing_derivation::TimingAuditEvent {
                    verb: event.verb,
                    physical_time_ms: event.hlc.physical_time,
                    row_id: Uuid::from_u128(event.row_id.0).to_string(),
                    reason: event.reason,
                }
            }));
            if page_len > remaining || events.len() == TIMING_WINDOW_MAX_EVENTS {
                truncated = true;
                break;
            }
            if page_len != TIMING_PAGE_SIZE { break; }
            cursor = last_hlc;
        }
        let timing = neuron_kit::timing_derivation::derive_timings(&events, 0);
        Ok(EstateTiming { watermark_ms: timing.watermark_ms, truncated })
    }
}

impl EstateDiagnosticsAuthority for SelectedEstateDiagnosticsAuthority<'_> {
    fn authorize(
        &self,
        _operation: EstateDiagnosticsOperation,
        requested_estate_id: Option<Uuid>,
        context: &EstateDiagnosticsContext,
    ) -> Result<EstateDiagnosticsGrant, EstateDiagnosticsFailure> {
        self.validate_context(context)?;
        if requested_estate_id.is_some_and(|estate_id| estate_id != self.estate_id()) {
            return Err(EstateDiagnosticsFailure::operational(
                "estate_unavailable",
                "The requested estate is not available to this caller.",
                false,
            ));
        }
        Ok(self.grant())
    }

    fn snapshot(
        &self,
        operation: EstateDiagnosticsOperation,
        grant: &EstateDiagnosticsGrant,
        context: &EstateDiagnosticsContext,
    ) -> Result<EstateDiagnosticsSnapshot, EstateDiagnosticsFailure> {
        self.validate_context(context)?;
        if grant != &self.grant() {
            return Err(EstateDiagnosticsFailure::operational(
                "estate_unavailable",
                "The selected estate changed during diagnostics.",
                true,
            ));
        }
        let coord = self.registry.default.coord.lock().map_err(|_| {
            EstateDiagnosticsFailure::operational("estate_unavailable", "The selected estate is unavailable.", true)
        })?;
        let handle = &self.registry.default.handle;
        let mounted = matches!(
            coord.mount_state(handle),
            Some(genius_locus_kit::EstateMountState::Mounted)
        );
        let mut snapshot = self.base_snapshot(mounted);
        match operation {
            // Liveness must stay lightweight; do not add any inventory, fact,
            // drain, rebuild, or audit read to this arm.
            EstateDiagnosticsOperation::Ping => {}
            EstateDiagnosticsOperation::Status => {
                snapshot.memories = coord
                    .all_drawers(handle)
                    .map_err(|error| Self::map_error("estate status", error))?
                    .into_iter()
                    .filter(|drawer| drawer.tombstoned_at.is_none())
                    .map(|drawer| DiagnosticsMemory {
                        wing: String::new(),
                        room: String::new(),
                        lifecycle: Self::lifecycle(drawer.state().is_cluster_a()),
                        bulk_exportable: drawer.adjective_sensitivity().is_bulk_exportable(),
                    })
                    .collect();
                snapshot.facts = coord
                    .recall_kg_facts(handle)
                    .map_err(|error| Self::map_error("estate status", error))?
                    .into_iter()
                    .map(|fact| DiagnosticsFact {
                        lifecycle: Self::lifecycle(fact.state().is_cluster_a()),
                        bulk_exportable: fact.adjective_sensitivity().is_bulk_exportable(),
                    })
                    .collect();
                snapshot.drains = Self::drains(&coord, handle)?;
            }
            EstateDiagnosticsOperation::Map => {
                let drawers = coord
                    .all_drawers(handle)
                    .map_err(|error| Self::map_error("estate map", error))?;
                let node_ids: Vec<_> = drawers.iter().map(|drawer| drawer.parent_node_id.clone()).collect();
                let names = coord.resolve_drawer_node_names(handle, &node_ids);
                snapshot.memories = drawers
                    .into_iter()
                    .filter(|drawer| drawer.tombstoned_at.is_none())
                    .map(|drawer| {
                        let (wing, room) = names.get(&drawer.parent_node_id).cloned().unwrap_or_default();
                        DiagnosticsMemory {
                            wing,
                            room,
                            lifecycle: Self::lifecycle(drawer.state().is_cluster_a()),
                            bulk_exportable: drawer.adjective_sensitivity().is_bulk_exportable(),
                        }
                    })
                    .collect();
            }
            EstateDiagnosticsOperation::Drain => { snapshot.drains = Self::drains(&coord, handle)?; }
            EstateDiagnosticsOperation::Rebuild => {
                snapshot.rebuild = if coord.derived_rebuild_active(handle) {
                    EstateRebuildState::Running
                } else {
                    EstateRebuildState::Idle
                };
            }
            EstateDiagnosticsOperation::Timing => { snapshot.timing = Self::timing(&coord, handle)?; }
        }
        Ok(snapshot)
    }

    fn revalidate(
        &self,
        _operation: EstateDiagnosticsOperation,
        grant: &EstateDiagnosticsGrant,
        context: &EstateDiagnosticsContext,
    ) -> Result<(), EstateDiagnosticsFailure> {
        self.validate_context(context)?;
        if grant != &self.grant() {
            return Err(EstateDiagnosticsFailure::operational(
                "estate_unavailable",
                "The selected estate changed during diagnostics.",
                true,
            ));
        }
        Ok(())
    }
}
