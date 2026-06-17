// coordinator.rs — EstateCoordinator: the estate registry and the full
// nine-verb dispatch surface, the Rust parity of the Swift `GeniusLocusKit`
// actor (Sources/GeniusLocusKit/GeniusLocusKit.swift + Verbs/VerbSurface.swift).
//
// The registry holds a live `locus_kit::Estate` per open handle; all nine
// verbs delegate to it exactly as the Swift `extension GeniusLocusKit` verbs
// delegate to `estate(for: handle)`. All nine verbs (capture/recall/mutate/
// withdraw/expunge/reanchor/learn/propose/associate) reach a real Estate
// implementation; `NotSupportedByEstate` is the generic dispatch error an
// estate raises for a verb it does not implement (see `remap` below),
// matching the Swift surface on both legs.
//
// The boundary guards (EmptyReanchor at reanchor, ExpungeNotConfirmed at
// expunge) fire before any estate dispatch, parity of the Swift guards.
//
// The parity taxonomy (VerbError, VERB_NAMES, Verb, Noun, SurfaceTarget)
// lives in `verbs::lexicon` and is imported by both this coordinator and
// the parity tests.
//
// Scored recall (recall_scored): the nine-verb recall path is supplemented
// by recall_scored(handle, request: GLKRecallRequest) -> Result<GLKRecallResult>.
// This is ADDITIVE — the plain recall(handle, frame, now) method is unchanged
// and all existing callers (CognitionKit recipes, ARIA_MCP, branches) continue
// to use it. recall_scored mirrors the Swift RecallDirector extension on
// GeniusLocusKit (Sources/GeniusLocusKit/RecallDirector/RecallDirector.swift).
//
// Scoring modes implemented:
//   GLKRecallMode::LocusOnly — bitmap-index scan with RecallScoreVector::locus(1.0)
//   GLKRecallMode::Hybrid   — all three lanes active when corpus/vector registered:
//                              locus (bitmap), BM25 (CorpusKit), vector (VectorKit).
//                              RRF fusion (k=60) over all populated lists.
//                              Falls back to rank-normalised locus-only when neither
//                              corpus nor vector store is registered for the handle.
//   GLKRecallMode::CorpusOnly — BM25 + vector lanes. If corpus/vector absent,
//                              falls back to rank-normalised locus-only.
//   GLKRecallMode::UnionBest — all three lanes + union profile. Same fallback.
//   GLKRecallMode::NodeTreeNative — host-tree topology path; tree edges are
//                              frozen once per recall_tunnels call (G1) and
//                              unioned with estate tunnel edges for the
//                              structural lens path. Drawer retrieval delegates
//                              to the LocusOnly bitmap lane.
// All modes produce a GLKRecallResult. The scoring strategy (.raw / .rrf /
// .matrixAware) changes the final score math, producing ranked ≠ substring results.

use std::collections::HashMap;
use std::sync::Arc;

// ConvergenceKit: sync-backend abstraction. `SyncEngine` trait + `SyncState` enum
// are imported so GLK can store the active engine per estate and surface the real
// sync state through `sync_state_token`. Only the base protocol crate is imported;
// backend-specific crates (NoSyncEngine, FederationSyncEngine) are injected by callers.
use convergence_kit::engine::SyncEngine;
use convergence_kit::types::SyncState;

// IntellectusLib: per-estate rollup telemetry (GLK_ROLLUPS_001).
// Off-path cost: single AtomicBool::load(Acquire) + branch — zero allocation.
// `Intellectus` and `StatSample` are consumed inside the `glk_emit!` macro
// expansion, which is why they appear to the compiler as unused at the
// call sites. The macro re-qualifies them via `intellectus_lib::` rather than
// importing them here, so these imports can be dropped.
use crate::telemetry::metric_names;
use crate::glk_emit;

use corpus_kit::corpus::{Corpus, EmbeddingModelConfig};
use vectorkit::vector_store::VectorStore;
use persistence_kit::storage::Storage;
use persistence_kit::inmemory::InMemoryStorage;
use locus_kit::diary_entry::DiaryEntry;
use locus_kit::drawer::Drawer;
use uuid::Uuid;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::error::LocusKitError;
use locus_kit::recall_trace_item::RecallTraceItem;
use locus_kit::estate::Estate;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::RecallFrame;
use locus_kit::frames::{AssociateFrame as LocusAssociateFrame, CaptureFrame, LearnFrame as LocusLearnFrame, MutationKind, ProposeFrame as LocusProposeFrame};
use locus_kit::tunnel::Tunnel;

use crate::grants::{
    CustodyMode, Grant, GrantError, GrantOptions, IssueGrantResult, GrantStore, ScopeKeyVault,
};
use crate::handle::{EstateHandle, EstateUuid};
use crate::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallResult, GLKRecallScoring,
    RecallEvidencePath, RecallHit, RecallOrigin, RecallPlan, RecallScoreVector,
    RecallShape, RecallUnionProfile, RecallWeights,
};
use crate::verbs::lexicon::VerbError;

/// Errors raised by the GeniusLocusKit composition surface on the Rust
/// side. Mirrors the Swift `GeniusLocusKitError`; cases carry the same
/// identifying data so parity tests match behaviour across ports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GeniusLocusKitError {
    /// Caller passed a manifest that violates the kit's preconditions.
    InvalidManifest { key: String, detail: String },

    /// A handle was used after the estate it referenced was closed, or a
    /// handle that was never issued by this coordinator was passed in.
    EstateNotOpen { estate_uuid: EstateUuid },

    /// An attempt to open an estate whose UUID matches one already in the
    /// registry. Estate UUIDs are immutable per spec § 7.7, so a duplicate
    /// is almost always the same database file being opened twice.
    DuplicateEstate { estate_uuid: EstateUuid },

    /// Caller asked for a fan-out region whose `low` exceeds its `high`.
    InvalidLatticeRegion { low: i64, high: i64 },

    /// `Estate::open` failed on the underlying store (bad manifest, layout
    /// mismatch, empty owner). Carries the textual cause; the Swift side
    /// lets the LocusKit error propagate from `Estate.open`.
    EstateOpenFailed { detail: String },

    /// An estate was referenced while it is quiesced and not accepting new work.
    /// Mirrors Swift `GeniusLocusKitError.estateQuiesced`.
    EstateQuiesced { estate_uuid: EstateUuid },

    /// `destroy` was called on an estate that has not been closed. Callers must
    /// call `close` or `destroy` (which closes internally) — not both raw paths
    /// simultaneously. Mirrors Swift `GeniusLocusKitError.destroyRequiresClose`.
    DestroyRequiresClose { estate_uuid: EstateUuid },

    /// An underlying estate failure propagated out of a GLK provision or lifecycle
    /// operation. Mirrors Swift `GeniusLocusKitError.underlyingEstateFailure`.
    UnderlyingEstateFailure { reason: String },

    /// A cross-estate federated read was refused because the source estate
    /// holds no active, unexpired grant naming the requester as grantee.
    /// Mirrors Swift `GeniusLocusKitError.crossEstateReadRefused`. The
    /// `reason` distinguishes no-grant from expired-grant so callers can
    /// surface the appropriate message.
    CrossEstateReadRefused {
        source: uuid::Uuid,
        requester: uuid::Uuid,
        reason: FederatedReadRefusalReason,
    },
}

/// Why a federated read was refused. Mirrors Swift `FederatedReadRefusalReason`.
///
/// Carried by `GeniusLocusKitError::CrossEstateReadRefused`. Variants
/// distinguish "never authorized", "authorization lapsed", "budget
/// exhausted", and "custody mode refused" so the caller can surface a
/// meaningful message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FederatedReadRefusalReason {
    /// No active (non-revoked) grant names the requester.
    NoActiveGrant,
    /// A matching grant exists but its lifetime elapsed at `now`.
    GrantExpired,
    /// The grant was revoked. Normally unreachable via the active-grant
    /// path (revoked grants are excluded from `GrantStore::active`), but
    /// included for completeness and future-proofing.
    GrantRevoked,
    /// The grant's `inference_remaining_budget` reached zero. Every
    /// federated recall debits `BUDGET_DEBIT_PER_READ` (0.01 per read,
    /// ~100 reads on a full 1.0 budget). Budget <= 0 refuses all reads.
    ///
    /// Chosen rule (spec §6 is silent on debit quantum; fail-closed wins):
    /// debit = 0.01 per read. A fresh grant (budget=1.0) supports ~100
    /// reads. Mirrors Swift `FederatedReadRefusalReason.budgetExhausted`.
    BudgetExhausted,
    /// The grant's `custody_mode` refused the recall at the cryptographic
    /// gate. Specific sub-reasons (mirrors Swift `.custodyRefused`):
    ///   - `Mediated` (mode 1): vault does not hold the scope key.
    ///   - `HandedOver` (mode 2): never raises this; expiry check covers it.
    ///   - `DecayDerived` (mode 3): lifetime expiry covers it; never raises this.
    ///   - `TimeAging` (mode 4): effective content level decayed to 0 (floor 0).
    CustodyRefused,

}

/// The outcome of a successful grant-gated cross-estate federated read.
///
/// Mirrors Swift `FederatedRecallResult`. Returned by
/// `EstateCoordinator::federated_recall` when the source estate holds
/// an active, unexpired grant naming the requester as grantee.
/// Content-level and scope filtering have already been applied; `drawers`
/// contains only rows the authorizing grant permits.
#[derive(Debug)]
pub struct FederatedRecallResult {
    /// Filtered drawers from the source estate.
    pub drawers: Vec<Drawer>,
    /// The grant that authorized this read.
    pub grant: Grant,
    /// The estate whose content was read (the grantor).
    pub source_handle: EstateHandle,
    /// The estate that requested the read (the grantee named on `grant`).
    pub requester_handle: EstateHandle,
}

// MARK: - GLK_PROVISION_001 types

/// Kind of estate to provision. Controls which sub-stores GLK wires on
/// `provision`. Mirrors Swift `EstateKind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstateKind {
    /// Full composition: LocusKit + VectorStore + Corpus.
    Glk,
    /// LocusKit core + Corpus only. No standalone VectorStore.
    CorpusOnly,
    /// LocusKit only. No Corpus, no VectorStore.
    LocusOnly,
}

impl EstateKind {
    /// Render the kind as the raw-value prefix stored in the manifest's
    /// `framework_profile` field. Mirrors Swift `EstateKind.rawValue`.
    pub fn raw_value(&self) -> &'static str {
        match self {
            EstateKind::Glk        => "GLK",
            EstateKind::CorpusOnly => "CorpusOnly",
            EstateKind::LocusOnly  => "LocusOnly",
        }
    }
}

/// Sync mode recorded in the estate's manifest. Mirrors Swift `SyncMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncMode {
    None,
    CloudKit,
    Federation,
}

impl SyncMode {
    /// Encode to the `active_storage_mode` manifest integer.
    /// 0 = None, 1 = CloudKit, 2 = Federation. Mirrors Swift
    /// `syncModeToStorageMode` in `EstateLifecycle.swift`.
    pub fn to_storage_mode(self) -> i64 {
        match self {
            SyncMode::None        => 0,
            SyncMode::CloudKit    => 1,
            SyncMode::Federation  => 2,
        }
    }
}

/// Provisioning parameters for `EstateCoordinator::provision`.
/// Mirrors Swift `EstateProvisionParams`.
#[derive(Debug, Clone)]
pub struct EstateProvisionParams {
    pub estate_name: String,
    pub kind: EstateKind,
    pub zoom_window_low: i64,
    pub zoom_window_high: i64,
    pub framework_profile: String,
    pub sync_mode: SyncMode,
}

/// Lifecycle state for an open estate. Mirrors Swift `EstateMountState`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstateMountState {
    /// Estate is open and accepting new work.
    Mounted,
    /// Estate has stopped accepting new work but is still open.
    Quiesced,
    /// Estate is finishing in-flight work before quiescing.
    Draining,
    /// Estate is closed. This state is transitional; the handle is removed
    /// from the registry immediately after.
    Unmounted,
}

/// The outcome of a single-estate expunge integrity sweep.
///
/// `remediated_count`: rows that were tombstoned without an audit event,
/// had their cross-kit delete re-attempted, and were sealed with a
/// "tombstone" (success) audit.
///
/// `orphaned_count`: rows that were tombstoned without an audit event,
/// had their cross-kit delete re-attempted, but the re-attempt also failed;
/// sealed with an "expungeOrphan" audit so the row is now auditable.
///
/// `per_row_errors`: one string per row that could not be remediated,
/// pairing the row_id with the failure reason. The sweep is partial-success:
/// rows that could be remediated are sealed; failures are collected here
/// and do not block other rows from being processed.
///
/// An `Err` return from `run_expunge_integrity_sweep` indicates a fatal
/// query failure (the orphan-query itself could not execute) rather than
/// a per-row remediation failure. Per-row failures are always returned in
/// `per_row_errors`, never as `Err`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ExpungeIntegritySweepResult {
    /// Rows successfully re-deleted and sealed with the success audit.
    pub remediated_count: usize,
    /// Rows where the re-delete also failed; sealed with expungeOrphan.
    pub orphaned_count: usize,
    /// Per-row error strings for rows that could not be remediated and
    /// could not be sealed as expungeOrphan either. Format: "row_id: reason".
    pub per_row_errors: Vec<String>,
}

/// The outcome of a verb dispatch. Rust needs a typed error where Swift
/// uses untyped `throws` over two domains: `estate(for:)` throwing
/// `GeniusLocusKitError.estateNotOpen` (outside the per-verb do/catch), and
/// the verb body throwing `VerbError`. This union encodes both faithfully
/// without altering the parity-gated `VerbError` enum.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VerbDispatchError {
    /// The addressed estate was not open (parity of the Swift
    /// `GeniusLocusKitError.estateNotOpen` a verb propagates).
    EstateNotOpen { estate_uuid: EstateUuid },
    /// A verb-surface failure (boundary guard, underlying estate failure,
    /// or not-supported), parity of the Swift `VerbError`.
    Verb(VerbError),
}

impl From<VerbError> for VerbDispatchError {
    fn from(e: VerbError) -> Self {
        VerbDispatchError::Verb(e)
    }
}

/// Remap a LocusKit estate error to the verb surface's `VerbError`, parity
/// of the Swift `remap(verb:error:)`: a `NotSupported` (or an
/// `InvalidContent` whose message contains "not yet implemented") becomes
/// `NotSupportedByEstate`; anything else is an `UnderlyingEstateFailure`.
/// All nine ARIA verbs are live; this remains the generic fallback for any
/// verb whose dependency is unavailable. (The GLK-error passthrough Swift's
/// remap does is handled in Rust by `estate_for` surfacing `EstateNotOpen`
/// before the verb body runs.)
///
/// When `estate_id` is non-empty, emits a `geniuslocus.estate.verb_error`
/// metric through IntellectusLib (GLK_ROLLUPS_001). Mirrors the Swift
/// `remap(verb:estateID:error:)` signature extension; callers that cannot
/// provide an estate id pass `""` (no metric emitted).
fn remap(verb: &str, estate_id: &str, error: LocusKitError) -> VerbError {
    // NotSupported is the canonical fail-loud path for a verb whose
    // dependency is unavailable. Mapped to NotSupportedByEstate so ARIA
    // callers get a clear, typed response rather than an opaque
    // UnderlyingEstateFailure.
    if let LocusKitError::NotSupported(_) = &error {
        return VerbError::NotSupportedByEstate {
            verb: verb.to_string(),
        };
    }
    if let LocusKitError::InvalidContent(detail) = &error {
        if detail.contains("not yet implemented") {
            return VerbError::NotSupportedByEstate {
                verb: verb.to_string(),
            };
        }
    }
    // Telemetry: emit verb_error at the estate boundary (GLK_ROLLUPS_001).
    // Only emit when the estate_id is known (i.e. the estate was open and
    // routing succeeded; EstateNotOpen is handled before remap is called).
    if !estate_id.is_empty() {
        let eid = estate_id.to_string();
        let v = verb.to_string();
        glk_emit!(metric_names::VERB_ERROR, 1.0, {
            let mut tags = HashMap::new();
            tags.insert("estate_id".to_string(), eid);
            tags.insert("verb".to_string(), v);
            tags
        });
    }
    VerbError::UnderlyingEstateFailure {
        verb: verb.to_string(),
        reason: format!("{error:?}"),
    }
}

/// Convert a raw `[u8; 16]` estate UUID to a hyphenated lowercase UUID string.
///
/// Used by telemetry emit sites to produce a human-readable `estate_id` tag
/// without calling Uuid::new_v4 or any allocation unless monitoring is enabled.
/// The Uuid crate is already in Cargo.toml dependencies (required by EstateCoordinator
/// for `Uuid::new_v4()` elsewhere in this file).
#[inline]
fn uuid_to_str(bytes: &[u8; 16]) -> String {
    Uuid::from_bytes(*bytes).to_string()
}

/// Maps the Brain layer's `ProposalKind` (routing-queue labels from
/// `brain::scheduler::api`) to the substrate's `locus_kit::ProposalKind`
/// (cookbook §2.4 bitmap axis). The two vocabularies operate at different
/// altitudes; this function is the single translation point per the
/// mission's two-vocabulary architecture.
///
/// Mapping rules (Brain label → substrate axis):
///   - ByReferenceDrift     → NewTunnel (closest structural analogue)
///   - TournamentUpdate     → MutateDrawer
///   - MiningPattern        → MiningPatternAdjustment
///   - DisciplineViolation  → RecordObservation
///   - MutateCandidate      → MutateDrawer
///   - Amend                → MutateDrawer
///   - TestPropose          → NewTunnel (test scaffold)
///   - Other                → NewTunnel (safe fallback)
fn map_brain_kind_to_substrate(
    brain_kind: &crate::brain::scheduler::api::ProposalKind,
) -> locus_kit::proposal_operational::ProposalKind {
    use crate::brain::scheduler::api::ProposalKind as BrainKind;
    use locus_kit::proposal_operational::ProposalKind as SubstrateKind;
    match brain_kind {
        BrainKind::ByReferenceDrift    => SubstrateKind::NewTunnel,
        BrainKind::TournamentUpdate    => SubstrateKind::MutateDrawer,
        BrainKind::MiningPattern       => SubstrateKind::MiningPatternAdjustment,
        BrainKind::DisciplineViolation => SubstrateKind::RecordObservation,
        BrainKind::MutateCandidate     => SubstrateKind::MutateDrawer,
        // Enrichment / Q-ID assignment mutates the target drawer's anchor.
        BrainKind::Enrichment          => SubstrateKind::MutateDrawer,
        BrainKind::Amend               => SubstrateKind::MutateDrawer,
        BrainKind::TestPropose         => SubstrateKind::NewTunnel,
        BrainKind::Other(_)            => SubstrateKind::NewTunnel,
    }
}

/// A paired sync engine and its human-readable backend label.
///
/// Stored in `EstateCoordinator::sync_engines[handle]`. The `backend_name` is
/// set once at registration and is immutable for the engine's lifetime on that
/// handle. Re-registering replaces the entry entirely.
///
/// Mirrors Swift `SyncEngineEntry` in `SyncEngineAPI.swift`.
pub struct SyncEngineEntry {
    /// The active sync engine, erased to the `SyncEngine` trait object.
    pub engine: Box<dyn SyncEngine>,
    /// Human-readable backend label: "none", "cloudkit", or "federation".
    /// Callers supply this because Rust trait objects cannot recover the
    /// concrete type name from a `Box<dyn SyncEngine>`.
    pub backend_name: String,
}

/// Convert a ConvergenceKit `SyncState` + backend name to the canonical sync token.
///
/// This is the single formatting function for the `sync:` field in
/// `moot_estate_status`. The Swift port mirrors this logic in
/// `syncStateDescription` in `SyncEngineAPI.swift`. Any vocabulary change here
/// MUST be reflected in the Swift port and in `ARIA_MCP_INTERFACE.md`.
///
/// Vocabulary (parity contract — Swift and Rust must emit identical tokens):
///   "local-only"                              — no engine registered
///   "<backend> (idle)"                        — engine disabled
///   "<backend> (enabled, zone: <z>)"          — engine enabled (non-federation)
///   "federation (in-process, zone: <z>)"      — federation enabled (v1.0 in-process)
///   "<backend> (syncing, direction: <d>)"     — engine mid-sync
///   "<backend> (error: <e>)"                  — engine error state
pub fn format_sync_state_token(state: &SyncState, backend_name: &str) -> String {
    match state {
        SyncState::Disabled => format!("{backend_name} (idle)"),
        SyncState::Enabled { zone, .. } => {
            if backend_name == "federation" {
                // Federation wire transport is in-process at v1.0 per architecture ruling.
                // Report "in-process" rather than "connected" to avoid over-promising
                // a network transport that does not yet exist in production.
                format!("federation (in-process, zone: {zone})")
            } else {
                format!("{backend_name} (enabled, zone: {zone})")
            }
        }
        SyncState::Syncing { direction } => {
            format!("{backend_name} (syncing, direction: {direction:?})")
        }
        SyncState::Errored { error, .. } => {
            format!("{backend_name} (error: {error:?})")
        }
    }
}

/// The coordinator. Owns the registry of currently-open estates and is the
/// live verb-dispatch surface. Construction is cheap; the registry starts
/// empty. Callers admit estates via `open` and address them by
/// `EstateHandle` thereafter.
///
/// It also owns the COW-branch registry (`branches`), parity of the Swift
/// actor's `branches: [BranchID: EstateBranch]`: branches are inserted by
/// `glk_derive_branch` and retained through every lifecycle state so the
/// audit trail stays reachable (I-15). The branch verbs live in
/// `branches.rs` as an `impl EstateCoordinator` block.
///
/// Grant subsystem fields (`grant_stores`, `scope_vaults`) are parallel
/// maps indexed by `EstateHandle`. One `GrantStore` and one `ScopeKeyVault`
/// per open estate, inserted on `open` and removed on `close`. Mirror of
/// the Swift actor's `grantStore(for:)` and `scopeVault(for:)` accessors.
///
/// Corpus and vector store registrations (`corpus_kits`, `vector_stores`)
/// are optional per-estate handles that activate the BM25 and vector recall
/// lanes in `recall_scored`. Callers wire them via `register_corpus` and
/// `register_vector_store` after opening the estate. Absent registrations
/// cause Hybrid/CorpusOnly/UnionBest to fall back to locus-only ranked
/// scoring — the same behavior as before CorpusKit/VectorKit were wired.
/// Mirroring the Swift actor's `corpusKits` and `vectorStores` dictionaries.
pub struct EstateCoordinator {
    registry: HashMap<EstateHandle, Estate>,
    pub(crate) branches: HashMap<crate::branches::BranchId, crate::branches::EstateBranch>,
    /// Per-estate grant stores. Parallel to `registry`.
    grant_stores: HashMap<EstateHandle, GrantStore>,
    /// Per-estate scope key vaults. Parallel to `registry`.
    scope_vaults: HashMap<EstateHandle, ScopeKeyVault>,
    /// Per-estate CorpusKit handles. Optional; activates BM25 lane in recall_scored.
    /// Mirrors Swift actor's `corpusKits: [EstateHandle: Corpus]`.
    corpus_kits: HashMap<EstateHandle, Arc<Corpus>>,
    /// Per-estate VectorKit handles. Optional; activates vector lane in recall_scored.
    /// Mirrors Swift actor's `vectorStores: [EstateHandle: VectorStore]`.
    vector_stores: HashMap<EstateHandle, Arc<VectorStore>>,
    /// Per-estate mount state. Set to `Mounted` on open, updated by quiesce/drain,
    /// removed on close. Mirrors Swift actor's `mountStates: [EstateHandle: EstateMountState]`.
    mount_states: HashMap<EstateHandle, EstateMountState>,
    /// Per-estate dedicated encode queue (Dual-Path Intake D-B). Mounted at
    /// provision for estates with a Corpus; carries the EncodeJob queue, its HLC,
    /// and the encode stream id. Mirrors Swift actor's `encodeQueues` /
    /// `encodeHLCs`. There is no parallel drain-worker map: the synchronous Rust
    /// port has no background worker (the drain is pump-driven — see intake.rs).
    pub(crate) encode_queues: HashMap<EstateHandle, crate::intake::EncodeQueue>,
    /// Per-estate unified audit-log G-Set. Minted empty on `open`, fed from
    /// the estate's LocusKit audit trail by `feed_audit_log`, and read back by
    /// `current_audit_log` for the maintenance reader's audit-integrity input.
    /// Mirrors the Swift actor's `auditLogs: [EstateHandle: UnifiedAuditLog]`.
    audit_logs: HashMap<EstateHandle, crate::audit::UnifiedAuditLog>,
    /// Per-estate recall-scoring matrix tier. Registered by
    /// `register_matrix_tier` (called from `rebuild_derived_accelerators` and
    /// the hydration path), read by the `matrixAware` recall lane. Absent ⇒
    /// all matrix score columns read 0.0, correct for a fresh estate. Mirrors
    /// the Swift actor's `matrixTiers: [EstateHandle: MatrixTier]`.
    matrix_tiers: HashMap<EstateHandle, crate::matrix::MatrixTier>,
    /// Per-estate host-tree topology providers for the `NodeTreeNative` recall
    /// mode and the structural lens path.
    ///
    /// Populated via `register_node_topology`. When present, `recall_tunnels`
    /// calls `provider.tree_edges(None)` EXACTLY ONCE at the top of the call
    /// (G1 — read-once-and-freeze) and unions the returned containment edges with
    /// the estate's stored tunnel edges before returning. When absent,
    /// `recall_tunnels` returns only stored tunnels (existing behaviour,
    /// unchanged). Dropped when the estate is closed.
    ///
    /// Topology boundary invariant (G4): this registry stores ONLY the
    /// three-method `NodeTopologyProvider` adapter — no content is accessible
    /// through it. Any node-content need routes through CorpusKit.
    /// Mirrors Swift actor's `nodeTopologyProviders: [EstateHandle: any NodeTopologyProvider]`.
    node_topology_providers: HashMap<EstateHandle, Arc<dyn crate::node_topology::NodeTopologyProvider>>,

    /// Per-estate active sync engine entry (ConvergenceKit backend + label).
    ///
    /// Registered via `register_sync_engine`. When present, `sync_state_token`
    /// queries `engine.state()` and formats the canonical `sync:` field token.
    /// When absent, `sync_state_token` returns `"local-only"`.
    ///
    /// `SyncEngineEntry` pairs the engine (erased behind the `SyncEngine` trait)
    /// with the human-readable backend name ("none", "cloudkit", "federation").
    /// Callers supply the name at registration time because Rust trait objects
    /// cannot recover the concrete type name. Dropped when the estate is closed.
    ///
    /// Mirrors Swift actor's `syncEngines: [EstateHandle: SyncEngineEntry]`.
    sync_engines: HashMap<EstateHandle, SyncEngineEntry>,

    // ── Recall degradation test seams (P1 fail-loud contract) ──
    //
    // Each field mirrors the Swift `_testForce*` actor properties on `GeniusLocusKit`
    // (Sources/GeniusLocusKit/GeniusLocusKit.swift). Single-use: taken on the first
    // recall call that checks it; subsequent calls behave normally. Gated behind
    // `#[cfg(any(test, feature = "test-seams"))]` so they compile to nothing in
    // production builds — zero footprint on the non-test path. Never set in production code.

    /// Test-only: when `Some`, the Hamming vector lane returns this error string
    /// instead of calling `VectorStore::find_nearest`. Taken once; cleared on use.
    /// `RefCell` allows the seam to be consumed from `&self` without requiring
    /// callers to hold `&mut`. Mirrors Swift `_testForceVectorHammingError`.
    #[cfg(any(test, feature = "test-seams"))]
    pub(crate) test_force_vector_hamming_error: std::cell::RefCell<Option<String>>,

    /// Test-only: when `Some`, `Corpus::embed` in the multi-lane path returns
    /// this error string instead of computing an embedding. Taken once; cleared on use.
    /// `RefCell` allows the seam to be consumed from `&self`. Mirrors Swift `_testForceEmbedError`.
    #[cfg(any(test, feature = "test-seams"))]
    pub(crate) test_force_embed_error: std::cell::RefCell<Option<String>>,

    /// Test-only: simulate a TRANSIENT encode-ingest failure. When set, each
    /// drawer's FIRST encode-drain ingest attempt (`drain_encode_queue_once`)
    /// fails once; subsequent attempts for the same drawer succeed — a transient
    /// fault that clears, so the at-least-once bounded-retry path can be
    /// force-tested deterministically. The set records drawers already failed.
    /// `RefCell` lets the pump consume it without `&mut`. Mirrors the Swift
    /// `encodeIngestFailureHook` + `FirstAttemptFailureSet`.
    #[cfg(any(test, feature = "test-seams"))]
    pub(crate) test_force_encode_ingest_transient: std::cell::RefCell<Option<std::collections::HashSet<String>>>,
}

impl Default for EstateCoordinator {
    fn default() -> Self {
        Self::new()
    }
}

impl EstateCoordinator {
    /// Construct a coordinator with empty estate, branch, grant, and
    /// corpus/vector registries.
    pub fn new() -> Self {
        Self {
            registry: HashMap::new(),
            branches: HashMap::new(),
            grant_stores: HashMap::new(),
            scope_vaults: HashMap::new(),
            corpus_kits: HashMap::new(),
            vector_stores: HashMap::new(),
            mount_states: HashMap::new(),
            encode_queues: HashMap::new(),
            audit_logs: HashMap::new(),
            matrix_tiers: HashMap::new(),
            node_topology_providers: HashMap::new(),
            sync_engines: HashMap::new(),
            // Test seams start clear; only `inject_*` methods set them.
            #[cfg(any(test, feature = "test-seams"))]
            test_force_vector_hamming_error: std::cell::RefCell::new(None),
            #[cfg(any(test, feature = "test-seams"))]
            test_force_embed_error: std::cell::RefCell::new(None),
            #[cfg(any(test, feature = "test-seams"))]
            test_force_encode_ingest_transient: std::cell::RefCell::new(None),
        }
    }

    /// Arm a transient encode-ingest failure injector (test seam).
    ///
    /// Once armed, each drawer's FIRST encode-drain ingest attempt fails once
    /// (a transient fault); the retry then succeeds. Exercises the at-least-once
    /// bounded-retry path. Available when `test` or `feature = "test-seams"` is
    /// active. Mirrors the Swift `_setEncodeIngestFailureHook` +
    /// `FirstAttemptFailureSet`.
    #[cfg(any(test, feature = "test-seams"))]
    pub fn arm_transient_encode_ingest_failures(&self) {
        *self.test_force_encode_ingest_transient.borrow_mut() =
            Some(std::collections::HashSet::new());
    }

    // ── Test seam injection helpers (P1 fail-loud contract) ──
    //
    // Mirror the Swift `_inject(vectorHammingError:)` / `_inject(embedError:)` actor
    // methods (GeniusLocusKit.swift). Active in `test` builds and when the
    // `test-seams` feature is enabled. Never call in production code.

