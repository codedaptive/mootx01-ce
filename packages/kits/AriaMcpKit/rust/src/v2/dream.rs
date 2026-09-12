//! Typed direct lower lane for `moot_dream`.
//!
//! This module supplies the strict request, admission, lower-engine, and
//! result contract for the selected-surface owner.

use std::sync::{Arc, Mutex};

use genius_locus_kit::{EstateCoordinator, EstateHandle};
use serde::Serialize;
use uuid::Uuid;

use crate::jsonrpc::JsonValue;

use super::codec::{optional_string, optional_uuid, strict_object, V2DecodeResult};

pub const DREAM_TOOL: &str = "moot_dream";

/// V2 admits a caller-proposed cycle clock and an association sweep mode in
/// addition to the estate selector.  Both new fields are optional, preserving
/// backwards-compatibility with callers that supply only `estate_id`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2DreamRequest {
    pub estate_id: Option<Uuid>,
    /// Caller-proposed cycle clock as milliseconds since epoch.  Parsed from
    /// an ISO 8601 UTC string; `None` when the argument is absent.  The
    /// authority enforces a 24-hour future ceiling before admitting the instant.
    pub now_millis: Option<i64>,
    /// Association sweep mode: `"all"` = full-estate pass
    /// (`DREAM_ASSOCIATE_ALL_MODE_MAX_PROBE`), `"off"` = skip the sweep
    /// entirely, `None` = default cadence (`DEFAULT_PROBE_LIMIT`).
    pub associates: Option<String>,
}

impl V2DreamRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["estate_id", "now", "associates"])?;
        let now_millis = if let Some(s) = optional_string(object, "now")? {
            let epoch = crate::recipe_tools::parse_iso8601_to_epoch(s).ok_or_else(|| {
                super::codec::V2InvalidArgument::new("now", "Argument 'now' must be a valid ISO 8601 date-time string.")
                    .correction("Provide 'now' in the format YYYY-MM-DDTHH:MM:SSZ.")
            })?;
            Some(epoch)
        } else {
            None
        };
        // Normalise first, then validate. "OFF" and "ALL" are accepted alongside
        // their lowercase forms; any other value is refused with -32602 before
        // the lower engine is reached, so no sweep runs on an unknown mode.
        let associates = if let Some(raw) = optional_string(object, "associates")? {
            let normalised = raw.to_lowercase();
            if normalised != "off" && normalised != "all" {
                return Err(super::codec::V2InvalidArgument::new(
                    "associates",
                    "Argument 'associates' must be \"off\" or \"all\".",
                )
                .allowed(["off".to_owned(), "all".to_owned()])
                .correction(
                    "Use \"off\" to skip the association sweep or \"all\" for a full-estate pass.",
                ));
            }
            Some(normalised)
        } else {
            None
        };
        Ok(Self {
            estate_id: optional_uuid(object, "estate_id")?,
            now_millis,
            associates,
        })
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

/// Error variants the authority or service can produce.  `InvalidArgument`
/// maps to JSON-RPC -32602 (never a refusal envelope); `Unavailable` and
/// `OutcomeUnverified` map to operational refusal envelopes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2DreamAuthorityError {
    Unavailable,
    /// Caller-supplied argument is structurally valid but semantically out of
    /// range (e.g. `now` more than 24 hours in the future).  The service
    /// converts this to a thrown -32602 error so destructive paths are never
    /// reached with an out-of-range clock.
    InvalidArgument(String),
}

pub trait V2DreamAuthority: Send + Sync {
    fn admit(
        &self,
        requested_estate_id: Option<Uuid>,
        requested_now: Option<i64>,
    ) -> Result<V2DreamAdmission, V2DreamAuthorityError>;
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
    /// Absent rather than null when the step did not run. The declared dream
    /// data schema types these three as nonnegative integers and leaves them
    /// out of `required`, so a null would violate the contract while an absent
    /// key conforms. Swift omits them; skipping keeps the two ports byte-equal.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subjects_backfilled: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub associations_written: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2DreamError {
    Unavailable,
    OutcomeUnverified,
    /// Caller-supplied argument is out of range.  Converts to -32602, never
    /// a refusal envelope.
    InvalidArgument(String),
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

