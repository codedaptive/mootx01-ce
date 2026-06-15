// lib.rs — GeniusLocusKit Rust port.
//
// This crate mirrors the Swift implementation across the landed GLK
// sub-missions:
//   GLK-01 — EstateHandle value type, EstateCoordinator (open / close
//            / list / per-handle access), and the lattice-scoped read
//            fan-out across open estates.
//   GLK-02 — Unified nine-verb surface and frames mirrored against
//            AriaLexicon.
//   GLK-03 — Unified audit log, projection, and recovery folding
//            events from the LocusKit and CorpusKit storage tiers.
//   GLK-04 — Standing-signal scheduler (single-serial-dispatch lane
//            through QueueKit).
//   GLK-05 — Six v1 standing signals and default registration.
//   GLK-06 — Matrix tier: F, C, O, T family, calibration curves, NMF
//            latent factors, selectable in-memory or snapshotted
//            persistence.
//   GLK-07 — Training daemon: manifest-set transition-count threshold
//            gate, enrichment pipeline that folds the post-watermark
//            audit-log tail into the matrix tier, and the daemon
//            engine that composes the two with a held watermark.
//
// The theorem / performance gate (GLK-08) remains out of scope and
// ships in a later sub-mission.
//
// Conformance gate: the lattice-overlap routing, the verb / frame /
// acceptance enumeration, the unified audit log's content-hash shape,
// the scheduler, the six standing signals, the matrix tier, the
// training daemon, and the dormant-surfaces estate reads are all
// parity-tested against the Swift reference via shared inputs and
// expected outputs encoded in `tests/parity.rs`,
// `tests/verb_parity.rs`, `tests/audit_parity.rs`,
// `tests/scheduler_parity.rs`, `tests/standing_signals_parity.rs`,
// `tests/matrix_parity.rs`, `tests/training_parity.rs`, and
// `tests/dormant_surfaces.rs`.
// Whenever the Swift side changes a primitive, the Rust port must
// match bit-for-bit to keep the conformance contract honored. Per
// `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` §15 and the
// SubstrateLib pattern.

#![deny(rust_2018_idioms)]
#![deny(unused_must_use)]

pub mod audit;
pub mod brain;
pub mod branches;
pub mod coordinator;
// telemetry.rs — per-estate rollup metrics (GLK_ROLLUPS_001). Metric name
// constants and the `glk_emit!` macro. Emit sites live in coordinator.rs at
// open/close/provision/quiesce/drain and the verb-error remap boundary.
pub mod telemetry;
pub mod fan_out;
pub mod grants;
pub mod handle;
// hydration.rs — GLK-level hydrate-on-launch integration (Rust port of
// EstateHydration.swift). Exposes `open_hydrating`, `flush`, and the
// `composite_schema` declaration. Also adds `open_hydrating` to
// `EstateCoordinator` via an impl block.
pub mod hydration;
// intake.rs — Dual-Path Intake (G7): WriteMode, EncodeJob, the per-estate
// encode queue (D-B), mode-aware capture (D-A), and the pump-driven drain.
// Rust twin of EncodeJob.swift + EncodeIntake.swift.
pub mod intake;
pub mod matrix;
pub mod migration;
pub mod node_topology;
pub mod recall;
pub mod training;
pub mod verbs;

