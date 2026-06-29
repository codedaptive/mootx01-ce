// brain/scheduler/serial_lane.rs — single serial-lane executor for the Rust
// standing-signal scheduler.
//
// Architecture spec §11.3 / DECISION_STANDING_SIGNAL_SCHEDULER_2026-05-21:
// one drainer per estate, jobs applied in submission order, no parallel signal
// execution against one estate.
//
// T5 (ADR-021 Decision 7): The Rust scheduler now backs the signals lane with
// the SHARED per-estate `queue.sqlite`, isolated by `stream_id = "signals"`.
// This mirrors the Swift `StandingSignalScheduler` backend migration and closes
// the crash-durability parity gap: SQLite-backed estates get durable standing-
// signal queuing; in-memory estates use a transient PersistenceKitBackend.
//
// Each emission is encoded into a `SignalJobEnvelope` payload (serde_json),
// submitted to the queue with `stream_id = "signals"`, drained via the
// stream-scoped `drain_for_stream`, processed, and replied Done. This matches
// Swift's enqueue→drainAll→reply(to:status:.done) lifecycle exactly.
//
// # Backend selection (matches NeuronKit ensure_scheduler, matches Swift SignalAPI.ensureScheduler)
//
//   - SQLite estate → shared encrypted `queue.sqlite` beside the estate +
//     `DrainLease::new(estate_dir, "signals", owner)`.
//   - InMemory (or absent) estate → transient PersistenceKitBackend + None
//     lease.
//
// # Synchronous predicates
//
//   Swift's `ConditionPredicate` is async; the Rust mirror uses a synchronous
//   closure so the parity test has no async runtime. The four-class emission
//   contract is unchanged.
//
// # Dispatcher carries `now_nanos`
//
//   The Rust substrate uses explicit `now` parameters throughout (determinism
//   convention). The Swift `SignalDispatcher` calls `dispatchPropose` /
//   `dispatchAssociate` without a timestamp because the Swift coordinator reads
//   its own clock; the Rust port threads `now_nanos` from the drain loop through
//   `apply_emission` into both dispatch methods so verb calls reach a
//   deterministic coordinator path.
//
// # drain_telemetry_now
//
//   A wall-clock read is used ONLY for the QueueKit drain head-of-line age
//   telemetry (the `drain_telemetry_now()` helper). This is queue infrastructure
//   telemetry, not the deterministic signal engine — it mirrors Swift's
//   `QueueKit.drain()` reading `ContinuousClock` internally and does not violate
//   the engine-determinism rule (which governs `apply_emission` and the
//   dispatcher, not the drain loop header).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use queuekit::{DrainLease, Job, JobId, ObservationStatus, QueueBackend, QueueKit, StreamId};
use serde::{Deserialize, Serialize};

use crate::brain::scheduler::api::*;
use crate::brain::scheduler::schedule::SchedulerError;
use crate::coordinator::{EstateCoordinator, VerbDispatchError};
use crate::handle::EstateHandle;
use crate::verbs::frames::{
    AssociateFrame as VerbAssociateFrame, ProposeFrame as VerbProposeFrame,
};
use crate::verbs::lexicon::VerbError;

// ── Dispatcher trait ──────────────────────────────────────────────────────────

/// Routing surface the scheduler calls back into to execute `propose`
/// and `associate` emissions against the live coordinator. Mirrors
/// Swift's `SignalDispatcher` protocol.
///
/// `now_nanos` is threaded from the drain loop so verb calls satisfy
/// the Rust determinism convention (explicit `now` everywhere, never
/// `SystemTime::now()` inside the coordinator).
///
/// Return contract (parity with Swift `dispatchPropose`/`dispatchAssociate`):
///   `Ok(true)`  — verb succeeded → records `Routed`
///   `Ok(false)` — verb raised `VerbError::NotSupportedByEstate` →
///                 records `RoutedButVerbStubbed`
///   `Err(msg)`  — any other verb or dispatch failure → records `RouteFailed`
pub trait Dispatcher: Send + Sync {
    fn dispatch_propose(
        &self,
        handle: &EstateHandleID,
        frame: &ProposalFrame,
        now_nanos: i64,
    ) -> Result<bool, String>;

    fn dispatch_associate(
        &self,
        handle: &EstateHandleID,
        frame: &AssociationFrame,
        now_nanos: i64,
    ) -> Result<bool, String>;
}

// ── NoopDispatcher (test-only) ────────────────────────────────────────────────