        // Resolve association sweep probe limit from the `associates` mode:
        //   "all"  → full-estate pass, bounded by DREAM_ASSOCIATE_ALL_MODE_MAX_PROBE
        //   "off"  → skip the sweep entirely; associations fields are absent
        //   None   → default cadence (DEFAULT_PROBE_LIMIT, 50 probes)
        let associates_mode = request.associates.as_deref().map(str::to_lowercase);
        let (associations_written, associations_non_unique_probes) =
            if associates_mode.as_deref() == Some("off") {
                (None, None)
            } else {
                let probe_limit: usize = if associates_mode.as_deref() == Some("all") {
                    crate::recipe_tools::DREAM_ASSOCIATE_ALL_MODE_MAX_PROBE_PUB
                } else {
                    genius_locus_kit::brain::signals::vector_similarity::VectorSimilaritySignal::DEFAULT_PROBE_LIMIT
                };
                let sweep = coordinator
                    .associate_sweep(&admission.estate_handle, Some(probe_limit), admission.now_millis)
                    .map_err(|_| ())?;
                (Some(sweep.written as u64), Some(sweep.non_unique_probes as u64))
            };
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
            associations_written,
            associations_non_unique_probes,
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
        let admission = self.authority
            .admit(request.estate_id, request.now_millis)
            .map_err(|e| match e {
                V2DreamAuthorityError::Unavailable => V2DreamError::Unavailable,
                V2DreamAuthorityError::InvalidArgument(msg) => V2DreamError::InvalidArgument(msg),
            })?;
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
        fn admit(
            &self,
            requested: Option<Uuid>,
            _requested_now: Option<i64>,
        ) -> Result<V2DreamAdmission, V2DreamAuthorityError> {
            if requested.is_none() || requested == Some(self.admission.estate_id) {
                Ok(self.admission.clone())
            } else {
                Err(V2DreamAuthorityError::Unavailable)
            }
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
        let result = service.execute(V2DreamRequest { estate_id: None, now_millis: None, associates: None }).expect("status result");
        assert_eq!(result.status, V2DreamStatus::AlreadyRunning);
        assert_eq!(result.cycle, None);
    }

    /// Records how many times the lower ran, so a test can prove the service
    /// never reached it. The dreaming cycle prunes recall traces at the
    /// admitted instant minus thirty days, so "the lower did not run" is the
    /// assertion that proves an out-of-range clock cannot destroy anything.
    struct CountingLower {
        calls: Arc<Mutex<usize>>,
        seen_now: Arc<Mutex<Option<i64>>>,
    }
    impl V2DreamLower for CountingLower {
        fn run(
            &self,
            admission: &V2DreamAdmission,
            _: &V2DreamRequest,
        ) -> Result<V2DreamSourceOutcome, ()> {
            *self.calls.lock().unwrap() += 1;
            *self.seen_now.lock().unwrap() = Some(admission.now_millis);
            Ok(V2DreamSourceOutcome::Completed(V2DreamCycleReceipt {
                candidates_considered: 0,
                proposals_emitted: Vec::new(),
                suppressed_duplicates: 0,
                below_threshold: 0,
                contradictions_proposed: 0,
                contradiction_candidates_borderline: 0,
                subjects_backfilled: None,
                associations_written: None,
                associations_non_unique_probes: None,
            }))
        }
    }

    /// Refuses every admission with an out-of-range argument, standing in for
    /// `SelectedDreamAuthority` rejecting a `now` beyond the 24-hour ceiling.
    struct RefusingAuthority;
    impl V2DreamAuthority for RefusingAuthority {
        fn admit(
            &self,
            _: Option<Uuid>,
            _: Option<i64>,
        ) -> Result<V2DreamAdmission, V2DreamAuthorityError> {
            Err(V2DreamAuthorityError::InvalidArgument(
                "Argument 'now' must not be more than 24 hours in the future.".to_owned(),
            ))
        }
        fn revalidate(&self, _: &V2DreamAdmission) -> Result<(), ()> { Ok(()) }
    }

    /// Admits the caller's instant when one is supplied and its own otherwise,
    /// mirroring the resolve step in `SelectedDreamAuthority::admit`.
    struct AdmittingAuthority { admission: V2DreamAdmission }
    impl V2DreamAuthority for AdmittingAuthority {
        fn admit(
            &self,
            _: Option<Uuid>,
            requested_now: Option<i64>,
        ) -> Result<V2DreamAdmission, V2DreamAuthorityError> {
            let mut admitted = self.admission.clone();
            if let Some(proposed) = requested_now { admitted.now_millis = proposed; }
            Ok(admitted)
        }
        fn revalidate(&self, _: &V2DreamAdmission) -> Result<(), ()> { Ok(()) }
    }

