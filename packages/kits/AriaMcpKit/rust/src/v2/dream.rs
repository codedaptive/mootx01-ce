//! Typed direct lower lane for `moot_dream`.
//!
//! This module supplies the strict request, admission, lower-engine, and
//! result contract for the selected-surface owner.

use std::sync::{Arc, Mutex};

use genius_locus_kit::{EstateCoordinator, EstateHandle};
use serde::Serialize;
use uuid::Uuid;

use crate::jsonrpc::JsonValue;

use super::codec::{optional_uuid, strict_object, V2DecodeResult};

pub const DREAM_TOOL: &str = "moot_dream";

/// V2 accepts only the canonical selected-estate selector.  The authority owns
/// the cycle clock; a caller cannot smuggle a second clock through the request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2DreamRequest {
    pub estate_id: Option<Uuid>,
}

impl V2DreamRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["estate_id"])?;
        Ok(Self { estate_id: optional_uuid(object, "estate_id")? })
    }
}

/// Selected-estate proof handed to direct lower work without re-resolving a
/// caller-provided estate. `now_millis` is authority-owned and deterministic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2DreamAdmission {
    pub estate_id: Uuid,
    pub estate_handle: EstateHandle,
    pub caller_binding: String,
    pub authorization_generation: String,
    pub now_millis: i64,
}

pub trait V2DreamAuthority: Send + Sync {
    fn admit(&self, requested_estate_id: Option<Uuid>) -> Result<V2DreamAdmission, ()>;
    fn revalidate(&self, admission: &V2DreamAdmission) -> Result<(), ()>;
}

/// Lower-engine lifecycle state.  The service transmits it unchanged, so an
/// observed active, already-running, or queued state is never manufactured as
/// a completion by the v2 projection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum V2DreamStatus {
    Completed,
    Active,
    AlreadyRunning,
    Queued,
}

/// The completed `data` object. Its encoded keys are the fixture's public
/// camel-case contract; lifecycle status belongs to the surrounding envelope.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct V2DreamCycleReceipt {
    pub candidates_considered: u64,
    pub proposals_emitted: Vec<String>,
    pub suppressed_duplicates: u64,
    pub below_threshold: u64,
    pub contradictions_proposed: u64,
    pub contradiction_candidates_borderline: u64,
    pub subjects_backfilled: Option<u64>,
    pub associations_written: Option<u64>,
    pub associations_non_unique_probes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2DreamSourceOutcome {
    Completed(V2DreamCycleReceipt),
    Active,
    AlreadyRunning,
    Queued,
}

impl V2DreamSourceOutcome {
    pub fn status(&self) -> V2DreamStatus {
        match self {
            Self::Completed(_) => V2DreamStatus::Completed,
            Self::Active => V2DreamStatus::Active,
            Self::AlreadyRunning => V2DreamStatus::AlreadyRunning,
            Self::Queued => V2DreamStatus::Queued,
        }
    }

    pub fn receipt(&self) -> Option<&V2DreamCycleReceipt> {
        match self { Self::Completed(value) => Some(value), _ => None }
    }
}

/// Typed service result before the selected surface places lifecycle state in
/// envelope metadata or renders a structured refusal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2DreamResult {
    pub status: V2DreamStatus,
    pub cycle: Option<V2DreamCycleReceipt>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2DreamError {
    Unavailable,
    OutcomeUnverified,
}

/// Direct lower seam.  It accepts typed authority output and returns a typed
/// source result; it must never call a v1 dispatcher or parse a v1 payload.
pub trait V2DreamLower: Send + Sync {
    fn run(
        &self,
        admission: &V2DreamAdmission,
        request: &V2DreamRequest,
    ) -> Result<V2DreamSourceOutcome, ()>;
}

/// Production adapter over the existing matrix rebuild plus NeuronKit's
/// `DreamingDaemon::run_cycle`.  The only returned terminal state is the
/// actual receipt from that lower engine; scheduler owners may supply their
/// own lower implementation for active, already-running, or queued states.
pub struct V2GeniusLocusDreamLower {
    coordinator: Arc<Mutex<EstateCoordinator>>,
}

