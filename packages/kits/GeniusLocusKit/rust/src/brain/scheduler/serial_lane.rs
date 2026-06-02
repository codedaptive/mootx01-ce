// brain/scheduler/serial_lane.rs — single serial-lane executor for
// the Rust mirror. Architecture spec §11.3 / DECISION_STANDING_SIGNAL
// _SCHEDULER_2026-05-21: one drainer per estate, jobs applied in
// submission order, no parallel signal execution against one estate.
//
// Rust port differences vs Swift:
//
// - No QueueKit. The Rust port of QueueKit does not exist. The
//   in-process FIFO here gives the same guarantee — we own the
//   only drainer and apply jobs in submission order, which is
//   FIFO. The serial-lane semantics the parity test checks are the
//   ordering and the "drained exactly once" invariant.
//
// - Synchronous predicates. Swift's `ConditionPredicate` is async;
//   the Rust mirror uses a synchronous closure so the parity test
//   has no async runtime. The four-class emission contract is
//   unchanged.

use std::collections::HashMap;
use std::time::Duration;

use crate::brain::scheduler::api::*;
use crate::brain::scheduler::schedule::SchedulerError;

/// Closure shape the scheduler calls back into to route `propose`
/// and `associate` emissions. Mirrors Swift's `SignalDispatcher`
/// protocol.
///
/// `Ok(true)` records `Routed`; `Ok(false)` records
/// `RoutedButVerbStubbed` (the GLK-02 substrate-stub case);
/// `Err(reason)` records `RouteFailed`.
pub trait Dispatcher: Send + Sync {
    fn dispatch_propose(
        &self,
        handle: &EstateHandleID,
        frame: &ProposalFrame,
    ) -> Result<bool, String>;

    fn dispatch_associate(
        &self,
        handle: &EstateHandleID,
        frame: &AssociationFrame,
    ) -> Result<bool, String>;
}

/// Default dispatcher that mimics GLK-02's substrate-stub behaviour:
/// every propose/associate call is acknowledged but reported as
/// `routed_but_verb_stubbed`. The parity test uses this so the Rust
/// surface matches the Swift surface where LocusKit's Brain-layer
/// bodies have not yet shipped.
pub struct NoopDispatcher;

impl Dispatcher for NoopDispatcher {
    fn dispatch_propose(
        &self,
        _handle: &EstateHandleID,
        _frame: &ProposalFrame,
    ) -> Result<bool, String> {
        Ok(false)
    }

    fn dispatch_associate(
        &self,
        _handle: &EstateHandleID,
        _frame: &AssociationFrame,
    ) -> Result<bool, String> {
        Ok(false)
    }
}

/// One emission held in the FIFO lane awaiting drain. Mirrors the
/// Swift `SignalJobEnvelope`'s payload shape but without the
/// QueueKit row encoding — the Rust mirror operates entirely in
/// process.
struct LaneEntry {
    signal_id: SignalID,
    emission: SignalEmission,
}

/// Per-signal record. Equivalent to the dictionaries Swift's
/// `StandingSignalScheduler` actor holds (signals, states,
/// emissionCount, etc.) — collapsed into one struct keyed by
/// SignalID in the Rust port for cleaner borrow patterns.
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

/// Retention bound for `recent_diagnostics`, `recent_outcomes`, and
/// `drain_order_log`. Matches the Swift constant so the parity test
/// can feed long-running vectors and observe the same truncation.
pub const RETENTION: usize = 64;

/// The scheduler. Owns the in-process FIFO lane, the per-signal
/// records, and the dispatcher. Single-threaded by construction —
/// the caller invokes `tick` from one task at a time per estate.
pub struct SerialLaneScheduler<D: Dispatcher> {
    handle: EstateHandleID,
    dispatcher: D,
    signals: HashMap<SignalID, SignalRecord>,
    lane: Vec<LaneEntry>,
    /// Drain audit trail in `(signal_id, class_tag)` pairs. The
    /// conformance gate inspects this to verify serial application
    /// order matches the Swift reference's `drainHistory`.
    drain_order_log: Vec<(SignalID, &'static str)>,
}

impl<D: Dispatcher> SerialLaneScheduler<D> {
    pub fn new(handle: EstateHandleID, dispatcher: D) -> Self {
        Self {
            handle,
            dispatcher,
            signals: HashMap::new(),
            lane: Vec::new(),
            drain_order_log: Vec::new(),
        }
    }

