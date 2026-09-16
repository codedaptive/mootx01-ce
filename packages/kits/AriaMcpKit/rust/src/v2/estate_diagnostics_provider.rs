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
    EstateRebuildState, EstateTiming, SharedContentMigration,
};
use genius_locus_kit_migrations::{SharedContentMigrationExt, SharedContentReclaimStatus};
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
            // Populated by the Status arm via get_meta; left None for all
            // other operations (Ping, Map) which do not need the FDC floor.
            fdc_floor: None,
            // Same rule for the rest: the Status arm fills these, and the
            // operations that do not report them leave the base values. A
            // None trace count means "not read", never "no traces".
            recall_trace_count: None,
            sync_state: "local-only".to_owned(),
            drawer_rows: None,
            subjects_bearing: 0,
            subjects_eligible: 0,
            shared_content_migration: None,
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

    fn shared_content_migration(
        status: SharedContentReclaimStatus,
    ) -> Option<SharedContentMigration> {
        let state = serde_json::to_value(status.state?).ok()?.as_str()?.to_owned();
        Some(SharedContentMigration {
            state,
            estimated_reclaimable_bytes: status
                .estimated_reclaimable_bytes
                .and_then(|value| value.try_into().ok()),
            reclaimed_bytes: status
                .reclaimed_bytes
                .and_then(|value| value.try_into().ok()),
        })
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
            // Liveness stays lightweight: one COUNT over drawers, read for the
            // LSA retrain backstop declaration; no inventory, fact, drain,
            // rebuild, or audit read in this arm.
            EstateDiagnosticsOperation::Ping => {
                snapshot.drawer_rows = coord.count_drawer_rows(handle).ok().map(|n| n as u64);
            }
            EstateDiagnosticsOperation::Status => {
                let status_drawers = coord
                    .all_drawers(handle)
                    .map_err(|error| Self::map_error("estate status", error))?;
                // Subject debt over the sensitivity-visible, non-empty set.
                // Empty content is not eligible for a subject, so it is left
                // out of both sides rather than counted as permanent debt.
                let eligible: Vec<_> = status_drawers
                    .iter()
                    .filter(|drawer| {
                        drawer.tombstoned_at.is_none()
                            && drawer.adjective_sensitivity().is_bulk_exportable()
                            && !drawer.content.is_empty()
                    })
                    .collect();
                snapshot.subjects_eligible = eligible.len() as u64;
                snapshot.subjects_bearing = eligible
                    .iter()
                    .filter(|drawer| drawer.subject.is_some())
                    .count() as u64;
                // Best-effort, all three: a diagnostics read must not fail
                // because one field could not be gathered.
                snapshot.recall_trace_count =
                    coord.count_recall_traces(handle).ok().map(|count| count as u64);
                snapshot.sync_state = coord
                    .sync_state_token(handle)
                    .ok()
                    .unwrap_or_else(|| "local-only".to_owned());
                snapshot.shared_content_migration = Self::shared_content_migration(
                    coord.shared_content_reclaim_status(handle),
                );
                snapshot.memories = status_drawers
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
                // Read the FDC floor from the estate meta table. The coord
                // lock is already held; go through the store directly to
                // avoid a double-lock. None means the key has never been set.
                snapshot.fdc_floor = self.registry.default.store
                    .get_meta(crate::interface_tools::FDC_RECALCED_DATA_VERSION_META_KEY)
                    .ok()
                    .flatten();
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

#[cfg(test)]
mod sec07_tests {
    use super::*;
    use genius_locus_kit_migrations::SharedContentMigrationState;

    #[test]
    fn reclaim_status_maps_to_public_diagnostics_shape() {
        let mapped = SelectedEstateDiagnosticsAuthority::shared_content_migration(
            SharedContentReclaimStatus {
                state: Some(SharedContentMigrationState::ReclaimPending),
                estimated_reclaimable_bytes: Some(4096),
                reclaimed_bytes: None,
                live_reclaimable_bytes: Some(2048),
            },
        )
        .expect("persisted migration state must be reported");
        assert_eq!(mapped.state, "reclaimPending");
        assert_eq!(mapped.estimated_reclaimable_bytes, Some(4096));
        assert_eq!(mapped.reclaimed_bytes, None);
    }

    #[test]
    fn absent_migration_record_stays_omitted() {
        assert_eq!(
            SelectedEstateDiagnosticsAuthority::shared_content_migration(
                SharedContentReclaimStatus {
                    state: None,
                    estimated_reclaimable_bytes: None,
                    reclaimed_bytes: None,
                    live_reclaimable_bytes: Some(2048),
                },
            ),
            None
        );
    }
}