impl V2GeniusLocusDreamLower {
    pub fn new(coordinator: Arc<Mutex<EstateCoordinator>>) -> Self {
        Self { coordinator }
    }
}

impl V2DreamLower for V2GeniusLocusDreamLower {
    fn run(
        &self,
        admission: &V2DreamAdmission,
        request: &V2DreamRequest,
    ) -> Result<V2DreamSourceOutcome, ()> {
        if request.estate_id.is_some_and(|id| id != admission.estate_id) {
            return Err(());
        }
        let mut coordinator = self.coordinator.lock().map_err(|_| ())?;
        coordinator
            .rebuild_derived_accelerators(&admission.estate_handle, admission.now_millis)
            .map_err(|_| ())?;

        let now_seconds = admission.now_millis / 1_000;
        let now_iso = neuron_kit::topology_analysis::epoch_to_iso8601(admission.now_millis);
        let reader = neuron_kit::EstateDreamingReader::new(
            &coordinator,
            &admission.estate_handle,
            &now_iso,
            &now_iso,
            now_seconds as f64,
        ).map_err(|_| ())?;
        let mut sink = neuron_kit::EstateDreamingSink::new(
            &coordinator,
            admission.estate_handle.clone(),
            admission.now_millis,
        );
        let mut daemon = neuron_kit::DreamingDaemon::new(neuron_kit::DreamingPolicy::default());
        let report = daemon.run_cycle(
            now_seconds as f64,
            &reader,
            &neuron_kit::RecallTraceRewardSource,
            &mut sink,
        );
        let hunt = coordinator
            .hunt_contradictions(
                &admission.estate_handle, "minilm-v6", 500, None, 64, admission.now_millis,
            )
            .map_err(|_| ())?;
        let association = coordinator
            .associate_sweep(&admission.estate_handle, Some(50), admission.now_millis)
            .map_err(|_| ())?;
        let subjects_backfilled = if coordinator
            .subject_producer_pipeline(&admission.estate_handle)
            .is_some()
        {
            let debt = coordinator
                .estate_for(&admission.estate_handle)
                .ok()
                .and_then(|estate| estate.count_subject_debt().ok())
                .unwrap_or(0);
            if debt > 0 {
                Some(
                    coordinator
                        .subject_backfill_sweep(&admission.estate_handle, 32, admission.now_millis)
                        .map_err(|_| ())?
                        .written as u64,
                )
            } else {
                None
            }
        } else {
            None
        };
        Ok(V2DreamSourceOutcome::Completed(V2DreamCycleReceipt {
            candidates_considered: report.candidates_considered as u64,
            proposals_emitted: report.proposals_emitted.into_iter().map(|value| value.target).collect(),
            suppressed_duplicates: report.suppressed_duplicates as u64,
            below_threshold: report.below_threshold as u64,
            contradictions_proposed: hunt.proposed.len() as u64,
            contradiction_candidates_borderline: hunt.borderline.len() as u64,
            subjects_backfilled,
            associations_written: Some(association.written as u64),
            associations_non_unique_probes: Some(association.non_unique_probes as u64),
        }))
    }
}

pub struct V2DreamService<A, L> {
    authority: A,
    lower: L,
}

impl<A, L> V2DreamService<A, L> {
    pub fn new(authority: A, lower: L) -> Self { Self { authority, lower } }
}