/// Test-only stub dispatcher. Every propose/associate call is acknowledged but
/// reported as `routed_but_verb_stubbed`, so tests that verify scheduling
/// mechanics (ordering, emission counting, concurrency policy) can run without
/// a live estate.
///
/// NOT wired in any production path: the production dispatcher is
/// `CoordinatorDispatcher`. Compiled out of the production binary: gated behind
/// `#[cfg(any(test, feature = "test-seams"))]` so it leaves the public API in
/// shipped builds. Integration tests reach it via the `test-seams` feature
/// (declared `required-features` on their `[[test]]` targets — same technique as
/// the recall/encode degradation seams). Swift has no public noop equivalent
/// (Brain scheduling is async actor lanes there).
#[cfg(any(test, feature = "test-seams"))]
pub struct NoopDispatcher;

#[cfg(any(test, feature = "test-seams"))]
impl Dispatcher for NoopDispatcher {
    fn dispatch_propose(
        &self,
        _handle: &EstateHandleID,
        _frame: &ProposalFrame,
        _now_nanos: i64,
    ) -> Result<bool, String> {
        Ok(false)
    }

    fn dispatch_associate(
        &self,
        _handle: &EstateHandleID,
        _frame: &AssociationFrame,
        _now_nanos: i64,
    ) -> Result<bool, String> {
        Ok(false)
    }
}

// ── CoordinatorDispatcher ─────────────────────────────────────────────────────

/// Production dispatcher that routes scheduler emissions through the
/// live `EstateCoordinator` verb surface. This is the Rust equivalent
/// of Swift's `SchedulerDispatcher` in `SignalAPI.swift`:
///
/// ```swift
/// internal struct SchedulerDispatcher: SignalDispatcher {
///     let kit: GeniusLocusKit
///     func dispatchPropose(handle:frame:) async throws { try await kit.propose(handle, frame) }
///     func dispatchAssociate(handle:frame:) async throws { try await kit.associate(handle, frame) }
/// }
/// ```
///
/// The coordinator is shared behind a `Mutex` so the same `EstateCoordinator`
/// that the application uses for direct verb calls can also service
/// scheduler-driven emissions — single ownership, no duplication of estate state.
///
/// The stored `handle` is the live `EstateHandle` for this estate. The
/// scheduler's `EstateHandleID` string is checked against the handle's UUID for
/// belt-and-suspenders safety; a mismatch records `RouteFailed` because it
/// indicates the scheduler was wired to the wrong coordinator instance.
///
/// `VerbError::NotSupportedByEstate` is mapped to `Ok(false)` (recorded as
/// `RoutedButVerbStubbed`) matching Swift's `dispatchPropose` catch block that
/// checks `if case .notSupportedByEstate = verbError`. All other failures
/// propagate as `Err(reason)` (recorded as `RouteFailed`).
pub struct CoordinatorDispatcher {
    /// Shared coordinator that owns the live estate. `Mutex` because the estate
    /// coordinator's verb methods take `&self` (interior mutation via the
    /// underlying SQLite connection), which is already thread-safe; the `Mutex`
    /// exists to satisfy `Send + Sync` for the `Dispatcher` trait bound.
    pub coordinator: Arc<Mutex<EstateCoordinator>>,
    /// The specific estate this scheduler services. Stored as a value type so
    /// the dispatcher can validate the incoming `EstateHandleID` without a map
    /// lookup on every emission.
    pub handle: EstateHandle,
}

impl CoordinatorDispatcher {
    /// Construct a dispatcher backed by `coordinator` for `handle`.
    pub fn new(coordinator: Arc<Mutex<EstateCoordinator>>, handle: EstateHandle) -> Self {
        Self { coordinator, handle }
    }
}

impl Dispatcher for CoordinatorDispatcher {
    /// Route a `propose` emission from the scheduler to the coordinator's
    /// `propose` verb.
    ///
    /// `now_nanos` is the drain-loop nanosecond timestamp. The coordinator stores
    /// `filed_at` in epoch-seconds (ISO8601 TEXT column), so `now_nanos` is
    /// converted to seconds by dividing by `1_000_000_000` before the verb call.
    /// This matches the Swift path where `dispatchPropose` calls `kit.propose`
    /// without a timestamp and the Swift actor reads `Date()` (seconds-precision
    /// for storage purposes).
    fn dispatch_propose(
        &self,
        handle_id: &EstateHandleID,
        frame: &ProposalFrame,
        now_nanos: i64,
    ) -> Result<bool, String> {
        // Belt-and-suspenders: verify the incoming handle ID matches the stored
        // handle. A mismatch means the scheduler was constructed with a different
        // handle than the coordinator owns, which is a wiring error in the caller.
        let expected_id = uuid::Uuid::from_bytes(self.handle.estate_uuid).to_string();
        if handle_id != &expected_id {
            return Err(format!(
                "CoordinatorDispatcher handle mismatch: scheduler handle={handle_id}, \
                 coordinator handle={expected_id}"
            ));
        }
        // Convert nanoseconds → epoch-seconds for the coordinator's ISO8601-backed
        // `filed_at` column.
        let now_sec = now_nanos / 1_000_000_000;
        let verb_frame = VerbProposeFrame {
            target: frame.target.clone(),
            kind: frame.kind.clone(),
            justification: frame.justification.clone(),
        };
        let coordinator = self
            .coordinator
            .lock()
            .map_err(|e| format!("coordinator lock poisoned: {e}"))?;
        match coordinator.propose(&self.handle, verb_frame, now_sec) {
            Ok(_) => Ok(true),
            Err(VerbDispatchError::Verb(VerbError::NotSupportedByEstate { .. })) => Ok(false),
            Err(e) => Err(format!("{e:?}")),
        }
    }