pub use audit::{
    AuditChainReport, AuditChainVerifier, AuditProjectionFold, AuditRecovery,
    AuditRecoveryDivergence, AuditRecoveryResult, AuditTier, RowMismatch, UnifiedAuditEntry,
    UnifiedAuditLog, UnifiedAuditValue, UnifiedAuditVerb, UnifiedProjection, UnifiedProjectionKey,
    UnifiedRowProjection,
};
// Re-export for NeuronKit B-1 constraint: event_lag_pairs is the estate-
// surface entry point for converting UnifiedAuditEntry → TemporalAuditEntry.
pub use brain::event_lag_pairs::event_lag_pairs;
pub use brain::scheduler::{
    trigger_tag as scheduler_trigger_tag, AssociationFrame as SchedulerAssociationFrame,
    ConcurrencyPolicy as SchedulerConcurrencyPolicy,
    ConditionPredicate as SchedulerConditionPredicate,
    CoordinatorDispatcher as SchedulerCoordinatorDispatcher,
    DiagnosticReport as SchedulerDiagnosticReport, Dispatcher as SchedulerDispatcher,
    MutationKind as SchedulerMutationKind, NoopDispatcher as SchedulerNoopDispatcher,
    ProposalFrame as SchedulerProposalFrame, ProposalKind as SchedulerProposalKind,
    ResourceCostEstimate as SchedulerResourceCostEstimate, SchedulerError, SerialLaneScheduler,
    SignalContext as SchedulerSignalContext, SignalEmission as SchedulerSignalEmission,
    SignalID as SchedulerSignalID, SignalReport as SchedulerSignalReport,
    SignalRouteOutcome as SchedulerSignalRouteOutcome, SignalSpec as SchedulerSignalSpec,
    SignalState as SchedulerSignalState, SignalTrigger as SchedulerSignalTrigger,
    SubscriptionID as SchedulerSubscriptionID, EMISSION_CLASS_TAGS,
};
pub use brain::signals::{
    default_standing_signal_names, default_standing_signal_specs, ByReferenceValiditySignal,
    DecaySweepSignal, DreamingSignal, EndOfDayTournamentSignal, MaintenanceSignal,
    VectorSimilaritySignal,
};
pub use migration::{ExternalCorpus, ExternalEntry};
// Dual-Path Intake (G7) public surface: the write mode and the encode-job
// payload. The coordinator methods (`capture_with_mode`, `mount_encode_queue`,
// `await_encode_drain`, `drain_encode_queue_once`) are inherent methods on
// `EstateCoordinator` and reachable through it directly.
pub use intake::{EncodeJob, WriteMode};
pub use hydration::{
    bridge_audit_event, composite_schema, open_hydrating, flush as glk_flush,
    HydratedEstate, HydrateError,
};
// GLK_PROVISION_001: estate provisioning and lifecycle types.
pub use coordinator::{
    EstateCoordinator, GeniusLocusKitError, VerbDispatchError,
    EstateKind, EstateMountState, EstateProvisionParams, SyncMode,
    FederatedRecallResult, FederatedReadRefusalReason,
    SyncEngineEntry, format_sync_state_token,
    ExpungeIntegritySweepResult,
};
pub use fan_out::{EstateRecallContribution, LatticeRegion};
pub use handle::EstateHandle;
// Re-exports for B-1-compliant reader types: NeuronKit readers import these
// from genius_locus_kit so they carry no direct locus_kit:: imports.
pub use locus_kit::adjectives::{AdjectiveExportability, AdjectiveSensitivity, State as DrawerState};
pub use locus_kit::container_fingerprint_store::{ContainerFingerprint, RoomLevelEntry};
pub use locus_kit::drawer::Drawer;
pub use locus_kit::recall_trace_item::RecallTraceItem;
pub use locus_kit::tunnel::Tunnel;
pub use matrix::{
    MatrixCalibrationBucket, MatrixCalibrationCurve, MatrixCalibrationOutcome,
    MatrixCalibrationRegistry, MatrixCoOccurKey, MatrixFieldCell, MatrixNMF,
    MatrixNMFFactorization, MatrixPersistenceBackend, MatrixPersistenceError,
    MatrixPersistenceMode, MatrixSnapshot, MatrixTemporalKey, MatrixTier, MatrixValueCoord,
};
pub use training::{
    EnrichmentPassResult, EnrichmentPipeline, TrainingDaemon, TrainingDaemonReport,
    TrainingDaemonTick, TrainingThresholdDecision, TrainingThresholdGate,
};
pub use node_topology::{MemoryTopologyProvider, NodeTopologyProvider};
pub use recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallResult, GLKRecallScoring,
    RecallEvidencePath, RecallFallbackPolicy, RecallHit, RecallLane,
    RecallOrigin, RecallPlan, RecallScoreVector, RecallUnionProfile, RecallWeights,
};
pub use verbs::{
    Acceptance, Adjective, AssociateFrame, CaptureFrame, ExpungeFrame, LatticeAnchor, LearnFrame,
    MutateFrame, MutationKind, Noun, NounRole, ProposeFrame, ReanchorFrame, RecallFrame,
    SurfaceTarget, Verb, VerbError, VerbFlow, WithdrawFrame, VERB_NAMES,
};
pub use grants::{
    CustodyMode, DecayFieldElement, DecayPolicy, DecayShareProvider, DriftRate, Grant, GrantError,
    GrantLifetime, GrantOptions, GrantScope, GrantStore, GrantStoreError, IssueGrantResult,
    LagrangeDecayKey, ReSharePermission, ReferenceDecayShareProvider, ScopeKeyVault, StoredGrant,
};