    /// Inject a Hamming vector lane error for the next `recall_scored` call.
    ///
    /// Sets the single-use `test_force_vector_hamming_error` seam. The next
    /// `recall_scored_multi_lane` call that attempts `VectorStore::find_nearest`
    /// will treat this string as a fatal error, record `"vectorHamming.findNearest"`
    /// in `degraded_stages`, and return empty vector candidates. Subsequent calls
    /// behave normally. Uses `RefCell` so the seam can be consumed from a `&self`
    /// context without requiring callers to hold `&mut EstateCoordinator`.
    ///
    /// Available when `test` or `feature = "test-seams"` is active.
    /// Mirrors Swift `GeniusLocusKit._inject(vectorHammingError:)`.
    #[cfg(any(test, feature = "test-seams"))]
    pub fn inject_vector_hamming_error(&self, msg: impl Into<String>) {
        *self.test_force_vector_hamming_error.borrow_mut() = Some(msg.into());
    }

    /// Inject an embed error for the next `recall_scored` multi-lane call.
    ///
    /// Sets the single-use `test_force_embed_error` seam. The next
    /// `recall_scored_multi_lane` call that attempts `Corpus::embed` will treat
    /// this string as a fatal error, record `"corpus.embed"` in `degraded_stages`,
    /// and skip the vector lane for that query. Subsequent calls behave normally.
    ///
    /// Available when `test` or `feature = "test-seams"` is active.
    /// Mirrors Swift `GeniusLocusKit._inject(embedError:)`.
    #[cfg(any(test, feature = "test-seams"))]
    pub fn inject_embed_error(&self, msg: impl Into<String>) {
        *self.test_force_embed_error.borrow_mut() = Some(msg.into());
    }

    /// Number of estates currently open.
    pub fn open_estate_count(&self) -> usize {
        self.registry.len()
    }

    /// Snapshot of currently-open estate handles. `HashMap`-iteration order
    /// (unspecified); callers needing stable order sort by `estate_uuid`.
    pub fn handles(&self) -> Vec<EstateHandle> {
        self.registry.keys().copied().collect()
    }

    /// Admit an estate into the registry. Opens the underlying
    /// `locus_kit::Estate` over `store` (parity of the Swift
    /// `LocusKit.Estate.open(storage:owner:)` call inside the actor's
    /// `open`), derives the handle's UUID from the opened estate, and
    /// registers it under a fresh `EstateHandle` carrying the zoom window.
    ///
    /// Refuses a UUID already registered (spec § 7.7: estate UUIDs are
    /// immutable, so a duplicate is almost certainly the same store opened
    /// twice).
    pub fn open(
        &mut self,
        store: Arc<dyn DrawerStore>,
        owner: OwnerCredentials,
        zoom_window_low: i64,
        zoom_window_high: i64,
    ) -> Result<EstateHandle, GeniusLocusKitError> {
        let estate =
            Estate::open(store, owner).map_err(|e| GeniusLocusKitError::EstateOpenFailed {
                detail: format!("{e:?}"),
            })?;
        let estate_uuid: EstateUuid = estate.estate_uuid().into_bytes();
        let handle = EstateHandle::new(estate_uuid, zoom_window_low, zoom_window_high)?;
        if self.registry.contains_key(&handle) {
            return Err(GeniusLocusKitError::DuplicateEstate { estate_uuid });
        }
        self.registry.insert(handle, estate);
        // Initialise durable grant store backed by an in-memory storage (the
        // default for `open`; callers that want SQLite-backed grant persistence
        // use `open_with_grant_storage` or `provision`). The schema is opened
        // inside `GrantStore::new` — failure would mean a malformed schema
        // declaration, which cannot happen here (the schema is a compile-time
        // constant). Unwrapping is safe.
        let grant_storage: Arc<dyn Storage> = Arc::new(
            InMemoryStorage::with_estate(Uuid::from_bytes(estate_uuid))
        );
        let grant_store = GrantStore::new(grant_storage)
            .expect("GrantStore::new with InMemoryStorage must not fail");
        self.grant_stores.insert(handle, grant_store);
        self.scope_vaults.insert(handle, ScopeKeyVault::new());
        // Mark the estate mounted (GLK_PROVISION_001).
        self.mount_states.insert(handle, EstateMountState::Mounted);
        // Mint an empty unified audit log for the estate (GLK-03 parity). The
        // log starts empty so a verify pass before any feed reports a clean,
        // zero-entry chain; `feed_audit_log` populates it from the LocusKit
        // audit trail on demand. Mirrors Swift `auditLogs[handle] = UnifiedAuditLog()`.
        self.audit_logs.insert(handle, crate::audit::UnifiedAuditLog::new());

        // Telemetry: emit mount-state transition to mounted (GLK_ROLLUPS_001).
        // The report! macro evaluates the argument ONLY when monitoring is enabled.
        // Off-path: single AtomicBool::load + branch, zero allocation.
        let estate_id_str = uuid_to_str(&estate_uuid);
        glk_emit!(metric_names::MOUNT_STATE_TRANSITION, 1.0, {
            let mut tags = HashMap::new();
            tags.insert("estate_id".to_string(), estate_id_str.clone());
            tags.insert("state".to_string(), "mounted".to_string());
            tags
        });

        // Telemetry: emit noun_count=0 snapshot for a freshly opened estate.
        // The Rust coordinator always opens fresh stores (existing data is
        // restored through the hydration path, not the open path), so noun_count
        // is always 0 here — matches Swift's allDrawers().count for a new estate.
        glk_emit!(metric_names::NOUN_COUNT, 0.0, {
            let mut tags = HashMap::new();
            tags.insert("estate_id".to_string(), estate_id_str);
            tags
        });

        Ok(handle)
    }

    /// Remove an estate from the registry. The handle becomes stale;
    /// subsequent `estate_for` lookups return `EstateNotOpen`. Also
    /// drops the grant store, scope vault, and any registered corpus/vector
    /// handles for that estate.
    pub fn close(&mut self, handle: &EstateHandle) -> Result<(), GeniusLocusKitError> {
        if self.registry.remove(handle).is_none() {
            return Err(GeniusLocusKitError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            });
        }
        self.grant_stores.remove(handle);
        self.scope_vaults.remove(handle);
        self.corpus_kits.remove(handle);
        self.vector_stores.remove(handle);
        // Drop the dedicated encode queue (Dual-Path Intake D-B). Mirrors Swift
        // `dropEncodeQueue(for:)` in `close`. No worker to cancel in the
        // synchronous Rust port — just drop the queue registry entry.
        self.encode_queues.remove(handle);
        // Drop the audit log and matrix tier with the estate — a closed handle
        // must not resolve to a live log or a stale recall tier (GLK-03 parity).
        self.audit_logs.remove(handle);
        self.matrix_tiers.remove(handle);
        // Drop the node topology provider (w5-nodetree-native). A closed handle
        // must not resolve to a stale provider; parity of Swift `close` which
        // drops `nodeTopologyProviders[handle]`.
        self.node_topology_providers.remove(handle);
        // Drop the sync engine so no engine reference outlives the estate.
        // Parity of Swift `close` which drops `syncEngines[handle]`.
        self.sync_engines.remove(handle);
        // Drop mount state (GLK_PROVISION_001).
        self.mount_states.remove(handle);

        // Telemetry: emit mount-state transition to unmounted (GLK_ROLLUPS_001).
        // Emitted after all registry cleanup so the closed state is authoritative.
        let estate_id_str = uuid_to_str(&handle.estate_uuid);
        glk_emit!(metric_names::MOUNT_STATE_TRANSITION, 1.0, {
            let mut tags = HashMap::new();
            tags.insert("estate_id".to_string(), estate_id_str);
            tags.insert("state".to_string(), "unmounted".to_string());
            tags
        });