    /// Route an `associate` emission from the scheduler to the coordinator's
    /// `associate` verb.
    ///
    /// `now_nanos` is converted to epoch-seconds before the call for the same
    /// reason as `dispatch_propose` — the coordinator's `filed_at` column is
    /// ISO8601 TEXT (seconds precision).
    fn dispatch_associate(
        &self,
        handle_id: &EstateHandleID,
        frame: &AssociationFrame,
        now_nanos: i64,
    ) -> Result<bool, String> {
        let expected_id = uuid::Uuid::from_bytes(self.handle.estate_uuid).to_string();
        if handle_id != &expected_id {
            return Err(format!(
                "CoordinatorDispatcher handle mismatch: scheduler handle={handle_id}, \
                 coordinator handle={expected_id}"
            ));
        }
        let now_sec = now_nanos / 1_000_000_000;
        let verb_frame = VerbAssociateFrame {
            a: frame.a.clone(),
            b: frame.b.clone(),
            weight: frame.weight,
        };
        let coordinator = self
            .coordinator
            .lock()
            .map_err(|e| format!("coordinator lock poisoned: {e}"))?;
        match coordinator.associate(&self.handle, verb_frame, now_sec) {
            Ok(_) => Ok(true),
            Err(VerbDispatchError::Verb(VerbError::NotSupportedByEstate { .. })) => Ok(false),
            Err(e) => Err(format!("{e:?}")),
        }
    }
}

// ── SignalJobEnvelope ─────────────────────────────────────────────────────────

/// Wire payload for a standing-signal job in the shared `queue.sqlite`,
/// `stream_id = "signals"`. Encodes one `SignalEmission` as JSON.
///
/// Field names are chosen to match the Swift `SignalJobEnvelope` Codable keys
/// for training-data cleanliness (both ports agree on vocabulary even though
/// queue.sqlite is per-port and byte-for-byte wire identity is not required).
///
/// Serialization: `to_payload()` → `serde_json::to_vec` → `Job.payload`;
/// `from_payload()` → `serde_json::from_slice` on drain.
#[derive(Debug, Serialize, Deserialize)]
struct SignalJobEnvelope {
    /// The SignalID that produced this emission, as a string. Stored in the
    /// payload so the drain loop can attribute outcomes back to the signal record.
    signal_id: String,
    /// The emission class: "propose", "associate", "mutate_candidate", or
    /// "diagnostic". Matches `SignalEmission::class_tag()`.
    class_tag: String,
    /// Present for `propose` and `mutate_candidate` emissions: target row ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    propose_target: Option<String>,
    /// Present for `propose` emissions: the ProposalKind raw value.
    #[serde(skip_serializing_if = "Option::is_none")]
    propose_kind: Option<String>,
    /// Present for `propose` emissions: optional human-readable justification.
    #[serde(skip_serializing_if = "Option::is_none")]
    propose_justification: Option<String>,
    /// Present for `associate` emissions: the first member row ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    associate_a: Option<String>,
    /// Present for `associate` emissions: the second member row ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    associate_b: Option<String>,
    /// Present for `associate` emissions: the link weight.
    #[serde(skip_serializing_if = "Option::is_none")]
    associate_weight: Option<f64>,
    /// Present for `mutate_candidate` emissions: the mutation kind tag.
    #[serde(skip_serializing_if = "Option::is_none")]
    mutate_kind: Option<String>,
    /// Present for `diagnostic` emissions: the diagnostic title.
    #[serde(skip_serializing_if = "Option::is_none")]
    diagnostic_title: Option<String>,
    /// Present for `diagnostic` emissions: the diagnostic detail.
    #[serde(skip_serializing_if = "Option::is_none")]
    diagnostic_detail: Option<String>,
    /// Present for `diagnostic` emissions: observed_at nanoseconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    diagnostic_observed_at_nanos: Option<i64>,
}

