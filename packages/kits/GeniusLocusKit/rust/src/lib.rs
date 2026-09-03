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
//   NT-G1  — SubstrateNodeTopologyProvider adapter (String↔UUID bridge
//            over LocusKit NodeStore, auto-registered on estate open).
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

/// The product's active dense-context converter: intent-span v23.2, the
/// attributed peer-dialogue ruleset (activated 2026-09-03 per the addendum
/// to DECISION_CONTEXTDISTILLLIB_2026-09-02). Twin of Swift
/// `GeniusLocusKit.distillationConverter`. Its ID is written to
/// `distilled_pipeline_version` on every distillation beside the SHA-256
/// digest of the complete content the representation was rendered from
/// (`distilled_source_digest`); `distilled_representation_is_current`
/// compares both, so bumping the converter re-distills each estate lazily
/// through the sweep and eagerly through the Redistill recipe. The v22
/// ruleset stays in the library; nothing here routes between converters.
/// Readers below GLK (CognitionKit, the CLI) take the ID from here, never
/// from the library directly, so the choice of converter lives in exactly
/// one place.
pub const DISTILLATION_CONVERTER: context_distill_lib::converter::ContextDistillConverter =
    context_distill_lib::converter::ContextDistillConverter::IntentSpanV23Attributed;

/// The converter ID written to `distilled_pipeline_version`. Twin of Swift
/// `GeniusLocusKit.distillationConverterID`.
pub fn distillation_converter_id() -> &'static str {
    DISTILLATION_CONVERTER.id()
}

