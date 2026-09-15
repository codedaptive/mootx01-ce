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
pub use brain::fact_extraction_duty::FactExtractionBatchResult;

/// The product's active read-time converter: complete-form v6.
/// Compacts the complete source rather than selecting passages. Twin of Swift
/// `GeniusLocusKit.distillationConverter`. Every distilled rendering is
/// computed inline at read time from the verbatim content
/// (`hydration_representation::distilled_rendering`); nothing stores it.
/// Readers below GLK (CognitionKit, the CLI) take the converter from here,
/// never from the library directly, so the choice of converter lives in
/// exactly one place. The v23.2 ruleset stays in the library; nothing here
/// routes between converters.
pub const DISTILLATION_CONVERTER: context_distill_lib::converter::ContextDistillConverter =
    context_distill_lib::converter::ContextDistillConverter::CompleteFormV6;
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
pub mod estate_catalog;
pub mod estate_open_posture;
pub mod estate_format;
pub mod branches;
pub mod coordinator;
// recall_router.rs — estate recall route list: one ordered list consulted once
// per recall before the directive is read. Route 1 is the cross-encoder
// strict-transcript path gated on `cross_encoder_routing`. Mirrors
// RecallRouter.swift.
pub mod recall_router;
pub mod span_content_version;
pub mod encoder_activation;
pub use encoder_activation::{
    BundledModelDirectoryResolver, ModelDirectoryResolving, NilModelDirectoryResolver,
};
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
// The recall-hydration representation selector (content/distilled/tokenized
// variants, every one computed at read from the verbatim content).
pub mod hydration_representation;
// intake.rs — Dual-Path Intake (G7): WriteMode and mode-aware capture (D-A),
// the capture→encode ORCHESTRATION. The encode queue + drain + worker pool +
// retry + job payload now live in CorpusKit (corpus_ingest_queue.rs); GLK
// enqueues into the Corpus and coordinates the room rollup via on_encoded.
// Rust twin of EncodeIntake.swift.
pub mod intake;
pub mod matrix;
pub mod kg_fact_search_projection_backfill_gateway;
pub mod migration;
pub mod node_topology;
pub mod substrate_node_topology_provider;
pub mod recall;
pub mod recall_explainer;
pub mod span_rerank;
// The retrieval-time cross-encoder stage (fusion rule, span selection,
// report). Twin of Swift RecallDirector/CrossEncoderStage.swift.
pub mod cross_encoder_stage;
pub mod recall_signal_budget;
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
    default_standing_signal_names, default_standing_signal_specs, FactExtractionSignal, SpanEncodeSignal,
    AssociationEdgeChecker, ByReferenceValiditySignal, ConsolidationSignal, DecaySweepSignal,
    DreamingSignal, EndOfDayTournamentSignal, MaintenanceSignal,
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
    DatasetFilingError, EstateCoordinator, GeniusLocusKitError, VerbDispatchError,
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
pub use estate_open_posture::{EstateOpenPosture, EstateOpenPostureError, EstateOpenPostureKind};
pub use estate_catalog::{
    EstateBackend, EstateCatalog, EstateCatalogError, EstateCatalogNames, EstateManifest,
    EstateManifestEncryption, EstateRecord, EstateRecordKind, EstateSelector,
};
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
pub use locus_kit::frames::TunnelCaptureFrame;
pub use locus_kit::dataset_handle::DatasetColumnSummary;
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
    GLKRecallMode, GLKRecallRequest, GLKRecallResult, GLKRecallScoring, GLKSubSpanScoring,
    GraphCache, PreferenceStore,
    RecallEvidencePath, RecallFallbackPolicy, RecallHit, RecallLane,
    RecallOrigin, RecallPlan, RecallScoreVector, RecallShape, RecallUnionProfile, RecallWeights,
};
/// Request-borne rerank contract re-exported for recipes.  This keeps
/// CognitionKit downstream of GLK rather than adding a direct CorpusKit edge.
pub use corpus_kit::encoder::RerankDirective;
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