impl SignalJobEnvelope {
    /// Encode a `SignalEmission` into an envelope ready to serialize as job
    /// payload. Mirrors Swift's `SignalJobEnvelope.init(signalId:emission:)`.
    fn from_emission(signal_id: &SignalID, emission: &SignalEmission) -> Self {
        let class_tag = emission.class_tag().to_string();
        match emission {
            SignalEmission::Propose(frame) => SignalJobEnvelope {
                signal_id: signal_id.0.clone(),
                class_tag,
                propose_target: Some(frame.target.clone()),
                propose_kind: Some(frame.kind.raw_value().to_string()),
                propose_justification: frame.justification.clone(),
                associate_a: None,
                associate_b: None,
                associate_weight: None,
                mutate_kind: None,
                diagnostic_title: None,
                diagnostic_detail: None,
                diagnostic_observed_at_nanos: None,
            },
            SignalEmission::Associate(frame) => SignalJobEnvelope {
                signal_id: signal_id.0.clone(),
                class_tag,
                propose_target: None,
                propose_kind: None,
                propose_justification: None,
                associate_a: Some(frame.a.clone()),
                associate_b: Some(frame.b.clone()),
                associate_weight: Some(frame.weight),
                mutate_kind: None,
                diagnostic_title: None,
                diagnostic_detail: None,
                diagnostic_observed_at_nanos: None,
            },
            SignalEmission::MutateCandidate { row_id, kind } => SignalJobEnvelope {
                signal_id: signal_id.0.clone(),
                class_tag,
                propose_target: Some(row_id.clone()),
                propose_kind: None,
                propose_justification: None,
                associate_a: None,
                associate_b: None,
                associate_weight: None,
                mutate_kind: Some(kind.tag().to_string()),
                diagnostic_title: None,
                diagnostic_detail: None,
                diagnostic_observed_at_nanos: None,
            },
            SignalEmission::Diagnostic(report) => SignalJobEnvelope {
                signal_id: signal_id.0.clone(),
                class_tag,
                propose_target: None,
                propose_kind: None,
                propose_justification: None,
                associate_a: None,
                associate_b: None,
                associate_weight: None,
                mutate_kind: None,
                diagnostic_title: Some(report.title.clone()),
                diagnostic_detail: Some(report.detail.clone()),
                diagnostic_observed_at_nanos: Some(report.observed_at_nanos),
            },
        }
    }

    /// Decode the envelope back into a `(SignalID, SignalEmission)` pair.
    /// Returns `None` when the payload is corrupt or the class_tag is
    /// unrecognized — the drain loop treats these as permanently blocked and
    /// replies `ObservationStatus::Blocked`.
    fn to_emission(&self) -> Option<(SignalID, SignalEmission)> {
        let signal_id = SignalID(self.signal_id.clone());
        let emission = match self.class_tag.as_str() {
            "propose" => SignalEmission::Propose(ProposalFrame {
                target: self.propose_target.clone()?,
                kind: ProposalKind::from_raw(self.propose_kind.as_deref().unwrap_or("")),
                justification: self.propose_justification.clone(),
            }),
            "associate" => SignalEmission::Associate(AssociationFrame {
                a: self.associate_a.clone()?,
                b: self.associate_b.clone()?,
                weight: self.associate_weight?,
            }),
            "mutate_candidate" => SignalEmission::MutateCandidate {
                row_id: self.propose_target.clone()?,
                kind: MutationKind::from_tag(self.mutate_kind.as_deref().unwrap_or("")),
            },
            "diagnostic" => SignalEmission::Diagnostic(DiagnosticReport {
                title: self.diagnostic_title.clone().unwrap_or_default(),
                detail: self.diagnostic_detail.clone().unwrap_or_default(),
                observed_at_nanos: self.diagnostic_observed_at_nanos.unwrap_or(0),
            }),
            _ => return None,
        };
        Some((signal_id, emission))
    }

    fn to_payload(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("SignalJobEnvelope serialization cannot fail")
    }

    fn from_payload(bytes: &[u8]) -> Option<Self> {
        serde_json::from_slice(bytes).ok()
    }
}

// ── Queue type alias ──────────────────────────────────────────────────────────

/// The signals queue facade: `QueueKit` over either backend, held as a
/// type-erased `Box<dyn QueueBackend>`. Aliased for readability at multiple
/// use sites; matches the CorpusKit `IngestQueue` aliasing pattern.
pub type SignalsQueue = QueueKit<Box<dyn QueueBackend>>;