/// The one representation-currency rule (both ports, one function): a
/// drawer's stored representation is current iff bit 19 is set, its
/// converter ID equals `distillation_converter_id()`, AND its stored source
/// digest equals `source_digest(content)` — the digest of the complete
/// content beside it. A `None` digest (written before the digest column
/// existed) is stale by definition. Every regeneration decision — the sweep,
/// the drain-stage rider, seeding, and the awaiting-reindex probe — keys on
/// this rule; the storage-level aggregates in LocusKit apply the half SQL
/// can see (converter ID and digest NULL-ness). Requires a fully hydrated
/// drawer: at the structured projection `content` is empty and the digest
/// comparison would read stale. Pure: no I/O, no clock. Twin of Swift
/// `GeniusLocusKit.distilledRepresentationIsCurrent(_:)`.
pub fn distilled_representation_is_current(drawer: &locus_kit::drawer::Drawer) -> bool {
    drawer.has_current_representation()
        && drawer.distilled_pipeline_version.as_deref() == Some(distillation_converter_id())
        && drawer.distilled_source_digest.as_deref()
            == Some(context_distill_lib::digest::source_digest(&drawer.content).as_str())
}
// packager.rs — GLKResultsPackager Rust port (PACKAGER mission). Post-recall,
// pre-presentation packager: gate signals, confidence levels, cliff cutoff,
// and the packed result type consumed by the ARIA boundary. Mirrors
// GeniusLocusKit/RecallDirector/GLKResultsPackager.swift.
pub mod packager;
// dataset_signatures.rs — MX-TAB-5 layered dataset signatures.
// Tier-1 table SHA-256 + tier-2 per-column SHA-256 fingerprints computed from
// schema + sampled content. Byte-identical mirror of
// GeniusLocusKit/Sources/GeniusLocusKit/Intake/DatasetSignatures.swift.
pub mod dataset_signatures;
pub mod estate_format;
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
// The SPEC_DISTILLATION_STORAGE §10.1 recall-hydration representation
// selector (content/distilled/tokenized variants, computed at read).
pub mod hydration_representation;
// intake.rs — Dual-Path Intake (G7): WriteMode and mode-aware capture (D-A),
// the capture→encode ORCHESTRATION. The encode queue + drain + worker pool +
// retry + job payload now live in CorpusKit (corpus_ingest_queue.rs); GLK
// enqueues into the Corpus and coordinates the room rollup via on_encoded.
// Rust twin of EncodeIntake.swift.
pub mod intake;
pub mod matrix;
pub mod migration;
pub mod node_topology;
pub mod substrate_node_topology_provider;
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
    MutationKind as SchedulerMutationKind,
    ProposalFrame as SchedulerProposalFrame, ProposalKind as SchedulerProposalKind,
    ResourceCostEstimate as SchedulerResourceCostEstimate, SchedulerError, SerialLaneScheduler,
    SignalContext as SchedulerSignalContext, SignalEmission as SchedulerSignalEmission,
    SignalID as SchedulerSignalID, SignalReport as SchedulerSignalReport,
    SignalRouteOutcome as SchedulerSignalRouteOutcome, SignalSpec as SchedulerSignalSpec,
    SignalState as SchedulerSignalState, SignalTrigger as SchedulerSignalTrigger,
    SubscriptionID as SchedulerSubscriptionID, EMISSION_CLASS_TAGS,
    // stream_id stamped on every signal Job sent to the
    // shared per-estate queue.sqlite. The drain loop uses drain_for_stream to
    // claim only "signals" jobs, leaving encode jobs or dreaming jobs untouched.
    SIGNAL_STREAM_ID,
};
// Test-only stub dispatcher — compiled out of production (see serial_lane.rs).
// Reachable from integration tests via the `test-seams` feature.
#[cfg(any(test, feature = "test-seams"))]
pub use brain::scheduler::NoopDispatcher as SchedulerNoopDispatcher;
pub use brain::signals::{
    default_standing_signal_names, default_standing_signal_specs, AdornmentPassSignal,
    AssociationEdgeChecker, ByReferenceValiditySignal, ConsolidationSignal, DecaySweepSignal,
    DistillationSignal, DreamingSignal, EndOfDayTournamentSignal, MaintenanceSignal,
    TemporalCausalitySignal, TrainingSignal, VectorSimilaritySignal,
};
pub use migration::{
    run_parallel, verify_migration, ExternalCorpus, ExternalEntry, MigrationDivergence,
    MigrationError, MigrationVerification, ParallelCaptureMode, ParallelRunHandle,
};
// Dual-Path Intake (G7) public surface: the write mode. The coordinator
// methods (`capture_with_mode`, `await_encode_drain`, `reindex_missing`) are
// inherent methods on `EstateCoordinator` and reachable through it directly;
// they delegate the encode mechanism to the estate's Corpus (CorpusKit owns the
// ingest queue + drain + worker pool).
pub use intake::WriteMode;
pub use hydration::{
    bridge_audit_event, composite_schema, open_hydrating, flush as glk_flush,
    HydratedEstate, HydrateError,
};
// GLK_PROVISION_001: estate provisioning and lifecycle types.
pub use coordinator::{
    EstateCoordinator, GeniusLocusKitError, VerbDispatchError,
    EstateKind, EstateLifetime, EstateMountState, EstateProvisionParams, SyncMode,
    FederatedRecallResult, FederatedReadRefusalReason,
    SyncEngineEntry, format_sync_state_token,
    ExpungeIntegritySweepResult, ExpungeVerbOutcome, DrainStatus,
    SubjectProducer, SubjectBackfillReport,
    // dreaming-queue job payload. Public so the drainer
    // (a downstream crate) and integration tests can decode queue.sqlite payloads.
    DreamingItem,
    // W4: optimizer-owned recall tuning envelope. Public so NeuronKit and the
    // ARIA boundary can read/write it without reaching into coordinator internals.
    RecallTuningManifest,
};
pub use fan_out::{EstateRecallContribution, LatticeRegion};
pub use handle::EstateHandle;
// Re-export the encode-speed knob so consumers that depend on GeniusLocusKit
// (VaultKit's PalaceBridge, AriaMcpKit) can name it without a direct CorpusKit
// dependency. `.foreground` / `.background` select the drain's embedding QoS;
// write strategy is size-gated separately. (Swift defines a distinct GLK enum
// that maps to CorpusKit's, because Swift forbids using an imported enum's cases
// in a default argument; Rust has no such restriction, so a re-export suffices.)
pub use corpus_kit::corpus::EncodeSpeed;
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
pub use substrate_node_topology_provider::SubstrateNodeTopologyProvider;
pub use recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallResult, GLKRecallScoring,
    GraphCache, PreferenceStore,
    RecallEvidencePath, RecallFallbackPolicy, RecallHit, RecallLane,
    RecallOrigin, RecallPlan, RecallScoreVector, RecallShape, RecallUnionProfile, RecallWeights,
};
// PACKAGER mission: GLKResultsPackager public surface. Re-exported from
// packager.rs so downstream crates (AriaMcpKit) import from `genius_locus_kit`
// without reaching into module internals.
pub use packager::{
    GLKAnswerBlock, GLKConfidenceSignals, GLKPackagedResult, GLKResponseLevel,
    GLKResultsPackager, PackagerAnswerMode, PackagerConfidenceLevel, PackagerThresholds,
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