    fn test_admission() -> V2DreamAdmission {
        let store: Arc<dyn locus_kit::drawer_store::DrawerStore> = Arc::new(
            locus_kit::drawer_store_inmemory::InMemoryDrawerStore::new(0, None).expect("store"),
        );
        let mut coordinator = EstateCoordinator::new();
        let handle = coordinator
            .open(store, locus_kit::estate_types::OwnerCredentials::new("owner"), 0, 100)
            .expect("open");
        V2DreamAdmission {
            estate_id: Uuid::nil(),
            estate_handle: handle,
            caller_binding: "caller".to_owned(),
            authorization_generation: "generation".to_owned(),
            now_millis: 1_700_000_000_000,
        }
    }

    /// An out-of-range argument short-circuits before the lower. The call count
    /// is the load-bearing half: it proves the destructive dreaming cycle is
    /// unreachable with a rejected clock, rather than merely that the caller
    /// saw an error. Swift twin: `nowFarFutureRefused`.
    #[test]
    fn service_invalid_argument_never_reaches_the_lower() {
        let calls = Arc::new(Mutex::new(0usize));
        let seen_now = Arc::new(Mutex::new(None));
        let service = V2DreamService::new(
            RefusingAuthority,
            CountingLower { calls: Arc::clone(&calls), seen_now: Arc::clone(&seen_now) },
        );

        let error = service
            .execute(V2DreamRequest {
                estate_id: None,
                now_millis: Some(1_900_000_000_000),
                associates: None,
            })
            .expect_err("an out-of-range now must not succeed");

        assert!(
            matches!(error, V2DreamError::InvalidArgument(_)),
            "the authority's InvalidArgument must stay an InvalidArgument, not become Unavailable: {error:?}"
        );
        assert_eq!(
            *calls.lock().unwrap(), 0,
            "the lower must not run when the clock is out of range"
        );
        assert_eq!(
            *seen_now.lock().unwrap(), None,
            "no instant may reach the lower on a refused admission"
        );
    }

    /// The instant the lower stamps is the one the caller proposed, not the
    /// authority's own clock. Asserting the value rather than the absence of an
    /// error is what catches the argument being decoded and then dropped.
    #[test]
    fn service_stamps_the_admitted_caller_instant() {
        let proposed = 1_600_000_000_000i64;
        let calls = Arc::new(Mutex::new(0usize));
        let seen_now = Arc::new(Mutex::new(None));
        let service = V2DreamService::new(
            AdmittingAuthority { admission: test_admission() },
            CountingLower { calls: Arc::clone(&calls), seen_now: Arc::clone(&seen_now) },
        );

        service
            .execute(V2DreamRequest {
                estate_id: None,
                now_millis: Some(proposed),
                associates: None,
            })
            .expect("an in-range now must complete");

        assert_eq!(*calls.lock().unwrap(), 1, "the lower must run for an admitted instant");
        assert_eq!(
            *seen_now.lock().unwrap(), Some(proposed),
            "the lower must stamp the caller's instant, not the authority's clock"
        );
    }

    /// With no `now`, the authority's own instant is what reaches the lower.
    /// This is the no-regression half: admitting the argument must not change
    /// behaviour for callers that never send one.
    #[test]
    fn service_falls_back_to_the_authority_instant_when_now_is_absent() {
        let admission = test_admission();
        let authority_now = admission.now_millis;
        let calls = Arc::new(Mutex::new(0usize));
        let seen_now = Arc::new(Mutex::new(None));
        let service = V2DreamService::new(
            AdmittingAuthority { admission },
            CountingLower { calls: Arc::clone(&calls), seen_now: Arc::clone(&seen_now) },
        );

        service
            .execute(V2DreamRequest { estate_id: None, now_millis: None, associates: None })
            .expect("an absent now must complete");

        assert_eq!(*calls.lock().unwrap(), 1, "the lower must run when now is absent");
        assert_eq!(
            *seen_now.lock().unwrap(), Some(authority_now),
            "an absent now must leave the authority's instant in place"
        );
    }

    /// The two probe bounds the `associates` branch selects between. The mode
    /// resolution lives inside `V2GeniusLocusDreamLower::run`, which reaches
    /// `associate_sweep` through a concrete coordinator with no seam to
    /// intercept the argument, so the value actually passed is not assertable.
    /// Pinning the constants catches the bounds themselves drifting, which is
    /// the part that would silently make a documented depth a lie.
    #[test]
    fn associates_mode_selects_the_documented_probe_bounds() {
        assert_eq!(
            crate::recipe_tools::DREAM_ASSOCIATE_ALL_MODE_MAX_PROBE_PUB, 10_000,
            "all-mode sweeps to v1's documented 10_000 probes"
        );
        assert_eq!(
            genius_locus_kit::brain::signals::vector_similarity::VectorSimilaritySignal::DEFAULT_PROBE_LIMIT,
            50,
            "the default cadence stays at 50 probes"
        );
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