// ── Wall-clock helper (telemetry only) ───────────────────────────────────────

/// Wall-clock epoch seconds for the QueueKit drain telemetry (head-of-line age).
/// This is queue INFRASTRUCTURE telemetry, not the deterministic signal engine —
/// it mirrors Swift's `QueueKit.drain()` reading `ContinuousClock` internally,
/// so a wall-clock read here is consistent with the Swift port and does not
/// violate the engine-determinism rule (which governs `apply_emission` and the
/// dispatcher, not the drain loop header).
fn drain_telemetry_now() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

// ── Per-signal record ─────────────────────────────────────────────────────────

/// Per-signal record. Equivalent to the dictionaries Swift's
/// `StandingSignalScheduler` actor holds (signals, states, emissionCount, etc.)
/// — collapsed into one struct keyed by SignalID for cleaner borrow patterns.
struct SignalRecord {
    spec: SignalSpec,
    state: SignalState,
    last_run_at: Option<i64>,
    last_emitted_at: Option<i64>,
    emission_count: u64,
    recent_diagnostics: Vec<DiagnosticReport>,
    recent_outcomes: Vec<SignalRouteOutcome>,
    #[allow(clippy::type_complexity)]
    // subscriber closure type is intentional — factoring into a type alias would obscure the contract
    subscribers: HashMap<SubscriptionID, Box<dyn Fn(&SignalEmission) + Send + Sync>>,
}

impl SignalRecord {
    fn report(&self, id: SignalID) -> SignalReport {
        SignalReport {
            signal_id: id,
            name: self.spec.name.clone(),
            trigger_tag: trigger_tag(&self.spec.trigger).to_string(),
            state: self.state.clone(),
            last_run_at_nanos: self.last_run_at,
            last_emitted_at_nanos: self.last_emitted_at,
            emission_count: self.emission_count,
            recent_diagnostics: self.recent_diagnostics.clone(),
            recent_outcomes: self.recent_outcomes.clone(),
            concurrency_policy: self.spec.concurrency_policy,
        }
    }
}

// ── Constants ─────────────────────────────────────────────────────────────────

/// Retention bound for `recent_diagnostics`, `recent_outcomes`, and
/// `drain_order_log`. Matches the Swift constant so the parity test can feed
/// long-running vectors and observe the same truncation.
pub const RETENTION: usize = 64;

/// The canonical stream identifier for standing-signal jobs (T5, ADR-021
/// Decision 7). Every `Job` sent to the shared `queue.sqlite` carries
/// `stream_id = SIGNAL_STREAM_ID`; the drain loop uses `drain_for_stream` to
/// claim only these jobs, leaving encode jobs or dreaming jobs on the same
/// queue.sqlite untouched.
pub const SIGNAL_STREAM_ID: &str = "signals";

fn signal_stream_id() -> StreamId {
    StreamId(SIGNAL_STREAM_ID.to_string())
}

// ── SerialLaneScheduler ───────────────────────────────────────────────────────

/// The scheduler. Owns the shared `queue.sqlite` signals lane (or a transient
/// in-memory queue on non-SQLite estates), the per-signal records, and the
/// dispatcher.
///
/// Single-threaded by construction — the caller invokes `tick` from one task at
/// a time per estate. The queue provides crash durability on SQLite estates: a
/// job that was enqueued but not yet drained survives a process restart and will
/// be claimed on the next `drain_lane` pass.
///
/// Swift parity: mirrors `StandingSignalScheduler` (GLK) with `stream_id =
/// "signals"` on the shared per-estate `queue.sqlite`.
pub struct SerialLaneScheduler<D: Dispatcher> {
    handle: EstateHandleID,
    dispatcher: D,
    signals: HashMap<SignalID, SignalRecord>,
    /// The QueueKit facade over the signals lane. `Box<dyn QueueBackend>`
    /// allows either a SQLite PersistenceKitBackend (durable) or an in-memory
    /// PersistenceKitBackend (transient) — selected at construction time by
    /// the caller based on the estate's backend configuration.
    queue: SignalsQueue,
    /// Stream-keyed drain lease, mirroring Swift `StandingSignalScheduler.drainLease`.
    /// `Some` on SQLite estates, `None` on in-memory estates (single-process).
    /// Reserved for future multi-process drain coordination: the lease is
    /// constructed and held, but the current single in-process governor drainer
    /// does not acquire or heartbeat it (hence `#[allow(dead_code)]` — the field
    /// is intentionally never read), exactly as the Swift scheduler holds its
    /// `drainLease` without acquiring it in the drain loop. `DrainLease` has no
    /// `Drop`, so holding the field does not by itself touch the filesystem; a
    /// future multi-process drainer can call `try_acquire`/`heartbeat`/`release`
    /// without an API change. Parity note: keep this inert-but-present in both
    /// ports until a multi-process signal drainer is actually built.
    #[allow(dead_code)]
    drain_lease: Option<DrainLease>,
    /// HLC for stamping signal job submissions. Derives its node identity from
    /// the estate UUID for determinism across reopens of the same estate.
    hlc: substrate_types::hlc::HLCGenerator,
    /// Drain audit trail in `(signal_id, class_tag)` pairs. The conformance gate
    /// inspects this to verify serial application order matches the Swift
    /// reference's `drainHistory`.
    drain_order_log: Vec<(SignalID, &'static str)>,
}

impl<D: Dispatcher> SerialLaneScheduler<D> {
    /// Construct the scheduler. The caller is responsible for backend selection
    /// (SQLite vs in-memory) and passes the pre-built queue + optional drain
    /// lease + HLC.
    ///
    /// Mirrors Swift's `StandingSignalScheduler.init(queue:drainLease:hlc:)`:
    /// the caller (Swift's `SignalAPI.ensureScheduler`, Rust's
    /// `AutonomicGovernor::ensure_scheduler`) selects the backend and passes a
    /// fully-wired queue + lease into the scheduler.
    pub fn new(
        handle: EstateHandleID,
        dispatcher: D,
        queue: SignalsQueue,
        drain_lease: Option<DrainLease>,
        hlc: substrate_types::hlc::HLCGenerator,
    ) -> Self {
        Self {
            handle,
            dispatcher,
            signals: HashMap::new(),
            queue,
            drain_lease,
            hlc,
            drain_order_log: Vec::new(),
        }
    }