        Ok(())
    }

    /// Crate-internal access to the registry for the hydration module.
    /// The hydration path needs to check for duplicates and insert a
    /// pre-opened `Estate` directly (bypassing the DrawerStore layer).
    pub(crate) fn registry(&self) -> &HashMap<EstateHandle, Estate> {
        &self.registry
    }

    /// Crate-internal method to register an already-opened `Estate` and
    /// initialise its grant store and scope vault entries.
    ///
    /// Used by `hydration::EstateCoordinator::open_estate_directly` so the
    /// hydrated estate is registered identically to one opened via `open`.
    pub(crate) fn register_estate(&mut self, handle: EstateHandle, estate: Estate) {
        self.registry.insert(handle, estate);
        // Grant store backed by in-memory storage — hydration restores drawers, not grants.
        let grant_storage: Arc<dyn Storage> = Arc::new(
            InMemoryStorage::with_estate(Uuid::from_bytes(handle.estate_uuid))
        );
        let grant_store = GrantStore::new(grant_storage)
            .expect("GrantStore::new with InMemoryStorage must not fail");
        self.grant_stores.insert(handle, grant_store);
        self.scope_vaults.insert(handle, ScopeKeyVault::new());
        // Mark the estate mounted so mount_state queries work on hydrated estates too.
        self.mount_states.insert(handle, EstateMountState::Mounted);
        // Mint an empty audit log; the hydration path installs the rebuilt log
        // via `set_audit_log` after replaying the durable audit trail.
        self.audit_logs.insert(handle, crate::audit::UnifiedAuditLog::new());
    }

    /// Wire a `Corpus` into the scored-recall BM25 lane for `handle`.
    ///
    /// Activates the BM25 recall lane in `recall_scored` for Hybrid,
    /// CorpusOnly, and UnionBest modes. Replaces any previously registered
    /// corpus for this handle (idempotent). Mirrors Swift
    /// `GeniusLocusKit.registerCorpus(_:for:)`.
    pub fn register_corpus(&mut self, handle: &EstateHandle, corpus: Arc<Corpus>) {
        self.corpus_kits.insert(*handle, corpus);
    }

    /// Wire a `VectorStore` into the scored-recall vector lane for `handle`.
    ///
    /// Activates the vector recall lane in `recall_scored` for Hybrid,
    /// CorpusOnly, and UnionBest modes. Replaces any previously registered
    /// store for this handle (idempotent). Mirrors Swift
    /// `GeniusLocusKit.registerVectorStore(_:for:)`.
    pub fn register_vector_store(&mut self, handle: &EstateHandle, store: Arc<VectorStore>) {
        self.vector_stores.insert(*handle, store);
    }

    /// Register a `NodeTopologyProvider` for the given estate handle.
    ///
    /// The provider gives the coordinator access to the host's parent-child
    /// node tree for the `NodeTreeNative` recall mode and for the structural
    /// lens path. When a provider is registered, `recall_tunnels` calls
    /// `provider.tree_edges(None)` EXACTLY ONCE at the start of each call
    /// (G1 — read-once-and-freeze) and unions the frozen containment edges with
    /// the estate's stored tunnel edges before returning. The provider is never
    /// called again during that recall; determinism does not depend on provider
    /// stability after the freeze point.
    ///
    /// Topology boundary invariant (G4): the provider exposes exactly three
    /// methods (`parent_id` / `child_ids` / `tree_edges`) and NO content accessor.
    /// Any node-content need routes through CorpusKit. This seam will never be widened.
    ///
    /// G3 — sanctioned async/sync asymmetry: Swift is async; Rust is synchronous.
    /// Conformance is proved by comparing edge output, not call shape.
    ///
    /// Re-registering replaces the existing entry for the handle (idempotent).
    /// When no provider is registered, `recall_tunnels` returns only stored tunnels —
    /// existing behaviour unchanged. Mirrors Swift
    /// `GeniusLocusKit.registerNodeTopology(_:for:)`.
    ///
    /// - Parameters:
    ///   - provider: The host-side topology adapter (`Arc<dyn NodeTopologyProvider>`).
    ///   - handle:   The estate to associate this topology with.
    pub fn register_node_topology(
        &mut self,
        handle: &EstateHandle,
        provider: Arc<dyn crate::node_topology::NodeTopologyProvider>,
    ) {
        self.node_topology_providers.insert(*handle, provider);
    }

    /// Register a sync engine for the given estate handle.
    ///
    /// Replaces any previously registered engine + label for the handle. Call
    /// after `open` to wire a ConvergenceKit backend. The engine's `state()`
    /// method is read lazily on each `sync_state_token` call — GLK does not
    /// drive the engine's enable/disable/push/pull lifecycle.
    ///
    /// Callers that want local-only behaviour need NOT call this. When no engine
    /// is registered, `sync_state_token` returns `"local-only"`.
    ///
    /// - `engine`: Concrete sync engine implementing `SyncEngine` (boxed).
    /// - `backend_name`: Human-readable label: `"none"`, `"cloudkit"`, or
    ///   `"federation"`. Callers supply this because trait objects cannot recover
    ///   the concrete type name from `Box<dyn SyncEngine>`.
    ///
    /// Returns `Err(EstateNotOpen)` if the handle is not in the registry.
    pub fn register_sync_engine(
        &mut self,
        handle: &EstateHandle,
        engine: Box<dyn SyncEngine>,
        backend_name: &str,
    ) -> Result<(), GeniusLocusKitError> {
        if !self.registry.contains_key(handle) {
            return Err(GeniusLocusKitError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            });
        }
        self.sync_engines.insert(
            *handle,
            SyncEngineEntry { engine, backend_name: backend_name.to_string() },
        );
        Ok(())
    }

    /// Return the canonical sync-status token for `moot_estate_status`.
    ///
    /// Reads the registered engine's `state()` method and formats it with
    /// `format_sync_state_token`. Returns `"local-only"` when no engine is
    /// registered — the estate is local-only (no sync configured).
    ///
    /// Vocabulary (parity with Swift `syncStateToken(for:)`):
    /// ```text
    /// local-only                              — no engine registered
    /// none (idle)                             — NoSyncEngine disabled
    /// none (enabled, zone: <zone>)            — NoSyncEngine enabled
    /// cloudkit (idle)                         — CloudKit disabled
    /// cloudkit (enabled, zone: <zone>)        — CloudKit enabled
    /// cloudkit (syncing, direction: <d>)      — CloudKit syncing
    /// cloudkit (error: <e>)                   — CloudKit error
    /// federation (idle)                       — Federation disabled
    /// federation (in-process, zone: <zone>)   — Federation enabled (v1.0 in-process)
    /// federation (syncing, direction: <d>)    — Federation syncing
    /// federation (error: <e>)                 — Federation error
    /// ```
    ///
    /// The token `"connected"` is NEVER returned.
    ///
    /// Returns `Err(EstateNotOpen)` if the handle is not in the registry.
    pub fn sync_state_token(
        &self,
        handle: &EstateHandle,
    ) -> Result<String, GeniusLocusKitError> {
        if !self.registry.contains_key(handle) {
            return Err(GeniusLocusKitError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            });
        }
        let Some(entry) = self.sync_engines.get(handle) else {
            // No engine registered — estate is local-only (no sync configured).
            return Ok("local-only".to_string());
        };
        let state = entry.engine.state();
        Ok(format_sync_state_token(&state, &entry.backend_name))
    }

    /// Returns `true` if a `Corpus` is registered for `handle`.
    ///
    /// Used by tests and the admin plane to verify that `provision` (or
    /// `register_corpus`) wired the BM25 lane for the addressed estate.
    /// Mirrors the Swift test assertion `kit.corpusKits[handle] != nil`.
    pub fn has_corpus(&self, handle: &EstateHandle) -> bool {
        self.corpus_kits.contains_key(handle)
    }

    /// The `Corpus` registered for `handle`, if any (a cheap `Arc` clone).
    ///
    /// Used by the Dual-Path Intake composition (`intake.rs`) to ingest a
    /// captured drawer into the estate's BM25/vector lanes. Mirrors the Swift
    /// actor's `corpusKits[handle]` lookup.
    pub(crate) fn corpus_for(&self, handle: &EstateHandle) -> Option<Arc<Corpus>> {
        self.corpus_kits.get(handle).map(Arc::clone)
    }

    /// Returns `true` if a `VectorStore` is registered for `handle`.
    ///
    /// Used by tests and the admin plane to verify that `provision` (or
    /// `register_vector_store`) wired the vector lane for the addressed estate.
    /// Mirrors the Swift test assertion `kit.vectorStores[handle] != nil`.
    pub fn has_vector_store(&self, handle: &EstateHandle) -> bool {
        self.vector_stores.contains_key(handle)
    }

    /// Return a clone of the `VectorStore` registered for `handle`, or `None`
    /// when no store has been registered. Parity of the Swift
    /// `registeredVectorStore(for:)` accessor. Used by the expunge orchestration
    /// path to invalidate the standalone store's resident slot after
    /// `Corpus::remove` has deleted from the shared backing table.
    pub(crate) fn vector_store_for(&self, handle: &EstateHandle) -> Option<Arc<VectorStore>> {
        self.vector_stores.get(handle).map(Arc::clone)
    }

    /// Resolve a handle to its live estate. Parity of the Swift
    /// `estate(for:)`; returns `EstateNotOpen` for a stale or never-issued
    /// handle.
    pub fn estate_for(&self, handle: &EstateHandle) -> Result<&Estate, GeniusLocusKitError> {
        self.registry
            .get(handle)
            .ok_or(GeniusLocusKitError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            })
    }

    // Internal: resolve to an estate, mapping the not-open case into the
    // verb-dispatch error domain (parity of `estate(for:)` propagating
    // `estateNotOpen` out of a verb).
    fn estate_for_verb(&self, handle: &EstateHandle) -> Result<&Estate, VerbDispatchError> {
        self.registry
            .get(handle)
            .ok_or(VerbDispatchError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            })
    }

    // MARK: - capture

    /// File a new drawer into the estate addressed by `handle`. Parity of
    /// the Swift `capture(_:_:)`. `now` is explicit per the Rust substrate's
    /// determinism convention (the Swift estate reads its own clock).
    pub fn capture(
        &self,
        handle: &EstateHandle,
        frame: CaptureFrame,
        now: i64,
    ) -> Result<Drawer, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .capture(frame, now)
            .map_err(|e| remap("capture", &uuid_to_str(&handle.estate_uuid), e).into())
    }

    // MARK: - recall

    /// Recall rows from the estate addressed by `handle`, draining the
    /// stream into a materialized array. Parity of the Swift `recall(_:_:)`.
    ///
    /// The Swift `GeniusLocusKit.recall(_:_:)` routes through the RecallDirector
    /// in `.locusOnly` mode, which sets `traceLimit = request.limit` on the
    /// primary locus call ONLY for external-origin requests (B-10a). Internal
    /// reads — dreaming, standing signals, recipes/lenses, migration, benchmarks
    /// — must NOT write recall-trace rows.
    ///
    /// This plain `recall` variant is used by internal callers and the legacy
    /// compatibility path; it leaves `trace_limit` None so no trace rows are
    /// written (B-10a compliant).
    pub fn recall(
        &self,
        handle: &EstateHandle,
        frame: RecallFrame,
        now: i64,
    ) -> Result<Vec<Drawer>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        // trace_limit intentionally None here — internal caller, no trace rows (B-10a).
        Ok(estate.recall(frame, now).collect_all())
    }

    /// External-facing recall used by the ARIA boundary: sets `trace_limit`
    /// on the frame so the reward cycle records the surfaced rows.
    ///
    /// Only call this from the ARIA_MCP boundary. All internal callers
    /// (dreaming, lenses, recipes, migration) must use `recall` above (B-10a).
    pub fn recall_external(
        &self,
        handle: &EstateHandle,
        mut frame: RecallFrame,
        now: i64,
    ) -> Result<Vec<Drawer>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        // B-10a: only external requests write trace rows.
        frame.trace_limit = Some(frame.limit.unwrap_or(50));
        Ok(estate.recall(frame, now).collect_all())
    }

    // MARK: - recall_tunnels

    /// Read the tunnels originating in `wing` for the estate addressed by
    /// `handle`, unioned with any host-tree containment edges from a registered
    /// `NodeTopologyProvider`.
    ///
    /// Resolves the handle through `estate_for_verb` and returns the
    /// non-tombstoned drawer-to-drawer tunnels whose source is `wing`,
    /// in stored filing order, followed by synthetic containment tunnels
    /// when a `NodeTopologyProvider` is registered for the handle.
    ///
    /// G1 — read-once-and-freeze: when a `NodeTopologyProvider` is registered
    /// for `handle`, `provider.tree_edges(None)` is called EXACTLY ONCE at the
    /// top of this method. The result is frozen into a local variable before the
    /// estate tunnel read begins. No subsequent provider call is made during this
    /// method or any downstream computation that consumes the returned `Vec`.
    ///
    /// G4 — topology boundary: the provider supplies ONLY edge topology
    /// (parent/child id pairs). No node content crosses this boundary.
    ///
    /// When no provider is registered, returns only stored tunnels —
    /// existing behaviour is unchanged (no-provider path is identical to
    /// pre-`NodeTreeNative` behaviour). Mirrors Swift
    /// `GeniusLocusKit.recallTunnels(_:wing:)`.
    pub fn recall_tunnels(
        &self,
        handle: &EstateHandle,
        wing: &str,
    ) -> Result<Vec<Tunnel>, VerbDispatchError> {
        // G1 — read-once-and-freeze. Call tree_edges exactly once here;
        // no provider method is called again during this recall or by any
        // consumer of the returned Vec.
        let frozen_tree_edges: Vec<(String, String)> =
            if let Some(provider) = self.node_topology_providers.get(handle) {
                provider.tree_edges(None)
            } else {
                // No provider registered — empty tree edge set, existing behaviour
                // unchanged. Structural lenses see only stored tunnel edges.
                Vec::new()
            };

        let estate = self.estate_for_verb(handle)?;
        let stored_tunnels: Vec<Tunnel> = estate
            .tunnels_from_wing(wing)
            .map_err(|e| VerbDispatchError::from(remap("recall_tunnels", "", e)))?;

        // No tree edges → return stored tunnels only (identical to pre-registration
        // behaviour; proved unchanged by test co_nt1_no_provider_behaviour_unchanged).
        if frozen_tree_edges.is_empty() {
            return Ok(stored_tunnels);
        }

        // Union: append synthetic containment tunnels from the frozen tree snapshot.
        // Each tree edge (parent, child) becomes a Tunnel with:
        //   - id:              "containment:<parent>:<child>"
        //   - label:           "containment" — the tag a lens uses to weight
        //                       tree-vs-graph edges
        //   - kind:            TunnelKind::References — TunnelKind has no dedicated
        //                       Containment case; `label` is the discriminator
        //   - source_drawer_id / target_drawer_id: the node ids (parent → child)
        //   - filed_at:        i64::MIN — synthetic tunnels have no real capture time;
        //                       i64::MIN is the Rust parity of Swift Date.distantPast,
        //                       keeping synthetic tunnels stable-sortable below real tunnels
        //   - added_by:        "nodeTopologyProvider" — provenance marker
        // All bitmap fields are 0 (default active/normal state).
        let synthetic: Vec<Tunnel> = frozen_tree_edges
            .into_iter()
            .map(|(parent, child)| {
                let mut t = Tunnel::new(
                    format!("containment:{parent}:{child}"),
                    wing.to_string(),
                    "topology".to_string(),
                    wing.to_string(),
                    "topology".to_string(),
                    "containment".to_string(),
                    "nodeTopologyProvider".to_string(),
                    i64::MIN,
                );
                // parent → child direction: source_drawer_id is the parent node id,
                // target_drawer_id is the child node id (parity of Swift's
                // sourceDrawerId: edge.parent, targetDrawerId: edge.child).
                t.source_drawer_id = Some(parent);
                t.target_drawer_id = Some(child);
                t
            })
            .collect();

        Ok([stored_tunnels, synthetic].concat())
    }

    // MARK: - mutate

    /// Apply a named mutation to a drawer. Delegates to `Estate::mutate`,
    /// which handles every kind: `Confirm` moves the confirmation axis to
    /// `UserConfirmed`; the state-axis kinds (Reject/Contest/Resolve/
    /// Supersede/Revive/Accept) drive the lifecycle automaton, each guarded
    /// by its legal source state. A gate violation surfaces as a substrate
    /// error that `remap` translates — parity of the Swift surface.
    pub fn mutate(
        &self,
        handle: &EstateHandle,
        row_id: &str,
        kind: MutationKind,
        payload: Option<&str>,
    ) -> Result<(), VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .mutate(row_id, kind, payload)
            .map_err(|e| remap("mutate", &uuid_to_str(&handle.estate_uuid), e).into())
    }

    // MARK: - withdraw

    /// Withdraw a drawer — move its `State` axis to `withdrawn`. Parity of
    /// the Swift `withdraw(_:_:)`.
    pub fn withdraw(
        &self,
        handle: &EstateHandle,
        row_id: &str,
        reason: Option<&str>,
        now: i64,
    ) -> Result<(), VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .withdraw(row_id, reason, now)
            .map_err(|e| remap("withdraw", &uuid_to_str(&handle.estate_uuid), e).into())
    }

    // MARK: - expunge

    /// Tombstone a drawer, zeroize its content, and purge its vector
    /// embedding(s) from VectorKit/CorpusKit. Raises
    /// `VerbError::ExpungeNotConfirmed` at the boundary when `confirmation`
    /// is false (the substrate is not reached) — parity of the Swift guard.
    ///
    /// Executes in two steps, parity of the Swift `VerbSurface.expunge`:
    ///
    /// **Step 1 — Storage expunge (LocusKit):** tombstones the drawer row,
    /// zeroes its content, and seals a sealed audit event. Failure raises
    /// `VerbDispatchError` and the cross-kit step is not attempted.
    ///
    /// **Step 2 — Cross-kit vector delete (GLK orchestration, fail-closed):**
    /// when a `Corpus` is registered for the estate, calls `Corpus::remove`
    /// to purge BM25 index entries and all vector embeddings. When a
    /// standalone `VectorStore` is also registered (`.glk` estate), additionally
    /// calls `VectorStore::delete_all_vectors` to invalidate the standalone
    /// store's resident slot. Failure raises
    /// `VerbError::CrossKitVectorDeleteFailed` — the storage expunge already
    /// succeeded, but a vector orphan must not be silently swallowed.
    ///
    /// When no Corpus or VectorStore is registered (`.locusOnly`), Step 2 is a
    /// no-op.
    /// Expunge a drawer: tombstone storage, scrub content, then delete cross-kit
    /// vectors — sealing the success audit only after ALL steps succeed.
    ///
    /// The §B-2a audit-seal ordering is enforced here:
    ///   Step 1 — LocusKit storage expunge (validate, tombstone, scrub; NO seal).
    ///   Step 2 — Cross-kit vector delete (fail-closed).
    ///   Step 3 — Seal success audit (only on step-2 success).
    ///   On step-2 failure — seal an "expungeOrphan" audit, then throw.
    ///
    /// This prevents a false-success audit when step 2 fails, which was the
    /// Perkins P2 finding: before this fix, the success audit was sealed in step 1
    /// before step 2 ran, so a step-2 failure left a misleading "expunge succeeded"
    /// record in the audit log while the vector embedding survived.
    ///
    /// Direct LocusKit callers (bypassing GLK) use `estate.expunge` with the
    /// default `seal_audit: true` and are unaffected by this change.
    pub fn expunge(
        &self,
        handle: &EstateHandle,
        row_id: &str,
        reason: &str,
        confirmation: bool,
        now: i64,
    ) -> Result<(), VerbDispatchError> {
        if !confirmation {
            return Err(VerbError::ExpungeNotConfirmed {
                row_id: row_id.to_string(),
            }
            .into());
        }

        let estate = self.estate_for_verb(handle)?;

        // Step 1 — LocusKit storage expunge with deferred audit seal.
        // The gate-produced AuditEvent is returned unsealed; we hold it until
        // step 2 confirms the cross-kit delete succeeded (§B-2a ordering).
        let unsealed_event = estate
            .expunge(row_id, reason, confirmation, now, false)
            .map_err(|e| remap("expunge", &uuid_to_str(&handle.estate_uuid), e))?;

        // Step 2 — Cross-kit vector delete (fail-closed; must not be silent).
        //
        // GLK is the composition layer responsible for coordinating the cross-kit
        // vector delete on expunge (GENIUSLOCUSKIT_SPEC_v0.8 §B-2a).
        let corpus = self.corpus_for(handle);
        let vector_store = self.vector_store_for(handle);

        if corpus.is_some() || vector_store.is_some() {
            let step2_result: Result<(), VerbDispatchError> = (|| {
                if let Some(ref c) = corpus {
                    // Remove BM25 entries and all vector embeddings for this
                    // drawer. source_id == drawer.id is the ingest convention
                    // (EncodeIntake G4).
                    c.remove(row_id).map_err(|e| {
                        VerbDispatchError::Verb(VerbError::CrossKitVectorDeleteFailed {
                            row_id: row_id.to_string(),
                            reason: format!("{:?}", e),
                        })
                    })?;
                }
                if let Some(ref vs) = vector_store {
                    if let Some(ref c) = corpus {
                        // For .glk estates: the standalone VectorStore's resident
                        // array must also be invalidated (it shares the backing table
                        // with the corpus's internal VectorStore but maintains a
                        // separate in-memory live/tombstone bitmap). Derive modelID
                        // from the corpus.
                        let model_id = c.model_id();
                        vs.delete_all_vectors(row_id, model_id).map_err(|e| {
                            VerbDispatchError::Verb(VerbError::CrossKitVectorDeleteFailed {
                                row_id: row_id.to_string(),
                                reason: format!("{:?}", e),
                            })
                        })?;
                    } else {
                        // Standalone VectorStore registered without a Corpus (not a
                        // standard provisioning path, but handled defensively). The
                        // modelID is not available; raise a clear error rather than
                        // silently leaving an orphan.
                        return Err(VerbDispatchError::Verb(
                            VerbError::CrossKitVectorDeleteFailed {
                                row_id: row_id.to_string(),
                                reason: format!(
                                    "standalone VectorStore registered without a Corpus — \
                                     model_id unavailable for delete_all_vectors; \
                                     manual cleanup required for estate {}",
                                    uuid_to_str(&handle.estate_uuid)
                                ),
                            },
                        ));
                    }
                }
                Ok(())
            })();

            if let Err(step2_err) = step2_result {
                // Step 2 failed. Seal an "expungeOrphan" audit to record the
                // partial state honestly: row is tombstoned+scrubbed but the
                // vector embedding was NOT removed (§B-2a fail path).
                //
                // The orphan-seal result is NOT discarded. If the seal also
                // fails (double-failure: step-2 delete failed AND the audit
                // cannot record the orphan state), the seal error is folded
                // into the returned error's reason string so the ARIA caller
                // surfaces both failures. The row remains detectable by the
                // `run_expunge_integrity_sweep` maintenance pass, which
                // queries for tombstoned rows without a tombstone/expungeOrphan
                // audit event and re-attempts remediation.
                //
                // Mirrors the Swift path in `VerbSurface.expunge`: the catch
                // block calls `sealExpungeOrphanAudit`, and if that also throws,
                // it logs at fault level and rethrows the step-2 error. The
                // Rust port folds the seal error into the reason string (no
                // OS logger available in library kits) and returns step2_err
                // as the principal cause.
                let step2_err = match estate.seal_expunge_orphan_audit(row_id, &unsealed_event, now) {
                    Ok(()) => step2_err,
                    Err(seal_err) => {
                        // Double-failure: fold the seal error into the
                        // CrossKitVectorDeleteFailed reason so callers learn
                        // both the delete failure and the audit failure from
                        // the single returned error.
                        match step2_err {
                            VerbDispatchError::Verb(VerbError::CrossKitVectorDeleteFailed {
                                ref row_id,
                                ref reason,
                            }) => VerbDispatchError::Verb(VerbError::CrossKitVectorDeleteFailed {
                                row_id: row_id.clone(),
                                reason: format!(
                                    "{}; orphan-audit seal also failed: {}",
                                    reason,
                                    seal_err
                                ),
                            }),
                            other => other,
                        }
                    }
                };
                return Err(step2_err);
            }
        }

        // Step 3 — Seal success audit. Both storage and cross-kit delete
        // succeeded; the audit now correctly records a complete expunge.
        estate
            .seal_expunge_audit(&unsealed_event)
            .map_err(|e| remap("expunge", &uuid_to_str(&handle.estate_uuid), e))?;

        Ok(())
    }

    // MARK: - run_expunge_integrity_sweep

    /// Detect and remediate tombstoned drawers that lack a sealed audit event.
    ///
    /// This maintenance function closes two gap scenarios that the expunge §B-2a
    /// path cannot handle inline:
    ///
    ///   1. **Crash window**: the process exited between step 1 (tombstone) and
    ///      step 3 (audit seal). The row is tombstoned and scrubbed but has no
    ///      audit record, making its expunge history invisible.
    ///
    ///   2. **Double-failure**: both the step-2 cross-kit delete and the
    ///      orphan-seal write failed in the same expunge call. The `expunge`
    ///      verb already returns the folded error; this sweep detects the
    ///      resulting audit-less tombstoned row on the next maintenance pass and
    ///      re-attempts remediation.
    ///
    /// For each tombstoned row without a "tombstone" or "expungeOrphan" audit:
    ///   - Re-attempt the cross-kit vector+corpus delete.
    ///   - On success: seal a "tombstone" success audit (`seal_expunge_audit`).
    ///   - On failure: seal an "expungeOrphan" audit (`seal_expunge_orphan_audit`).
    ///
    /// The sweep result is always `Ok(result)` as long as the orphan-query
    /// succeeds; per-row remediation failures are collected in
    /// `result.per_row_errors` without blocking other rows. Only a fatal
    /// query failure (the underlying `tombstoned_rows_without_expunge_audit`
    /// store call fails) returns `Err`.
    ///
    /// `now` must be a deterministic epoch-millisecond timestamp supplied by
    /// the caller — never derived from the system clock inside this function.
    ///
    /// ## Call this function:
    ///   - On startup, after registering the Corpus and VectorStore for a
    ///     re-opened estate (so the cross-kit re-delete has the registered kit).
    ///   - On demand from the maintenance/admin plane.
    ///
    /// ## What it does NOT do:
    ///   - Does not alter active (non-tombstoned) drawers.
    ///   - Does not re-tombstone already-tombstoned rows.
    ///   - Does not seal a second audit for rows that already have one.
    pub fn run_expunge_integrity_sweep(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<ExpungeIntegritySweepResult, GeniusLocusKitError> {
        let estate = self.estate_for(handle)?;

        // Query for tombstoned rows without a tombstone/expungeOrphan audit.
        // A query failure is fatal — we cannot enumerate the orphan set.
        let orphaned_rows = estate
            .tombstoned_rows_without_expunge_audit()
            .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!(
                    "expunge integrity sweep: orphan-query failed for estate {}: {}",
                    uuid_to_str(&handle.estate_uuid),
                    e
                ),
            })?;

        if orphaned_rows.is_empty() {
            // No-op: every tombstoned row already has an audit. Common case
            // on a healthy estate; zero work done.
            return Ok(ExpungeIntegritySweepResult::default());
        }

        let corpus = self.corpus_for(handle);
        let vector_store = self.vector_store_for(handle);
        let mut result = ExpungeIntegritySweepResult::default();

        for drawer in &orphaned_rows {
            let row_id = &drawer.id;

            // Re-attempt the cross-kit vector+corpus delete (step 2 of the
            // original §B-2a expunge). Same logic as the normal expunge step 2:
            // corpus.remove clears BM25+vector index entries; VectorStore.
            // delete_all_vectors clears the resident in-memory bitmap.
            let delete_result: Result<(), String> = (|| {
                if let Some(ref c) = corpus {
                    c.remove(row_id)
                        .map_err(|e| format!("corpus.remove failed: {:?}", e))?;
                }
                if let Some(ref vs) = vector_store {
                    if let Some(ref c) = corpus {
                        let model_id = c.model_id();
                        vs.delete_all_vectors(row_id, model_id)
                            .map_err(|e| format!("VectorStore.delete_all_vectors failed: {:?}", e))?;
                    } else {
                        // Standalone VectorStore without Corpus: model_id unavailable.
                        // The delete cannot complete; this row remains orphaned.
                        // Mirrors the live expunge path (§B-2a), which raises
                        // crossKitVectorDeleteFailed in the same scenario.
                        return Err(format!(
                            "standalone VectorStore registered without a Corpus for row {} \
                             — model_id unavailable for deleteAllVectors; \
                             manual cleanup required",
                            row_id
                        ));
                    }
                }
                Ok(())
            })();

            // In both the success and failure cases, seal a synthetic
            // "expungeOrphan" audit. The original step-1 gate event was lost
            // (crash window); we cannot reconstruct it to seal a "tombstone"
            // success audit. An "expungeOrphan" event is accurate: the row is
            // tombstoned, content is gone, and the vector embedding state is
            // documented by the sweep result (remediated or still-orphaned).
            // Audit consumers can distinguish sweep-remediated from live-orphaned
            // by correlating this event with the sweep result telemetry.
            match delete_result {
                Ok(()) => {
                    // Re-delete succeeded: vector embedding removed.
                    match estate.seal_expunge_orphan_audit_synthetic(row_id, now) {
                        Ok(()) => result.remediated_count += 1,
                        Err(seal_err) => {
                            result.per_row_errors.push(format!(
                                "{}: re-delete succeeded but sweep audit-seal failed: {}",
                                row_id, seal_err
                            ));
                        }
                    }
                }
                Err(delete_err) => {
                    // Re-delete also failed: vector embedding still orphaned.
                    match estate.seal_expunge_orphan_audit_synthetic(row_id, now) {
                        Ok(()) => result.orphaned_count += 1,
                        Err(seal_err) => {
                            result.per_row_errors.push(format!(
                                "{}: re-delete failed ({}); sweep audit-seal also failed: {}",
                                row_id, delete_err, seal_err
                            ));
                        }
                    }
                }
            }
        }

        Ok(result)
    }

    // MARK: - reanchor

    /// Move a drawer's room and/or lattice anchor. At least one of `to_room`
    /// / `to_lattice` must be present; an empty reanchor raises
    /// `VerbError::EmptyReanchor` at the boundary before dispatch — parity
    /// of the Swift guard.
    pub fn reanchor(
        &self,
        handle: &EstateHandle,
        row_id: &str,
        to_room: Option<&str>,
        to_lattice: Option<LatticeAnchor>,
    ) -> Result<(), VerbDispatchError> {
        if to_room.is_none() && to_lattice.is_none() {
            return Err(VerbError::EmptyReanchor {
                row_id: row_id.to_string(),
            }
            .into());
        }
        let estate = self.estate_for_verb(handle)?;
        estate
            .reanchor(row_id, to_room, to_lattice)
            .map_err(|e| remap("reanchor", &uuid_to_str(&handle.estate_uuid), e).into())
    }

    // MARK: - learn

    /// Ingest a learned reference into the estate addressed by `handle`.
    ///
    /// `learn` is grounding-driven per AriaLexicon's flow taxonomy. Delegates
    /// to `locus_kit::Estate::learn`. Validates the handle first so a stale
    /// handle raises `EstateNotOpen` uniformly, matching the other verbs.
    ///
    /// The `frame` carries the `SourceCatalogEntry` whose genuine lattice
    /// anchor the learned reference inherits — `Estate::learn` derives a real
    /// anchor from the source rather than fabricating a sentinel (P1
    /// mandate). `Estate::learn` fails loud with
    /// `LocusKitError::InvalidContent` only on genuinely invalid input (an
    /// empty reference handle); `remap` converts substrate errors to the
    /// typed `VerbError` surface.
    ///
    /// `now` is explicit per the Rust substrate's determinism convention.
    pub fn learn(
        &self,
        handle: &EstateHandle,
        frame: LocusLearnFrame,
        now: i64,
    ) -> Result<locus_kit::learned_reference::LearnedReference, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.learn(frame, now).map_err(|e| remap("learn", &uuid_to_str(&handle.estate_uuid), e).into())
    }

    // MARK: - propose

    /// Create a proposal targeting a row in the estate addressed by `handle`.
    ///
    /// Maps the GLK-level `ProposeFrame` (Brain-layer frame with String-based
    /// `ProposalKind`) to the LocusKit-level `ProposeFrame` (Int-based substrate
    /// axis via `mapBrainKindToSubstrate`), then delegates to
    /// `locus_kit::Estate::propose`. Validates the handle first so a stale handle
    /// raises `EstateNotOpen` uniformly. Per cookbook §10.7.
    ///
    /// `now` is explicit per the Rust substrate's determinism convention.
    pub fn propose(
        &self,
        handle: &EstateHandle,
        frame: crate::verbs::frames::ProposeFrame,
        now: i64,
    ) -> Result<locus_kit::proposal::Proposal, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        let locus_kind = map_brain_kind_to_substrate(&frame.kind);
        let locus_frame = LocusProposeFrame {
            target: frame.target,
            kind: locus_kind,
            justification: frame.justification,
        };
        estate.propose(locus_frame, now).map_err(|e| remap("propose", &uuid_to_str(&handle.estate_uuid), e).into())
    }

    // MARK: - associate

    /// Create an association between two rows in the estate addressed by `handle`.
    ///
    /// Constructs a `locus_kit::AssociateFrame` from the GLK-level frame and
    /// delegates to `locus_kit::Estate::associate`. Validates the handle first so
    /// a stale handle raises `EstateNotOpen` uniformly. Per cookbook §10.8.
    ///
    /// `now` is explicit per the Rust substrate's determinism convention.
    pub fn associate(
        &self,
        handle: &EstateHandle,
        frame: crate::verbs::frames::AssociateFrame,
        now: i64,
    ) -> Result<locus_kit::association::Association, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        let locus_frame = LocusAssociateFrame {
            a: frame.a,
            b: frame.b,
            weight: frame.weight,
        };
        estate.associate(locus_frame, now).map_err(|e| remap("associate", &uuid_to_str(&handle.estate_uuid), e).into())
    }

    // MARK: - recall_kg_facts

    /// Recall kg-fact rows for the estate addressed by `handle`.
    ///
    /// Returns the kg-facts in the RowState Cluster-A (active) set —
    /// `g_state_cluster < RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW` (16) —
    /// ordered by `filed_at` ascending. Delegates to
    /// `Estate::all_kg_facts`, the estate-wide active read path.
    pub fn recall_kg_facts(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::kg_fact::KGFact>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.all_kg_facts().map_err(|e| remap("recall_kg_facts", "", e).into())
    }

    // MARK: - recall_kg_fact_timeline

    /// Recall ALL kg-fact rows for the estate — active and retired — in
    /// chronological order (`filed_at` ascending), suitable for powering
    /// the `moot_fact_timeline` tool.
    ///
    /// Unlike `recall_kg_facts`, which applies the RowState Cluster-A
    /// active-only filter (`g_state_cluster < ACTIVE_CLUSTER_UPPER_BOUND_RAW`,
    /// 16), this method reads every row ever filed, including
    /// facts in `withdrawn`, `expired`, `decayed`, `superseded`, `rejected`,
    /// and `tombstoned` states.  The full lifecycle history lets callers trace
    /// how structured knowledge in the estate evolved over time.
    ///
    /// Optional `entity` filter: when `Some`, only facts whose `subject` or
    /// `object` contains the given string are returned.  Matching is
    /// case-sensitive at this layer — `run_fact_timeline` in `interface_tools.rs`
    /// lowers both sides before calling this method.
    ///
    /// Delegates to `Estate::all_kg_facts_including_retired`.
    /// Peer of the Swift `GeniusLocusKit.recallKGFactTimeline(_:entity:)`.
    pub fn recall_kg_fact_timeline(
        &self,
        handle: &EstateHandle,
        entity: Option<&str>,
    ) -> Result<Vec<locus_kit::kg_fact::KGFact>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        let mut facts = estate
            .all_kg_facts_including_retired()
            .map_err(|e| VerbDispatchError::from(remap("recall_kg_fact_timeline", "", e)))?;
        if let Some(e) = entity {
            facts.retain(|f| f.subject.contains(e) || f.object.contains(e));
        }
        Ok(facts)
    }

    // MARK: - recall_diary_entries

    /// Recall diary-entry rows for the estate addressed by `handle`.
    ///
    /// Returns all non-tombstoned diary entries, ordered by `filed_at`
    /// ascending. Delegates to `Estate::all_diary_entries` — the new
    /// estate-wide read path added to `DrawerStore` in this stream.
    pub fn recall_diary_entries(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::diary_entry::DiaryEntry>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.all_diary_entries().map_err(|e| remap("recall_diary_entries", "", e).into())
    }

    // MARK: - add_kg_fact

    /// Capture a new KGFact in the estate addressed by `handle`.
    ///
    /// Allocates a UUID v4 id, constructs a `KGFact` with all-zero bitmaps,
    /// and delegates to `Estate::add_kg_fact`. Returns the stored fact so
    /// callers can retain the generated id. Mirrors the Swift
    /// `GeniusLocusKit.captureKGFact(_:subject:predicate:object:sourceDrawerID:now:)`.
    ///
    /// `now` is epoch-seconds. Always pass the current time from the caller;
    /// never call time inside this method — keeps the coordinator deterministic.
    pub fn add_kg_fact(
        &self,
        handle: &EstateHandle,
        subject: &str,
        predicate: &str,
        object: &str,
        source_drawer_id: &str,
        now: i64,
    ) -> Result<locus_kit::kg_fact::KGFact, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        let fact = locus_kit::kg_fact::KGFact::new(
            Uuid::new_v4().to_string(),
            subject.to_string(),
            predicate.to_string(),
            object.to_string(),
            source_drawer_id.to_string(),
            now,
        );
        estate.add_kg_fact(&fact).map_err(|e| VerbDispatchError::from(remap("add_kg_fact", "", e)))?;
        Ok(fact)
    }

    // MARK: - withdraw_kg_fact

    /// Retire a KGFact by transitioning its state to `Withdrawn`.
    ///
    /// The row is preserved for audit purposes; `g_state_cluster` rises to 18
    /// which excludes the fact from the active-recall filter. Delegates to
    /// `Estate::withdraw_kg_fact`. Mirrors the Swift
    /// `GeniusLocusKit.retireKGFact(_:rowID:)`.
    pub fn withdraw_kg_fact(
        &self,
        handle: &EstateHandle,
        id: &str,
        now: i64,
    ) -> Result<(), VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.withdraw_kg_fact(id, now).map_err(|e| VerbDispatchError::from(remap("withdraw_kg_fact", "", e)))
    }

    // MARK: - add_diary_entry

    /// Write a diary entry for `agent_name` into the estate addressed by `handle`.
    ///
    /// Allocates a UUID v4 id and constructs a `DiaryEntry`. If
    /// `embedding_model_id` is empty the caller's intent is "no embedding";
    /// substitute `"no-embedding"` so the non-empty model-id contract is
    /// satisfied. Mirrors the Swift `GeniusLocusKit.addDiaryEntry(in:_:)`.
    ///
    /// `now` is epoch-seconds. `topic` and `embedding_model_id` are caller-
    /// supplied; callers that have no topic may pass `""`.
    pub fn add_diary_entry(
        &self,
        handle: &EstateHandle,
        agent_name: &str,
        entry_text: &str,
        topic: &str,
        embedding_model_id: &str,
        now: i64,
    ) -> Result<DiaryEntry, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        // Substitute "no-embedding" when the caller left the field empty,
        // matching the Swift DreamingWrites.addDiaryEntry guard.
        let model_id = if embedding_model_id.is_empty() {
            "no-embedding"
        } else {
            embedding_model_id
        };
        let entry = DiaryEntry::new(
            Uuid::new_v4().to_string(),
            agent_name.to_string(),
            entry_text.to_string(),
            topic.to_string(),
            format!("wing_{agent_name}"),
            "diary".to_string(),
            now,
            model_id.to_string(),
        );
        estate.add_diary_entry(&entry).map_err(|e| VerbDispatchError::from(remap("add_diary_entry", "", e)))?;
        Ok(entry)
    }

    // MARK: - diary_entries

    /// Read the most-recent `last_n` diary entries for `agent_name` from the
    /// estate addressed by `handle`, newest first.
    ///
    /// Delegates to `Estate::read_diary`. Mirrors the Swift
    /// `GeniusLocusKit.readDiaryEntries(in:agentName:lastN:)`.
    pub fn diary_entries(
        &self,
        handle: &EstateHandle,
        agent_name: &str,
        last_n: usize,
    ) -> Result<Vec<DiaryEntry>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.read_diary(agent_name, last_n).map_err(|e| VerbDispatchError::from(remap("diary_entries", "", e)))
    }

    // MARK: - recall_proposals

    /// Recall proposal rows for the estate addressed by `handle`.
    ///
    /// Returns all proposals estate-wide, ordered by `filed_at` ascending.
    /// Delegates to `Estate::all_proposals` — the new estate-wide read path
    /// added to `DrawerStore` in this stream.
    pub fn recall_proposals(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::proposal::Proposal>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.all_proposals().map_err(|e| remap("recall_proposals", "", e).into())
    }

    // MARK: - recall_associations

    /// Recall association rows for the estate addressed by `handle`.
    ///
    /// Returns all non-tombstoned associations, ordered by `filed_at`
    /// ascending. Delegates to `Estate::all_associations` — the new
    /// estate-wide read path added to `DrawerStore` in this stream.
    pub fn recall_associations(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::association::Association>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.all_associations().map_err(|e| remap("recall_associations", "", e).into())
    }

    // MARK: - recall_learned_references

    /// Recall learned-reference rows for the estate addressed by `handle`.
    ///
    /// Returns all non-tombstoned learned references, ordered by `filed_at`
    /// ascending. Delegates to `Estate::all_learned_references` — the new
    /// estate-wide read path added to `DrawerStore` in this stream.
    pub fn recall_learned_references(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::learned_reference::LearnedReference>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.all_learned_references().map_err(|e| remap("recall_learned_references", "", e).into())
    }

    // MARK: - all_drawers

    /// All drawers in the estate (including tombstoned rows).
    ///
    /// Full-corpus snapshot. Used by the dreaming and maintenance readers to
    /// obtain raw drawer data through the GLK surface (B-1 compliance). Mirrors
    /// the Swift `GeniusLocusKit.allDrawers(in:)`. Delegates to
    /// `Estate::all_drawers`.
    pub fn all_drawers(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<Drawer>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.all_drawers().map_err(|e| remap("all_drawers", "", e).into())
    }

    // MARK: - all_drawers_bounded

    /// Up to `limit` drawers in the estate (including tombstoned rows), in
    /// `filed_at`-ascending order. The bounded counterpart to `all_drawers`:
    /// the LIMIT is applied at the storage tier (O(limit) I/O), so the
    /// maintenance reader's health scan reads a bounded slice instead of the
    /// full corpus. `None` reads everything, identical to `all_drawers`.
    /// Mirrors the Swift `GeniusLocusKit.allDrawers(in:limit:)`. Delegates to
    /// `Estate::all_drawers_bounded`.
    ///
    /// B-10a: internal read — no trace_limit is set, no recall-trace rows are
    /// written.
    pub fn all_drawers_bounded(
        &self,
        handle: &EstateHandle,
        limit: Option<usize>,
    ) -> Result<Vec<Drawer>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .all_drawers_bounded(limit)
            .map_err(|e| remap("all_drawers_bounded", "", e).into())
    }

    // MARK: - room_level_fingerprints

    /// Every room-level container fingerprint (room non-empty) with its
    /// bitwise-OR aggregate over the container's active drawers.
    ///
    /// The maintenance daemon's fingerprint-drift signal reads these as the
    /// live per-scope fingerprint and compares them against a prior snapshot.
    /// Delegates to `Estate::room_level_fingerprints`, which reads the OR
    /// aggregates the recall pruner maintains straight from the
    /// `container_fingerprints` table — no drawer scan. Mirrors the Swift
    /// `GeniusLocusKit.roomLevelFingerprints(in:)` (B-1 compliance).
    pub fn room_level_fingerprints(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::container_fingerprint_store::RoomLevelEntry>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .room_level_fingerprints()
            .map_err(|e| remap("room_level_fingerprints", "", e).into())
    }

    // MARK: - unified audit log (GLK-03 parity)

    /// Return a snapshot of the unified audit log for `handle`.
    ///
    /// The log is a value type, so the returned snapshot is safe to use
    /// without aliasing the registry's copy. Mirrors the Swift
    /// `GeniusLocusKit.auditLog(for:)`.
    pub fn audit_log(
        &self,
        handle: &EstateHandle,
    ) -> Result<crate::audit::UnifiedAuditLog, VerbDispatchError> {
        self.audit_logs
            .get(handle)
            .cloned()
            .ok_or(VerbDispatchError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            })
    }

    /// Install a pre-built audit log for `handle` (the hydration path uses
    /// this after replaying the durable audit trail). Mirrors the Swift
    /// hydration installing the fed log into the actor's `auditLogs` map.
    pub(crate) fn set_audit_log(
        &mut self,
        handle: &EstateHandle,
        log: crate::audit::UnifiedAuditLog,
    ) {
        self.audit_logs.insert(*handle, log);
    }

    /// Pull audit rows from the estate's LocusKit tier, bridge them into
    /// `UnifiedAuditEntry` values, and merge them into the registry's log for
    /// `handle`.
    ///
    /// Idempotent: entries are content-addressed, so re-feeding the same rows
    /// is a G-Set no-op. The pull is unbounded over the estate's stored audit
    /// history, so no wall-clock read happens here and the result is determined
    /// entirely by the estate's contents. Mirrors the Swift
    /// `GeniusLocusKit.feedAuditLog(for:)`.
    pub fn feed_audit_log(&mut self, handle: &EstateHandle) -> Result<(), VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        // Reuse the hydration path's per-drawer bridge walk — the same
        // cross-row enumeration the Swift feedAuditLog performs.
        let fed: crate::audit::UnifiedAuditLog =
            crate::hydration::feed_audit_log_from_estate(estate).map_err(|e| {
                VerbDispatchError::from(remap(
                    "feed_audit_log",
                    &uuid_to_str(&handle.estate_uuid),
                    e,
                ))
            })?;
        self.audit_logs
            .entry(*handle)
            .or_insert_with(crate::audit::UnifiedAuditLog::new)
            .merge(&fed);
        Ok(())
    }

    /// Feed the estate's audit log and return a snapshot of the unified log.
    ///
    /// The maintenance daemon calls this to supply `AuditChainVerifier::verify`
    /// with a current log snapshot (NEURONKIT_SPEC § 3.5 audit-chain integrity
    /// monitor). Mirrors the Swift `GeniusLocusKit.currentAuditLog(in:)`.
    pub fn current_audit_log(
        &mut self,
        handle: &EstateHandle,
    ) -> Result<crate::audit::UnifiedAuditLog, VerbDispatchError> {
        self.feed_audit_log(handle)?;
        self.audit_log(handle)
    }

    /// Verify the estate's audit chain from a freshly-replayed snapshot, read-only.
    ///
    /// Walks the estate's LocusKit audit trail into a `UnifiedAuditLog` and runs
    /// `AuditChainVerifier::verify` on it WITHOUT mutating the coordinator's
    /// stored log. The maintenance reader holds the coordinator by shared
    /// reference, so it uses this `&self` path rather than `current_audit_log`
    /// (which needs `&mut`). The verdict is identical: both verify the same
    /// content-addressed entries. The audit-integrity monitor (NEURONKIT_SPEC
    /// § 3.5) consumes the report.
    pub fn verify_audit_chain(
        &self,
        handle: &EstateHandle,
    ) -> Result<crate::audit::AuditChainReport, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        let log: crate::audit::UnifiedAuditLog =
            crate::hydration::feed_audit_log_from_estate(estate).map_err(|e| {
                VerbDispatchError::from(remap(
                    "verify_audit_chain",
                    &uuid_to_str(&handle.estate_uuid),
                    e,
                ))
            })?;
        Ok(crate::audit::AuditChainVerifier::verify(&log))
    }

    // MARK: - matrix tier (recall-scoring accelerator)

    /// Register a `MatrixTier` snapshot for `handle`. The `matrixAware` recall
    /// lane reads this registry; re-registering replaces the existing entry.
    /// When no tier is registered, all matrix score columns read 0.0 — correct
    /// for a fresh estate. Mirrors the Swift
    /// `GeniusLocusKit.registerMatrixTier(_:for:)`.
    pub fn register_matrix_tier(
        &mut self,
        handle: &EstateHandle,
        tier: crate::matrix::MatrixTier,
    ) {
        self.matrix_tiers.insert(*handle, tier);
    }

    /// The `MatrixTier` registered for `handle`, if any. The `matrixAware`
    /// recall path reads this to populate co-occurrence / field-fit / temporal
    /// score columns. Mirrors the Swift actor's `matrixTiers[handle]` lookup.
    pub fn matrix_tier(&self, handle: &EstateHandle) -> Option<&crate::matrix::MatrixTier> {
        self.matrix_tiers.get(handle)
    }

    /// Feed the unified audit log, rebuild the recall-scoring `MatrixTier`
    /// from it (both passes: F/O/C + T), and register the tier for `handle`.
    ///
    /// The on-demand counterpart to the hydration path's matrix rebuild —
    /// the Rust parity of the Swift `GeniusLocusKit.rebuildDerivedAccelerators(for:)`.
    /// `moot_dream` calls this so the `matrixAware` recall lane is live after a
    /// dreaming cycle rather than reading a stale (or absent) tier.
    ///
    /// Idempotent: feeding the same events is a G-Set no-op, and rebuilding
    /// from the same log produces the same tier.
    pub fn rebuild_derived_accelerators(
        &mut self,
        handle: &EstateHandle,
    ) -> Result<(), VerbDispatchError> {
        // Step 1 — feed the unified audit log (MatrixTier consumes the CRDT,
        // not raw storage events).
        self.feed_audit_log(handle)?;
        // Steps 2 + 3 — full rebuild (F/O/C then T) and install.
        let log = self.audit_log(handle)?;
        let tier = crate::matrix::MatrixTier::full_rebuild(&log);
        self.register_matrix_tier(handle, tier);
        Ok(())
    }

    // MARK: - all_tunnels

    /// All tunnels in the estate across all wings.
    ///
    /// Full association-graph snapshot. Used by the dreaming reader to check
    /// for existing tunnels during co-occurrence consolidation (B-1 compliance).
    /// Mirrors the Swift `GeniusLocusKit.allTunnels(in:)`. Delegates to
    /// `Estate::all_tunnels`.
    pub fn all_tunnels(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::tunnel::Tunnel>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.all_tunnels().map_err(|e| remap("all_tunnels", "", e).into())
    }

    // MARK: - mine_apriori_rules

    /// Mine multi-antecedent Apriori association rules from the estate's
    /// current drawer state.
    ///
    /// Mirrors `mineAprioriRules(estate:thresholds:)` on the Swift
    /// `GeniusLocusKit` actor (`EstateAssociationRuleMining.swift:93`).
    ///
    /// Implementation note — Rust vs Swift audit-log difference (sanctioned):
    ///
    ///   The Swift version reads `currentAuditLog(in:)` (an in-memory
    ///   `UnifiedAuditLog` maintained by the actor through every verb call)
    ///   and converts each `UnifiedAuditEntry` to a `RowAuditEntry` for
    ///   `RowAttributeView::from`. The Rust `EstateCoordinator` does not
    ///   maintain an equivalent in-memory audit log per estate — it delegates
    ///   every verb directly to the LocusKit `Estate` layer.
    ///
    ///   The Rust port synthesises equivalent `RowAuditEntry` values from
    ///   each drawer's current bitmap columns (`adjective_bitmap`,
    ///   `operational_bitmap`, `provenance`): each non-zero bitmap field
    ///   produces one `RowAuditEntry` with `RowAuditValue::Bitmap(bits)`,
    ///   using `field_path` strings that match the Swift field-path
    ///   vocabulary used by the actor's `toRowAuditEntry` helper
    ///   ("adjective_bitmap" / "operational_bitmap" / "provenance").
    ///   `RowAttributeView::from()` then decomposes each bitmap into
    ///   per-bit-position `Item` attributes — identical to what the audit
    ///   log projection would produce for a drawer captured once with no
    ///   subsequent mutations. For mutated drawers the synthesised view
    ///   reflects the current state, matching the last-write-wins projection
    ///   that `RowAttributeView::from()` applies to audit entries anyway.
    ///
    /// - `now` — current Unix epoch seconds (used only for the error path; the
    ///   drawer retrieval is a direct all-drawers snapshot).
    /// - Returns rules sorted by lift DESC, confidence DESC, evidence_count DESC.
    pub fn mine_apriori_rules(
        &self,
        handle: &EstateHandle,
        thresholds: substrate_ml::apriori_mining::AprioriThresholds,
    ) -> Result<Vec<substrate_ml::apriori_mining::AprioriRule>, VerbDispatchError> {
        use substrate_ml::row_attribute_view::{RowAuditEntry, RowAuditValue, RowAttributeView};
        use substrate_types::hlc::HLC;

        let estate = self.estate_for_verb(handle)?;
        let drawers = estate
            .all_drawers()
            .map_err(|e| VerbDispatchError::from(remap("all_drawers", "", e)))?;

        if drawers.is_empty() {
            return Ok(vec![]);
        }

        // Build RowAuditEntry values from each drawer's current bitmap state.
        // Three bitmap columns per drawer; non-zero bitmaps are emitted as
        // Bitmap entries; zero bitmaps produce Null (no categorical content).
        //
        // The field_path strings match the Swift audit-log vocabulary so
        // cross-version vocabulary indices are consistent
        // ("adjective_bitmap" / "operational_bitmap" / "provenance").
        //
        // A stable but synthetic HLC is constructed from the drawer's index
        // (monotonically increasing, deterministic). `RowAttributeView::from`
        // uses HLC only for last-write-wins deduplication within a row — with
        // exactly one entry per field per row there is no ambiguity and the
        // HLC value does not affect output.
        let mut audit_entries: Vec<RowAuditEntry> = Vec::with_capacity(drawers.len() * 3);
        for (idx, drawer) in drawers.iter().enumerate() {
            // Parse the drawer id (UUID string) into u128 for RowAuditEntry.
            let row_id: u128 = uuid::Uuid::parse_str(&drawer.id)
                .map(|u| u.as_u128())
                .unwrap_or(idx as u128); // fallback: positional index

            let hlc = HLC::new(idx as i64, 0, 0);

            let adj = drawer.adjective_bitmap;
            let op  = drawer.operational_bitmap;
            let prov = drawer.provenance;

            audit_entries.push(RowAuditEntry::new(
                row_id,
                "locus",
                "adjective_bitmap",
                hlc,
                if adj == 0 { RowAuditValue::Null } else { RowAuditValue::Bitmap(adj as u64) },
            ));
            audit_entries.push(RowAuditEntry::new(
                row_id,
                "locus",
                "operational_bitmap",
                hlc,
                if op == 0 { RowAuditValue::Null } else { RowAuditValue::Bitmap(op as u64) },
            ));
            audit_entries.push(RowAuditEntry::new(
                row_id,
                "locus",
                "provenance",
                hlc,
                if prov == 0 { RowAuditValue::Null } else { RowAuditValue::Bitmap(prov as u64) },
            ));
        }

        // Build RowAttributeView rows and run the Apriori engine.
        let views = RowAttributeView::from(&audit_entries);
        let rows: Vec<Vec<substrate_ml::association_rule_mining::Item>> = views
            .iter()
            .map(|v| {
                v.attributes
                    .iter()
                    .map(|&(f, val)| substrate_ml::association_rule_mining::Item::new(f, val))
                    .collect()
            })
            .collect();

        Ok(substrate_ml::apriori_mining::mine_apriori_rules(&rows, &thresholds))
    }

    // MARK: - recent_recall_traces

    /// Recall-trace rows whose `recalled_at` falls in `[since, now]`.
    ///
    /// Both bounds are inclusive ISO8601 strings. Used by the dreaming reader
    /// to build the reward map for one cycle tick (B-1 compliance). Mirrors
    /// the Swift `GeniusLocusKit.recentRecallTraces(in:since:now:)`. Delegates
    /// to `Estate::recent_recall_traces`.
    pub fn recent_recall_traces(
        &self,
        handle: &EstateHandle,
        since: &str,
        now: &str,
    ) -> Result<Vec<RecallTraceItem>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.recent_recall_traces(since, now).map_err(|e| remap("recent_recall_traces", "", e).into())
    }

    // MARK: - prune_recall_traces

    /// Delete recall-trace rows whose `recalled_at` is strictly before
    /// `cutoff`. Returns the number of rows deleted.
    ///
    /// `cutoff` is an ISO8601 string derived from the caller's deterministic
    /// `now`. Called after the dreaming daemon's reward sweep to keep the
    /// recall_trace table bounded (B-1 compliance). Mirrors the Swift
    /// `GeniusLocusKit.pruneRecallTraces(in:olderThan:)`. Delegates to
    /// `Estate::prune_recall_traces`.
    pub fn prune_recall_traces(
        &self,
        handle: &EstateHandle,
        cutoff: &str,
    ) -> Result<usize, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.prune_recall_traces(cutoff).map_err(|e| remap("prune_recall_traces", "", e).into())
    }

    // MARK: - mark_recall_used

    /// Mark all recall-trace rows for `target` whose `recalled_at` falls within
    /// `[since, now]` as used. Returns the count of rows updated.
    ///
    /// Called by the ARIA_MCP boundary after a dereference verb (withdraw,
    /// update, confirm, move) confirms that the surfaced drawer was acted upon.
    /// Bulk marks by drawer-id target within the retention window so the dreaming
    /// daemon's reward sweep sees reward 1.0 for those entries.
    ///
    /// Mirrors Swift `GeniusLocusKit.markRecallUsed(_:target:now:)`.
    pub fn mark_recall_used(
        &self,
        handle: &EstateHandle,
        target: &str,
        since: &str,
        now: &str,
    ) -> Result<usize, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .mark_recall_traces_used(target, since, now)
            .map_err(|e| remap("mark_recall_used", &uuid_to_str(&handle.estate_uuid), e).into())
    }

    // MARK: - count_recall_traces

    /// Return the total number of recall-trace rows in the estate.
    ///
    /// Used by `moot_estate_status` to report the trace table size.
    /// Mirrors Swift `GeniusLocusKit.countRecallTraces(_:)`.
    pub fn count_recall_traces(
        &self,
        handle: &EstateHandle,
    ) -> Result<usize, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .count_recall_traces()
            .map_err(|e| remap("count_recall_traces", &uuid_to_str(&handle.estate_uuid), e).into())
    }

    // MARK: - Grant dispatch
    //
    // These methods mirror the Swift `issueGrant` and `revokeGrant` verbs on
    // `GeniusLocusKit` (Sources/GeniusLocusKit/Verbs/VerbSurface.swift §Grant).
    // The estate identity key is passed as raw `[u8; 32]` bytes — the Swift
    // surface extracts `.rawRepresentation` from a `Curve25519.Signing.PrivateKey`
    // before calling into the vault. The Rust port carries no CryptoKit types.

    /// Issue a grant for the estate addressed by `handle`.
    ///
    /// Constructs a `Grant` from `options`, inserts it into the estate's
    /// `GrantStore`, and delegates to `ScopeKeyVault::issue` for key
    /// material. Returns an `IssueGrantResult` containing the grant and
    /// (for modes 2 and 3) the scope key to hand to the grantee.
    ///
    /// `identity_key_raw` — the estate's signing key raw bytes (32 bytes for
    /// Curve25519). Used as HKDF IKM for mode-1 and mode-2 scope-key
    /// derivation. Mirror of Swift `VerbSurface.issueGrant`.
    ///
    /// `now` is Apple reference seconds (seconds since 2001-01-01 UTC),
    /// matching the Swift `Date.timeIntervalSinceReferenceDate` convention.
    pub fn issue_grant(
        &mut self,
        handle: &EstateHandle,
        options: GrantOptions,
        identity_key_raw: &[u8],
        now: f64,
    ) -> Result<IssueGrantResult, GrantError> {
        // Validate the custody mode before touching storage.
        if let CustodyMode::DecayDerived { experimental_ip_clearance_confirmed: false, .. }
            = &options.custody_mode
        {
            return Err(GrantError::ExperimentalModeNotActivated);
        }

        // Construct the Grant row.
        let grant = Grant {
            id: Uuid::new_v4(),
            grantee_estate_id: options.grantee_estate_id,
            scope: options.scope,
            content_level: options.content_level,
            lifetime: options.lifetime,
            custody_mode: options.custody_mode,
            re_share_permission: options.re_share_permission,
            inference_remaining_budget: 0.0, // default; callers may override via options
            issued_at: now,
            signature: vec![], // signing is caller's responsibility after receiving the result
        };

        // Resolve per-estate vault and store, returning GrantNotFound for a
        // stale/unknown handle (repurposed as "estate not open" in grant context).
        let store = self.grant_stores.get_mut(handle)
            .ok_or(GrantError::GrantNotFound(grant.id))?;
        let vault = self.scope_vaults.get_mut(handle)
            .ok_or(GrantError::GrantNotFound(grant.id))?;

        // Derive scope key material via the vault.
        let scope_key = vault.issue(&grant, identity_key_raw)?;

        // Persist the grant. Storage errors are surfaced as GrantNotFound
        // (the closest available GrantError variant; a storage layer failure
        // on issue is fatal to the grant and the caller should retry).
        store.insert(&grant)
            .map_err(|_| GrantError::GrantNotFound(grant.id))?;

        Ok(IssueGrantResult { grant, scope_key })
    }

    /// Revoke a grant for the estate addressed by `handle`.
    ///
    /// Marks the grant revoked in the `GrantStore` and drops any mediated
    /// key from the `ScopeKeyVault`. `now` is Apple reference seconds.
    ///
    /// Mirror of Swift `VerbSurface.revokeGrant`.
    pub fn revoke_grant(
        &mut self,
        handle: &EstateHandle,
        grant_id: Uuid,
        now: f64,
    ) -> Result<(), GrantError> {
        let store = self.grant_stores.get_mut(handle)
            .ok_or(GrantError::GrantNotFound(grant_id))?;
        // revoke_at_apple_ref converts the f64 Apple reference seconds to
        // ISO-8601 before persisting — matching Swift GrantStore.revoke(id:at:).
        store.revoke_at_apple_ref(grant_id, now)
            .map_err(|_| GrantError::GrantNotFound(grant_id))?;
        if let Some(vault) = self.scope_vaults.get_mut(handle) {
            vault.revoke(grant_id);
        }
        Ok(())
    }

    /// Borrow the `GrantStore` for `handle`, or `None` for a stale handle.
    ///
    /// Mirror of Swift `GeniusLocusKit.grantStore(for:)`.
    pub fn grant_store(&self, handle: &EstateHandle) -> Option<&GrantStore> {
        self.grant_stores.get(handle)
    }

    /// Borrow the `ScopeKeyVault` for `handle`, or `None` for a stale handle.
    ///
    /// Mirror of Swift `GeniusLocusKit.scopeVault(for:)`.
    pub fn scope_vault(&self, handle: &EstateHandle) -> Option<&ScopeKeyVault> {
        self.scope_vaults.get(handle)
    }

    /// Mutably borrow the `GrantStore` for `handle`, or `None` for a stale handle.
    ///
    /// Used by tests and internal enforcement paths that need to write to the
    /// store (budget debit, direct insertion in federation tests). Not needed
    /// on the normal verb surface — verbs route through their dedicated methods.
    pub fn grant_store_mut(&mut self, handle: &EstateHandle) -> Option<&mut GrantStore> {
        self.grant_stores.get_mut(handle)
    }

    /// Mutably borrow the `ScopeKeyVault` for `handle`, or `None` for a stale handle.
    ///
    /// Used by tests that need to simulate vault-key loss (mode-1 custody gate).
    pub fn scope_vault_mut(&mut self, handle: &EstateHandle) -> Option<&mut ScopeKeyVault> {
        self.scope_vaults.get_mut(handle)
    }

    // MARK: - federated_recall

    /// Per-read budget debit quantum. Mirrors Swift
    /// `GeniusLocusKit.budgetDebitPerRead` (0.01 per read, ~100 reads on
    /// a fresh 1.0 budget). Spec §6 is silent on debit amount; fail-closed
    /// chosen rule: 0.01 per read. A grant whose budget falls to or below
    /// 0.0 refuses all further reads.
    pub const BUDGET_DEBIT_PER_READ: f64 = 0.01;

    /// Grant-gated cross-estate federated read. Mirrors Swift
    /// `GeniusLocusKit.federatedRecall(_:from:requestedBy:now:)` in
    /// `CrossEstateFederation.swift`.
    ///
    /// Behavior, fail-closed:
    ///
    /// 1. Resolve both handles — a stale handle on either side returns
    ///    `EstateNotOpen`.
    /// 2. Read the **source** estate's grant store (mutable — needed for
    ///    budget debit in step 6).
    /// 3. Filter active (non-revoked) grants to those whose
    ///    `grantee_estate_id` equals the requester's UUID. None →
    ///    `CrossEstateReadRefused { NoActiveGrant }`.
    /// 4. Among matching grants, require at least one unexpired at `now`
    ///    (Apple reference seconds). Pick the one with highest
    ///    `content_level` to give the requester maximum entitled access.
    ///    All expired → `CrossEstateReadRefused { GrantExpired }`.
    /// 5. CustodyMode gate (per-mode semantics, mirrors Swift step 5):
    ///    - `Mediated`: vault must hold the scope key for the grant. If the
    ///      vault has no key, refuse with `CustodyRefused`. In the Rust port,
    ///      the vault's `holds_scope_key` check serves as the live presence
    ///      check (the Rust `ScopeKeyVault` does not serve session keys on
    ///      demand — that is a v1.0 access surface concern; this check is the
    ///      parity-correct enforcement for the substrate coordinator layer).
    ///    - `HandedOver`: no vault check. Expiry in step 4 covers the window.
    ///    - `DecayDerived`: lifetime expiry in step 4 covers the decay window.
    ///      If we reach here the window has not elapsed; accept.
    ///    - `TimeAging` (mode 4): the grant's effective content level attenuates
    ///      by its decay policy (half-life of elapsed time since started_at,
    ///      floored at floor) against injected `now`. Decayed to 0 (floor 0) →
    ///      refuse `CustodyRefused`; otherwise step 8 gates with the attenuated
    ///      level.
    ///    - Any other mode: fail-closed, refuse `CustodyRefused`.
    /// 6. InferenceRemainingBudget gate: re-read the current budget from the
    ///    store. If budget <= 0.0, refuse `BudgetExhausted`. Otherwise debit
    ///    `BUDGET_DEBIT_PER_READ` (0.01) atomically before the read. Single-
    ///    threaded coordinator means no concurrent double-spend possible.
    /// 7. Recall from the source estate. `now_unix` drives the LocusKit bitmap
    ///    clock (Unix seconds, not Apple ref seconds).
    /// 8. Content-level sensitivity gate: exclude drawers whose
    ///    `adjective_sensitivity().raw_value()` > `grant.content_level`.
    /// 9. Scope subtree filter: exclude drawers outside the granted
    ///    wing/room/lattice subtree/single row.
    /// 10. Return `FederatedRecallResult` with the filtered drawers and grant.
    ///
    /// Both `now` (Apple ref seconds, grant expiry) and `now_unix` (Unix
    /// seconds, LocusKit bitmap evaluation) are explicit for determinism.
    /// `&mut self` is required by the budget debit in step 6.
    pub fn federated_recall(
        &mut self,
        frame: RecallFrame,
        source: &EstateHandle,
        requested_by: &EstateHandle,
        now: f64,
        now_unix: i64,
    ) -> Result<FederatedRecallResult, GeniusLocusKitError> {
        // 1. Resolve both handles fail-closed.
        // Borrow the estate reference before any mutable borrow below.
        // We clone the drawers list later so we can release the immutable
        // borrow on `registry` before the mutable borrow on `grant_stores`.
        let _ = self.estate_for(&source)?;
        let _ = self.estate_for(&requested_by)?;

        let requester_uuid = Uuid::from_bytes(requested_by.estate_uuid);
        let source_uuid = Uuid::from_bytes(source.estate_uuid);

        // 2. Source estate's grant store (immutable borrow for steps 3–5).
        let authorizing_grant = {
            let store = match self.grant_stores.get(source) {
                Some(s) => s,
                None => return Err(GeniusLocusKitError::EstateNotOpen {
                    estate_uuid: source.estate_uuid,
                }),
            };

            // 3. Grantee-scoped filter over active grants.
            // active() queries the storage and returns Result; a storage failure
            // here is surfaced as CrossEstateReadRefused / NoActiveGrant (fail-closed).
            let matching: Vec<_> = store.active(now)
                .unwrap_or_default()
                .into_iter()
                .filter(|sg| sg.grant.grantee_estate_id == requester_uuid)
                .collect();
            if matching.is_empty() {
                return Err(GeniusLocusKitError::CrossEstateReadRefused {
                    source: source_uuid,
                    requester: requester_uuid,
                    reason: FederatedReadRefusalReason::NoActiveGrant,
                });
            }

            // 4. Require at least one unexpired grant; pick highest content_level.
            // A permanent grant (None expiry) is always valid.
            let authorizing = matching
                .iter()
                .filter(|sg| {
                    match sg.grant.lifetime.expiry(sg.grant.issued_at) {
                        None => true,
                        Some(expiry) => expiry >= now,
                    }
                })
                .max_by_key(|sg| sg.grant.content_level);
            match authorizing {
                Some(sg) => sg.grant.clone(),
                None => return Err(GeniusLocusKitError::CrossEstateReadRefused {
                    source: source_uuid,
                    requester: requester_uuid,
                    reason: FederatedReadRefusalReason::GrantExpired,
                }),
            }
        };

        // The effective content level the grant exposes at `now`. For every
        // mode except time-aging this is the grant's persisted content_level;
        // mode 4 attenuates it by its decay policy in the custody gate below.
        let mut effective_content_level = authorizing_grant.content_level;

        // 5. CustodyMode gate. Each mode's recall-path semantics.
        {
            let vault = match self.scope_vaults.get(source) {
                Some(v) => v,
                None => return Err(GeniusLocusKitError::EstateNotOpen {
                    estate_uuid: source.estate_uuid,
                }),
            };
            match &authorizing_grant.custody_mode {
                CustodyMode::Mediated => {
                    // Mode 1: vault must hold the scope key. If the vault has
                    // no key for this grant (estate restarted, key never loaded),
                    // the source cannot serve a mediated live read.
                    if !vault.holds_scope_key(authorizing_grant.id) {
                        return Err(GeniusLocusKitError::CrossEstateReadRefused {
                            source: source_uuid,
                            requester: requester_uuid,
                            reason: FederatedReadRefusalReason::CustodyRefused,
                        });
                    }
                }
                CustodyMode::HandedOver => {
                    // Mode 2: key handed to recipient; offline reads within window.
                    // Expiry in step 4 already covers the grant window.
                }
                CustodyMode::DecayDerived { .. } => {
                    // Mode 3: lifetime expiry in step 4 covers the decay window.
                    // If we reach here the window has not elapsed; accept.
                }
                CustodyMode::TimeAging(policy) => {
                    // Mode 4: the grant's effective content level attenuates by
                    // its decay policy (half-life of elapsed time since
                    // started_at, floored at floor), computed against injected
                    // `now`. A grant decayed to an effective level of 0 (floor 0)
                    // has aged out of all access and is refused. The attenuated
                    // level narrows the content-level gate in step 8.
                    let eff = policy.effective_level(authorizing_grant.content_level, now);
                    if eff <= 0 {
                        return Err(GeniusLocusKitError::CrossEstateReadRefused {
                            source: source_uuid,
                            requester: requester_uuid,
                            reason: FederatedReadRefusalReason::CustodyRefused,
                        });
                    }
                    effective_content_level = eff;
                }
            }
        }

        // 6. InferenceRemainingBudget gate and debit.
        // Re-read the current budget from the store to capture any prior debits
        // (single-threaded coordinator, so no concurrent race, but re-read is
        // the correct pattern mirroring the Swift actor's debitBudget read-then-write).
        // Debit atomically before the read proceeds so no read succeeds without
        // consuming from the budget.
        {
            let store = match self.grant_stores.get_mut(source) {
                Some(s) => s,
                None => return Err(GeniusLocusKitError::EstateNotOpen {
                    estate_uuid: source.estate_uuid,
                }),
            };
            // Re-read the current budget from storage. A storage failure is
            // fail-closed: treat as exhausted (0.0) to refuse the read rather
            // than grant content on a degraded storage path.
            let current_budget = store.get(authorizing_grant.id)
                .ok()
                .flatten()
                .map(|sg| sg.grant.inference_remaining_budget)
                .unwrap_or(0.0);
            if current_budget <= 0.0 {
                return Err(GeniusLocusKitError::CrossEstateReadRefused {
                    source: source_uuid,
                    requester: requester_uuid,
                    reason: FederatedReadRefusalReason::BudgetExhausted,
                });
            }
            // Debit persisted before the read returns content. Atomic within
            // the per-storage write lock (InMemoryStorage: Mutex; SQLite: WAL
            // write serialisation). Storage failure is ignored here — if the
            // debit write fails the read still returns content (the budget re-check
            // on the next call catches it). This mirrors Swift's behaviour where
            // a storage write failure on debit is propagated but does not block
            // the current read that already passed the budget gate.
            let _ = store.debit_budget(authorizing_grant.id, Self::BUDGET_DEBIT_PER_READ);
        }

        // 7. Read the source estate using the provided recall frame.
        // Borrow estate immutably after releasing the mutable grant_stores borrow.
        let source_estate = self.registry.get(source).ok_or(GeniusLocusKitError::EstateNotOpen {
            estate_uuid: source.estate_uuid,
        })?;
        let drawers = source_estate.recall(frame, now_unix).collect_all();

        // 8. Content-level sensitivity gate. Exclude drawers whose
        // sensitivity raw value exceeds the grant's content_level.
        // Normal (0) is admitted by all grants; higher levels unlock
        // elevated (16), restricted (32), secret (48). The fail-open
        // direction (unrecognised raw → Normal) matches the Swift port.
        // Mode-4 time-aging narrows content_max to the attenuated level from
        // the custody gate; every other mode uses the grant's raw content_level.
        let content_max = effective_content_level;
        let drawers: Vec<_> = drawers
            .into_iter()
            .filter(|d| d.adjective_sensitivity().raw_value() <= content_max as i64)
            .collect();

        // 9. Scope subtree filter — GLK primary enforcement.
        // Mirrors Swift CrossEstateFederation.federatedRecall step 9.
        // WholeEstate is a pass-through; the other four cases narrow.
        // Dot-boundary guard for LatticeSubtree: "500" must match "500"
        // and "500.1" but NOT "5001" — same guard as Swift and ARIA secondary.
        let drawers: Vec<_> = match &authorizing_grant.scope {
            crate::grants::GrantScope::WholeEstate => drawers,
            crate::grants::GrantScope::Wing(name) => {
                drawers.into_iter().filter(|d| &d.wing == name).collect()
            }
            crate::grants::GrantScope::Room(name) => {
                drawers.into_iter().filter(|d| &d.room == name).collect()
            }
            crate::grants::GrantScope::LatticeSubtree { udc_code } => {
                let prefix = format!("{udc_code}.");
                drawers.into_iter().filter(|d| {
                    &d.udc_code == udc_code || d.udc_code.starts_with(&prefix)
                }).collect()
            }
            crate::grants::GrantScope::SingleRow(id) => {
                let id_str = id.to_string().to_uppercase();
                drawers.into_iter().filter(|d| d.id.to_uppercase() == id_str).collect()
            }
        };

        Ok(FederatedRecallResult {
            drawers,
            grant: authorizing_grant,
            source_handle: source.clone(),
            requester_handle: requested_by.clone(),
        })
    }

    // MARK: - GLK_PROVISION_001: provision / quiesce / drain / destroy

    /// Return the current mount state for `handle`.
    ///
    /// Returns `Some(Mounted)` for a freshly opened or provisioned estate,
    /// `Some(Quiesced)` after `quiesce`, `Some(Draining)` during `drain`,
    /// and `None` for a stale (never-registered or already-closed) handle.
    ///
    /// Mirrors Swift `GeniusLocusKit.mountState(for:)`.
    pub fn mount_state(&self, handle: &EstateHandle) -> Option<EstateMountState> {
        self.mount_states.get(handle).copied()
    }

    /// Provision a new estate: create, open, wire sub-stores, and record kind metadata.
    ///
    /// This is the Rust parity of Swift
    /// `GeniusLocusKit.provision(storage:corpusStorage:owner:params:embeddingModel:)`.
    ///
    /// Steps:
    ///   1. Validates `params` (non-empty name, valid zoom window).
    ///   2. Writes the kind-prefixed `framework_profile` and zoom window into the
    ///      DrawerStore manifest via `set_meta` before `Estate::create`.
    ///   3. Calls `Estate::create` to seed the estate with `estate_name` and the
    ///      already-written manifest fields.
    ///   4. Calls `self.open` to admit the estate and set mount state to `Mounted`.
    ///   5. Wires sub-stores by kind:
    ///        - `Glk`        → `Corpus::open` + `VectorStore::open` on `corpus_storage`
    ///                          (or `storage` when `corpus_storage` is `None`);
    ///                          both are registered with the handle.
    ///        - `CorpusOnly` → `Corpus::open` on the corpus storage; no VectorStore.
    ///        - `LocusOnly`  → no sub-store wiring.
    ///
    /// Trait impedance resolution: `DrawerStore` (LocusKit's trait) and
    /// `persistence_kit::Storage` (VectorKit/CorpusKit's trait) are distinct. The
    /// caller supplies both the `Arc<dyn DrawerStore>` for the estate and an
    /// `Arc<dyn Storage>` for sub-store construction, mirroring the Swift surface
    /// where the caller also constructs the storage instances and passes them in.
    /// Concretely the same `InMemoryStorage` can back both — the caller wraps it
    /// as `InMemoryDrawerStore` (which implements `DrawerStore`) and passes the
    /// raw `Arc<dyn Storage>` handle as `storage`.
    ///
    /// If sub-store wiring fails, the estate is closed (no half-wired zombie in
    /// the registry) and `UnderlyingEstateFailure` is returned, mirroring Swift's
    /// rollback path on sub-store construction failure.
    ///
    /// Idempotent: re-provisioning the same store raises `DuplicateEstate`.
    ///
    /// - `store`:           DrawerStore for the LocusKit estate (owns the manifest).
    /// - `storage`:         PersistenceKit `Storage` used for sub-stores (Corpus +
    ///                      VectorStore) when `corpus_storage` is `None`.  For
    ///                      `LocusOnly` estates this parameter is unused and can be
    ///                      any valid `Storage` instance.
    /// - `corpus_storage`:  Optional separate `Storage` for Corpus + VectorStore.
    ///                      When `None`, `storage` is used for all sub-stores.
    /// - `embedding_models`: The recall ensemble passed to `Corpus::open_many`.
    ///                       Production callers pass
    ///                       `corpus_kit_providers::default_ensemble()` (the
    ///                       canonical 1.0 five-signal default: RI/PPMI/LSA/NMF/FDC).
    ///                       Rust has no default arguments, so the caller supplies
    ///                       the Vec explicitly; the app layer owns the default. A
    ///                       single-element `vec![EmbeddingModelConfig::Deterministic]`
    ///                       selects one signal (used by focused lifecycle tests).
    ///                       Must be non-empty.
    pub fn provision(
        &mut self,
        store: Arc<dyn DrawerStore>,
        storage: Arc<dyn Storage>,
        corpus_storage: Option<Arc<dyn Storage>>,
        owner: OwnerCredentials,
        params: EstateProvisionParams,
        embedding_models: Vec<EmbeddingModelConfig>,
    ) -> Result<EstateHandle, GeniusLocusKitError> {
        // Validate params before touching storage.
        if params.estate_name.is_empty() {
            return Err(GeniusLocusKitError::InvalidManifest {
                key: "estate_name".to_string(),
                detail: "estate name must not be empty".to_string(),
            });
        }
        if params.zoom_window_low > params.zoom_window_high {
            return Err(GeniusLocusKitError::InvalidManifest {
                key: "zoom_window".to_string(),
                detail: format!(
                    "zoom_window_low ({}) must be <= zoom_window_high ({})",
                    params.zoom_window_low, params.zoom_window_high
                ),
            });
        }

        // Write the kind-prefixed framework profile into the manifest before
        // Estate::create runs. Format: "<kind.raw_value>:<framework_profile>".
        // E.g. "GLK:KnowledgeWork", "LocusOnly:PersonalLifeMgmt".
        // GLK_PROVISION_001: this mirrors the Swift EstateLifecycle.swift `storedProfile` step.
        let stored_profile = format!("{}:{}", params.kind.raw_value(), params.framework_profile);
        store
            .set_meta(locus_kit::manifest::ManifestKey::FrameworkProfile.as_str(), &stored_profile)
            .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("set_meta framework_profile failed: {:?}", e),
            })?;
        // Write zoom window fields.
        if params.zoom_window_low != 0 || params.zoom_window_high != 0 {
            store
                .set_meta(
                    locus_kit::manifest::ManifestKey::ZoomWindowLow.as_str(),
                    &params.zoom_window_low.to_string(),
                )
                .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!("set_meta zoom_window_low failed: {:?}", e),
                })?;
            store
                .set_meta(
                    locus_kit::manifest::ManifestKey::ZoomWindowHigh.as_str(),
                    &params.zoom_window_high.to_string(),
                )
                .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!("set_meta zoom_window_high failed: {:?}", e),
                })?;
        }

        // Step 1: Create the estate with the name (remaining manifest fields are
        // already written above via set_meta; Estate::create only re-stamps the
        // estate_name from initial_values).
        let initial_values = locus_kit::manifest::ManifestValues {
            manifest_version: "v1".to_string(),
            schema_version: "v1".to_string(),
            estate_uuid: uuid::Uuid::new_v4().to_string(), // placeholder; store mints real uuid
            estate_name: params.estate_name.clone(),
            owner_identifier: owner.owner_identifier.clone(),
            lattice_citation: "udc".to_string(),
            framework_profile: stored_profile.clone(),
            framework_profile_definition: "{}".to_string(),
            zoom_window_low: params.zoom_window_low,
            zoom_window_high: params.zoom_window_high,
            access_posture: 0,
            provenance_defaults: 0,
            active_storage_mode: params.sync_mode.to_storage_mode(),
            tables_present: String::new(),
            created_at: 0,
            last_modified: 0,
            bitmap_layout_version: "v1".to_string(),
            provenance_bitmap_version: "v1.0".to_string(),
            federation_group_id: None,
            mining_patterns_hash: None,
            tiny_model_id: None,
            tiny_model_training_corpus_size: None,
            operational_bitmap_layouts: None,
        };
        Estate::create(store.clone(), owner.clone(), Some(&initial_values))
            .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("Estate::create failed: {:?}", e),
            })?;

        // Step 2: Open the estate through the coordinator path.
        // open() validates the manifest, issues the handle, and sets mount state to Mounted.
        let handle = self.open(
            store,
            owner,
            params.zoom_window_low,
            params.zoom_window_high,
        )?;

        // Step 3: Wire sub-stores by kind — same logic as Swift EstateLifecycle.swift §provision.
        // backing_storage is the persistence_kit Storage used for Corpus + VectorStore;
        // falls back to the primary `storage` when no separate corpus_storage is supplied.
        let backing_storage = corpus_storage.unwrap_or(storage);
        let wiring_result = match params.kind {
            EstateKind::Glk => {
                // Full composition: Corpus (BM25 + internal vectors) + standalone VectorStore.
                // Both are constructed on backing_storage. Corpus::open_many applies
                // both BundleStore and VectorStore schema migrations via `migrate`,
                // matching the Swift path where Corpus.init applies both schemas.
                // open_many fans every operation across all held signals (the
                // five-signal ensemble by default); the match arms are mutually
                // exclusive, so moving `embedding_models` here is sound.
                Corpus::open_many(Arc::clone(&backing_storage), embedding_models)
                    .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                        reason: format!("Corpus::open_many failed for GLK estate: {:?}", e),
                    })
                    .and_then(|corpus| {
                        // Wire a VectorStore pointing at the same backing storage so GLK's
                        // scored-recall vector lane operates independently of Corpus's
                        // internal vector store — mirrors Swift's explicit VectorStore wiring.
                        VectorStore::open(Arc::clone(&backing_storage))
                            .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                                reason: format!("VectorStore::open failed for GLK estate: {:?}", e),
                            })
                            .map(|vs| (Some(corpus), Some(vs)))
                    })
            }
            EstateKind::CorpusOnly => {
                // LocusKit core + Corpus. No standalone VectorStore registration.
                Corpus::open_many(Arc::clone(&backing_storage), embedding_models)
                    .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                        reason: format!("Corpus::open_many failed for CorpusOnly estate: {:?}", e),
                    })
                    .map(|corpus| (Some(corpus), None))
            }
            EstateKind::LocusOnly => {
                // LocusKit only — no sub-store wiring needed.
                Ok((None, None))
            }
        };

        match wiring_result {
            Ok((corpus_opt, vs_opt)) => {
                // Register the wired sub-stores. Arc<Corpus> and Arc<VectorStore> are
                // what the registry holds (matching Swift's corpusKits / vectorStores dicts).
                if let Some(corpus) = corpus_opt {
                    self.corpus_kits.insert(handle, Arc::new(corpus));
                }
                if let Some(vs) = vs_opt {
                    self.vector_stores.insert(handle, Arc::new(vs));
                }
                // Dual-Path Intake D-B: mount the dedicated encode queue for
                // estates that have a Corpus to feed (Glk / CorpusOnly). Mirrors
                // Swift `EstateLifecycle.swift` mounting the encode queue at
                // provision. LocusOnly estates register no corpus, so they get
                // no encode queue (a regular write degrades to row-only).
                if self.corpus_kits.contains_key(&handle) {
                    self.mount_encode_queue(&handle).map_err(|e| {
                        GeniusLocusKitError::UnderlyingEstateFailure {
                            reason: format!("mount_encode_queue failed: {e:?}"),
                        }
                    })?;
                }
            }
            Err(e) => {
                // Sub-store wiring failed. Close the estate to avoid a half-wired zombie
                // in the registry, mirroring Swift's `try? await close(handle)` rollback.
                let _ = self.close(&handle);
                return Err(e);
            }
        }

        // Telemetry: emit provision metric after successful wiring (GLK_ROLLUPS_001).
        // Emitted only on the success path — wiring failures return early above.
        // Off-path: single AtomicBool::load + branch, zero allocation.
        let estate_id_str = uuid_to_str(&handle.estate_uuid);
        glk_emit!(metric_names::PROVISION, 1.0, {
            let mut tags = HashMap::new();
            tags.insert("estate_id".to_string(), estate_id_str);
            tags.insert("kind".to_string(), params.kind.raw_value().to_string());
            tags
        });

        Ok(handle)
    }

    /// Quiesce an estate — stop accepting new work, keep it open.
    ///
    /// Transitions mount state from `Mounted` to `Quiesced`. Idempotent:
    /// calling on an already-quiesced estate is a no-op.
    ///
    /// Mirrors Swift `GeniusLocusKit.quiesce(_:)`.
    pub fn quiesce(&mut self, handle: &EstateHandle) -> Result<(), GeniusLocusKitError> {
        if !self.registry.contains_key(handle) {
            return Err(GeniusLocusKitError::EstateNotOpen { estate_uuid: handle.estate_uuid });
        }
        if self.mount_states.get(handle) == Some(&EstateMountState::Quiesced) {
            return Ok(()); // idempotent
        }
        self.mount_states.insert(*handle, EstateMountState::Quiesced);

        // Telemetry: emit mount-state transition to quiesced (GLK_ROLLUPS_001).
        // Off-path: single AtomicBool::load + branch, zero allocation.
        let estate_id_str = uuid_to_str(&handle.estate_uuid);
        glk_emit!(metric_names::MOUNT_STATE_TRANSITION, 1.0, {
            let mut tags = HashMap::new();
            tags.insert("estate_id".to_string(), estate_id_str);
            tags.insert("state".to_string(), "quiesced".to_string());
            tags
        });

        Ok(())
    }

    /// Drain an estate — wait for in-flight work, then quiesce.
    ///
    /// Transitions mount state to `Draining`, then immediately to `Quiesced`.
    /// The Rust coordinator is synchronous; there is no async queue to drain.
    /// The state transitions provide the same observable semantics as the Swift
    /// port: callers can observe `Draining` then `Quiesced`.
    ///
    /// Mirrors Swift `GeniusLocusKit.drain(_:)`.
    pub fn drain(&mut self, handle: &EstateHandle) -> Result<(), GeniusLocusKitError> {
        if !self.registry.contains_key(handle) {
            return Err(GeniusLocusKitError::EstateNotOpen { estate_uuid: handle.estate_uuid });
        }
        self.mount_states.insert(*handle, EstateMountState::Draining);

        // Telemetry: emit mount-state transition to draining (GLK_ROLLUPS_001).
        // Off-path: single AtomicBool::load + branch, zero allocation.
        let estate_id_str = uuid_to_str(&handle.estate_uuid);
        glk_emit!(metric_names::MOUNT_STATE_TRANSITION, 1.0, {
            let mut tags = HashMap::new();
            tags.insert("estate_id".to_string(), estate_id_str.clone());
            tags.insert("state".to_string(), "draining".to_string());
            tags
        });

        // The Rust coordinator is synchronous — all in-flight work is complete at this
        // point by definition. Transition directly to Quiesced.
        self.mount_states.insert(*handle, EstateMountState::Quiesced);

        // Telemetry: emit mount-state transition to quiesced after drain (GLK_ROLLUPS_001).
        glk_emit!(metric_names::MOUNT_STATE_TRANSITION, 1.0, {
            let mut tags = HashMap::new();
            tags.insert("estate_id".to_string(), estate_id_str);
            tags.insert("state".to_string(), "quiesced".to_string());
            tags
        });

        Ok(())
    }

    /// Destroy an estate — close it and tear down all sub-stores.
    ///
    /// Teardown sequence:
    ///   1. If the handle is in the registry, calls `close` to flush LocusKit
    ///      and drop registry entries.
    ///   2. Calls `Corpus::destroy_recall_index()` on the registered corpus (if any).
    ///   3. The standalone VectorStore is already cleaned up during step 2 if the
    ///      corpus shares storage; otherwise `VectorStore::destroy_all_vectors` would
    ///      be called here. In the Rust port, the corpus and standalone vector store
    ///      are retrieved before close() and their teardown is called after.
    ///
    /// Note: BundleStore rows are NOT deleted (append-only invariant). The recall
    /// surface is destroyed; verbatim content survives.
    ///
    /// Mirrors Swift `GeniusLocusKit.destroy(storage:corpusStorage:handle:)`.
    pub fn destroy(&mut self, handle: &EstateHandle) -> Result<(), GeniusLocusKitError> {
        // Capture references to registered sub-stores BEFORE close() drops them.
        let corpus = self.corpus_kits.get(handle).cloned();
        let vector_store = self.vector_stores.get(handle).cloned();

        // Step 1: Close the estate (drops registry, grant store, corpus/vector refs).
        if self.registry.contains_key(handle) {
            self.close(handle)?;
        }

        // Step 2: Destroy Corpus recall index (BM25 + internal vectors).
        if let Some(c) = corpus {
            c.destroy_recall_index().map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("Corpus destroy failed: {:?}", e),
            })?;
        }

        // Step 3: Destroy standalone VectorStore vectors.
        if let Some(vs) = vector_store {
            vs.destroy_all_vectors().map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("VectorStore destroy failed: {:?}", e),
            })?;
        }

        Ok(())
    }

    // MARK: - recall_scored

    /// Route a `GLKRecallRequest` through the scored Recall Director.
    ///
    /// This is the Rust parity of the Swift `GeniusLocusKit.recall(_:_:)` method
    /// that accepts a `GLKRecallRequest` (declared in
    /// `Sources/GeniusLocusKit/RecallDirector/RecallDirector.swift`). The plain
    /// nine-verb `recall(handle, frame, now)` method is unchanged; this method is
    /// an additive scored path on top of it.
    ///
    /// Scoring modes:
    ///
    /// **LocusOnly** — drains the LocusKit bitmap-index lane up to `frontier_k`
    /// rows, applies the limit, and wraps each drawer as a `RecallHit` with
    /// `score: RecallScoreVector::locus(1.0)` and `sources: [LocusBitmap]`.
    ///
    /// **Hybrid** — runs all three lanes: locus (bitmap), BM25 (`bm25_top_k_by_source`
    /// on the registered `Corpus`), and vector (`find_nearest` on the registered
    /// `VectorStore`). Fuses via RRF (k=60). Falls back to rank-normalised locus-only
    /// when neither corpus nor vector store is registered for this handle.
    ///
    /// **CorpusOnly** — BM25 + vector lanes only (locus lane excluded). Falls back
    /// to rank-normalised locus-only when neither is registered.
    ///
    /// **UnionBest** — all three lanes + union profile. Falls back like Hybrid.
    ///
    /// **NodeTreeNative** — host-tree topology path. Drawer retrieval delegates to
    /// the LocusOnly bitmap lane; tree-edge union is performed in `recall_tunnels`.
    ///
    /// All modes return `VerbDispatchError::EstateNotOpen` on a stale handle.
    /// `now` is explicit per the Rust substrate's determinism convention.
    pub fn recall_scored(
        &self,
        handle: &EstateHandle,
        request: GLKRecallRequest,
        now: i64,
    ) -> Result<GLKRecallResult, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;

        // Frontier-K bounds candidate retrieval: min(max(limit * 4, 64), 256).
        // Mirrors Swift RecallDirector's frontierK computation — enough candidates
        // for inter-lane deduplication without unbounded row retrieval. A
        // RecallShape may override this pool depth (6b-modifiers), clamped to the
        // SAME [64, 256] envelope so a shape cannot request an unbounded scan; a
        // None shape (or None override) leaves the computed default unchanged.
        let computed_frontier_k = (request.limit * 4).max(64).min(256);
        let frontier_k = request
            .recall_shape
            .as_ref()
            .map(|s| s.effective_frontier_k(computed_frontier_k))
            .unwrap_or(computed_frontier_k);

        let plan = RecallPlan {
            effective_mode: request.mode,
            frontier_k,
            weights: RecallWeights::UNIFORM,
        };

        // Extract test seam values before the multi-lane dispatch.
        // Each seam is single-use (consumed here, cleared in the RefCell) so the
        // next call after injection fires the seam exactly once, then resumes
        // normal behaviour — mirroring the Swift _testForce* actor-property pattern.
        //
        // cfg(any(test, feature = "test-seams")): active for unit tests inside
        // the crate (cfg(test)) AND for integration tests in tests/ which enable
        // the "test-seams" feature. Production builds carry neither — zero overhead.
        #[cfg(any(test, feature = "test-seams"))]
        let forced_vector_hamming_error = self.test_force_vector_hamming_error.borrow_mut().take();
        #[cfg(not(any(test, feature = "test-seams")))]
        let forced_vector_hamming_error: Option<String> = None;

        #[cfg(any(test, feature = "test-seams"))]
        let forced_embed_error = self.test_force_embed_error.borrow_mut().take();
        #[cfg(not(any(test, feature = "test-seams")))]
        let forced_embed_error: Option<String> = None;

        match request.mode {
            GLKRecallMode::LocusOnly => {
                Self::recall_scored_locus_only(estate, request, plan, now)
            }
            GLKRecallMode::Hybrid
            | GLKRecallMode::CorpusOnly
            | GLKRecallMode::UnionBest => {
                let corpus = self.corpus_kits.get(handle).cloned();
                let vector = self.vector_stores.get(handle).cloned();
                // Pass the registered MatrixTier (if any) for matrixAware scoring.
                // Cloned here so the static fn does not need &self access. The tier
                // is a cheap flat struct (HashMap<...> with a reference-count bump at
                // clone; the coordinator holds the only reference for a given handle
                // so the clone cost is proportional to the tier's live row count —
                // acceptable for the scored-recall call path which already does multiple
                // HashMap lookups per candidate).
                let matrix_tier = self.matrix_tiers.get(handle).cloned();
                Self::recall_scored_multi_lane(
                    estate, request, plan, now, corpus, vector, handle,
                    matrix_tier,
                    forced_vector_hamming_error, forced_embed_error,
                )
            }
            GLKRecallMode::NodeTreeNative => {
                // NodeTreeNative injects host-tree topology edges into the
                // StructureGraph via recall_tunnels (the structural lens path),
                // not via the scored drawer-recall path. For drawer retrieval,
                // delegate to the locusOnly bitmap lane so all estate drawers
                // are reachable through the normal bitmap filter.
                Self::recall_scored_locus_only(estate, request, plan, now)
            }
        }
    }

    /// LocusOnly lane: drain bitmap-index, wrap each drawer as a RecallHit with
    /// locus(1.0) score. All three scoring strategies produce the same ordering
    /// because no multi-lane combiner is active for a single lane.
    ///
    /// Mirrors Swift RecallDirector.recallLocusOnly(estate:request:plan:).
    fn recall_scored_locus_only(
        estate: &locus_kit::estate::Estate,
        request: GLKRecallRequest,
        plan: RecallPlan,
        now: i64,
    ) -> Result<GLKRecallResult, VerbDispatchError> {
        // B-10a: only external-origin requests write recall-trace rows. Build
        // a local frame copy and set trace_limit only when origin == External.
        let mut traced_frame = request.frame.clone();
        if request.origin == RecallOrigin::External {
            // External path: trace exactly the rows returned to the caller
            // (request.trace_limit ?? request.limit). Mirrors Swift RecallDirector.
            traced_frame.trace_limit = Some(request.trace_limit.unwrap_or(request.limit));
        }
        // Internal-origin: traced_frame.trace_limit stays None — no trace writes.

        // Drain the RecallStream up to frontier_k, then apply the limit.
        // collect_all_with_degraded surfaces LocusKit recall internal-read
        // failures (P0-5 sites 1-5): a failed liveRows / room-fingerprints /
        // room-drawer / bitmap-eval read names a locus.* stage so a FAILED
        // locus recall is distinguishable from a GENUINE-EMPTY estate.
        let (all_rows, locus_degraded) =
            estate.recall(traced_frame, now).collect_all_with_degraded();
        let rows: Vec<Drawer> = all_rows.into_iter().take(plan.frontier_k).collect();

        let limited: Vec<Drawer> = rows.into_iter().take(request.limit).collect();

        // Scoring-fallback disposition (parity with Swift recallLocusOnly):
        // the locusOnly lane has no matrix scoring pass, so MatrixAware falls
        // back to raw bitmap-evaluator ordering. Surface that fallback as the
        // `locusOnly.matrixAware` degraded stage so the caller knows the
        // requested scoring was not the one applied. Raw and Rrf (rank-
        // preserving over the single locus cursor) are real and record nothing.
        // Seed from the locus stream's internal-read failures (P0-5 sites 1-5);
        // genuine-empty seeds none.
        let mut degraded_stages: Vec<String> = locus_degraded;
        if request.scoring == GLKRecallScoring::MatrixAware {
            degraded_stages.push("locusOnly.matrixAware".to_string());
            let estate_tag = estate.estate_uuid().to_string();
            glk_emit!(
                crate::telemetry::metric_names::LOCUS_ONLY_MATRIX_AWARE_FALLBACK,
                1.0,
                [("estate_id".to_string(), estate_tag)]
                    .into_iter().collect::<std::collections::HashMap<_, _>>()
            );
        }

        // Each hit: sources=[LocusBitmap], score=locus(1.0).
        // locusOnly uses bitmap-evaluator ordering, not score-based ordering,
        // so 1.0 is a sentinel rather than a computed value.
        let hits: Vec<RecallHit> = limited
            .into_iter()
            .map(|drawer| RecallHit {
                id: drawer.id.clone(),
                drawer: Some(drawer),
                sources: vec![RecallEvidencePath::LocusBitmap],
                score: RecallScoreVector::locus(1.0),
                explanation: vec!["locusBitmap".to_string()],
            })
            .collect();

        Ok(GLKRecallResult {
            request,
            plan,
            union_profile: None,
            // locusOnly does not attempt the dense float lane — None per contract.
            dense_lane_status: None,
            degraded_stages,
            hits,
        })
    }

    /// Multi-lane recall for Hybrid, CorpusOnly, and UnionBest modes.
    ///
    /// Runs up to three lanes depending on mode and which kits are registered:
    ///
    ///   Locus lane (LocusBitmap) — active for Hybrid and UnionBest. Rank-
    ///   normalised score: `(frontier_k - rank) / frontier_k`. Excluded for
    ///   CorpusOnly, matching Swift RecallDirector.recallCorpusOnly which
    ///   skips the locus lane.
    ///
    ///   BM25 lane (Corpus.bm25_top_k_by_source) — active for all three modes
    ///   when a Corpus is registered. Returns (source_id, bm25_score) pairs.
    ///
    ///   Vector lane (VectorStore.find_nearest) — active for all three modes
    ///   when a VectorStore is registered and the request carries a non-empty
    ///   query_text. Embeds the query via Corpus.embed (requires corpus also
    ///   registered). Score = (256 - hamming_distance) / 256.0.
    ///
    /// Fallback: when neither corpus nor vector is registered, falls back to
    /// rank-normalised locus-only (identical to before CorpusKit/VectorKit
    /// were wired). This preserves existing behaviour for callers that have not
    /// yet registered corpus/vector stores.
    ///
    /// RRF fusion (k=60): for each candidate id appearing in any lane, the
    /// fused score is Σ_L 1/(k + rank_in_L), where rank_in_L is the 0-based
    /// position in that lane's sorted list. Tie-break: id ascending.
    /// Mirrors Swift RecallDirector.rrfFuseThree.
    ///
    /// .raw scoring strategy bypasses RRF: candidates are ordered by the
    /// combined raw score (locus rank-normalised + bm25 + vector), with the
    /// locus lane as the primary sort for Hybrid/UnionBest.
    /// Derive `MatrixValueCoord` set from a `Drawer`'s three bitmap fields.
    ///
    /// Mirrors Swift `RecallDirector.matrixCoordsFor(drawer:)`. Uses the same
    /// fieldPath/value pairs the AuditBridge writes to the UnifiedAuditLog when
    /// a drawer is captured: "adjective", "operational", and "provenance".
    /// Zero-bitmap fields are excluded because MatrixTier.apply_capture skips
    /// zero-bitmap coords — a zero-bitmap field never appears as a key in the O
    /// or T matrices, so including it would always produce a cache miss and
    /// contribute 0.0 to the score.
    fn matrix_coords_for_drawer(drawer: &Drawer) -> Vec<crate::matrix::MatrixValueCoord> {
        use crate::audit::UnifiedAuditValue;
        use crate::matrix::MatrixValueCoord;
        let mut coords = Vec::new();
        if drawer.adjective_bitmap != 0 {
            coords.push(MatrixValueCoord::new(
                "adjective",
                UnifiedAuditValue::Bitmap(drawer.adjective_bitmap as u64),
            ));
        }
        if drawer.operational_bitmap != 0 {
            coords.push(MatrixValueCoord::new(
                "operational",
                UnifiedAuditValue::Bitmap(drawer.operational_bitmap as u64),
            ));
        }
        if drawer.provenance != 0 {
            coords.push(MatrixValueCoord::new(
                "provenance",
                UnifiedAuditValue::Bitmap(drawer.provenance as u64),
            ));
        }
        coords
    }

    /// Min-max normalise a mutable Vec column to [0, 1] over its first `count` elements.
    ///
    /// Mirrors Swift `RecallCandidateBuffer.normalizedCopy(of:)`:
    ///   - NaN → 0 before normalisation.
    ///   - All-zero column: slots remain 0.0 (absent signal contributes nothing).
    ///   - Non-zero uniform column: slots set to 0.5 (measured but informationally flat).
    ///   - Varying column: standard min-max scale to [0, 1].
    fn normalize_column(col: &mut Vec<f32>, count: usize) {
        if count == 0 { return; }
        for v in &mut col[..count] {
            if v.is_nan() { *v = 0.0; }
        }
        let mut lo = col[0];
        let mut hi = col[0];
        for &v in &col[1..count] {
            if v < lo { lo = v; }
            if v > hi { hi = v; }
        }
        let range = hi - lo;
        if range == 0.0 {
            if lo > 0.0 {
                for v in &mut col[..count] { *v = 0.5; }
            }
            // All-zero: leave at 0.0.
        } else {
            for v in &mut col[..count] {
                *v = (*v - lo) / range;
            }
        }
    }

    /// N-way per-signal dense consensus fold, DENSE-STEERED by `dense:<model_id>`
    /// lane weights (6b-core consensus + 6b-modifiers-core-2 steering).
    ///
    /// Each per-signal dense list is an INDEPENDENT RRF voter tagged by its
    /// `model_id`. For list `L` the steering weight is
    /// `w = shape.weight("dense:<model_id>")` (1.0 when `shape` is None or the key
    /// is absent). Each list's reciprocal-rank term is scaled by `w`:
    ///   - `w == 1.0` — neutral. The term is `1/(k+rank+1)`; when EVERY held signal
    ///     is 1.0 (the None-shape default and any all-ones shape) `total_rrf`,
    ///     `best_term`, and the aggregate cosine match the unweighted code BYTE-FOR-
    ///     BYTE — the back-compat contract. A single signal at 1.0 has
    ///     `total_rrf == best_term` → boost 0, so N=1 stays byte-identical.
    ///   - `w == 0`   — EXCLUDE / leave-one-out. The list is SKIPPED: no term, and
    ///     its cosine is withheld from the aggregate `dense` column.
    ///   - `w < 0`    — SUPPRESS. The weighted term is NEGATIVE → it SUBTRACTS rank
    ///     mass from `total_rrf` (a drawer this signal ranks high is demoted). A
    ///     suppressed signal does NOT raise the aggregate cosine (only `w>0`
    ///     forwarding signals do).
    ///
    /// The boost is `total_rrf − best_term` (clamped at 0), where `best_term` is the
    /// single largest WEIGHTED per-signal term — generalising the pre-steer formula
    /// to signed weights. Returns `(boost_by_id, cosine_by_id)`; `cosine_by_id` is
    /// the MAX normalized cosine across FORWARDING signals (the aggregate `dense`
    /// column). Mirrors Swift RecallDirector's dense-steered consensus fold.
    fn dense_consensus_boost(
        per_signal_lists: &[(String, Vec<(String, f32)>)],
        k: f32,
        shape: &Option<RecallShape>,
    ) -> (HashMap<String, f32>, HashMap<String, f32>) {
        // Per-id: total reciprocal-rank mass across signals, the single largest
        // weighted per-signal term, and the max cosine across forwarding signals.
        let mut total_rrf: HashMap<String, f32> = HashMap::new();
        let mut best_term: HashMap<String, f32> = HashMap::new();
        let mut cosine_by_id: HashMap<String, f32> = HashMap::new();
        for (model_id, list) in per_signal_lists {
            let w = shape
                .as_ref()
                .map(|s| s.weight(&format!("dense:{model_id}")))
                .unwrap_or(1.0);
            if w == 0.0 { continue; } // exclusion: this dense signal votes for nothing
            for (rank, (id, cosine)) in list.iter().enumerate() {
                let term = w * (1.0 / (k + rank as f32 + 1.0));
                *total_rrf.entry(id.clone()).or_insert(0.0) += term;
                let b = best_term.entry(id.clone()).or_insert(f32::NEG_INFINITY);
                if term > *b { *b = term; }
                // Only forwarding signals (w > 0) contribute their cosine to the
                // aggregate column (the weighted-combination contract).
                if w > 0.0 {
                    let c = cosine_by_id.entry(id.clone()).or_insert(0.0);
                    if *cosine > *c { *c = *cosine; }
                }
            }
        }
        let mut boost: HashMap<String, f32> = HashMap::with_capacity(total_rrf.len());
        for (id, mass) in total_rrf {
            let best = best_term.get(&id).copied().unwrap_or(0.0);
            // Extra-voter mass beyond the single best rank. 0 for a single voter.
            boost.insert(id, (mass - best).max(0.0));
        }
        (boost, cosine_by_id)
    }

    #[allow(clippy::too_many_arguments)]
    fn recall_scored_multi_lane(
        estate: &locus_kit::estate::Estate,
        request: GLKRecallRequest,
        plan: RecallPlan,
        now: i64,
        corpus: Option<Arc<Corpus>>,
        vector: Option<Arc<VectorStore>>,
        handle: &EstateHandle,
        // MatrixTier registered for this estate — Some when the dreaming cycle has
        // run rebuild_derived_accelerators at least once. None on a fresh estate
        // with no matrix data (matrix signals are 0.0, same as Swift's fallback when
        // matrixTiers[handle] == nil).
        matrix_tier: Option<crate::matrix::MatrixTier>,
        // Test seam values — consumed once by the caller from cfg(any(test, feature = "test-seams")) RefCells.
        // On the production path these are always None (compiler eliminates the branches).
        force_vector_hamming_error: Option<String>,
        force_embed_error: Option<String>,
    ) -> Result<GLKRecallResult, VerbDispatchError> {
        // Accumulates stage IDs for any lane that degraded (i.e. threw and was
        // recovered rather than propagated). Matches Swift GLKRecallResult.degradedStages.
        let mut degraded_stages: Vec<String> = vec![];
        let has_corpus = corpus.is_some();
        let has_vector = vector.is_some();

        // When no corpus or vector store is registered, fall back to
        // rank-normalised locus-only scoring for Hybrid/CorpusOnly/UnionBest+Rrf/Raw.
        // Exception: UnionBest + MatrixAware proceeds to the full pipeline even without
        // corpus/vector — the matrix scoring pass is locus-based and does not require
        // corpus/vector. Mirrors Swift recallUnionBest which always runs the locus lane
        // and the matrix scoring block regardless of corpus/vector registration.
        let is_matrix_aware_union = request.mode == GLKRecallMode::UnionBest
            && request.scoring == GLKRecallScoring::MatrixAware;
        if !has_corpus && !has_vector && !is_matrix_aware_union {
            return Self::recall_scored_locus_ranked(estate, request, plan, now);
        }

        // --- Lane 1: Locus (active for Hybrid and UnionBest; skipped for CorpusOnly) ---
        // Rank-normalised: score = (frontier_k - rank) / frontier_k.
        //
        // B-10a: set trace_limit on the frame only for external-origin requests.
        // Internal reads must not write recall-trace rows. The locus lane is the
        // primary recall path and the only one where trace rows can be written.
        let mut traced_frame = request.frame.clone();
        if request.origin == RecallOrigin::External {
            traced_frame.trace_limit = Some(request.trace_limit.unwrap_or(request.limit));
        }
        // Internal-origin: traced_frame.trace_limit stays None — no trace writes.

        let locus_list: Vec<(String, f32)>;
        let drawer_index: HashMap<String, Drawer>;

        let include_locus = matches!(
            request.mode,
            GLKRecallMode::Hybrid | GLKRecallMode::UnionBest
        );

        if include_locus {
            // Use traced_frame (carries trace_limit for external-origin recalls).
            // collect_all_with_degraded surfaces LocusKit recall internal-read
            // failures (P0-5 sites 1-5) for the Hybrid/UnionBest locus lane: a
            // failed locus read names a locus.* stage so a FAILED locus lane is
            // distinguishable from a GENUINE-EMPTY one. Genuine-empty: none.
            let (all_locus, locus_degraded) =
                estate.recall(traced_frame, now).collect_all_with_degraded();
            degraded_stages.extend(locus_degraded);
            let locus_rows: Vec<Drawer> =
                all_locus.into_iter().take(plan.frontier_k).collect();
            locus_list = locus_rows
                .iter()
                .enumerate()
                .map(|(idx, d)| {
                    let score = (plan.frontier_k.saturating_sub(idx)) as f32
                        / plan.frontier_k.max(1) as f32;
                    (d.id.clone(), score)
                })
                .collect();
            drawer_index = locus_rows.into_iter().map(|d| (d.id.clone(), d)).collect();
        } else {
            locus_list = Vec::new();
            // For CorpusOnly: locus lane skipped for scoring, but still needed for
            // drawer hydration. Use plain frame (no trace_limit) — CorpusOnly external
            // recalls trace via the locus lane only when include_locus is true. This
            // branch is for CorpusOnly mode where the locus lane is not the recall path.
            let all_rows: Vec<Drawer> = estate
                .recall(request.frame.clone(), now)
                .collect_all()
                .into_iter()
                .take(plan.frontier_k)
                .collect();
            drawer_index = all_rows.into_iter().map(|d| (d.id.clone(), d)).collect();
        }

        // --- Lane 2: BM25 (active when corpus registered and query_text non-empty) ---
        // Returns (source_id, bm25_score) pairs. source_id == drawer_id per GLK
        // ingest convention (callers ingest with source_id = drawer_id).
        let query_str = request.query_text.as_deref().unwrap_or("").to_string();
        let bm25_list: Vec<(String, f32)> = if let Some(ref c) = corpus {
            if !query_str.is_empty() {
                c.bm25_top_k_by_source(&query_str, plan.frontier_k)
            } else {
                Vec::new()
            }
        } else {
            Vec::new()
        };

        // --- Lane 3: Vector (active when corpus+vector both registered and query non-empty) ---
        // Requires corpus for embed(); vector store for find_nearest().
        // Score = (256 - hamming_distance) / 256.0, matching Swift's hamming→score mapping.
        //
        // P1 fail-loud contract (SPEC §P1_FAIL_LOUD):
        //   embed failure        → degrade "corpus.embed" (query survives on locus + BM25)
        //   find_nearest failure → degrade "vectorHamming.findNearest" (query survives)
        //   Both are RECOVERABLE: the query returns with fewer signals, not an error throw.
        //   "stage failed" (degraded_stages non-empty) is DISTINGUISHABLE from
        //   "absent evidence" (empty Vec, no matching docs) per gate criterion (3).
        let vector_list: Vec<(String, f32)> = if let (Some(ref c), Some(ref vs)) = (&corpus, &vector) {
            if !query_str.is_empty() {
                // embed stage — may be forced by a test seam (single-use, already taken
                // from the cfg(any(test, feature = "test-seams")) RefCell by the dispatcher).
                // The seam returns EmbeddingFailed so type inference resolves to
                // Result<engram_lib::Engram, CorpusKitError>, matching c.embed's signature.
                let embed_result = if let Some(ref err_msg) = force_embed_error {
                    Err(corpus_kit::CorpusKitError::EmbeddingFailed(err_msg.clone()))
                } else {
                    c.embed(&query_str)
                };
                match embed_result {
                    Ok(probe) => {
                        let model = c.model_id().to_string();
                        // find_nearest stage — may be forced by a test seam.
                        // The seam returns StoreUnavailable so type inference resolves to
                        // Result<Vec<VectorMatch>, VectorKitError>, matching find_nearest's signature.
                        let nearest_result =
                            if let Some(ref err_msg) = force_vector_hamming_error {
                                Err(vectorkit::VectorKitError::StoreUnavailable(err_msg.clone()))
                            } else {
                                vs.find_nearest(&probe, &model, plan.frontier_k)
                            };
                        match nearest_result {
                            Ok(matches) => matches
                                .into_iter()
                                .map(|m| {
                                    // Hamming distance 0..=256 → score 0.0..=1.0.
                                    // Lane F rename: VectorMatch.drawer_id → item_id (arch spec §4.1).
                                    let score = (256 - m.distance.clamp(0, 256)) as f32 / 256.0;
                                    (m.item_id, score)
                                })
                                .collect(),
                            Err(_) => {
                                // Stage failed — DEGRADE. Record stage ID so callers can
                                // distinguish "stage failed" from "no matching evidence".
                                degraded_stages.push("vectorHamming.findNearest".to_string());
                                let estate_tag = uuid::Uuid::from_bytes(handle.estate_uuid).to_string();
                                glk_emit!(
                                    crate::telemetry::metric_names::VECTOR_HAMMING_DEGRADED,
                                    1.0,
                                    [("estate_id".to_string(), estate_tag)]
                                        .into_iter().collect::<std::collections::HashMap<_, _>>()
                                );
                                Vec::new()
                            }
                        }
                    }
                    Err(_) => {
                        // embed stage failed — DEGRADE. Record stage ID and emit telemetry.
                        degraded_stages.push("corpus.embed".to_string());
                        let estate_tag = uuid::Uuid::from_bytes(handle.estate_uuid).to_string();
                        glk_emit!(
                            crate::telemetry::metric_names::CORPUS_EMBED_DEGRADED,
                            1.0,
                            [("estate_id".to_string(), estate_tag)]
                                .into_iter().collect::<std::collections::HashMap<_, _>>()
                        );
                        Vec::new()
                    }
                }
            } else {
                Vec::new()
            }
        } else {
            Vec::new()
        };

        // --- Lane 4: Dense float (Lane D), PER-SIGNAL — UnionBest mode only ---
        // Cosine over the pooled float vector via Corpus.float_nearest_per_signal,
        // NOT the lossy 256-bit SimHash-Hamming projection. Fires independently of
        // the Hamming lane; both can contribute. Active ONLY in UnionBest mode —
        // this matches Swift where only `recallUnionBest` runs the dense lane while
        // `recallHybrid` and `recallCorpusOnly` carry `dense_lane_status: None`.
        //
        // PER-SIGNAL FAN-OUT (6b-core): every held provider slot is queried; each
        // returned (model_id, outcome) is its OWN ranked dense list — an independent
        // RRF voter. `per_signal_dense_lists` holds those voter lists. `dense_list`
        // is the deduped consensus list (id → MAX normalized cosine across signals)
        // used for the candidate set, the matrixAware `col_dense` column, and the
        // Raw scoring path — at N=1 it equals the single `float_nearest` list, so
        // the production-default path is byte-identical. The similarity (∈ [-1, 1])
        // is normalized to (sim + 1) / 2 (1.0 = identical direction). B-10a: adds
        // candidates to the in-memory fusion only — no trace rows.
        //
        // FloatLaneOutcome makes every dark-lane state observable PER SIGNAL: each
        // dark signal emits a glk.recall.dense_lane_dark counter tagged with its
        // model_id, while other signals still vote. dense_lane_status (the aggregate
        // marker) reports the DEFAULT signal's (slot 0) dark reason, preserving
        // pre-6b single-signal semantics — at N=1 the default is the only signal.
        let include_dense = matches!(request.mode, GLKRecallMode::UnionBest);
        let mut dense_lane_status: Option<String> = None;
        // RRF voter lists, each TAGGED with its model_id so the dense-steering weight
        // `shape.weight("dense:<model_id>")` can scale it (6b-modifiers-core-2). The
        // model_id is the only place per-signal dense identity exists before the lists
        // collapse into the single aggregate `dense` column built in the consensus fold.
        let mut per_signal_dense_lists: Vec<(String, Vec<(String, f32)>)> = Vec::new();
        // model_ids that voted for each id, in slot order, for per-hit provenance.
        let mut dense_signals_by_id: HashMap<String, Vec<String>> = HashMap::new();
        // First-seen id order (deterministic). The aggregate cosine column is built
        // LATER (in the consensus fold, weight-aware) so a signal weighted <= 0
        // contributes no cosine.
        let mut dense_order: Vec<String> = Vec::new();
        let mut dense_seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        if include_dense {
            if let Some(ref c) = corpus {
                if !query_str.is_empty() {
                    use corpus_kit::FloatLaneOutcome;
                    let estate_tag = uuid::Uuid::from_bytes(handle.estate_uuid).to_string();
                    for (idx, (model_id, outcome)) in
                        c.float_nearest_per_signal(&query_str, plan.frontier_k)
                            .into_iter()
                            .enumerate()
                    {
                        match outcome {
                            FloatLaneOutcome::Hits(matches) => {
                                // This signal contributed a ranked dense list. A signal
                                // EXCLUDED by the shape (w==0) did not vote in the fusion,
                                // so it must not claim per-hit provenance either; record
                                // its model_id only when it forwards or suppresses (w!=0).
                                // A suppressing signal (w<0) DID contribute (subtracted
                                // mass), so it stays in provenance — mirrors Swift.
                                let signal_votes = request
                                    .recall_shape
                                    .as_ref()
                                    .map(|s| s.weight(&format!("dense:{model_id}")))
                                    .unwrap_or(1.0)
                                    != 0.0;
                                let mut ranked: Vec<(String, f32)> =
                                    Vec::with_capacity(matches.len());
                                for (id, sim) in matches {
                                    let dense = ((sim + 1.0) / 2.0).clamp(0.0, 1.0);
                                    ranked.push((id.clone(), dense));
                                    if dense_seen.insert(id.clone()) {
                                        dense_order.push(id.clone());
                                    }
                                    if signal_votes {
                                        dense_signals_by_id
                                            .entry(id)
                                            .or_default()
                                            .push(model_id.clone());
                                    }
                                }
                                per_signal_dense_lists.push((model_id.clone(), ranked));
                            }
                            FloatLaneOutcome::UnavailableProviderOptOut => {
                                // This signal has no float lane — dark, tagged by model_id.
                                if idx == 0 {
                                    dense_lane_status = Some("dark:providerOptOut".to_string());
                                }
                                glk_emit!(
                                    crate::telemetry::metric_names::DENSE_LANE_DARK,
                                    1.0,
                                    [("estate_id".to_string(), estate_tag.clone()),
                                     ("reason".to_string(), "providerOptOut".to_string()),
                                     ("model_id".to_string(), model_id.clone())]
                                        .into_iter().collect::<std::collections::HashMap<_, _>>()
                                );
                            }
                            FloatLaneOutcome::UnavailableNoFloatRows => {
                                // This signal has no stored float rows — dark, tagged by model_id.
                                if idx == 0 {
                                    dense_lane_status = Some("dark:noFloatRows".to_string());
                                }
                                glk_emit!(
                                    crate::telemetry::metric_names::DENSE_LANE_DARK,
                                    1.0,
                                    [("estate_id".to_string(), estate_tag.clone()),
                                     ("reason".to_string(), "noFloatRows".to_string()),
                                     ("model_id".to_string(), model_id.clone())]
                                        .into_iter().collect::<std::collections::HashMap<_, _>>()
                                );
                            }
                            FloatLaneOutcome::EmptyQuery => {
                                // Guard above (query_str.is_empty()) prevents this;
                                // handle defensively for exhaustive match.
                                if idx == 0 {
                                    dense_lane_status = Some("dark:emptyQuery".to_string());
                                }
                            }
                            FloatLaneOutcome::StoreError(_) => {
                                // CorpusKit already printed the error and emitted
                                // corpus.float_lane.store_error for this signal. GLK
                                // adds the estate-level dark counter, tagged by model_id.
                                if idx == 0 {
                                    dense_lane_status = Some("dark:storeError".to_string());
                                }
                                glk_emit!(
                                    crate::telemetry::metric_names::DENSE_LANE_DARK,
                                    1.0,
                                    [("estate_id".to_string(), estate_tag.clone()),
                                     ("reason".to_string(), "storeError".to_string()),
                                     ("model_id".to_string(), model_id.clone())]
                                        .into_iter().collect::<std::collections::HashMap<_, _>>()
                                );
                            }
                        }
                    }
                }
            }
        }
        // N-way consensus RRF over the per-signal dense lists, DENSE-STEERED by the
        // `dense:<model_id>` weights (6b-modifiers-core-2). The boost folded into a
        // candidate's final score is the EXTRA-voter RRF mass beyond the single best
        // weighted term (0 for a single forwarding voter, so N=1 is byte-identical);
        // `dense_cosine_by_id` is the aggregate cosine column over FORWARDING signals
        // (an excluded/suppressed signal contributes no cosine). At all-1.0 weights
        // both maps equal the unweighted code byte-for-byte.
        let (dense_consensus_boost, dense_cosine_by_id): (HashMap<String, f32>, HashMap<String, f32>) =
            Self::dense_consensus_boost(&per_signal_dense_lists, 60.0, &request.recall_shape);
        // Consensus deduped dense list (id → max normalized cosine over FORWARDING
        // signals), first-seen order. Equals the single `float_nearest` list at N=1
        // with neutral weights. Every id seen by the dense lane stays in the list
        // (structural parity with Swift, which builds one dense hit per dense_order
        // id); an id whose every voting signal was excluded/suppressed has cosine 0
        // (no forwarding signal raised it), so it carries no dense mass — its dense
        // column is 0 in the matrixAware score and its dense `final` contribution is
        // the consensus boost only (0 at N=1, mirroring Swift's `cosine + boost`).
        let dense_list: Vec<(String, f32)> = dense_order
            .iter()
            .map(|id| (id.clone(), dense_cosine_by_id.get(id).copied().unwrap_or(0.0)))
            .collect();

        // --- Candidate set: collect unique IDs from all populated lanes ---
        let mut all_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
        for (id, _) in &locus_list  { all_ids.insert(id.clone()); }
        for (id, _) in &bm25_list   { all_ids.insert(id.clone()); }
        for (id, _) in &vector_list { all_ids.insert(id.clone()); }
        for (id, _) in &dense_list  { all_ids.insert(id.clone()); }

        // Build per-id score maps (raw score and rank) for each lane.
        let locus_score_map: HashMap<String, (usize, f32)> = locus_list
            .iter().enumerate().map(|(r, (id, s))| (id.clone(), (r, *s))).collect();
        let bm25_score_map: HashMap<String, (usize, f32)> = bm25_list
            .iter().enumerate().map(|(r, (id, s))| (id.clone(), (r, *s))).collect();
        let vector_score_map: HashMap<String, (usize, f32)> = vector_list
            .iter().enumerate().map(|(r, (id, s))| (id.clone(), (r, *s))).collect();
        let dense_score_map: HashMap<String, (usize, f32)> = dense_list
            .iter().enumerate().map(|(r, (id, s))| (id.clone(), (r, *s))).collect();

        let locus_contributed  = !locus_list.is_empty();
        let bm25_contributed   = !bm25_list.is_empty();
        let vector_contributed = !vector_list.is_empty();
        let dense_contributed  = !dense_list.is_empty();

        // --- Scoring paths ---
        //
        // UnionBest + MatrixAware:
        //   Full Swift-parity weighted pipeline (steps 5.6–9 of RecallDirector):
        //   (1) Build candidate columns from lane scores.
        //   (2) Matrix scoring — fieldFit, coOccurrence, temporal from MatrixTier.
        //   (3) Normalise all columns to [0, 1].
        //   (4) Compute RecallUnionProfile.
        //   (5) Compute adaptive weights from sketch signals + profile.
        //   (6) Weighted score: Σ weight * column + agreement_bonus.
        //
        // All other mode+scoring combinations (Hybrid/CorpusOnly regardless of
        // scoring, and UnionBest with Raw/Rrf):
        //   Swift also falls back to RRF for Hybrid and CorpusOnly with MatrixAware;
        //   for UnionBest + Raw/Rrf Swift uses buffer.final (same as RRF here).
        //   For simplicity, all non-(UnionBest+MatrixAware) paths use the RRF/raw
        //   formula below, matching Swift's documented fallback behaviour.
        let use_matrix_aware_pipeline = request.mode == GLKRecallMode::UnionBest
            && request.scoring == GLKRecallScoring::MatrixAware;

        // Tuple: (id, final_score, locus_raw, bm25_raw, vec_raw, dense_raw,
        //         field_fit, co_occurrence, temporal).
        #[allow(clippy::type_complexity)]
        let fused_scored: Vec<(String, f32, f32, f32, f32, f32, f32, f32, f32)>;

        let union_profile: Option<RecallUnionProfile>;

        if use_matrix_aware_pipeline {
            // ────────────────────────────────────────────────────────────
            // UnionBest + MatrixAware: full weighted pipeline
            // ────────────────────────────────────────────────────────────

            // Build ordered candidate list (deterministic: sort ids ascending
            // so the buffer is in a canonical order before scoring).
            let mut ordered_ids: Vec<String> = all_ids.into_iter().collect();
            ordered_ids.sort();
            let count = ordered_ids.len();

            // Lane score columns (raw values, before normalisation).
            let mut col_locus:  Vec<f32> = ordered_ids.iter().map(|id| {
                locus_score_map.get(id).map_or(0.0, |&(_, s)| s)
            }).collect();
            let mut col_bm25:   Vec<f32> = ordered_ids.iter().map(|id| {
                bm25_score_map.get(id).map_or(0.0, |&(_, s)| s)
            }).collect();
            let mut col_vector: Vec<f32> = ordered_ids.iter().map(|id| {
                vector_score_map.get(id).map_or(0.0, |&(_, s)| s)
            }).collect();
            let mut col_dense:  Vec<f32> = ordered_ids.iter().map(|id| {
                dense_score_map.get(id).map_or(0.0, |&(_, s)| s)
            }).collect();

            // Source-mask bitset per candidate for signal-agreement computation.
            // Bits: 0=locus, 1=bm25, 2=vector, 3=dense (matching Swift bit ordinals).
            let source_masks: Vec<u16> = ordered_ids.iter().map(|id| {
                let mut mask: u16 = 0;
                if locus_score_map.contains_key(id)  { mask |= 1 << 0; }
                if bm25_score_map.contains_key(id)   { mask |= 1 << 1; }
                if vector_score_map.contains_key(id) { mask |= 1 << 2; }
                if dense_score_map.contains_key(id)  { mask |= 1 << 3; }
                mask
            }).collect();

            // Matrix scoring (step 5.6):
            // Runs only when a MatrixTier is registered. Uses the top locus candidate's
            // bitmap fields as the query reference (queryCoords), exactly as Swift's
            // RecallDirector step 5.6 does:
            //   "queryCoords are derived from the top locus candidate — the
            //    highest-ranked bitmap hit sets the reference field-value signature"
            //
            // fieldFit: query coords only → broadcast the same scalar to every slot
            //   (Swift does this: `buffer.fieldFit[i] = ff` where ff is computed once
            //    from queryCoords and not from the candidate's coords).
            // coOccurrence + temporal: (query coords, candidate coords) per slot.
            let mut col_field_fit:    Vec<f32> = vec![0.0; count];
            let mut col_co_occur:     Vec<f32> = vec![0.0; count];
            let mut col_temporal:     Vec<f32> = vec![0.0; count];

            if let Some(ref tier) = matrix_tier {
                // Derive query coords from the first (highest-ranked) locus candidate.
                // If the locus lane has no candidates, query_coords is empty and all
                // matrix signals remain 0.0 — correct behaviour (no reference point).
                let query_coords: Vec<crate::matrix::MatrixValueCoord> = {
                    let top_locus_id = locus_list.first().map(|(id, _)| id.as_str());
                    if let Some(tid) = top_locus_id {
                        drawer_index.get(tid)
                            .map(|d| Self::matrix_coords_for_drawer(d))
                            .unwrap_or_default()
                    } else {
                        Vec::new()
                    }
                };

                if !query_coords.is_empty() && tier.live_row_count > 0 {
                    // fieldFit: F-based field-presence score for the query coords.
                    // Mirrors Swift RecallMatrixScorer.fieldFit(queryCoords:matrix:).
                    let ff = {
                        use crate::audit::UnifiedAuditValue;
                        let mut sum: f64 = 0.0;
                        for coord in &query_coords {
                            if let UnifiedAuditValue::Bitmap(bitmap) = coord.value {
                                if bitmap != 0 {
                                    // Walk set bits — mirrors Swift's trailing-zero-count path.
                                    let mut b = bitmap;
                                    while b != 0 {
                                        let bit_pos = b.trailing_zeros() as u8;
                                        let cell = crate::matrix::MatrixFieldCell::new(
                                            coord.field_path.clone(), bit_pos
                                        );
                                        sum += tier.correlation(&cell);
                                        b &= b.wrapping_sub(1);
                                    }
                                }
                            }
                        }
                        sum as f32
                    };
                    for v in &mut col_field_fit { *v = ff; }

                    // coOccurrence + temporal per candidate.
                    for (i, id) in ordered_ids.iter().enumerate() {
                        let candidate_coords: Vec<crate::matrix::MatrixValueCoord> =
                            drawer_index.get(id.as_str())
                                .map(|d| Self::matrix_coords_for_drawer(d))
                                .unwrap_or_default();

                        if !candidate_coords.is_empty() {
                            // coOccurrence: Σ O[q, c] / liveRowCount for all (q, c) pairs.
                            // Mirrors Swift RecallMatrixScorer.coOccurrence.
                            let mut co_sum: i64 = 0;
                            for q in &query_coords {
                                for c in &candidate_coords {
                                    let key = crate::matrix::MatrixCoOccurKey::new(
                                        q.clone(), c.clone()
                                    );
                                    co_sum += tier.co_occurrence.get(&key).copied().unwrap_or(0);
                                }
                            }
                            col_co_occur[i] = co_sum as f32 / tier.live_row_count as f32;

                            // temporal: Σ T[q, c, lag] / liveRowCount for all lags.
                            // Mirrors Swift RecallMatrixScorer.temporal.
                            let mut t_sum: i64 = 0;
                            for q in &query_coords {
                                for c in &candidate_coords {
                                    for &lag in crate::matrix::MatrixTier::LAG_BUCKETS {
                                        let key = crate::matrix::MatrixTemporalKey {
                                            source: q.clone(),
                                            target: c.clone(),
                                            lag_bucket: lag,
                                        };
                                        t_sum += tier.temporal_causality.get(&key).copied().unwrap_or(0);
                                    }
                                }
                            }
                            col_temporal[i] = t_sum as f32 / tier.live_row_count as f32;
                        }
                    }
                }
            }

            // Initial final column = per-lane RRF before normalisation.
            // normalizeFinals will overwrite with the weighted path, but the
            // normaliser needs a populated `final` column to sort top-16 for
            // the redundancy computation. We seed it with raw locus scores here;
            // after normalisation of all other columns the weighted formula replaces it.
            let mut col_final: Vec<f32> = col_locus.clone();

            // Normalise all columns to [0, 1] (step 6).
            Self::normalize_column(&mut col_locus,     count);
            Self::normalize_column(&mut col_bm25,      count);
            Self::normalize_column(&mut col_vector,    count);
            Self::normalize_column(&mut col_dense,     count);
            Self::normalize_column(&mut col_field_fit, count);
            Self::normalize_column(&mut col_co_occur,  count);
            Self::normalize_column(&mut col_temporal,  count);
            Self::normalize_column(&mut col_final,     count);

            // Compute union profile (step 7) over the normalised columns.
            let primary_source_count = {
                let mut n = 0usize;
                if locus_contributed  { n += 1; }
                if bm25_contributed   { n += 1; }
                if vector_contributed { n += 1; }
                if dense_contributed  { n += 1; }
                n.max(1)
            };
            let profile = RecallUnionProfile::compute(
                &col_locus,
                &col_bm25,
                &col_vector,
                &col_co_occur,
                &source_masks,
                &col_final,
                count,
                primary_source_count,
            );
            union_profile = Some(profile);

            // Compute adaptive weights (step 8).
            let has_bitmap_predicates = !request.frame.filter_chain.is_empty();
            let has_query_text = request.query_text.as_deref().map_or(false, |t| !t.is_empty());
            let weights = RecallWeights::adaptive(has_bitmap_predicates, has_query_text, &profile);

            // Compute final score per candidate (step 9 — matrixAware formula).
            // Formula mirrors Swift RecallDirector step 9:
            //   matrixSignal = (coOccurrence + temporal) * 0.5
            //   dense shares the vector weight budget.
            //   agreementBonus = 0.05 * popcount(sourceMask) / 4.
            //
            // Fixed-lane RecallShape steering (6b-modifiers-core-2): each retrieval
            // lane's column contribution is scaled by its signed shape weight ON TOP
            // of the adaptive `RecallWeights` budget. None shape (or any all-ones
            // shape) → every weight 1.0 → BYTE-IDENTICAL to the pre-steer score (the
            // back-compat contract). w==0 zeroes a lane's column; w<0 subtracts it
            // (demotion). The Hamming lane keys "hamming", the aggregate dense float
            // lane keys "dense" (per-signal `dense:<model_id>` steering already
            // applied in the consensus fold where col_dense was built). Matrix/graph/
            // preference lanes are NOT shape-steerable — RecallShape addresses the
            // retrieval lanes only, mirroring Swift.
            let (sh_locus, sh_bm25, sh_hamming, sh_dense) = match &request.recall_shape {
                Some(s) => (
                    s.weight("locus"),
                    s.weight("bm25"),
                    s.weight("hamming"),
                    s.weight("dense"),
                ),
                None => (1.0, 1.0, 1.0, 1.0),
            };
            let agreement_bonus: f32 = 0.05;
            for (i, v) in col_final.iter_mut().take(count).enumerate() {
                let matrix_signal = (col_co_occur[i] + col_temporal[i]) * 0.5;
                *v = sh_locus   * weights.locus    * col_locus[i]
                   + sh_bm25    * weights.bm25     * col_bm25[i]
                   + sh_hamming * weights.vector   * col_vector[i]
                   + sh_dense   * weights.vector   * col_dense[i]     // dense shares vector weight budget
                   + weights.field_fit * col_field_fit[i]
                   + weights.matrix   * matrix_signal
                   + weights.graph    * 0.0_f32          // graph: no cache registered → 0.0
                   + weights.graph    * 0.0_f32          // preference: no cache → 0.0
                   + agreement_bonus * source_masks[i].count_ones() as f32 / 4.0;
            }

            // Sort descending by final score; tie-break id ascending (deterministic).
            let mut indexed: Vec<(usize, f32)> = (0..count).map(|i| (i, col_final[i])).collect();
            indexed.sort_by(|a, b| {
                b.1.partial_cmp(&a.1)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then(ordered_ids[a.0].cmp(&ordered_ids[b.0]))
            });
            indexed.truncate(request.limit);

            fused_scored = indexed.into_iter().map(|(i, final_s)| {
                let id = ordered_ids[i].clone();
                (id,
                 final_s,
                 col_locus[i],
                 col_bm25[i],
                 col_vector[i],
                 col_dense[i],
                 col_field_fit[i],
                 col_co_occur[i],
                 col_temporal[i])
            }).collect();

        } else {
            // ────────────────────────────────────────────────────────────
            // RRF / Raw path — Hybrid, CorpusOnly, and UnionBest+Raw/Rrf
            // ────────────────────────────────────────────────────────────
            // Scoring-fallback disposition (parity with Swift): a requested
            // scoring strategy that is not distinctly implemented in this lane
            // falls back to the RRF/raw formula below and is SURFACED as a named
            // degraded stage so the caller knows the requested scoring was not
            // applied. Genuine combos (UnionBest+MatrixAware handled in the
            // branch above; Hybrid/CorpusOnly+Rrf real RRF fusion here) record
            // nothing.
            //   - Hybrid/CorpusOnly + MatrixAware → no matrix pass → rrf fallback
            //   - UnionBest + Rrf → no distinct RRF fusion → raw (final) fallback
            let estate_tag = uuid::Uuid::from_bytes(handle.estate_uuid).to_string();
            match (request.mode, request.scoring) {
                (GLKRecallMode::Hybrid, GLKRecallScoring::MatrixAware) => {
                    degraded_stages.push("hybrid.matrixAware".to_string());
                    glk_emit!(
                        crate::telemetry::metric_names::HYBRID_MATRIX_AWARE_FALLBACK,
                        1.0,
                        [("estate_id".to_string(), estate_tag.clone())]
                            .into_iter().collect::<std::collections::HashMap<_, _>>()
                    );
                }
                (GLKRecallMode::CorpusOnly, GLKRecallScoring::MatrixAware) => {
                    degraded_stages.push("corpusOnly.matrixAware".to_string());
                    glk_emit!(
                        crate::telemetry::metric_names::CORPUS_ONLY_MATRIX_AWARE_FALLBACK,
                        1.0,
                        [("estate_id".to_string(), estate_tag.clone())]
                            .into_iter().collect::<std::collections::HashMap<_, _>>()
                    );
                }
                (GLKRecallMode::UnionBest, GLKRecallScoring::Rrf) => {
                    degraded_stages.push("unionBest.rrf".to_string());
                    glk_emit!(
                        crate::telemetry::metric_names::UNION_BEST_RRF_FALLBACK,
                        1.0,
                        [("estate_id".to_string(), estate_tag.clone())]
                            .into_iter().collect::<std::collections::HashMap<_, _>>()
                    );
                }
                _ => {}
            }

            let k = 60_f32;
            // Signed per-lane weights (6b-modifiers). Parity surface: Swift routes
            // ONLY the Hybrid and CorpusOnly lanes through the weighted `rrfFuseN`
            // (locus/bm25/hamming); its UnionBest lane uses the buffer/MMR path,
            // which 6b-modifiers leaves unweighted. So weights apply here ONLY for
            // Hybrid/CorpusOnly and ONLY on the RRF branch (Swift's .raw branch
            // merges lists in order, also unweighted). The dense lane is empty in
            // Hybrid/CorpusOnly (include_dense is UnionBest-only), so no dense
            // weight key is consulted. A None shape yields 1.0 for every lane —
            // multiplying each term by exactly 1.0 — so the unweighted formula is
            // recovered byte-for-byte (the back-compat contract).
            let weights_active = matches!(
                request.mode,
                GLKRecallMode::Hybrid | GLKRecallMode::CorpusOnly
            ) && request.recall_shape.is_some();
            let (w_locus, w_bm25, w_hamming) = match (&request.recall_shape, weights_active) {
                (Some(shape), true) => (
                    shape.weight("locus"),
                    shape.weight("bm25"),
                    shape.weight("hamming"),
                ),
                _ => (1.0, 1.0, 1.0),
            };
            let mut scored: Vec<(String, f32, f32, f32, f32, f32, f32, f32, f32)> = all_ids
                .iter()
                .filter_map(|id| {
                    let (locus_rank, locus_raw) = locus_score_map.get(id).copied().unwrap_or((usize::MAX, 0.0));
                    let (bm25_rank, bm25_raw)   = bm25_score_map.get(id).copied().unwrap_or((usize::MAX, 0.0));
                    let (vec_rank, vec_raw)      = vector_score_map.get(id).copied().unwrap_or((usize::MAX, 0.0));
                    let (dense_rank, dense_raw)  = dense_score_map.get(id).copied().unwrap_or((usize::MAX, 0.0));
                    // Consensus boost from the EXTRA dense voters beyond the first
                    // (0 when an id was surfaced by a single dense signal, so N=1 is
                    // byte-identical). Folded into final_score so a multi-signal
                    // candidate ranks at/above an equal-cosine single-signal one.
                    let dense_boost = dense_consensus_boost.get(id).copied().unwrap_or(0.0);

                    let final_score = match request.scoring {
                        GLKRecallScoring::Raw => locus_raw + bm25_raw + vec_raw + dense_raw + dense_boost,
                        GLKRecallScoring::Rrf | GLKRecallScoring::MatrixAware => {
                            // MatrixAware falls back to RRF for Hybrid/CorpusOnly.
                            // Each lane's reciprocal-rank term is scaled by its signed
                            // weight: w=1.0 neutral, w=0 EXCLUDES (the lane is skipped
                            // entirely — an id whose ONLY source is an excluded lane
                            // receives no term and is DROPPED below, matching Swift
                            // rrfFuseN's `continue`), w<0 SUBTRACTS the lane's rank
                            // mass (demotion). For UnionBest, weights are 1.0
                            // (unweighted, per Swift's buffer/MMR path).
                            let mut rrf = 0.0_f32;
                            // `contributed` mirrors Swift rrfFuseN's "did this id enter
                            // the rrf map": true once any non-excluded lane that ranks
                            // the id adds a term. An id with no contributing lane is
                            // absent from Swift's output, so it is dropped here too.
                            let mut contributed = false;
                            if locus_rank < usize::MAX && w_locus != 0.0 {
                                rrf += w_locus * (1.0 / (k + locus_rank as f32 + 1.0));
                                contributed = true;
                            }
                            if bm25_rank < usize::MAX && w_bm25 != 0.0 {
                                rrf += w_bm25 * (1.0 / (k + bm25_rank as f32 + 1.0));
                                contributed = true;
                            }
                            if vec_rank < usize::MAX && w_hamming != 0.0 {
                                rrf += w_hamming * (1.0 / (k + vec_rank as f32 + 1.0));
                                contributed = true;
                            }
                            if dense_rank < usize::MAX {
                                // Dense lane is unweighted in this fusion path (it is
                                // empty for Hybrid/CorpusOnly; weights apply only to
                                // those modes), so its term always contributes.
                                rrf += 1.0 / (k + dense_rank as f32 + 1.0);
                                contributed = true;
                            }
                            // Per-signal dense consensus: the extra-voter RRF mass is
                            // additive on top of the single consensus dense_rank term,
                            // so each held dense signal is an independent voter. Zero
                            // at N=1 — identical to the pre-6b single-signal RRF.
                            if dense_boost != 0.0 { contributed = true; }
                            rrf += dense_boost;
                            // Drop ids no surviving lane voted for (exclusion parity).
                            if !contributed { return None; }
                            rrf
                        }
                    };
                    Some((id.clone(), final_score, locus_raw, bm25_raw, vec_raw, dense_raw, 0.0_f32, 0.0_f32, 0.0_f32))
                })
                .collect();

            scored.sort_by(|a, b| {
                b.1.partial_cmp(&a.1)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then(a.0.cmp(&b.0))
            });
            scored.truncate(request.limit);
            fused_scored = scored;

            union_profile = match request.mode {
                // UnionBest with non-matrixAware scoring returns a minimal zero profile.
                // The full buffer-based RecallUnionProfile is computed only on the
                // matrixAware weighted pipeline (the branch above); for .raw and .rrf
                // the buffer.final column carries the lane-normalised score and the
                // profile is RecallUnionProfile::ZERO. The .rrf case additionally
                // records the `unionBest.rrf` scoring fallback above, so the caller
                // can tell the requested rrf scoring was not distinctly applied.
                GLKRecallMode::UnionBest => Some(RecallUnionProfile::ZERO),
                _ => None,
            };
        }

        // Build RecallHits from the fused_scored list.
        //
        // ACTIVE-STATE FILTER (withdrawn/tombstoned must not surface): when the
        // locus lane participates (Hybrid / UnionBest), `drawer_index` is the
        // frame-filtered active set — `estate.recall(frame)` already excluded
        // withdrawn/tombstoned/non-matching drawers. A BM25- or vector-lane
        // candidate whose drawer is therefore ABSENT from `drawer_index` failed
        // that active filter (e.g. it was withdrawn) and must NOT be surfaced as
        // an unhydrated hit — dropping it is the parity of the Swift
        // RecallDirector hydration, which filters non-active drawers from the
        // fused frontier. (Surfaced before this filter, a withdrawn drawer's
        // corpus chunk would still appear in search once the encode worker has
        // ingested it — the near-realtime drain now makes that the common case.)
        // CorpusOnly (locus lane not included for scoring) keeps its prior
        // behaviour: drawer_index there is the frame-filtered hydration set too,
        // so the same drop rule holds.
        let hits: Vec<RecallHit> = fused_scored
            .into_iter()
            .filter(|(id, ..)| drawer_index.contains_key(id))
            .map(|(id, final_s, locus_s, bm25_s, vec_s, dense_s, ff_s, co_s, t_s)| {
                let drawer = drawer_index.get(&id).cloned();
                let mut sources = Vec::new();
                if locus_contributed  && locus_score_map.contains_key(&id)  { sources.push(RecallEvidencePath::LocusBitmap); }
                if bm25_contributed   && bm25_score_map.contains_key(&id)   { sources.push(RecallEvidencePath::CorpusBm25); }
                if vector_contributed && vector_score_map.contains_key(&id) { sources.push(RecallEvidencePath::VectorHamming); }
                if dense_contributed  && dense_score_map.contains_key(&id)  { sources.push(RecallEvidencePath::VectorDense); }
                // Matrix evidence paths when signals are non-zero.
                if ff_s > 0.0 { sources.push(RecallEvidencePath::MatrixFieldPresence); }
                if co_s > 0.0 { sources.push(RecallEvidencePath::MatrixCoOccurrence); }
                if t_s  > 0.0 { sources.push(RecallEvidencePath::MatrixTemporal); }
                if sources.is_empty() { sources.push(RecallEvidencePath::LocusBitmap); }
                let score = RecallScoreVector {
                    locus: locus_s,
                    bm25: bm25_s,
                    vector: vec_s,
                    field_fit: ff_s,
                    co_occurrence: co_s,
                    temporal: t_s,
                    graph: 0.0,
                    preference: 0.0,
                    redundancy_penalty: 0.0,
                    final_score: final_s,
                    dense: dense_s,
                };
                let mut explanation = Vec::new();
                if locus_s > 0.0 { explanation.push("locusBitmap".to_string()); }
                if bm25_s  > 0.0 { explanation.push("bm25".to_string()); }
                if vec_s   > 0.0 { explanation.push("vector".to_string()); }
                if dense_s > 0.0 { explanation.push("vectorDense".to_string()); }
                if ff_s    > 0.0 { explanation.push("matrixFieldPresence".to_string()); }
                if co_s    > 0.0 { explanation.push("matrixCoOccurrence".to_string()); }
                if t_s     > 0.0 { explanation.push("matrixTemporal".to_string()); }
                if explanation.is_empty() { explanation.push("locusBitmap".to_string()); }
                // PER-SIGNAL DENSE PROVENANCE (6b-core): name the dense signals that
                // voted for this id, in slot order. Mirrors Swift's step-11
                // "denseSignals: vectorDense:<modelID>, ..." line. Additive — only
                // present when the dense lane surfaced this id.
                if let Some(voters) = dense_signals_by_id.get(&id) {
                    if !voters.is_empty() {
                        let names: Vec<String> =
                            voters.iter().map(|m| format!("vectorDense:{m}")).collect();
                        explanation.push(format!("denseSignals: {}", names.join(", ")));
                    }
                }
                RecallHit { id, drawer, sources, score, explanation }
            })
            .collect();

        Ok(GLKRecallResult {
            request,
            plan,
            union_profile,
            // dense_lane_status is populated from the float_nearest outcome above:
            // Some("dark:<reason>") when the lane was dark, None on hits or no corpus.
            dense_lane_status,
            // degraded_stages accumulates stage IDs for any lane that threw and was
            // recovered. Empty on the happy path. "stage failed" (non-empty) is
            // DISTINGUISHABLE from "absent evidence" (empty Vec, no matching docs).
            degraded_stages,
            hits,
        })
    }

    /// Rank-normalised locus-only fallback for Hybrid/CorpusOnly/UnionBest when
    /// neither corpus nor vector store is registered.
    ///
    /// Runs the locus lane with rank-based scoring and applies the requested
    /// scoring strategy (RRF or raw). Ensures .rrf/.matrixAware produce different
    /// orderings than .raw for the same content — the ranking test verifies this.
    ///
    /// The locus lane score for candidate at rank `idx` (0-based) is:
    ///   `(frontier_k - idx) / frontier_k`
    ///
    /// Mirrors Swift RecallDirector.recallHybrid step 2 (rank-normalisation before
    /// RRF fusion) for the single-lane degenerate case.
    fn recall_scored_locus_ranked(
        estate: &locus_kit::estate::Estate,
        request: GLKRecallRequest,
        plan: RecallPlan,
        now: i64,
    ) -> Result<GLKRecallResult, VerbDispatchError> {
        // B-10a: set trace_limit on frame copy only for external-origin requests.
        let mut traced_frame = request.frame.clone();
        if request.origin == RecallOrigin::External {
            traced_frame.trace_limit = Some(request.trace_limit.unwrap_or(request.limit));
        }

        // Drain the locus lane up to frontier_k rows. collect_all_with_degraded
        // surfaces LocusKit recall internal-read failures (P0-5 sites 1-5):
        // since this no-corpus path's RESULT is the locus lane, a failed locus
        // read names a locus.* stage so a FAILED recall is distinguishable from
        // a GENUINE-EMPTY estate. Seeded into degraded_stages below.
        let (all_locus, locus_degraded) =
            estate.recall(traced_frame, now).collect_all_with_degraded();
        let locus_rows: Vec<Drawer> =
            all_locus.into_iter().take(plan.frontier_k).collect();

        // Build rank-normalised (id, score) list. Rank 0 → highest score.
        // Formula: score = (frontier_k - rank) / frontier_k, range (0, 1].
        let n = locus_rows.len();
        let locus_list: Vec<(String, f32)> = locus_rows
            .iter()
            .enumerate()
            .map(|(idx, d)| {
                let score = (plan.frontier_k.saturating_sub(idx)) as f32
                    / plan.frontier_k.max(1) as f32;
                (d.id.clone(), score)
            })
            .collect();

        // Build an index for fast drawer lookup during hit construction.
        let drawer_index: HashMap<String, Drawer> = locus_rows
            .into_iter()
            .map(|d| (d.id.clone(), d))
            .collect();

        // Per-id locus score for hit assembly after fused is built.
        let locus_score_by_id: HashMap<String, f32> = locus_list
            .iter()
            .map(|(id, score)| (id.clone(), *score))
            .collect();

        // Scoring-fallback disposition (parity with Swift): this no-corpus path
        // collapses Hybrid/CorpusOnly/UnionBest+Rrf to a single locus-ranked
        // lane. A requested scoring strategy that is not distinctly implemented
        // for the requested mode is SURFACED as a named degraded stage, keyed by
        // the REQUESTED mode so the stage string matches the wired-path
        // vocabulary cross-port (e.g. hybrid+matrixAware → "hybrid.matrixAware"
        // here and on the wired multi-lane path). UnionBest+MatrixAware never
        // reaches this path (is_matrix_aware_union guard routes it to the full
        // pipeline). Raw, and Rrf in Hybrid/CorpusOnly (real RRF), record nothing.
        // Seed from the locus stream's internal-read failures (P0-5 sites 1-5);
        // genuine-empty seeds none.
        let mut degraded_stages: Vec<String> = locus_degraded;
        let estate_tag = estate.estate_uuid().to_string();
        match (request.mode, request.scoring) {
            (GLKRecallMode::Hybrid, GLKRecallScoring::MatrixAware) => {
                degraded_stages.push("hybrid.matrixAware".to_string());
                glk_emit!(
                    crate::telemetry::metric_names::HYBRID_MATRIX_AWARE_FALLBACK,
                    1.0,
                    [("estate_id".to_string(), estate_tag.clone())]
                        .into_iter().collect::<std::collections::HashMap<_, _>>()
                );
            }
            (GLKRecallMode::CorpusOnly, GLKRecallScoring::MatrixAware) => {
                degraded_stages.push("corpusOnly.matrixAware".to_string());
                glk_emit!(
                    crate::telemetry::metric_names::CORPUS_ONLY_MATRIX_AWARE_FALLBACK,
                    1.0,
                    [("estate_id".to_string(), estate_tag.clone())]
                        .into_iter().collect::<std::collections::HashMap<_, _>>()
                );
            }
            (GLKRecallMode::UnionBest, GLKRecallScoring::Rrf) => {
                degraded_stages.push("unionBest.rrf".to_string());
                glk_emit!(
                    crate::telemetry::metric_names::UNION_BEST_RRF_FALLBACK,
                    1.0,
                    [("estate_id".to_string(), estate_tag.clone())]
                        .into_iter().collect::<std::collections::HashMap<_, _>>()
                );
            }
            (GLKRecallMode::LocusOnly, GLKRecallScoring::MatrixAware) => {
                // Reached when CorpusOnly degraded to locus-only upstream and the
                // plan mode was rewritten to LocusOnly — parity with Swift's
                // corpusOnly→recallLocusOnly allowDegraded path.
                degraded_stages.push("locusOnly.matrixAware".to_string());
                glk_emit!(
                    crate::telemetry::metric_names::LOCUS_ONLY_MATRIX_AWARE_FALLBACK,
                    1.0,
                    [("estate_id".to_string(), estate_tag.clone())]
                        .into_iter().collect::<std::collections::HashMap<_, _>>()
                );
            }
            _ => {}
        }

        // Select candidates according to the scoring strategy.
        //
        // .raw — candidates in locus-bitmap order, rank-normalised locus scores.
        // .rrf / .matrixAware — RRF over the single locus list (k=60).
        //   For a single lane this is rank-preserving (same relative order as .raw)
        //   but produces different score values — demonstrating strategy is active.
        let fused: Vec<(String, f32)> = match request.scoring {
            GLKRecallScoring::Raw => {
                locus_list.into_iter().take(request.limit).collect()
            }
            GLKRecallScoring::Rrf | GLKRecallScoring::MatrixAware => {
                // RRF over a single lane: rrfScore(id, rank) = 1 / (k + rank + 1).
                // k=60 is the Robertson et al. recommendation, matching Swift
                // RecallDirector.rrfFuse.
                let k = 60_f32;
                let mut scored: Vec<(String, f32)> = locus_list
                    .iter()
                    .enumerate()
                    .map(|(rank, (id, _))| {
                        let rrf_score = 1.0 / (k + rank as f32 + 1.0);
                        (id.clone(), rrf_score)
                    })
                    .collect();
                // Tie-break: id ascending (deterministic), matching Swift.
                scored.sort_by(|(id_a, score_a), (id_b, score_b)| {
                    score_b
                        .partial_cmp(score_a)
                        .unwrap_or(std::cmp::Ordering::Equal)
                        .then(id_a.cmp(id_b))
                });
                scored.into_iter().take(request.limit).collect()
            }
        };

        // Build RecallHits from the fused candidate list.
        let union_profile = if n == 0 {
            None
        } else {
            match request.mode {
                GLKRecallMode::UnionBest => Some(RecallUnionProfile::ZERO),
                _ => None,
            }
        };

        let hits: Vec<RecallHit> = fused
            .into_iter()
            .map(|(id, final_s)| {
                let drawer = drawer_index.get(&id).cloned();
                let locus_s = locus_score_by_id.get(&id).copied().unwrap_or(0.0);
                let score = RecallScoreVector {
                    locus: locus_s,
                    bm25: 0.0,
                    vector: 0.0,
                    field_fit: 0.0,
                    co_occurrence: 0.0,
                    temporal: 0.0,
                    graph: 0.0,
                    preference: 0.0,
                    redundancy_penalty: 0.0,
                    final_score: final_s,
                    dense: 0.0,
                };
                RecallHit {
                    id: id.clone(),
                    drawer,
                    sources: vec![RecallEvidencePath::LocusBitmap],
                    score,
                    explanation: vec!["locusBitmap".to_string()],
                }
            })
            .collect();

        Ok(GLKRecallResult {
            request,
            plan,
            union_profile,
            // Rank-normalised locus-only fallback: no corpus registered, dense lane
            // never attempted — None per contract (lane was not attempted).
            dense_lane_status: None,
            // Only a scoring-fallback stage can be recorded here (set above);
            // there is no throwing stage on the locus-ranked path.
            degraded_stages,
            hits,
        })
    }
}

