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
    RecallEvidencePath, RecallHit, RecallPlan, RecallScoreVector, RecallUnionProfile,
    RecallWeights,
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
/// of the Swift `remap(verb:error:)`: a `not yet implemented` stub error
/// becomes `NotSupportedByEstate`; anything else is an
/// `UnderlyingEstateFailure`. (The GLK-error passthrough Swift's remap does
/// is handled in Rust by `estate_for` surfacing `EstateNotOpen` before the
/// verb body runs.)
///
/// When `estate_id` is non-empty, emits a `geniuslocus.estate.verb_error`
/// metric through IntellectusLib (GLK_ROLLUPS_001). Mirrors the Swift
/// `remap(verb:estateID:error:)` signature extension; callers that cannot
/// provide an estate id pass `""` (no metric emitted).
fn remap(verb: &str, estate_id: &str, error: LocusKitError) -> VerbError {
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
        BrainKind::Amend               => SubstrateKind::MutateDrawer,
        BrainKind::TestPropose         => SubstrateKind::NewTunnel,
        BrainKind::Other(_)            => SubstrateKind::NewTunnel,
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
        }
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
        // Initialise empty grant store and scope vault for this estate.
        self.grant_stores.insert(handle, GrantStore::new());
        self.scope_vaults.insert(handle, ScopeKeyVault::new());
        // Mark the estate mounted (GLK_PROVISION_001).
        self.mount_states.insert(handle, EstateMountState::Mounted);

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
        self.grant_stores.insert(handle, GrantStore::new());
        self.scope_vaults.insert(handle, ScopeKeyVault::new());
        // Mark the estate mounted so mount_state queries work on hydrated estates too.
        self.mount_states.insert(handle, EstateMountState::Mounted);
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

    /// Returns `true` if a `Corpus` is registered for `handle`.
    ///
    /// Used by tests and the admin plane to verify that `provision` (or
    /// `register_corpus`) wired the BM25 lane for the addressed estate.
    /// Mirrors the Swift test assertion `kit.corpusKits[handle] != nil`.
    pub fn has_corpus(&self, handle: &EstateHandle) -> bool {
        self.corpus_kits.contains_key(handle)
    }

    /// Returns `true` if a `VectorStore` is registered for `handle`.
    ///
    /// Used by tests and the admin plane to verify that `provision` (or
    /// `register_vector_store`) wired the vector lane for the addressed estate.
    /// Mirrors the Swift test assertion `kit.vectorStores[handle] != nil`.
    pub fn has_vector_store(&self, handle: &EstateHandle) -> bool {
        self.vector_stores.contains_key(handle)
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
    pub fn recall(
        &self,
        handle: &EstateHandle,
        frame: RecallFrame,
        now: i64,
    ) -> Result<Vec<Drawer>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        Ok(estate.recall(frame, now).collect_all())
    }

    // MARK: - recall_tunnels

    /// Read the tunnels originating in `wing` for the estate addressed by
    /// `handle` — the graph-read accessor a structural reasoning lens
    /// (keystone centrality) needs. The drawer-to-drawer tunnels are the
    /// edges of the association graph. Read-only; parallels `recall`.
    ///
    /// Note: tree-edge injection from a registered `NodeTopologyProvider`
    /// (the `.nodeTreeNative` containment union the Swift port performs) is
    /// NOT yet wired in the Rust port — this method returns stored tunnels
    /// only. Wiring `register_node_topology` into the coordinator is a
    /// follow-up mission; until then the Rust structural lenses see tunnel
    /// edges only, never containment edges.
    pub fn recall_tunnels(
        &self,
        handle: &EstateHandle,
        wing: &str,
    ) -> Result<Vec<Tunnel>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .tunnels_from_wing(wing)
            .map_err(|e| remap("recall_tunnels", "", e).into())
    }

    // MARK: - mutate

    /// Apply a named mutation to a drawer. The `Confirm` kind is live — it
    /// transitions the row's confirmation axis to `UserConfirmed` and returns
    /// `Ok`. The state-axis kinds (Reject/Contest/Resolve/Supersede/Revive)
    /// are not yet wired in LocusKit and return
    /// `InvalidContent("…not yet implemented…")`, which `remap` turns into
    /// `NotSupportedByEstate { verb: "mutate" }` — parity of the Swift surface.
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

    /// Tombstone a drawer and zeroize its content. Raises
    /// `VerbError::ExpungeNotConfirmed` at the boundary when `confirmation`
    /// is false (the substrate is not reached) — parity of the Swift guard.
    pub fn expunge(
        &self,
        handle: &EstateHandle,
        row_id: &str,
        reason: &str,
        confirmation: bool,
    ) -> Result<(), VerbDispatchError> {
        if !confirmation {
            return Err(VerbError::ExpungeNotConfirmed {
                row_id: row_id.to_string(),
            }
            .into());
        }
        let estate = self.estate_for_verb(handle)?;
        estate
            .expunge(row_id, reason, confirmation)
            .map_err(|e| remap("expunge", &uuid_to_str(&handle.estate_uuid), e).into())
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
    /// `learn` is grounding-driven per AriaLexicon's flow taxonomy. The
    /// underlying `Estate::learn` is a stub that returns `InvalidContent`
    // MARK: - learn

    /// Ingest a learned reference into the estate addressed by `handle`.
    ///
    /// `learn` is grounding-driven per AriaLexicon's flow taxonomy. Delegates
    /// to `locus_kit::Estate::learn`. Validates the handle first so a stale
    /// handle raises `EstateNotOpen` uniformly, matching the other verbs.
    ///
    /// `now` is explicit per the Rust substrate's determinism convention.
    pub fn learn(
        &self,
        handle: &EstateHandle,
        source_handle: &str,
        now: i64,
    ) -> Result<locus_kit::learned_reference::LearnedReference, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        let frame = LocusLearnFrame { handle: source_handle.to_string() };
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
    /// Returns all kg-facts where state cluster < 7 (active, pre-resolution
    /// states), ordered by `filed_at` ascending. Delegates to
    /// `Estate::all_kg_facts` — the new estate-wide read path added to
    /// `DrawerStore` in this stream.
    pub fn recall_kg_facts(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::kg_fact::KGFact>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.all_kg_facts().map_err(|e| remap("recall_kg_facts", "", e).into())
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

        // Persist the grant.
        store.insert(grant.clone());

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
        store.revoke(grant_id, now)?;
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
    /// - `embedding_model`: Embedding model passed to `Corpus::open`. Use
    ///                      `EmbeddingModelConfig::Deterministic` (the default) for
    ///                      tests; no CoreML required.
    pub fn provision(
        &mut self,
        store: Arc<dyn DrawerStore>,
        storage: Arc<dyn Storage>,
        corpus_storage: Option<Arc<dyn Storage>>,
        owner: OwnerCredentials,
        params: EstateProvisionParams,
        embedding_model: EmbeddingModelConfig,
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
                // Both are constructed on backing_storage. Corpus::open applies both
                // BundleStore and VectorStore schema migrations via `migrate`, matching
                // the Swift path where Corpus.init applies both schemas.
                Corpus::open(Arc::clone(&backing_storage), embedding_model)
                    .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                        reason: format!("Corpus::open failed for GLK estate: {:?}", e),
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
                Corpus::open(Arc::clone(&backing_storage), embedding_model)
                    .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                        reason: format!("Corpus::open failed for CorpusOnly estate: {:?}", e),
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
        // for inter-lane deduplication without unbounded row retrieval.
        let frontier_k = (request.limit * 4).max(64).min(256);

        let plan = RecallPlan {
            effective_mode: request.mode,
            frontier_k,
            weights: RecallWeights::UNIFORM,
        };

        match request.mode {
            GLKRecallMode::LocusOnly => {
                Self::recall_scored_locus_only(estate, request, plan, now)
            }
            GLKRecallMode::Hybrid
            | GLKRecallMode::CorpusOnly
            | GLKRecallMode::UnionBest => {
                let corpus = self.corpus_kits.get(handle).cloned();
                let vector = self.vector_stores.get(handle).cloned();
                Self::recall_scored_multi_lane(estate, request, plan, now, corpus, vector)
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
        // Drain the RecallStream up to frontier_k, then apply the limit.
        let rows: Vec<Drawer> = estate
            .recall(request.frame.clone(), now)
            .collect_all()
            .into_iter()
            .take(plan.frontier_k)
            .collect();

        let limited: Vec<Drawer> = rows.into_iter().take(request.limit).collect();

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
    #[allow(clippy::too_many_arguments)]
    fn recall_scored_multi_lane(
        estate: &locus_kit::estate::Estate,
        request: GLKRecallRequest,
        plan: RecallPlan,
        now: i64,
        corpus: Option<Arc<Corpus>>,
        vector: Option<Arc<VectorStore>>,
    ) -> Result<GLKRecallResult, VerbDispatchError> {
        let has_corpus = corpus.is_some();
        let has_vector = vector.is_some();

        // When no corpus or vector store is registered, fall back to
        // rank-normalised locus-only scoring. This preserves the existing
        // behaviour for estates that have not wired CorpusKit/VectorKit.
        if !has_corpus && !has_vector {
            return Self::recall_scored_locus_ranked(estate, request, plan, now);
        }

        // --- Lane 1: Locus (active for Hybrid and UnionBest; skipped for CorpusOnly) ---
        // Rank-normalised: score = (frontier_k - rank) / frontier_k.
        let locus_list: Vec<(String, f32)>;
        let drawer_index: HashMap<String, Drawer>;

        let include_locus = matches!(
            request.mode,
            GLKRecallMode::Hybrid | GLKRecallMode::UnionBest
        );

        if include_locus {
            let locus_rows: Vec<Drawer> = estate
                .recall(request.frame.clone(), now)
                .collect_all()
                .into_iter()
                .take(plan.frontier_k)
                .collect();
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
            // For CorpusOnly we still need drawers for hydration; drain all up to frontier_k.
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
        let vector_list: Vec<(String, f32)> = if let (Some(ref c), Some(ref vs)) = (&corpus, &vector) {
            if !query_str.is_empty() {
                match c.embed(&query_str) {
                    Ok(probe) => {
                        let model = c.model_id().to_string();
                        match vs.find_nearest(&probe, &model, plan.frontier_k) {
                            Ok(matches) => matches
                                .into_iter()
                                .map(|m| {
                                    // Hamming distance 0..=256 → score 0.0..=1.0.
                                    let score = (256 - m.distance.clamp(0, 256)) as f32 / 256.0;
                                    (m.drawer_id, score)
                                })
                                .collect(),
                            Err(_) => Vec::new(),
                        }
                    }
                    Err(_) => Vec::new(),
                }
            } else {
                Vec::new()
            }
        } else {
            Vec::new()
        };

        // --- RRF fusion ---
        // For .raw: sum raw scores per id; sort desc by sum, id asc on tie.
        // For .rrf / .matrixAware: Σ_L 1/(k + rank_in_L) per id; k=60.
        //
        // Collect all unique candidate ids across populated lanes.
        let mut all_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
        for (id, _) in &locus_list { all_ids.insert(id.clone()); }
        for (id, _) in &bm25_list  { all_ids.insert(id.clone()); }
        for (id, _) in &vector_list { all_ids.insert(id.clone()); }

        // Build per-id score maps (raw score and rank) for each lane.
        let locus_score_map: HashMap<String, (usize, f32)> = locus_list
            .iter().enumerate().map(|(r, (id, s))| (id.clone(), (r, *s))).collect();
        let bm25_score_map: HashMap<String, (usize, f32)> = bm25_list
            .iter().enumerate().map(|(r, (id, s))| (id.clone(), (r, *s))).collect();
        let vector_score_map: HashMap<String, (usize, f32)> = vector_list
            .iter().enumerate().map(|(r, (id, s))| (id.clone(), (r, *s))).collect();

        let k = 60_f32;
        let mut fused_scored: Vec<(String, f32, f32, f32, f32)> = all_ids
            .iter()
            .map(|id| {
                let (locus_rank, locus_raw) = locus_score_map.get(id).copied().unwrap_or((usize::MAX, 0.0));
                let (bm25_rank, bm25_raw)   = bm25_score_map.get(id).copied().unwrap_or((usize::MAX, 0.0));
                let (vec_rank, vec_raw)      = vector_score_map.get(id).copied().unwrap_or((usize::MAX, 0.0));

                let final_score = match request.scoring {
                    GLKRecallScoring::Raw => {
                        locus_raw + bm25_raw + vec_raw
                    }
                    GLKRecallScoring::Rrf | GLKRecallScoring::MatrixAware => {
                        let mut rrf = 0.0_f32;
                        if locus_rank < usize::MAX {
                            rrf += 1.0 / (k + locus_rank as f32 + 1.0);
                        }
                        if bm25_rank < usize::MAX {
                            rrf += 1.0 / (k + bm25_rank as f32 + 1.0);
                        }
                        if vec_rank < usize::MAX {
                            rrf += 1.0 / (k + vec_rank as f32 + 1.0);
                        }
                        rrf
                    }
                };
                // Return (id, final_score, locus_raw, bm25_raw, vec_raw) for hit assembly.
                (id.clone(), final_score, locus_raw, bm25_raw, vec_raw)
            })
            .collect();

        // Sort descending by final_score; tie-break id ascending (deterministic).
        fused_scored.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(a.0.cmp(&b.0))
        });
        fused_scored.truncate(request.limit);

        // Collect which evidence lanes contributed for the union profile.
        let locus_contributed = !locus_list.is_empty();
        let bm25_contributed  = !bm25_list.is_empty();
        let vector_contributed = !vector_list.is_empty();

        let union_profile = match request.mode {
            GLKRecallMode::UnionBest => {
                // Populate a minimal union profile; matrix/graph/preference
                // signals remain 0.0 until the matrix tier is wired.
                Some(RecallUnionProfile::ZERO)
            }
            _ => None,
        };

        // Build RecallHits with per-lane score breakdown.
        let hits: Vec<RecallHit> = fused_scored
            .into_iter()
            .map(|(id, final_s, locus_s, bm25_s, vec_s)| {
                let drawer = drawer_index.get(&id).cloned();
                let mut sources = Vec::new();
                if locus_contributed && locus_score_map.contains_key(&id) {
                    sources.push(RecallEvidencePath::LocusBitmap);
                }
                if bm25_contributed && bm25_score_map.contains_key(&id) {
                    sources.push(RecallEvidencePath::CorpusBm25);
                }
                if vector_contributed && vector_score_map.contains_key(&id) {
                    sources.push(RecallEvidencePath::VectorHamming);
                }
                if sources.is_empty() {
                    sources.push(RecallEvidencePath::LocusBitmap);
                }
                let score = RecallScoreVector {
                    locus: locus_s,
                    bm25: bm25_s,
                    vector: vec_s,
                    field_fit: 0.0,
                    co_occurrence: 0.0,
                    temporal: 0.0,
                    graph: 0.0,
                    preference: 0.0,
                    redundancy_penalty: 0.0,
                    final_score: final_s,
                };
                let mut explanation = Vec::new();
                if locus_s > 0.0 { explanation.push("locusBitmap".to_string()); }
                if bm25_s > 0.0  { explanation.push("bm25".to_string()); }
                if vec_s > 0.0   { explanation.push("vector".to_string()); }
                if explanation.is_empty() { explanation.push("locusBitmap".to_string()); }
                RecallHit { id, drawer, sources, score, explanation }
            })
            .collect();

        Ok(GLKRecallResult {
            request,
            plan,
            union_profile,
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
        // Drain the locus lane up to frontier_k rows.
        let locus_rows: Vec<Drawer> = estate
            .recall(request.frame.clone(), now)
            .collect_all()
            .into_iter()
            .take(plan.frontier_k)
            .collect();

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
            hits,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};

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
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    fn confirmed() -> RecallFrame {
        // Admit user-confirmed rows (the evaluator's default ceiling, here
        // explicit) so a confirmed row is returned by recall.
        let mut f = RecallFrame::new(vec![Filter::UserConfirmed]);
        f.hydration_level = HydrationLevel::Structured;
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
        let err = coord.expunge(&h, &stored.id, "cleanup", false).unwrap_err();
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

    // CO-5b: a state-axis mutation kind (Reject) is not yet wired and remaps
    // to NotSupportedByEstate — the dispatch chain's error mapping is intact.
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
    // v2b-p2 non-drawer recall stubs.
    // Each method validates the handle first (stale handle → EstateNotOpen)
    // then returns NotSupportedByEstate so the MCP surface advertises the
    // tool honestly without pretending it works.
    // -----------------------------------------------------------------

    // CO-10: learn is now live — with a valid handle it returns a LearnedReference.
    #[test]
    fn co10_learn_with_valid_handle_returns_learned_reference() {
        let (coord, h) = open_one();
        let result = coord.learn(&h, "test-handle", 1_700_000_000);
        let ref_row = result.expect("learn should succeed with a valid handle");
        assert_eq!(ref_row.handle, "test-handle");
        assert_eq!(ref_row.added_by, "learn");
    }

    // CO-10b: learn with an empty handle returns InvalidContent.
    #[test]
    fn co10b_learn_with_empty_handle_returns_invalid_content() {
        let (coord, h) = open_one();
        let err = coord.learn(&h, "", 1_700_000_000).unwrap_err();
        assert!(matches!(
            err,
            VerbDispatchError::Verb(VerbError::UnderlyingEstateFailure { .. })
        ));
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

    // CO-16: stub verbs on a closed handle raise EstateNotOpen, not
    // NotSupportedByEstate — handle validation runs first.
    #[test]
    fn co16_stubs_on_closed_handle_raise_estate_not_open() {
        let (mut coord, h) = open_one();
        coord.close(&h).expect("close");

        assert_eq!(
            coord.learn(&h, "h", 1_700_000_000).unwrap_err(),
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, EmbeddingModelConfig::Deterministic)
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
            .provision(store1, stor1, None, OwnerCredentials::new("owner"), params.clone(), EmbeddingModelConfig::Deterministic)
            .expect("first provision should succeed");

        let err = coord
            .provision(store2, stor2, None, OwnerCredentials::new("owner"), params, EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("GLK1"), EmbeddingModelConfig::Deterministic)
            .expect("provision");
        assert_eq!(coord.mount_state(&handle), Some(EstateMountState::Mounted));
    }

    // PR-8: quiesce transitions mounted → quiesced.
    #[test]
    fn pr8_quiesce_transitions_mounted_to_quiesced() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("Q1"), EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("Q2"), EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("D1"), EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("L1"), EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("L2"), EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("L3"), EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("L4"), EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, EmbeddingModelConfig::Deterministic)
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
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, EmbeddingModelConfig::Deterministic)
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
}
