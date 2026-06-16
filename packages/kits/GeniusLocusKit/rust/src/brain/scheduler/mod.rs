// brain/scheduler/mod.rs — Rust mirror of the standing-signals
// scheduler. Re-exports the public surface used by the conformance
// gate in `tests/scheduler_parity.rs`.

pub mod api;
pub mod schedule;
pub mod serial_lane;

pub use api::{
    trigger_tag, AssociationFrame, ConcurrencyPolicy, ConditionPredicate, DiagnosticReport,
    MutationKind, ProposalFrame, ProposalKind, ResourceCostEstimate, SignalContext, SignalEmission,
    SignalID, SignalReport, SignalRouteOutcome, SignalSpec, SignalState, SignalTrigger,
    SubscriptionID, EMISSION_CLASS_TAGS,
};
pub use schedule::SchedulerError;
pub use serial_lane::{CoordinatorDispatcher, Dispatcher, NoopDispatcher, SerialLaneScheduler};