    /// Architecture spec §7.8.5 `register_standing_signal`.
    pub fn register(&mut self, spec: SignalSpec, registered_at_nanos: i64) -> SignalID {
        let id = SignalID::generate();
        let last_run = match &spec.trigger {
            // Interval triggers schedule first run at `now + interval`,
            // so the registration time is the implicit lower bound.
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
    /// Sorted lexically by SignalID to match the Swift reference's
    /// ordering convention.
    pub fn report(&self) -> Vec<SignalReport> {
        let mut ids: Vec<SignalID> = self.signals.keys().cloned().collect();
        ids.sort();
        ids.into_iter()
            .map(|id| self.signals[&id].report(id.clone()))
            .collect()
    }

    /// Architecture spec §7.8.5 `signal_subscribe`. Returns a
    /// SubscriptionID the caller passes to `unsubscribe`.
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

    /// Advance the scheduler at `now_nanos`. Interval-due signals
    /// have their emit closures invoked; the returned emissions land
    /// in the lane; the lane drains serially in submission order.
    pub fn tick(&mut self, now_nanos: i64) {
        // Snapshot sorted IDs so the iteration order is deterministic
        // for the conformance gate.
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

    /// Fire an event/condition signal explicitly. Mirrors Swift's
    /// `requestFire`.
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
        for emission in emissions.iter() {
            self.lane.push(LaneEntry {
                signal_id: id.clone(),
                emission: emission.clone(),
            });
        }
        if let Some(record) = self.signals.get_mut(id) {
            record.last_run_at = Some(now_nanos);
            if emissions.is_empty() {
                record.state = SignalState::LastRan;
            }
        }
    }

    fn drain_lane(&mut self, now_nanos: i64) {
        // Single drainer: pop from the front until empty. Equivalent
        // to the `while !batch.isEmpty` loop in Swift over QueueKit's
        // `.serializable` claim.
        while !self.lane.is_empty() {
            let entry = self.lane.remove(0);
            let signal_id = entry.signal_id.clone();
            let emission = entry.emission;
            self.set_state(&signal_id, SignalState::Running);
            let outcome = self.apply_emission(&signal_id, &emission);
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
        }
    }

    fn set_state(&mut self, id: &SignalID, state: SignalState) {
        if let Some(record) = self.signals.get_mut(id) {
            record.state = state;
        }
    }

    fn apply_emission(&self, _id: &SignalID, emission: &SignalEmission) -> SignalRouteOutcome {
        match emission {
            SignalEmission::Propose(frame) => {
                match self.dispatcher.dispatch_propose(&self.handle, frame) {
                    Ok(true) => SignalRouteOutcome::Routed {
                        verb: "propose".into(),
                    },
                    Ok(false) => SignalRouteOutcome::RoutedButVerbStubbed {
                        verb: "propose".into(),
                    },
                    Err(reason) => SignalRouteOutcome::RouteFailed {
                        verb: "propose".into(),
                        reason,
                    },
                }
            }
            SignalEmission::Associate(frame) => {
                match self.dispatcher.dispatch_associate(&self.handle, frame) {
                    Ok(true) => SignalRouteOutcome::Routed {
                        verb: "associate".into(),
                    },
                    Ok(false) => SignalRouteOutcome::RoutedButVerbStubbed {
                        verb: "associate".into(),
                    },
                    Err(reason) => SignalRouteOutcome::RouteFailed {
                        verb: "associate".into(),
                        reason,
                    },
                }
            }
            SignalEmission::MutateCandidate { row_id, kind } => {
                // §11.1: routed through `propose` for confirmation.
                // Build a ProposalFrame with kind=mutate_candidate
                // and the source mutation's case tag in the
                // justification so downstream consumers can identify
                // it.
                let frame = ProposalFrame {
                    target: row_id.clone(),
                    kind: ProposalKind::MutateCandidate,
                    justification: Some(format!("kind={}", kind.tag())),
                };
                match self.dispatcher.dispatch_propose(&self.handle, &frame) {
                    Ok(true) => SignalRouteOutcome::Routed {
                        verb: "propose".into(),
                    },
                    Ok(false) => SignalRouteOutcome::RoutedButVerbStubbed {
                        verb: "propose".into(),
                    },
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