    /// Architecture spec §7.8.5 `register_standing_signal`.
    pub fn register(&mut self, spec: SignalSpec, registered_at_nanos: i64) -> SignalID {
        let id = SignalID::generate();
        let last_run = match &spec.trigger {
            // Interval triggers schedule first run at `now + interval`, so the
            // registration time is the implicit lower bound.
            SignalTrigger::Interval { .. } => Some(registered_at_nanos),
            _ => None,
        };
        let record = SignalRecord {
            spec,
            state: SignalState::Idle,
            last_run_at: last_run,
            last_emitted_at: None,
            emission_count: 0,
            recent_diagnostics: Vec::new(),
            recent_outcomes: Vec::new(),
            subscribers: HashMap::new(),
        };
        self.signals.insert(id.clone(), record);
        id
    }

    /// Architecture spec §7.8.5 `signal_status() -> [SignalReport]`.
    /// Sorted lexically by SignalID to match the Swift reference's ordering
    /// convention.
    pub fn report(&self) -> Vec<SignalReport> {
        let mut ids: Vec<SignalID> = self.signals.keys().cloned().collect();
        ids.sort();
        ids.into_iter()
            .map(|id| self.signals[&id].report(id.clone()))
            .collect()
    }

    /// Architecture spec §7.8.5 `signal_subscribe`. Returns a SubscriptionID
    /// the caller passes to `unsubscribe`.
    pub fn subscribe<F>(
        &mut self,
        id: &SignalID,
        callback: F,
    ) -> Result<SubscriptionID, SchedulerError>
    where
        F: Fn(&SignalEmission) + Send + Sync + 'static,
    {
        let record = self
            .signals
            .get_mut(id)
            .ok_or_else(|| SchedulerError::SignalNotRegistered(id.clone()))?;
        let sub = SubscriptionID::generate();
        record.subscribers.insert(sub.clone(), Box::new(callback));
        Ok(sub)
    }

    /// Idempotent unsubscribe. Matches Swift's contract.
    pub fn unsubscribe(&mut self, id: &SignalID, sub: &SubscriptionID) {
        if let Some(record) = self.signals.get_mut(id) {
            record.subscribers.remove(sub);
        }
    }

    /// Advance the scheduler at `now_nanos`. Interval-due signals have their
    /// emit closures invoked; returned emissions are enqueued to the signals
    /// lane; the lane drains serially in submission order via the queue.
    pub fn tick(&mut self, now_nanos: i64) {
        // Snapshot sorted IDs so the iteration order is deterministic for the
        // conformance gate.
        let mut ids: Vec<SignalID> = self.signals.keys().cloned().collect();
        ids.sort();
        for id in &ids {
            if !self.is_due(id, now_nanos) {
                continue;
            }
            self.fire_signal(id, now_nanos);
        }
        self.drain_lane(now_nanos);
    }