#[cfg(test)]
// INTENTIONAL SINGLE-PROVIDER (mission 6a-iii-wire): these coordinator tests
// assert estate wiring, mount-state, and lifecycle — NOT recall content — so
// they provision with an explicit `vec![EmbeddingModelConfig::Deterministic]`.
// A single deterministic signal is sufficient and keeps this crate free of a
// `corpus-kit-providers` dependency (the five-signal default lives in the app
// layer, which owns the production default via `default_ensemble()`). The
// per-signal fusion / recall-un-pinning is proven in the dedicated end-to-end
// payoff test, not here.
mod tests {
    use super::*;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};
    use substrate_types::RowState;

    const NOW: i64 = 1_700_000_000;

    fn open_one() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let handle = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .expect("open");
        (coord, handle)
    }

    fn cap_frame(content: &str) -> CaptureFrame {
        CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        )
    }

    fn unconfirmed() -> RecallFrame {
        // .full hydration so these tests can assert on content — a .structured
        // recall returns content == "" (spec § 7.3 / Swift parity).
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Full;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    fn confirmed() -> RecallFrame {
        // Admit user-confirmed rows (the evaluator's default ceiling, here
        // explicit) so a confirmed row is returned by recall. .full hydration
        // so content assertions in the tests succeed (structured returns "").
        let mut f = RecallFrame::new(vec![Filter::UserConfirmed]);
        f.hydration_level = HydrationLevel::Full;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CO-1: capture then recall returns the captured drawer with matching
    // content — the live verb dispatch produces a real dataset (the whole
    // point: the GLK boundary returns the estate's rows, not a stub).
    #[test]
    fn co1_capture_then_recall_returns_the_row() {
        let (coord, h) = open_one();
        let stored = coord.capture(&h, cap_frame("alpha"), NOW).expect("capture");
        assert_eq!(stored.content, "alpha");
        let rows = coord.recall(&h, unconfirmed(), NOW).expect("recall");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, stored.id);
        assert_eq!(rows[0].content, "alpha");
    }

    // CO-2: withdraw moves the row off the unconfirmed/active set — the verb
    // reaches the real estate and mutates state.
    #[test]
    fn co2_withdraw_transitions_state() {
        let (coord, h) = open_one();
        let stored = coord.capture(&h, cap_frame("beta"), NOW).expect("capture");
        coord
            .withdraw(&h, &stored.id, Some("obsolete"), NOW)
            .expect("withdraw");
        // The row is no longer in the unconfirmed set after withdrawal.
        let rows = coord.recall(&h, unconfirmed(), NOW).expect("recall");
        assert!(
            rows.iter().all(|r| r.id != stored.id),
            "withdrawn row left the set"
        );
    }

    // CO-3: expunge without confirmation is refused at the boundary; the
    // substrate is never reached. Parity of the Swift guard.
    #[test]
    fn co3_expunge_requires_confirmation() {
        let (coord, h) = open_one();
        let stored = coord.capture(&h, cap_frame("gamma"), NOW).expect("capture");
        let err = coord.expunge(&h, &stored.id, "cleanup", false, NOW).unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::Verb(VerbError::ExpungeNotConfirmed { row_id: stored.id })
        );
    }

    // CO-4: an empty reanchor (neither room nor lattice) is refused at the
    // boundary. Parity of the Swift guard.
    #[test]
    fn co4_empty_reanchor_is_refused() {
        let (coord, h) = open_one();
        let err = coord.reanchor(&h, "row-1", None, None).unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::Verb(VerbError::EmptyReanchor {
                row_id: "row-1".to_string()
            })
        );
    }

    // CO-5: mutate(Confirm) reaches the real estate and transitions the row's
    // confirmation axis to UserConfirmed — the live verb dispatch produces a
    // real state change (parity of Swift Estate.mutate(.confirm)).
    #[test]
    fn co5_mutate_confirm_transitions_confirmation() {
        use locus_kit::provenance::Confirmation;
        let (coord, h) = open_one();
        let stored = coord.capture(&h, cap_frame("delta"), NOW).expect("capture");
        coord
            .mutate(&h, &stored.id, MutationKind::Confirm, None)
            .expect("mutate confirm");
        // The row now satisfies the user-confirmed ceiling.
        let rows = coord.recall(&h, confirmed(), NOW).expect("recall");
        let row = rows
            .iter()
            .find(|r| r.id == stored.id)
            .expect("confirmed row present in recall");
        assert_eq!(row.confirmation(), Confirmation::UserConfirmed);
    }

    // CO-5b: Contest (a state-axis mutation kind) succeeds end-to-end through
    // the coordinator dispatch chain — Active → Contested is a legal automaton
    // transition and the estate forwards it without remapping.
    #[test]
    fn co5b_state_axis_mutate_contest_succeeds() {
        let (coord, h) = open_one();
        let stored = coord
            .capture(&h, cap_frame("epsilon"), NOW)
            .expect("capture");
        // Contest is a live state-axis kind (no longer a stub).
        // Active -> Contest -> Contested is a valid automaton transition.
        coord
            .mutate(&h, &stored.id, MutationKind::Contest, None)
            .expect("contest should succeed — state-axis kinds are implemented");
    }

    // CO-6: a verb on a closed handle surfaces EstateNotOpen (the parity of
    // estate(for:) propagating out of a verb).
    #[test]
    fn co6_verb_on_closed_handle_is_estate_not_open() {
        let (mut coord, h) = open_one();
        coord.close(&h).expect("close");
        let err = coord.capture(&h, cap_frame("delta"), NOW).unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
    }

    // -----------------------------------------------------------------
    // recall_tunnels — coordinator-level read over the association graph.
    // Mirrors Swift `RecallTunnelsTests` case-for-case.
    // -----------------------------------------------------------------

    fn tunnel_frame(
        source: &str,
        target: &str,
        label: &str,
    ) -> locus_kit::frames::TunnelCaptureFrame {
        locus_kit::frames::TunnelCaptureFrame::new(source, "r1", target, "r2", label, "bilby")
    }

    // CO-7: tunnels captured into the estate are returned by the wing's read
    // through the coordinator surface.
    #[test]
    fn co7_recall_tunnels_returns_outgoing() {
        let (coord, h) = open_one();
        let estate = coord.estate_for(&h).expect("estate");
        estate
            .capture_tunnel(tunnel_frame("study", "kitchen", "links"), NOW)
            .unwrap();
        estate
            .capture_tunnel(tunnel_frame("study", "garden", "relates"), NOW + 1)
            .unwrap();

        let tunnels = coord.recall_tunnels(&h, "study").expect("recall_tunnels");
        assert_eq!(tunnels.len(), 2);
        let targets: std::collections::BTreeSet<&str> =
            tunnels.iter().map(|t| t.target_wing.as_str()).collect();
        assert_eq!(targets, ["garden", "kitchen"].into_iter().collect());
        assert!(tunnels.iter().all(|t| t.source_wing == "study"));
    }

    // CO-8: a wing with no outgoing tunnels reads empty (never errors).
    #[test]
    fn co8_recall_tunnels_empty_for_unlinked_wing() {
        let (coord, h) = open_one();
        let estate = coord.estate_for(&h).expect("estate");
        estate
            .capture_tunnel(tunnel_frame("study", "kitchen", "links"), NOW)
            .unwrap();

        let tunnels = coord.recall_tunnels(&h, "attic").expect("recall_tunnels");
        assert!(tunnels.is_empty());
    }

    // CO-9: a verb on a closed handle surfaces EstateNotOpen, not an empty
    // result — parity of the Swift stale-handle case.
    #[test]
    fn co9_recall_tunnels_on_closed_handle_is_estate_not_open() {
        let (mut coord, h) = open_one();
        coord.close(&h).expect("close");
        let err = coord.recall_tunnels(&h, "study").unwrap_err();
        assert_eq!(
            err,
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
    }

    // -----------------------------------------------------------------
    // v2b-p2 non-drawer recall — smoke tests.
    // These unit tests verify the handle-validation and empty-estate posture
    // for the non-drawer recall surfaces. Write-then-read round-trip tests
    // live in tests/non_drawer_recall_parity.rs (P1 #13).
    //
    // CO-10: learn writes a genuine LearnedReference end-to-end (SourceCatalogEntry
    //   implemented; write path is live, not sealed). See co10_learn_writes_genuine_reference.
    // CO-10b: learn with an empty reference handle fails loud (InvalidContent).
    // CO-11 through CO-15: recall_* surfaces return Ok(empty vec) on a fresh
    //   estate — verifying the live pass-through, not a stub return.
    // CO-16: stale handle always surfaces EstateNotOpen before verb dispatch.
    // -----------------------------------------------------------------

    fn sample_learn_frame(handle: &str) -> LocusLearnFrame {
        let source = locus_kit::source_catalog_entry::SourceCatalogEntry::new(
            "src-1",
            locus_kit::source_catalog_entry::SourceKind::User,
            "https://example.com",
            LatticeAnchor::udc("004"),
            NOW,
            "cataloger",
        );
        LocusLearnFrame::new(source, handle)
    }

    // CO-10: learn succeeds end-to-end — it derives the reference's genuine
    // anchor from the source catalog entry and persists it (P1 #5/#13: the
    // write path is live, not sealed).
    #[test]
    fn co10_learn_writes_genuine_reference() {
        let (coord, h) = open_one();
        let reference = coord
            .learn(&h, sample_learn_frame("https://example.com/page"), 1_700_000_100)
            .expect("learn should succeed");
        assert_eq!(reference.lattice_anchor.udc_code, "004");
        assert!(!reference.lattice_anchor.udc_code.is_empty());
        assert_eq!(reference.source_catalog_id, "src-1");
        // The reference is recallable through the live recall surface.
        let refs = coord.recall_learned_references(&h).expect("recall");
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].handle, "https://example.com/page");
    }

    // CO-10b: learn with an empty reference handle fails loud with the
    // typed verb error mapped from InvalidContent — fail loud ONLY on
    // genuinely invalid input.
    #[test]
    fn co10b_learn_with_empty_handle_fails_loud() {
        let (coord, h) = open_one();
        let err = coord.learn(&h, sample_learn_frame(""), 1_700_000_000).unwrap_err();
        assert!(
            matches!(err, VerbDispatchError::Verb(_)),
            "learn (empty handle) must fail loud with a verb error, got: {:?}",
            err
        );
    }

    // CO-11: recall_kg_facts returns Ok(empty vec) on a fresh in-memory estate —
    // the DrawerStore all_kg_facts() accessor is now live.
    #[test]
    fn co11_recall_kg_facts_returns_empty_vec_on_fresh_estate() {
        let (coord, h) = open_one();
        let facts = coord.recall_kg_facts(&h).expect("recall_kg_facts should succeed");
        assert!(facts.is_empty(), "fresh estate has no kg-facts");
    }

    // CO-12: recall_diary_entries returns Ok(empty vec) on a fresh in-memory
    // estate — the DrawerStore all_diary_entries() accessor is now live.
    #[test]
    fn co12_recall_diary_entries_returns_empty_vec_on_fresh_estate() {
        let (coord, h) = open_one();
        let entries = coord.recall_diary_entries(&h).expect("recall_diary_entries should succeed");
        assert!(entries.is_empty(), "fresh estate has no diary entries");
    }

    // CO-13: recall_proposals returns Ok(empty vec) on a fresh in-memory
    // estate — the DrawerStore all_proposals() accessor is now live.
    #[test]
    fn co13_recall_proposals_returns_empty_vec_on_fresh_estate() {
        let (coord, h) = open_one();
        let proposals = coord.recall_proposals(&h).expect("recall_proposals should succeed");
        assert!(proposals.is_empty(), "fresh estate has no proposals");
    }

    // CO-14: recall_associations returns Ok(empty vec) on a fresh in-memory
    // estate — the DrawerStore all_associations() accessor is now live.
    #[test]
    fn co14_recall_associations_returns_empty_vec_on_fresh_estate() {
        let (coord, h) = open_one();
        let associations = coord.recall_associations(&h).expect("recall_associations should succeed");
        assert!(associations.is_empty(), "fresh estate has no associations");
    }

    // CO-15: recall_learned_references returns Ok(empty vec) on a fresh
    // in-memory estate — the DrawerStore all_learned_references() accessor is now live.
    #[test]
    fn co15_recall_learned_references_returns_empty_vec_on_fresh_estate() {
        let (coord, h) = open_one();
        let refs = coord.recall_learned_references(&h).expect("recall_learned_references should succeed");
        assert!(refs.is_empty(), "fresh estate has no learned references");
    }

    // CO-16: verbs on a closed handle raise EstateNotOpen, not
    // NotSupportedByEstate — handle validation (estate_for_verb) runs
    // before any verb dispatch, so a stale handle always wins.
    #[test]
    fn co16_stubs_on_closed_handle_raise_estate_not_open() {
        let (mut coord, h) = open_one();
        coord.close(&h).expect("close");

        assert_eq!(
            coord.learn(&h, sample_learn_frame("h"), 1_700_000_000).unwrap_err(),
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
        assert_eq!(
            coord.recall_kg_facts(&h).unwrap_err(),
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
        assert_eq!(
            coord.recall_diary_entries(&h).unwrap_err(),
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
        assert_eq!(
            coord.recall_proposals(&h).unwrap_err(),
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
        assert_eq!(
            coord.recall_associations(&h).unwrap_err(),
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
        assert_eq!(
            coord.recall_learned_references(&h).unwrap_err(),
            VerbDispatchError::EstateNotOpen {
                estate_uuid: h.estate_uuid
            }
        );
    }

    // -----------------------------------------------------------------
    // GLK_PROVISION_001 tests — provision / quiesce / drain / destroy
    // -----------------------------------------------------------------

    /// Create a fresh in-memory DrawerStore and its backing Storage for provision tests.
    ///
    /// Returns `(store, storage)` where `store` is an `Arc<dyn DrawerStore>` for the
    /// LocusKit estate and `storage` is an `Arc<dyn Storage>` (the same `InMemoryStorage`)
    /// for Corpus + VectorStore construction.  The shared `InMemoryStorage` means one
    /// SQLite-equivalent in-memory instance backs all three sub-stores — the same pattern
    /// the Swift tests use with a single `InMemoryStorage`.
    fn make_provision_stores() -> (Arc<dyn DrawerStore>, Arc<dyn Storage>) {
        use persistence_kit::inmemory::InMemoryStorage;
        use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
        let storage = Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()));
        let store = Arc::new(
            InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW, None).unwrap()
        );
        (store as Arc<dyn DrawerStore>, storage as Arc<dyn Storage>)
    }

    fn glk_params(name: &str) -> EstateProvisionParams {
        EstateProvisionParams {
            estate_name: name.to_string(),
            kind: EstateKind::Glk,
            zoom_window_low: 1,
            zoom_window_high: 10,
            framework_profile: "KnowledgeWork".to_string(),
            sync_mode: SyncMode::None,
        }
    }

    fn locus_only_params(name: &str) -> EstateProvisionParams {
        EstateProvisionParams {
            estate_name: name.to_string(),
            kind: EstateKind::LocusOnly,
            zoom_window_low: 0,
            zoom_window_high: 5,
            framework_profile: "MinimalProfile".to_string(),
            sync_mode: SyncMode::None,
        }
    }

    // PR-1: provision(.glk) returns a valid handle and sets mount state to Mounted.
    #[test]
    fn pr1_provision_glk_returns_handle_and_mounted_state() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let params = glk_params("TestGLK");

        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, vec![EmbeddingModelConfig::Deterministic])
            .expect("provision should succeed");

        assert_eq!(coord.open_estate_count(), 1);
        assert_eq!(coord.mount_state(&handle), Some(EstateMountState::Mounted));
    }

    // PR-2: provision stores the kind-prefixed framework_profile in the manifest.
    #[test]
    fn pr2_provision_glk_stores_kind_prefixed_profile() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let params = EstateProvisionParams {
            estate_name: "ProfileTest".to_string(),
            kind: EstateKind::Glk,
            zoom_window_low: 0,
            zoom_window_high: 5,
            framework_profile: "KnowledgeWork".to_string(),
            sync_mode: SyncMode::None,
        };

        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, vec![EmbeddingModelConfig::Deterministic])
            .expect("provision should succeed");

        let estate = coord.estate_for(&handle).expect("estate must be open");
        let manifest = estate.manifest().expect("manifest must be readable");
        assert_eq!(
            manifest.framework_profile, "GLK:KnowledgeWork",
            "provision must store kind-prefixed profile in the manifest"
        );
    }

    // PR-3: provision stores zoom_window_low and zoom_window_high.
    #[test]
    fn pr3_provision_stores_zoom_window() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let params = EstateProvisionParams {
            estate_name: "ZoomTest".to_string(),
            kind: EstateKind::LocusOnly,
            zoom_window_low: 3,
            zoom_window_high: 12,
            framework_profile: "ZoomProfile".to_string(),
            sync_mode: SyncMode::None,
        };

        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, vec![EmbeddingModelConfig::Deterministic])
            .expect("provision should succeed");

        // The handle carries the zoom window from the manifest.
        assert_eq!(handle.zoom_window_low, 3);
        assert_eq!(handle.zoom_window_high, 12);
    }

    // PR-4: re-provisioning the same store raises DuplicateEstate.
    #[test]
    fn pr4_reprovision_same_store_raises_duplicate_estate() {
        use persistence_kit::inmemory::InMemoryStorage;
        let mut coord = EstateCoordinator::new();
        // Shared storage: both provisions use the same InMemoryStorage so the
        // estate UUID is identical and the second call hits DuplicateEstate.
        let shared_storage = Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()));
        let store1 = Arc::new(
            InMemoryDrawerStore::with_storage(Arc::clone(&shared_storage), NOW, None).unwrap()
        ) as Arc<dyn DrawerStore>;
        let store2 = Arc::new(
            InMemoryDrawerStore::with_storage(Arc::clone(&shared_storage), NOW, None).unwrap()
        ) as Arc<dyn DrawerStore>;
        let stor1 = Arc::clone(&shared_storage) as Arc<dyn Storage>;
        let stor2 = Arc::clone(&shared_storage) as Arc<dyn Storage>;
        let params = glk_params("DupeTest");

        coord
            .provision(store1, stor1, None, OwnerCredentials::new("owner"), params.clone(), vec![EmbeddingModelConfig::Deterministic])
            .expect("first provision should succeed");

        let err = coord
            .provision(store2, stor2, None, OwnerCredentials::new("owner"), params, vec![EmbeddingModelConfig::Deterministic])
            .expect_err("second provision on same store must fail");

        assert!(
            matches!(err, GeniusLocusKitError::DuplicateEstate { .. }),
            "expected DuplicateEstate, got {:?}",
            err
        );
    }

    // PR-5: provision with empty estate name raises InvalidManifest.
    #[test]
    fn pr5_provision_empty_name_raises_invalid_manifest() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let params = EstateProvisionParams {
            estate_name: String::new(),
            kind: EstateKind::Glk,
            zoom_window_low: 0,
            zoom_window_high: 5,
            framework_profile: "P".to_string(),
            sync_mode: SyncMode::None,
        };

        let err = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, vec![EmbeddingModelConfig::Deterministic])
            .expect_err("empty name must fail");

        assert!(
            matches!(&err, GeniusLocusKitError::InvalidManifest { key, .. } if key == "estate_name"),
            "expected InvalidManifest(estate_name), got {:?}",
            err
        );
    }

    // PR-6: provision with inverted zoom window raises InvalidManifest.
    #[test]
    fn pr6_provision_inverted_zoom_window_raises_invalid_manifest() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let params = EstateProvisionParams {
            estate_name: "InvertedWindow".to_string(),
            kind: EstateKind::Glk,
            zoom_window_low: 10,
            zoom_window_high: 3, // inverted
            framework_profile: "P".to_string(),
            sync_mode: SyncMode::None,
        };

        let err = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, vec![EmbeddingModelConfig::Deterministic])
            .expect_err("inverted zoom window must fail");

        assert!(
            matches!(&err, GeniusLocusKitError::InvalidManifest { key, .. } if key == "zoom_window"),
            "expected InvalidManifest(zoom_window), got {:?}",
            err
        );
    }

    // PR-7: freshly provisioned estate is in Mounted state.
    #[test]
    fn pr7_fresh_provisioned_estate_is_mounted() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("GLK1"), vec![EmbeddingModelConfig::Deterministic])
            .expect("provision");
        assert_eq!(coord.mount_state(&handle), Some(EstateMountState::Mounted));
    }

    // PR-8: quiesce transitions mounted → quiesced.
    #[test]
    fn pr8_quiesce_transitions_mounted_to_quiesced() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("Q1"), vec![EmbeddingModelConfig::Deterministic])
            .expect("provision");

        coord.quiesce(&handle).expect("quiesce must succeed");
        assert_eq!(coord.mount_state(&handle), Some(EstateMountState::Quiesced));
    }

    // PR-9: quiesce is idempotent on an already-quiesced estate.
    #[test]
    fn pr9_quiesce_is_idempotent() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("Q2"), vec![EmbeddingModelConfig::Deterministic])
            .expect("provision");

        coord.quiesce(&handle).expect("first quiesce");
        coord.quiesce(&handle).expect("second quiesce must be idempotent");
        assert_eq!(coord.mount_state(&handle), Some(EstateMountState::Quiesced));
    }

    // PR-10: drain transitions to quiesced.
    #[test]
    fn pr10_drain_transitions_to_quiesced() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("D1"), vec![EmbeddingModelConfig::Deterministic])
            .expect("provision");

        coord.drain(&handle).expect("drain must succeed");
        assert_eq!(coord.mount_state(&handle), Some(EstateMountState::Quiesced),
            "drain must complete with Quiesced state");
    }

    // PR-11: destroy removes the estate from the registry.
    #[test]
    fn pr11_destroy_removes_estate_from_registry() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("L1"), vec![EmbeddingModelConfig::Deterministic])
            .expect("provision");

        assert_eq!(coord.open_estate_count(), 1);
        coord.destroy(&handle).expect("destroy must succeed");
        assert_eq!(coord.open_estate_count(), 0);
        assert_eq!(coord.mount_state(&handle), None,
            "destroyed estate must have nil mount state");
    }

    // PR-12: quiesce on closed handle raises EstateNotOpen.
    #[test]
    fn pr12_quiesce_on_closed_handle_raises_estate_not_open() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("L2"), vec![EmbeddingModelConfig::Deterministic])
            .expect("provision");

        coord.close(&handle).expect("close");
        let err = coord.quiesce(&handle).expect_err("quiesce on closed handle must fail");
        assert!(
            matches!(err, GeniusLocusKitError::EstateNotOpen { .. }),
            "expected EstateNotOpen, got {:?}",
            err
        );
    }

    // PR-13: drain on closed handle raises EstateNotOpen.
    #[test]
    fn pr13_drain_on_closed_handle_raises_estate_not_open() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("L3"), vec![EmbeddingModelConfig::Deterministic])
            .expect("provision");

        coord.close(&handle).expect("close");
        let err = coord.drain(&handle).expect_err("drain on closed handle must fail");
        assert!(
            matches!(err, GeniusLocusKitError::EstateNotOpen { .. }),
            "expected EstateNotOpen, got {:?}",
            err
        );
    }

    // PR-14: destroy after manual close succeeds (no double-close error).
    #[test]
    fn pr14_destroy_after_close_succeeds() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("L4"), vec![EmbeddingModelConfig::Deterministic])
            .expect("provision");

        coord.close(&handle).expect("close");
        // destroy on an already-closed handle — the registry check skips close().
        coord.destroy(&handle).expect("destroy after close must succeed");
        assert_eq!(coord.open_estate_count(), 0);
    }

    // PR-15: CorpusOnly kind stores CorpusOnly-prefixed profile.
    #[test]
    fn pr15_corpus_only_stores_corpus_only_prefix() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let params = EstateProvisionParams {
            estate_name: "CorpusOnlyEstate".to_string(),
            kind: EstateKind::CorpusOnly,
            zoom_window_low: 2,
            zoom_window_high: 8,
            framework_profile: "CorpusTest".to_string(),
            sync_mode: SyncMode::None,
        };

        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, vec![EmbeddingModelConfig::Deterministic])
            .expect("provision");

        let estate = coord.estate_for(&handle).expect("estate");
        let manifest = estate.manifest().expect("manifest");
        assert_eq!(
            manifest.framework_profile, "CorpusOnly:CorpusTest",
            "CorpusOnly provision must store CorpusOnly-prefixed profile"
        );
    }

    // PR-16: LocusOnly kind stores LocusOnly-prefixed profile.
    #[test]
    fn pr16_locus_only_stores_locus_only_prefix() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let params = locus_only_params("LocusOnlyEstate");

        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, vec![EmbeddingModelConfig::Deterministic])
            .expect("provision");

        let estate = coord.estate_for(&handle).expect("estate");
        let manifest = estate.manifest().expect("manifest");
        assert_eq!(
            manifest.framework_profile, "LocusOnly:MinimalProfile",
            "LocusOnly provision must store LocusOnly-prefixed profile"
        );
    }

    // PR-17: mount_state for a handle that was never registered returns None.
    #[test]
    fn pr17_mount_state_for_unregistered_handle_is_none() {
        let coord = EstateCoordinator::new();
        // Construct a dummy handle via open_one but check a different handle.
        let dummy_handle = EstateHandle::new(
            [0u8; 16],
            0,
            1,
        ).expect("dummy handle");
        assert_eq!(coord.mount_state(&dummy_handle), None);
    }

    // ── Maintenance-accessor bundle (board items 4b/4c/4d + matrix tier) ──

    // ACC-1: all_drawers_bounded caps the read at `limit` rows from the
    // storage tier; None reads the whole corpus (== all_drawers).
    #[test]
    fn acc1_all_drawers_bounded_caps_the_read() {
        let (coord, h) = open_one();
        for i in 0..5 {
            coord.capture(&h, cap_frame(&format!("c{i}")), NOW + i).expect("capture");
        }
        let two = coord.all_drawers_bounded(&h, Some(2)).expect("bounded");
        assert_eq!(two.len(), 2, "limit caps the read at 2 rows");
        let all = coord.all_drawers_bounded(&h, None).expect("unbounded");
        assert_eq!(all.len(), 5, "None reads the full corpus");
        assert_eq!(all.len(), coord.all_drawers(&h).expect("all").len());
    }

    // ACC-2: all_drawers_bounded on a stale handle raises EstateNotOpen.
    #[test]
    fn acc2_all_drawers_bounded_stale_handle_errors() {
        let (mut coord, h) = open_one();
        coord.close(&h).expect("close");
        let err = coord.all_drawers_bounded(&h, Some(1)).unwrap_err();
        assert!(matches!(err, VerbDispatchError::EstateNotOpen { .. }));
    }

    // ACC-3: room_level_fingerprints is wired through the GLK surface and
    // returns the live container aggregate for an open estate. The Rust
    // capture path ORs each drawer's bitmaps into the container_fingerprints
    // aggregate (P0-PARITY #33), so a captured drawer makes the room-level
    // read non-empty — the maintenance fingerprint-drift signal now reads
    // real values, not an empty set.
    #[test]
    fn acc3_room_level_fingerprints_returns_live_aggregate() {
        let (coord, h) = open_one();
        coord.capture(&h, cap_frame("alpha"), NOW).expect("capture");
        let entries = coord.room_level_fingerprints(&h).expect("room-level FP read");
        // cap_frame files into room "study"; capture-time OR-in created its
        // room-level row. Before this fix the aggregate stayed empty and this
        // read returned no entries, starving the maintenance fingerprint-drift
        // signal. The row's mere presence (one room — the wing-rollup row,
        // room == "", is excluded by room_level_entries) proves the OR-in
        // fired. The drift signal now reads a real value, not an empty set.
        assert_eq!(entries.len(), 1, "the captured drawer's room is enumerated");
        assert_eq!(entries[0].room, "study");
    }

    // ACC-4: current_audit_log feeds the unified log from the estate's audit
    // trail; a captured drawer produces a non-empty, verifiable chain.
    #[test]
    fn acc4_current_audit_log_feeds_and_verifies() {
        let (mut coord, h) = open_one();
        coord.capture(&h, cap_frame("alpha"), NOW).expect("capture");
        let log = coord.current_audit_log(&h).expect("current audit log");
        assert!(!log.is_empty(), "a captured drawer yields audit entries");
        // The freshly-fed chain verifies clean.
        let report = coord.verify_audit_chain(&h).expect("verify");
        assert!(report.valid, "fed chain is intact");
        assert_eq!(report.entry_count, log.count());
        assert!(report.first_broken_at_millis.is_none());
    }

    // ACC-5: feed_audit_log is idempotent — re-feeding the same trail is a
    // G-Set no-op (entry count unchanged).
    #[test]
    fn acc5_feed_audit_log_is_idempotent() {
        let (mut coord, h) = open_one();
        coord.capture(&h, cap_frame("alpha"), NOW).expect("capture");
        coord.feed_audit_log(&h).expect("feed 1");
        let first = coord.audit_log(&h).expect("log").count();
        coord.feed_audit_log(&h).expect("feed 2");
        let second = coord.audit_log(&h).expect("log").count();
        assert_eq!(first, second, "re-feeding the same trail adds no entries");
    }

    // ACC-6: verify_audit_chain on an empty (freshly opened) estate is
    // vacuously valid with zero entries.
    #[test]
    fn acc6_verify_audit_chain_empty_estate_is_valid() {
        let (coord, h) = open_one();
        let report = coord.verify_audit_chain(&h).expect("verify");
        assert!(report.valid);
        assert_eq!(report.entry_count, 0);
        assert!(report.first_broken_at_millis.is_none());
    }

    // ACC-7: register_matrix_tier installs a tier the accessor reads back;
    // an unregistered estate reads None.
    #[test]
    fn acc7_register_matrix_tier_round_trips() {
        let (mut coord, h) = open_one();
        assert!(coord.matrix_tier(&h).is_none(), "fresh estate has no tier");
        let tier = crate::matrix::MatrixTier::default();
        coord.register_matrix_tier(&h, tier);
        assert!(coord.matrix_tier(&h).is_some(), "tier registered and readable");
    }

    // ACC-8: rebuild_derived_accelerators feeds the audit log and installs a
    // matrix tier — the moot_dream matrix-rebuild step's substrate path.
    #[test]
    fn acc8_rebuild_derived_accelerators_installs_tier() {
        let (mut coord, h) = open_one();
        coord.capture(&h, cap_frame("alpha"), NOW).expect("capture");
        assert!(coord.matrix_tier(&h).is_none(), "no tier before rebuild");
        coord.rebuild_derived_accelerators(&h).expect("rebuild");
        assert!(coord.matrix_tier(&h).is_some(), "tier present after rebuild");
        // The audit log was fed as part of the rebuild.
        assert!(!coord.audit_log(&h).expect("log").is_empty());
    }

    // ACC-9: closing an estate drops its audit log and matrix tier — a stale
    // handle no longer resolves to a live log or tier.
    #[test]
    fn acc9_close_drops_audit_log_and_matrix_tier() {
        let (mut coord, h) = open_one();
        coord.register_matrix_tier(&h, crate::matrix::MatrixTier::default());
        coord.close(&h).expect("close");
        assert!(coord.matrix_tier(&h).is_none(), "tier dropped on close");
        let err = coord.audit_log(&h).unwrap_err();
        assert!(matches!(err, VerbDispatchError::EstateNotOpen { .. }));
    }

    // -----------------------------------------------------------------
    // Node topology provider — coordinator-level wiring (w5-nodetree-native).
    //
    // These tests are the Rust twins of the Swift §6 acceptance gates in
    // NodeTopologyProviderTests.swift that exercise the coordinator surface
    // (register_node_topology + recall_tunnels merge), NOT just the trait.
    //
    // CO-NT-1: no registered provider → recall_tunnels returns stored tunnels
    //          only (behaviour unchanged, no synthetic containment tunnels).
    // CO-NT-2: registered provider → synthetic containment tunnels appear in
    //          recall_tunnels output with label "containment".
    // CO-NT-3: provider is called EXACTLY ONCE per recall_tunnels call (G1).
    // CO-NT-4: closing an estate drops its topology provider — closed handle
    //          leaves no stale provider entry.
    // CO-NT-5: unregistered estate unchanged — registering a provider on
    //          handle A does not affect handle B.
    // CO-NT-6: dedup / ordering — synthetic tunnels carry correct id format,
    //          source_drawer_id = parent, target_drawer_id = child, filed_at = i64::MIN.
    // -----------------------------------------------------------------

    /// Instrumented provider for coordinator-level tests (CO-NT-3 call-count gate).
    ///
    /// Uses `std::cell::Cell` so the call count can be mutated through a
    /// shared reference — the coordinator holds the provider behind `Arc<dyn …>`
    /// and never gives us `&mut` back. This is safe because tests are
    /// single-threaded and the coordinator is also not `Send` in these tests.
    struct CallCountProvider {
        edges: Vec<(String, String)>,
        call_count: std::cell::Cell<usize>,
    }
    impl CallCountProvider {
        fn new(edges: Vec<(String, String)>) -> Self {
            Self { edges, call_count: std::cell::Cell::new(0) }
        }
        fn call_count(&self) -> usize { self.call_count.get() }
    }
    // SAFETY: single-threaded tests only; Cell is not Sync but the Arc wrapping
    // for the coordinator requires Send+Sync. In tests we know no concurrent
    // access occurs. The `unsafe impl Sync` is the same technique used for the
    // test-seam RefCell fields on EstateCoordinator itself.
    unsafe impl Send for CallCountProvider {}
    unsafe impl Sync for CallCountProvider {}
    impl crate::node_topology::NodeTopologyProvider for CallCountProvider {
        fn parent_id(&self, _: &str) -> Option<String> { None }
        fn child_ids(&self, _: &str) -> Vec<String> { Vec::new() }
        fn tree_edges(&self, _scope: Option<&[String]>) -> Vec<(String, String)> {
            self.call_count.set(self.call_count.get() + 1);
            self.edges.clone()
        }
    }

    /// Build the canonical 4-edge test tree: root→A, root→B, A→C, B→D.
    /// Matches `smallTree()` in NodeTopologyProviderTests.swift.
    fn small_tree_edges() -> Vec<(String, String)> {
        vec![
            ("root".to_string(), "A".to_string()),
            ("root".to_string(), "B".to_string()),
            ("A".to_string(),    "C".to_string()),
            ("B".to_string(),    "D".to_string()),
        ]
    }

    // CO-NT-1: when no NodeTopologyProvider is registered, recall_tunnels
    // returns only the estate's stored tunnels — identical to pre-registration
    // behaviour. Synthetic containment tunnels must NOT appear.
    // Mirrors Swift nodeTreeNative_noProvider_behaviorUnchanged (§6 gate 1).
    #[test]
    fn co_nt1_no_provider_behaviour_unchanged() {
        let (coord, h) = open_one();

        // Capture a tunnel and read it back without a provider.
        let estate = coord.estate_for(&h).expect("estate");
        estate
            .capture_tunnel(tunnel_frame("wing-a", "wing-b", "links"), NOW)
            .unwrap();

        let tunnels = coord.recall_tunnels(&h, "wing-a").expect("recall_tunnels");

        // Stored tunnel is present.
        assert_eq!(tunnels.len(), 1, "expected 1 stored tunnel; got {}", tunnels.len());
        // No containment labels when no provider is registered.
        let containment_count = tunnels.iter().filter(|t| t.label == "containment").count();
        assert_eq!(
            containment_count, 0,
            "no provider registered — no containment tunnels expected, found {containment_count}"
        );
    }

    // CO-NT-2: when a NodeTopologyProvider is registered, its frozen tree edges
    // appear as synthetic tunnels with label "containment" in recall_tunnels output.
    // Mirrors Swift nodeTreeNative_registeredProvider_addsContainmentEdges (§6 gate 2).
    #[test]
    fn co_nt2_registered_provider_adds_containment_edges() {
        let (mut coord, h) = open_one();
        let provider: Arc<dyn crate::node_topology::NodeTopologyProvider> =
            Arc::new(crate::node_topology::MemoryTopologyProvider::new(
                // MemoryTopologyProvider takes (child, parent) pairs.
                [
                    ("A".to_string(), "root".to_string()),
                    ("B".to_string(), "root".to_string()),
                    ("C".to_string(), "A".to_string()),
                    ("D".to_string(), "B".to_string()),
                ]
            ));
        coord.register_node_topology(&h, provider);

        // No stored tunnels — result is purely the containment set.
        let tunnels = coord.recall_tunnels(&h, "test-wing").expect("recall_tunnels");
        let containment: Vec<&Tunnel> =
            tunnels.iter().filter(|t| t.label == "containment").collect();

        // All 4 edges of the small tree must appear as containment tunnels.
        assert_eq!(
            containment.len(), 4,
            "expected 4 containment tunnels from small tree, got {}",
            containment.len()
        );

        // Each containment tunnel must carry non-None source_drawer_id and target_drawer_id.
        for t in &containment {
            assert!(t.source_drawer_id.is_some(),
                "containment tunnel should have source_drawer_id (parent)");
            assert!(t.target_drawer_id.is_some(),
                "containment tunnel should have target_drawer_id (child)");
        }

        // Edge root→A must be present (id format "containment:root:A").
        let root_to_a = containment
            .iter()
            .find(|t| t.source_drawer_id.as_deref() == Some("root")
                   && t.target_drawer_id.as_deref() == Some("A"));
        assert!(root_to_a.is_some(), "root→A containment edge not found in recall_tunnels output");
    }

    // CO-NT-3: the provider's tree_edges is called EXACTLY ONCE per
    // recall_tunnels invocation (G1 read-once-and-freeze contract).
    // Mirrors Swift nodeTreeNative_callCount_exactlyOne_perRecall (§6 gate 7).
    #[test]
    fn co_nt3_provider_called_exactly_once_per_recall() {
        let provider = Arc::new(CallCountProvider::new(small_tree_edges()));
        let provider_ref = Arc::clone(&provider);
        let (mut coord, h) = open_one();
        coord.register_node_topology(&h, provider);

        // First recall_tunnels call.
        _ = coord.recall_tunnels(&h, "wing-1").expect("recall_tunnels 1");
        assert_eq!(
            provider_ref.call_count(), 1,
            "after first recall_tunnels: call count must be exactly 1"
        );

        // Second recall_tunnels call must increment independently.
        _ = coord.recall_tunnels(&h, "wing-2").expect("recall_tunnels 2");
        assert_eq!(
            provider_ref.call_count(), 2,
            "after second recall_tunnels: call count must be exactly 2 (one per call)"
        );
    }

    // CO-NT-4: closing an estate drops its topology provider — the provider
    // registry entry for the handle is removed on close. Parity of the Swift
    // `close` behaviour which drops `nodeTopologyProviders[handle]`.
    #[test]
    fn co_nt4_close_drops_topology_provider() {
        let (mut coord, h) = open_one();
        let provider: Arc<dyn crate::node_topology::NodeTopologyProvider> =
            Arc::new(crate::node_topology::MemoryTopologyProvider::new(
                [("A".to_string(), "root".to_string())]
            ));
        coord.register_node_topology(&h, provider);
        // Provider is registered: a fresh recall would see containment tunnels.
        coord.close(&h).expect("close");
        // After close, the provider entry must be gone — not just the estate.
        // We prove this by confirming the node_topology_providers map no longer
        // holds the handle. Direct field access via the internal registry.
        assert!(
            !coord.node_topology_providers.contains_key(&h),
            "topology provider entry must be dropped when estate is closed"
        );
    }

    // CO-NT-5: registering a provider on handle A does not affect handle B —
    // unregistered estates remain unchanged. Parity of the Swift test that
    // asserts a fresh estate produces only stored tunnels with no containment labels.
    #[test]
    fn co_nt5_unregistered_estate_unchanged() {
        let mut coord = EstateCoordinator::new();
        let store_a: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let store_b: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let ha = coord.open(store_a, OwnerCredentials::new("owner-a"), 0, 100).expect("open A");
        let hb = coord.open(store_b, OwnerCredentials::new("owner-b"), 0, 100).expect("open B");

        // Register provider on A only.
        let provider: Arc<dyn crate::node_topology::NodeTopologyProvider> =
            Arc::new(crate::node_topology::MemoryTopologyProvider::new(
                [("A".to_string(), "root".to_string())]
            ));
        coord.register_node_topology(&ha, provider);

        // B has no stored tunnels and no provider — must return empty, no containment.
        let tunnels_b = coord.recall_tunnels(&hb, "any-wing").expect("recall_tunnels B");
        let containment_b = tunnels_b.iter().filter(|t| t.label == "containment").count();
        assert_eq!(
            containment_b, 0,
            "estate B has no provider — no containment tunnels expected"
        );
        assert!(
            tunnels_b.is_empty(),
            "estate B has no stored tunnels — result must be empty"
        );
    }

    // CO-NT-6: synthetic containment tunnels carry the exact field values
    // specified in the INTERFACE doc (id format, label, filed_at = i64::MIN,
    // added_by = "nodeTopologyProvider", source/target_drawer_id = parent/child).
    #[test]
    fn co_nt6_synthetic_tunnel_field_values() {
        let (mut coord, h) = open_one();
        let provider: Arc<dyn crate::node_topology::NodeTopologyProvider> =
            Arc::new(crate::node_topology::MemoryTopologyProvider::new(
                // Single edge: parent "P" → child "C".
                [("C".to_string(), "P".to_string())]
            ));
        coord.register_node_topology(&h, provider);

        let tunnels = coord.recall_tunnels(&h, "w").expect("recall_tunnels");
        assert_eq!(tunnels.len(), 1, "expected exactly 1 synthetic tunnel");
        let t = &tunnels[0];

        // id format: "containment:<parent>:<child>"
        assert_eq!(t.id, "containment:P:C", "id must be 'containment:<parent>:<child>'");
        // label discriminator
        assert_eq!(t.label, "containment", "label must be 'containment'");
        // source_drawer_id = parent node id (P)
        assert_eq!(t.source_drawer_id.as_deref(), Some("P"),
            "source_drawer_id must be the parent node id");
        // target_drawer_id = child node id (C)
        assert_eq!(t.target_drawer_id.as_deref(), Some("C"),
            "target_drawer_id must be the child node id");
        // filed_at = i64::MIN (parity of Swift Date.distantPast)
        assert_eq!(t.filed_at, i64::MIN,
            "filed_at must be i64::MIN (Rust parity of Swift Date.distantPast)");
        // provenance marker
        assert_eq!(t.added_by, "nodeTopologyProvider",
            "added_by must be 'nodeTopologyProvider'");
        // All bitmaps zero (default active/normal state)
        assert_eq!(t.adjective_bitmap, 0, "adjective_bitmap must be 0");
        assert_eq!(t.operational_bitmap, 0, "operational_bitmap must be 0");
        assert_eq!(t.provenance_bitmap, 0, "provenance_bitmap must be 0");
    }

    // -------------------------------------------------------------------------
    // FT-1: recall_kg_fact_timeline returns active + retired facts, time-ordered.
    //
    // Fixture: file a fact, retire it, call recall_kg_fact_timeline with no
    // entity filter.  The returned slice must contain the fact (lifecycle state
    // bytes 0-5 of adjective_bitmap = 18 = State::Withdrawn, a RowState
    // Cluster-B raw at/above the active upper bound) AND it must not appear in
    // the active-only recall_kg_facts result (regression guard).
    // -------------------------------------------------------------------------
    #[test]
    fn ft1_fact_timeline_shows_retired_fact() {
        let (coord, h) = open_one();

        // File a fact: Earth orbits Sun.
        let fact = coord
            .add_kg_fact(&h, "Earth", "orbits", "Sun", "drawer-ft1", NOW)
            .expect("add_kg_fact should succeed");

        // Before retirement: both paths show the fact.
        let active_before = coord.recall_kg_facts(&h).expect("recall_kg_facts");
        assert!(
            active_before.iter().any(|f| f.id == fact.id),
            "active recall must include the fact before retirement"
        );
        let timeline_before = coord
            .recall_kg_fact_timeline(&h, None)
            .expect("recall_kg_fact_timeline");
        assert!(
            timeline_before.iter().any(|f| f.id == fact.id),
            "timeline must include the fact before retirement"
        );

        // Retire the fact — withdraw transitions adjective_bitmap bits 0-5 to
        // State::Withdrawn raw value (18), which makes g_state_cluster = 18,
        // at/above the active upper bound (RowState Cluster B).
        coord
            .withdraw_kg_fact(&h, &fact.id, NOW + 1)
            .expect("withdraw_kg_fact should succeed");

        // After retirement: active-only recall must NOT include the fact.
        let active_after = coord.recall_kg_facts(&h).expect("recall_kg_facts after retire");
        assert!(
            !active_after.iter().any(|f| f.id == fact.id),
            "active recall must exclude the fact after retirement"
        );

        // After retirement: timeline must include it, retired (raw at/above the
        // canonical active upper bound, i.e. RowState Cluster B/C).
        let timeline_after = coord
            .recall_kg_fact_timeline(&h, None)
            .expect("recall_kg_fact_timeline after retire");
        let retired_row = timeline_after.iter().find(|f| f.id == fact.id);
        assert!(
            retired_row.is_some(),
            "timeline must contain the retired fact"
        );
        let state_cluster = (retired_row.unwrap().adjective_bitmap & 0x3F) as u8;
        assert!(
            state_cluster >= RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW,
            "retired fact must have g_state_cluster >= active upper bound ({}), got {}",
            RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW,
            state_cluster
        );
    }

    // -------------------------------------------------------------------------
    // FT-2: recall_kg_fact_timeline entity filter returns only matching facts.
    //
    // Fixture: file two facts with different subjects.  Filter by subject
    // substring — only the matching fact must appear in results.
    // -------------------------------------------------------------------------
    #[test]
    fn ft2_fact_timeline_entity_filter() {
        let (coord, h) = open_one();

        let alice = coord
            .add_kg_fact(&h, "alice", "worksAt", "ACME", "drawer-ft2", NOW)
            .expect("add alice fact");
        let bob = coord
            .add_kg_fact(&h, "bob", "worksAt", "ACME", "drawer-ft2", NOW + 1)
            .expect("add bob fact");

        let filtered = coord
            .recall_kg_fact_timeline(&h, Some("alice"))
            .expect("recall_kg_fact_timeline with entity filter");

        let ids: Vec<&str> = filtered.iter().map(|f| f.id.as_str()).collect();
        assert!(ids.contains(&alice.id.as_str()), "alice fact must be present");
        assert!(!ids.contains(&bob.id.as_str()), "bob fact must be absent");
    }

    // -------------------------------------------------------------------------
    // FT-3: recall_kg_fact_timeline returns facts in filed_at ascending order.
    //
    // Fixture: file three facts at increasing timestamps.  The timeline must
    // return them in filed_at ascending order (oldest first).
    // -------------------------------------------------------------------------
    #[test]
    fn ft3_fact_timeline_is_time_ordered() {
        let (coord, h) = open_one();

        let f1 = coord
            .add_kg_fact(&h, "A", "rel", "B", "drawer-ft3", NOW)
            .expect("fact 1");
        let f2 = coord
            .add_kg_fact(&h, "B", "rel", "C", "drawer-ft3", NOW + 10)
            .expect("fact 2");
        let f3 = coord
            .add_kg_fact(&h, "C", "rel", "D", "drawer-ft3", NOW + 20)
            .expect("fact 3");

        let timeline = coord
            .recall_kg_fact_timeline(&h, None)
            .expect("recall_kg_fact_timeline");

        // Verify ascending order: each fact must appear after its predecessor.
        let pos = |id: &str| timeline.iter().position(|f| f.id == id);
        let p1 = pos(&f1.id).expect("f1 in timeline");
        let p2 = pos(&f2.id).expect("f2 in timeline");
        let p3 = pos(&f3.id).expect("f3 in timeline");
        assert!(p1 < p2 && p2 < p3, "timeline must be filed_at ascending");
    }

    // -------------------------------------------------------------------------
    // FT-4: recall_kg_facts regression — active-only (parity guard).
    //
    // Retire a fact and confirm recall_kg_facts returns active count unchanged
    // (no retired rows leak through the RowState Cluster-A active filter,
    // g_state_cluster < ACTIVE_CLUSTER_UPPER_BOUND_RAW).
    // -------------------------------------------------------------------------
    #[test]
    fn ft4_recall_kg_facts_active_only_regression() {
        let (coord, h) = open_one();

        let active1 = coord
            .add_kg_fact(&h, "Mars", "has_moon", "Phobos", "drawer-ft4", NOW)
            .expect("active fact 1");
        let to_retire = coord
            .add_kg_fact(&h, "Pluto", "classifiedAs", "planet", "drawer-ft4", NOW + 1)
            .expect("fact to retire");

        // Baseline: both are active.
        let baseline = coord.recall_kg_facts(&h).expect("baseline recall");
        assert_eq!(baseline.len(), 2, "baseline must have 2 active facts");

        coord
            .withdraw_kg_fact(&h, &to_retire.id, NOW + 2)
            .expect("withdraw");

        // After retirement: active recall must have exactly 1 fact.
        let active_after = coord.recall_kg_facts(&h).expect("active after retire");
        assert_eq!(active_after.len(), 1, "active recall must have 1 fact after retirement");
        assert!(
            active_after.iter().any(|f| f.id == active1.id),
            "the active fact must still appear"
        );

        // Timeline must have both.
        let timeline = coord
            .recall_kg_fact_timeline(&h, None)
            .expect("timeline");
        assert_eq!(timeline.len(), 2, "timeline must have both facts");
    }
}