impl<A: V2DreamAuthority, L: V2DreamLower> V2DreamService<A, L> {
    pub fn execute(&self, request: V2DreamRequest) -> Result<V2DreamResult, V2DreamError> {
        let admission = self.authority.admit(request.estate_id).map_err(|_| V2DreamError::Unavailable)?;
        let outcome = self.lower.run(&admission, &request).map_err(|_| V2DreamError::Unavailable)?;
        self.authority.revalidate(&admission).map_err(|_| V2DreamError::OutcomeUnverified)?;
        Ok(V2DreamResult { status: outcome.status(), cycle: outcome.receipt().cloned() })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn request_rejects_unknown_or_malformed_estate_selectors() {
        let unknown = JsonValue::Object(BTreeMap::from([("estateID".to_owned(), JsonValue::String("x".to_owned()))]));
        assert!(V2DreamRequest::decode(&unknown).is_err());
        let malformed = JsonValue::Object(BTreeMap::from([("estate_id".to_owned(), JsonValue::String("x".to_owned()))]));
        assert!(V2DreamRequest::decode(&malformed).is_err());
    }

    #[derive(Clone)]
    struct Authority { admission: V2DreamAdmission }
    impl V2DreamAuthority for Authority {
        fn admit(&self, requested: Option<Uuid>) -> Result<V2DreamAdmission, ()> {
            if requested.is_none() || requested == Some(self.admission.estate_id) { Ok(self.admission.clone()) } else { Err(()) }
        }
        fn revalidate(&self, _: &V2DreamAdmission) -> Result<(), ()> { Ok(()) }
    }

    struct Lower(V2DreamSourceOutcome);
    impl V2DreamLower for Lower {
        fn run(&self, _: &V2DreamAdmission, _: &V2DreamRequest) -> Result<V2DreamSourceOutcome, ()> { Ok(self.0.clone()) }
    }

    #[test]
    fn service_preserves_an_observed_scheduler_status() {
        let store: Arc<dyn locus_kit::drawer_store::DrawerStore> = Arc::new(
            locus_kit::drawer_store_inmemory::InMemoryDrawerStore::new(0, None).expect("store"),
        );
        let mut coordinator = EstateCoordinator::new();
        let handle = coordinator
            .open(store, locus_kit::estate_types::OwnerCredentials::new("owner"), 0, 100)
            .expect("open");
        let admission = V2DreamAdmission {
            estate_id: Uuid::nil(), estate_handle: handle, caller_binding: "caller".to_owned(),
            authorization_generation: "generation".to_owned(), now_millis: 0,
        };
        let service = V2DreamService::new(Authority { admission }, Lower(V2DreamSourceOutcome::AlreadyRunning));
        let result = service.execute(V2DreamRequest { estate_id: None }).expect("status result");
        assert_eq!(result.status, V2DreamStatus::AlreadyRunning);
        assert_eq!(result.cycle, None);
    }

    #[test]
    fn completed_receipt_retains_fixture_fields_and_proposal_order() {
        let receipt = V2DreamCycleReceipt {
            candidates_considered: 7,
            proposals_emitted: vec!["drawer-a".to_owned(), "drawer-b".to_owned()],
            suppressed_duplicates: 2,
            below_threshold: 1,
            contradictions_proposed: 4,
            contradiction_candidates_borderline: 5,
            subjects_backfilled: Some(6),
            associations_written: Some(7),
            associations_non_unique_probes: Some(8),
        };
        assert_eq!(receipt.proposals_emitted, ["drawer-a", "drawer-b"]);
        assert_eq!(receipt.contradictions_proposed, 4);
        assert_eq!(receipt.contradiction_candidates_borderline, 5);
        assert_eq!(receipt.subjects_backfilled, Some(6));
        assert_eq!(receipt.associations_written, Some(7));
        assert_eq!(receipt.associations_non_unique_probes, Some(8));
        let data = serde_json::to_value(&receipt).expect("fixture serialization");
        assert_eq!(data["candidatesConsidered"], 7);
        assert_eq!(data["proposalsEmitted"], serde_json::json!(["drawer-a", "drawer-b"]));
        assert_eq!(data["suppressedDuplicates"], 2);
        assert_eq!(data["belowThreshold"], 1);
        assert_eq!(data["contradictionsProposed"], 4);
        assert_eq!(data["contradictionCandidatesBorderline"], 5);
        assert_eq!(data["subjectsBackfilled"], 6);
        assert_eq!(data["associationsWritten"], 7);
        assert_eq!(data["associationsNonUniqueProbes"], 8);
        assert!(data.get("candidates_considered").is_none());
    }
}