    /// Fire an event/condition signal explicitly. Mirrors Swift's `requestFire`.
    pub fn request_fire(&mut self, id: &SignalID, now_nanos: i64) -> Result<(), SchedulerError> {
        if !self.signals.contains_key(id) {
            return Err(SchedulerError::SignalNotRegistered(id.clone()));
        }
        self.fire_signal(id, now_nanos);
        self.drain_lane(now_nanos);
        Ok(())
    }

    pub fn drain_history(&self) -> &[(SignalID, &'static str)] {
        &self.drain_order_log
    }

    pub fn open_signal_count(&self) -> usize {
        self.signals.len()
    }

    fn is_due(&self, id: &SignalID, now_nanos: i64) -> bool {
        let Some(record) = self.signals.get(id) else {
            return false;
        };
        match &record.spec.trigger {
            SignalTrigger::Interval { seconds } => {
                let Some(last) = record.last_run_at else {
                    return true;
                };
                let elapsed_nanos = now_nanos.saturating_sub(last);
                Duration::from_nanos(elapsed_nanos.max(0) as u64) >= *seconds
            }
            SignalTrigger::Event { .. } => false,
            SignalTrigger::Condition(pred) => {
                let ctx = SignalContext {
                    signal_id: id.clone(),
                    handle: self.handle.clone(),
                    now_nanos,
                    last_run_at_nanos: record.last_run_at,
                };
                (pred.evaluate)(&ctx)
            }
        }
    }

    /// Invoke the signal's emit closure and enqueue each emission as a
    /// `SignalJobEnvelope` on the shared signals queue. Mirrors Swift's
    /// `StandingSignalScheduler.enqueue(signal:at:)`.
    fn fire_signal(&mut self, id: &SignalID, now_nanos: i64) {
        let (last_run, emit) = {
            let record = self.signals.get(id).expect("signal present");
            (record.last_run_at, record.spec.emit.clone())
        };
        let ctx = SignalContext {
            signal_id: id.clone(),
            handle: self.handle.clone(),
            now_nanos,
            last_run_at_nanos: last_run,
        };
        if let Some(record) = self.signals.get_mut(id) {
            record.state = SignalState::Queued;
        }
        let emissions = emit(&ctx);

        // Stamp each emission on the HLC and enqueue to the shared signals
        // queue. `now_millis` converts nanoseconds to milliseconds — the HLC
        // physical clock is in milliseconds (substrate-types convention).
        let now_millis = now_nanos / 1_000_000;
        for emission in emissions.iter() {
            let envelope = SignalJobEnvelope::from_emission(id, emission);
            let payload = envelope.to_payload();
            let submitted_at = self.hlc.send(now_millis);
            let job = Job {
                id: JobId(uuid::Uuid::new_v4().simple().to_string()),
                stream_id: signal_stream_id(),
                submitted_at,
                priority: 50,
                payload,
                extensions: serde_json::Map::new(),
            };
            // Enqueue failures are logged but not fatal — a transient storage
            // error does not crash the signal lane; the emission is dropped and
            // the next tick will re-fire if the signal is still due.
            if let Err(e) = self.queue.send(&job) {
                eprintln!(
                    "SerialLaneScheduler: failed to enqueue signal {} emission {}: {:?}",
                    id.0,
                    emission.class_tag(),
                    e
                );
            }
        }

        if let Some(record) = self.signals.get_mut(id) {
            record.last_run_at = Some(now_nanos);
            if emissions.is_empty() {
                record.state = SignalState::LastRan;
            }
        }
    }

    /// Drain all pending signal jobs from the queue, apply each emission, and
    /// reply `Done`. Mirrors Swift's `StandingSignalScheduler.drainAll(now:)`.
    ///
    /// Single drainer: claims all available `"signals"` jobs in one pass, then
    /// processes each in order. The drain loop re-runs until the queue is empty
    /// so a burst enqueued during one fire_signal pass is fully processed in the
    /// same tick.
    fn drain_lane(&mut self, now_nanos: i64) {
        loop {
            let claimed = match self
                .queue
                .drain_for_stream(&signal_stream_id(), drain_telemetry_now())
            {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("SerialLaneScheduler: drain_for_stream error: {:?}", e);
                    break;
                }
            };
            if claimed.is_empty() {
                break;
            }
            for (job, _session) in claimed {
                // Decode the envelope. An undecodable payload is permanently
                // corrupt; reply Blocked and move on (at-most-once semantics).
                let envelope = match SignalJobEnvelope::from_payload(&job.payload) {
                    Some(e) => e,
                    None => {
                        eprintln!(
                            "SerialLaneScheduler: corrupt job payload {}, replying Blocked",
                            job.id.0
                        );
                        let _ = self.queue.reply(&job.id, ObservationStatus::Blocked, vec![]);
                        continue;
                    }
                };
                let (signal_id, emission) = match envelope.to_emission() {
                    Some(pair) => pair,
                    None => {
                        eprintln!(
                            "SerialLaneScheduler: unrecognized class_tag '{}' in job {}, replying Blocked",
                            envelope.class_tag, job.id.0
                        );
                        let _ = self.queue.reply(&job.id, ObservationStatus::Blocked, vec![]);
                        continue;
                    }
                };

                self.set_state(&signal_id, SignalState::Running);

                // Thread now_nanos through apply_emission so the dispatcher can
                // forward the drain-loop timestamp to the coordinator's verb calls
                // (determinism convention: explicit `now` everywhere).
                let outcome = self.apply_emission(&signal_id, &emission, now_nanos);

                if let Some(record) = self.signals.get_mut(&signal_id) {
                    record.recent_outcomes.push(outcome);
                    trim_retention(&mut record.recent_outcomes);
                }
                if let SignalEmission::Diagnostic(ref report) = emission {
                    if let Some(record) = self.signals.get_mut(&signal_id) {
                        record.recent_diagnostics.push(report.clone());
                        trim_retention(&mut record.recent_diagnostics);
                    }
                }

                self.drain_order_log
                    .push((signal_id.clone(), emission.class_tag()));
                trim_retention(&mut self.drain_order_log);

                if let Some(record) = self.signals.get_mut(&signal_id) {
                    record.emission_count += 1;
                    record.last_emitted_at = Some(now_nanos);
                }

                if let Some(record) = self.signals.get(&signal_id) {
                    for cb in record.subscribers.values() {
                        cb(&emission);
                    }
                }

                self.set_state(&signal_id, SignalState::LastRan);

                // Reply Done — the job is fully processed. Errors here are
                // logged but not fatal: the next drain pass will not re-claim
                // an already-Done job.
                if let Err(e) = self.queue.reply(&job.id, ObservationStatus::Done, vec![]) {
                    eprintln!(
                        "SerialLaneScheduler: reply Done failed for job {}: {:?}",
                        job.id.0, e
                    );
                }
            }
        }
    }

    fn set_state(&mut self, id: &SignalID, state: SignalState) {
        if let Some(record) = self.signals.get_mut(id) {
            record.state = state;
        }
    }

    fn apply_emission(
        &self,
        _id: &SignalID,
        emission: &SignalEmission,
        now_nanos: i64,
    ) -> SignalRouteOutcome {
        match emission {
            SignalEmission::Propose(frame) => {
                match self.dispatcher.dispatch_propose(&self.handle, frame, now_nanos) {
                    Ok(true) => SignalRouteOutcome::Routed { verb: "propose".into() },
                    Ok(false) => SignalRouteOutcome::RoutedButVerbStubbed { verb: "propose".into() },
                    Err(reason) => SignalRouteOutcome::RouteFailed {
                        verb: "propose".into(),
                        reason,
                    },
                }
            }
            SignalEmission::Associate(frame) => {
                match self.dispatcher.dispatch_associate(&self.handle, frame, now_nanos) {
                    Ok(true) => SignalRouteOutcome::Routed { verb: "associate".into() },
                    Ok(false) => {
                        SignalRouteOutcome::RoutedButVerbStubbed { verb: "associate".into() }
                    }
                    Err(reason) => SignalRouteOutcome::RouteFailed {
                        verb: "associate".into(),
                        reason,
                    },
                }
            }
            SignalEmission::MutateCandidate { row_id, kind } => {
                // §11.1: routed through `propose` for confirmation. Build a
                // ProposalFrame with kind=MutateCandidate and the source mutation's
                // case tag in the justification so downstream consumers can identify it.
                let frame = ProposalFrame {
                    target: row_id.clone(),
                    kind: ProposalKind::MutateCandidate,
                    justification: Some(format!("kind={}", kind.tag())),
                };
                match self.dispatcher.dispatch_propose(&self.handle, &frame, now_nanos) {
                    Ok(true) => SignalRouteOutcome::Routed { verb: "propose".into() },
                    Ok(false) => SignalRouteOutcome::RoutedButVerbStubbed { verb: "propose".into() },
                    Err(reason) => SignalRouteOutcome::RouteFailed {
                        verb: "propose".into(),
                        reason,
                    },
                }
            }
            SignalEmission::Diagnostic(_) => SignalRouteOutcome::DiagnosticRecorded,
        }
    }
}

fn trim_retention<T>(buf: &mut Vec<T>) {
    if buf.len() > RETENTION {
        let drop = buf.len() - RETENTION;
        buf.drain(..drop);
    }
}
