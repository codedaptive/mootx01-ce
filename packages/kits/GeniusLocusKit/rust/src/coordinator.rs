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

use std::cell::RefCell;
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

use corpus_kit::corpus::{EmbeddingModelConfig, EncodeSpeed};
use corpus_kit::{
    CorpusContentConfiguration, CorpusContentEngine, CorpusIndexUnitPolicy, CorpusOperatingMode,
};
use crate::intake::LocusDrawerContentSource;
use engram_lib::Engram;
use vectorkit::vector_store::{VectorMatch, VectorStore};
use persistence_kit::storage::{Storage, BackendConfiguration};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::sqlite::SqliteStorage;
use queuekit::{DrainLease, PersistenceKitBackend};
use std::path::Path;
use locus_kit::default_wings::DEFAULT_WINGS;
use locus_kit::diary_entry::DiaryEntry;
use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::ContentKind;
use uuid::Uuid;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::error::LocusKitError;
use locus_kit::recall_trace_item::RecallTraceItem;
use locus_kit::estate::Estate;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::RecallFrame;
use locus_kit::frames::{AssociateFrame as LocusAssociateFrame, CaptureFrame, LearnFrame as LocusLearnFrame, MutationKind, ProposeFrame as LocusProposeFrame};
// GLK-level LearnFrame — the public verb boundary type that callers supply.
// Mapped to LocusLearnFrame at the dispatch boundary (same pattern as
// ProposeFrame → LocusProposeFrame). Imported here for the `learn` method
// signature and the test helper below.
use crate::verbs::frames::LearnFrame as GlkLearnFrame;
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

/// Build a lookup map from parent_node_id to (wing_name, room_name)
/// for all drawers. Uses the coordinator's `node_stores` registry
/// — `estate.node_store` is `pub(crate)` in LocusKit
/// and not accessible from GeniusLocusKit.
fn build_node_name_map(
    ns: Option<&Arc<locus_kit::node_store::NodeStore>>,
    drawers: &[Drawer],
) -> std::collections::HashMap<String, (String, String)> {
    let mut map = std::collections::HashMap::new();
    let ns = match ns {
        Some(ns) => ns,
        None => return map,
    };
    for drawer in drawers {
        if map.contains_key(&drawer.parent_node_id) {
            continue;
        }
        let room_uuid = match Uuid::parse_str(&drawer.parent_node_id) {
            Ok(u) => u,
            Err(_) => continue,
        };
        let room_node = match ns.get_node(room_uuid) {
            Ok(Some(n)) => n,
            _ => continue,
        };
        let room_name = room_node.display_name.clone();
        let wing_name = room_node
            .parent_id
            .and_then(|pid| ns.get_node(pid).ok().flatten())
            .map(|n| n.display_name)
            .unwrap_or_default();
        map.insert(drawer.parent_node_id.clone(), (wing_name, room_name));
    }
    map
}

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

    /// The grant's Ed25519 signature does not verify against the GRANTER's
    /// registered identity public key.
    ///
    /// Trust derives from the estate registry (the manifest-persisted public key),
    /// not from any field in the grant blob — same registered-key trust anchor
    /// as the F-3 `pull()` hardening in ConvergenceKit `FederationSyncEngine`.
    ///
    /// Migration posture: `federated_recall` is local in-process (I-13 invariant).
    /// An empty signature is allowed with a logged warning; a non-empty signature
    /// that fails verification is always rejected. Mirrors Swift
    /// `FederatedReadRefusalReason.invalidGrantSignature`.
    InvalidGrantSignature,
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

/// Key-material lifetime for a provisioned estate.
///
/// Mirrors Swift `EstateLifetime`. The distinction matters on Apple platforms
/// where the Ed25519 identity key is written to the Apple Keychain on
/// `.durable` estates. On Linux/non-Darwin targets the Rust coordinator does
/// not interact with a system Keychain; `dispose_estate_keys` is therefore a
/// no-op regardless of lifetime. The field exists for parity so callers that
/// round-trip params across the Swift/Rust boundary do not need conditional
/// logic.
///
/// ## .durable (default)
/// Identity and db-key material live in the system Keychain (Apple platforms)
/// or process-local secure storage (other targets). Correct for all
/// production/user-owned estates.
///
/// ## .ephemeral
/// Identity material lives only in process memory. No Keychain writes at any
/// point. Use for test loops and agent-driven harnesses that need SQLite
/// persistence semantics without accumulating Keychain items.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EstateLifetime {
    /// Keychain-backed identity and db-key material. Correct for production. (default)
    #[default]
    Durable,
    /// In-memory identity only. No Keychain writes. For test loops.
    Ephemeral,
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
    /// Key-material lifetime declaration. Defaults to `EstateLifetime::Durable`.
    /// All existing call sites are unaffected (struct literal construction on the
    /// Rust side must add this field; callers using `..Default::default()` inherit
    /// Durable automatically).
    pub lifetime: EstateLifetime,
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
    /// The addressed estate is quiesced or draining and not accepting new work
    /// (parity of Swift `GeniusLocusKitError.estateQuiesced`). Raised by the
    /// `estate_for_verb` gate before any registry or row lookup.
    EstateQuiesced { estate_uuid: EstateUuid },
    /// The recall mode requested a lane (corpus/vector) that is not registered
    /// for this estate AND the fallback policy is `FailClosed`. Raised instead
    /// of silently degrading to locus-only hits the caller did not request.
    /// Parity of Swift `RecallDirectorError.corpusUnavailable`.
    RecallLaneUnavailable { reason: String },
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

/// Epoch-seconds → ISO8601 UTC string for the recall-trace window reads.
/// Hand-rolled (no chrono dependency) — same construction the NeuronKit
/// governor uses; correct for the 2001–2100 range.
fn epoch_secs_to_iso8601(epoch_secs: i64) -> String {
    let secs = epoch_secs.max(0) as u64;
    let s = secs % 60;
    let m = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    let (year, month, day) = days_to_ymd(days);
    format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}Z")
}

fn days_to_ymd(days: u64) -> (u64, u64, u64) {
    // Proleptic Gregorian from days since 1970-01-01 (era algorithm).
    let z = days + 719468;
    let era = z / 146097;
    let doe = z % 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

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
        // Use Display (not Debug) so LocusKitError's human-readable description
        // surfaces rather than the internal Rust type chain. LocusKitError
        // implements Display; the gate-rejection message already contains
        // clean English (set by drawer_store_inmemory's map_err above).
        reason: format!("{error}"),
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
            // Display (not Debug) so direction emits camelCase rawValue parity
            // with Swift SyncDirection.rawValue: "bidirectional", "pushOnly",
            // "pullOnly". Debug would give PascalCase ("Bidirectional" etc.)
            // which diverges from the canonical vocabulary in the parity contract.
            format!("{backend_name} (syncing, direction: {direction})")
        }
        SyncState::Errored { error, .. } => {
            // Display (not Debug) so the error string is human-readable and
            // matches the Swift \(err) interpolation format via SyncError.Display.
            format!("{backend_name} (error: {error})")
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

/// The dreaming-queue job payload.
///
/// Encoded as JSON in `Job.payload`. Field names use snake_case to match the
/// Swift `DreamingItem` CodingKeys exactly (`recall_event_id`, `drawer_ids`)
/// so payloads are cross-port legible and the drainer (T9) can deserialise
/// either port's output without a schema adapter.
///
/// `recall_event_id` — 32-hex UUID (no hyphens), one per recall event, used
/// by the drainer to group co-recalled drawers in a single dreaming session.
/// `drawer_ids` — surfaced drawer ids in result order. Always ≥ 2 entries
/// (guard is applied by `enqueue_dreaming_item` before this struct is built).
/// `pub` rather than `pub(crate)` so the T9 drainer (a downstream crate) and
/// integration tests can decode the payload and verify the schema.
#[derive(serde::Serialize, serde::Deserialize, Debug, Clone)]
pub struct DreamingItem {
    /// A fresh id generated per recall event (32-hex UUID, no hyphens).
    /// Matches the JobId shape convention from the signals lane.
    pub recall_event_id: String,
    /// Surfaced drawer ids in result order. Always ≥ 2 entries per spec §12.2.
    pub drawer_ids: Vec<String>,
}

/// Maximum characters carried per borderline snippet. Mirrors Swift
/// `GeniusLocusKit.huntSnippetLimit`.
pub const HUNT_SNIPPET_LIMIT: usize = 160;

/// A `contradicts` tunnel the hunter proposed this pass. Rust mirror of
/// Swift `ProposedContradiction`.
#[derive(Debug, Clone, PartialEq)]
pub struct ProposedContradiction {
    pub tunnel_id: String,
    pub source_drawer_id: String,
    pub target_drawer_id: String,
    /// `ConflictCueKind` wire string ("negation_asymmetry", ...).
    pub cue_kind: String,
    pub score: f32,
}

/// A pair the screen found suspicious but below the auto-propose bar —
/// the agent-adjudication feed. Rust mirror of Swift
/// `BorderlineContradiction`.
#[derive(Debug, Clone, PartialEq)]
pub struct BorderlineContradiction {
    pub source_drawer_id: String,
    pub target_drawer_id: String,
    pub cue_kind: String,
    pub score: f32,
    pub source_snippet: String,
    pub target_snippet: String,
}

/// BM25 candidate count per probe on the corpus lane. Candidate generation is
/// LEXICAL, via the corpus's persistent BM25 inverted index — a contradiction
/// is two statements about the same thing that disagree, "about the same thing"
/// is what BM25 answers cheaply (sub-linear WAND/BMW), and it is the same
/// shared-term similarity the conflict-cue screen keys on. A small K suffices
/// because BM25 ranks the shared-term twin near the top. Mirrors Swift
/// `huntBM25CandidateK`.
pub const HUNT_BM25_CANDIDATE_K: usize = 20;

/// Character cap on the BM25 query built from a probe drawer's content. WAND
/// cost grows with query term count, so querying an entire large body makes the
/// per-probe cost scale with drawer size; candidate generation only needs the
/// probe's topic, which the leading content carries (the full bodies are
/// compared by the conflict-cue screen downstream regardless). Mirrors Swift
/// `huntBM25QueryCharLimit`.
pub const HUNT_BM25_QUERY_CHAR_LIMIT: usize = 240;

/// One hunt pass's outcome. `vector_store_available == false` means the
/// estate has no registered VectorStore — the pass is a no-op, reported
/// honestly rather than as a silent zero. Rust mirror of Swift
/// `ContradictionHuntReport`.

#[derive(Debug, Clone)]
pub struct ContradictionHuntReport {
    pub vector_store_available: bool,
    pub probes_scanned: usize,
    pub pairs_screened: usize,
    pub proposed: Vec<ProposedContradiction>,
    pub borderline: Vec<BorderlineContradiction>,
    /// Pairs skipped because a `contradicts` tunnel already exists between
    /// them (any lifecycle — includes rejected reviews).
    pub deduplicated: usize,
}

/// # Adding a per-estate registry
///
/// Every `HashMap<EstateHandle, …>` field below is a PER-ESTATE REGISTRY, and
/// a handle is stable across reopens of the same estate (`handle.rs`). A
/// registry that `close` does not remove therefore survives into the next open
/// of that estate and resolves to state the caller never re-registered.
///
/// A new registry needs TWO things beyond its declaration:
///   1. a removal in `close`, of the form `self.<field>.remove(handle);`
///      (or `self.<field>.borrow_mut().remove(handle);` for a `RefCell` map),
///      teardown-ordered if the value owns a worker, a lease, or a connection;
///   2. nothing else — `tests/estate_close_completeness.rs` reads this file and
///      fails if a declared registry has no matching removal in the `close`
///      body. It will catch you, but it cannot fix you.
///
/// The Swift twin carries the same note on its own declaration block.
pub struct EstateCoordinator {
    registry: HashMap<EstateHandle, Estate>,
    pub(crate) branches: HashMap<crate::branches::BranchId, crate::branches::EstateBranch>,
    /// Per-estate grant stores. Parallel to `registry`.
    grant_stores: HashMap<EstateHandle, GrantStore>,
    /// Per-estate scope key vaults. Parallel to `registry`.
    scope_vaults: HashMap<EstateHandle, ScopeKeyVault>,
    /// Per-estate CorpusKit handles. Optional; activates BM25 lane in recall_scored.
    /// Mirrors Swift actor's `corpusKits: [EstateHandle: Corpus]`.
    pub(crate) corpus_kits: HashMap<EstateHandle, Arc<CorpusContentEngine>>,
    /// Subject-backfill rider registry (PR-09, DARK LANE): the pluggable
    /// producer that writes subjects for subject-debt rows. No producer
    /// ships in Rust until a model exists (the SIMD/tagger dark-lane
    /// precedent); tests inject stubs. While empty for a handle, the
    /// subject_backfill drain lane does not render and the sweep refuses.
    pub(crate) subject_producers: HashMap<EstateHandle, Arc<dyn SubjectProducer>>,
    /// Per-estate VectorKit handles. Optional; activates vector lane in recall_scored.
    /// Mirrors Swift actor's `vectorStores: [EstateHandle: VectorStore]`.
    /// `pub(crate)` so `intake.rs` can access it without routing through a public
    /// accessor that would expose the type externally.
    pub(crate) vector_stores: HashMap<EstateHandle, Arc<VectorStore>>,
    /// Per-estate mount state. Set to `Mounted` on open, updated by quiesce/drain,
    /// removed on close. Mirrors Swift actor's `mountStates: [EstateHandle: EstateMountState]`.
    mount_states: HashMap<EstateHandle, EstateMountState>,
    // The per-estate encode QUEUE + DRAIN + per-estate HLC used to live here.
    // They were relocated into CorpusKit: a Corpus now owns its ingest queue,
    // drain worker pool, and retry (see corpus_kit::corpus_ingest_queue). The
    // coordinator reaches them through `corpus_kits[handle]` and is pure
    // orchestration — it enqueues work and, via the Corpus `on_encoded`
    // callback wired at provision, rolls up the touched LocusKit rooms.
    /// Per-estate unified audit-log G-Set. Minted empty on `open`.
    /// `current_audit_log` / `verify_audit_chain`
    /// / `verify_audit_chain_with_rejections` no longer read from or write to
    /// this registry — each builds a fresh transient log per call via
    /// `hydration::feed_audit_log_from_estate` and returns it directly.
    /// Populated by `set_audit_log`, called from the hydrate-on-launch path
    /// (`open_hydrating`) after replaying the durable audit trail, AND
    /// (RUST-AUDIT-DURABILITY, 2026-07-09) directly by
    /// `append_sensitivity_audit_entry` / `append_grant_audit_entry` on every
    /// sensitivity-unlock and grant-lifecycle write, so a live (non-reopened)
    /// session sees its own writes immediately without waiting for a
    /// hydrate cycle. A non-hydrated, no-sensitivity/grant-activity estate's
    /// entry stays at the empty log minted here for the estate's lifetime.
    /// Read back by the public `audit_log(&self, handle)` getter. Mirrors
    /// the Swift actor's `auditLogs: [EstateHandle: UnifiedAuditLog]` (Swift
    /// removed this map entirely post-Bug-4-fix; Rust retains it as the
    /// live-session read path while durability is layered on top via the
    /// `_storagekit_audit` seam).
    audit_logs: HashMap<EstateHandle, crate::audit::UnifiedAuditLog>,
    /// Per-estate recall-scoring matrix tier. Registered by
    /// `register_matrix_tier` (called from `rebuild_derived_accelerators` and
    /// the hydration path), read by the `matrixAware` recall lane. Absent ⇒
    /// all matrix score columns read 0.0, correct for a fresh estate. Mirrors
    /// the Swift actor's `matrixTiers: [EstateHandle: MatrixTier]`.
    matrix_tiers: HashMap<EstateHandle, crate::matrix::MatrixTier>,
    /// Per-estate graph-centrality caches. Registered by `register_graph_cache`
    /// (called by the dreaming cycle once it has computed per-drawer graph
    /// centrality), read by the `matrixAware` recall lane to populate the `graph`
    /// score column. Absent ⇒ the `graph` column reads 0.0, correct for a fresh
    /// estate with no graph priors. Mirrors the Swift actor's
    /// `graphCaches: [EstateHandle: any GraphCache]`.
    graph_caches: HashMap<EstateHandle, Arc<dyn crate::recall::GraphCache>>,
    /// Per-estate learned-preference stores. Registered by
    /// `register_preference_store` (called by the training daemon once Bradley-
    /// Terry / RecallTrace weights are trained), read by the `matrixAware` recall
    /// lane to populate the `preference` score column. Absent ⇒ the `preference`
    /// column reads 0.0, correct for a fresh estate with no preference priors.
    /// Mirrors the Swift actor's
    /// `preferenceStores: [EstateHandle: any PreferenceStore]`.
    preference_stores: HashMap<EstateHandle, Arc<dyn crate::recall::PreferenceStore>>,
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

    /// Per-estate NodeStore references for resolving drawer parent_node_id
    /// to human-readable (wing, room) display names. Populated
    /// alongside the topology provider during `open`. The NodeStore is the
    /// same Arc that backs the SubstrateNodeTopologyProvider, so no extra
    /// database connection is created. Used by `resolve_drawer_node_names`.
    node_stores: HashMap<EstateHandle, Arc<locus_kit::node_store::NodeStore>>,

    /// Per-estate `Storage` references retained for storage-keyed accelerators:
    /// the explicit transaction boundary (GLK_BATCH1) and the matrix snapshot
    /// store (which loads/persists the matrix tier on disk). Populated during
    /// `open` from `DrawerStore::storage()`, and during hydration by
    /// `open_estate_directly`. Every production drawer store — InMemory, SQLite,
    /// and Postgres — overrides `storage()` to return `Some`, so real estates
    /// always populate this field; only a test/mock store that leaves the trait's
    /// `None` default in place (no backing `Storage`) is absent here, and such a
    /// store correctly gets the no-persistence fallback.
    ///
    /// Mirrors Swift actor's `storages: [EstateHandle: any Storage]`.
    pub(crate) storages: HashMap<EstateHandle, Arc<dyn Storage>>,
    /// Opaque fault token used by optional migration crates' resume proofs.
    /// Core stores no historical migration state-machine type.
    migration_fault_token: Option<String>,

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

    /// Per-estate dreaming queue handles.
    ///
    /// Lazy-mounted in `ensure_dreaming_queue` on the first external-origin scored
    /// recall (`recall_scored` with `request.origin == RecallOrigin::External`) for
    /// each estate. The queue opens the same per-estate `queue.sqlite` that the
    /// encode and signals streams use — one queue, three streams,
    /// isolated by `stream_id = "dreaming"`. Backend selection mirrors the signals
    /// lane in `build_signals_queue` (NeuronKit): SQLite estate → encrypted
    /// `queue.sqlite` sibling; InMemory / absent → transient in-memory backend.
    ///
    /// The `HLCGenerator` is paired with the queue so dreaming jobs carry a
    /// monotone HLC stamp. nodeID derivation: first four estate UUID bytes
    /// big-endian → u32 → cast to i32 (byte-identical to Swift's formula in
    /// `ensureDreamingQueue` and `ensureScheduler`).
    ///
    /// `RefCell` provides interior mutability so `ensure_dreaming_queue` and
    /// `enqueue_dreaming_item` can operate on `&self` — matching `recall_scored`'s
    /// `&self` signature (which has many callers and must not become `&mut self`).
    /// The coordinator is not `Sync`-shared across threads for per-estate mutable
    /// state — it is accessed under the transport's lock — so `RefCell` is sound
    /// here (no concurrent mutable borrows). Mirrors the `RefCell<Option<String>>`
    /// pattern the `test_force_*` seams already use in this coordinator.
    ///
    /// No `DrainLease` is held — T6 is enqueue-only; the lease is a T9 drainer
    /// concern. Dropped in `close` alongside all other per-estate registries.
    ///
    /// Mirrors Swift actor's `dreamingQueues: [EstateHandle: QueueKit]` and
    /// `dreamingHLCs: [EstateHandle: HLCGenerator]`.
    dreaming_queues: RefCell<HashMap<EstateHandle, (queuekit::QueueKit<Box<dyn queuekit::QueueBackend>>, substrate_types::hlc::HLCGenerator)>>,

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

    // The transient encode-ingest failure seam relocated into CorpusKit with the
    // drain: it is now `Corpus::arm_ingest_failure_hook` (see
    // corpus_kit::corpus_ingest_queue). Tests arm it on the estate's Corpus,
    // reached via `corpus_for(handle)`.
}

impl Default for EstateCoordinator {
    fn default() -> Self {
        Self::new()
    }
}

/// A read-only status snapshot of one long-running background drain.
///
/// The substrate reports TWO drains: `"corpus_encode"` (the
/// `corpus_ingest_queue` worker, which encodes captured/imported text into the
/// BM25 + vector lanes asynchronously) and `"distillation"` (the
/// SPEC_DISTILLATION_STORAGE §7.1 accounting surface — `pending` is the
/// row-level eligibility-predicate count, `in_flight` always 0).
/// `EstateCoordinator::drain_statuses` returns a `Vec<DrainStatus>` so that
/// when additional drains are added later, each appends its own entry and the
/// report surfaces all of them with no wire reshape. The list is built from
/// the drains that actually exist — no speculative drain machinery. Mirrors
/// Swift `DrainStatus`.
/// A subject producer (PR-09): turns drawer content into a one-sentence
/// AI-facing subject. The Rust lane is DARK — no implementation ships
/// until a model exists; tests inject stubs. The producer's pipeline
/// version is stored as provenance on every subject it writes and is
/// the regeneration lever. Mirrors Swift `SubjectProducer`.
pub trait SubjectProducer: Send + Sync {
    /// Provenance tier written to `subject_pipeline_version`
    /// (e.g. `locus_kit::drawer_store::SUBJECT_PIPELINE_MINILLM_V1`).
    fn pipeline_version(&self) -> &str;
    /// Produce a subject for `content`. The sweep validates the result
    /// against `locus_kit::subject_register` before writing;
    /// inadmissible output is counted and skipped, never stored.
    fn subject_for_content(&self, content: &str) -> Result<String, String>;

    /// The pipeline tiers this producer is allowed to REGENERATE, in
    /// addition to NULL rows (PR-10). Trust ladder by construction: a
    /// producer lists only tiers BELOW itself — never ai-v1, never its
    /// own tier. Default: empty (NULL-only, the PR-09 behavior).
    fn regenerates_pipelines(&self) -> Vec<String> {
        Vec::new()
    }
}

/// One subject-backfill sweep's outcome. Counts are per-call except
/// `remaining_debt`, the estate-wide presence debt AFTER the sweep.
/// Mirrors Swift `SubjectBackfillReport`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SubjectBackfillReport {
    /// Subjects written this sweep.
    pub written: usize,
    /// Producer outputs rejected by the register contract (skipped; the
    /// rows remain debt and re-enumerate next sweep).
    pub skipped_inadmissible: usize,
    /// Estate-wide subject debt after the sweep.
    pub remaining_debt: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DrainStatus {
    /// Stable identifier for the drain (e.g. `"corpus_encode"`). Lets a status
    /// reader tell drains apart when more than one exists.
    pub name: String,
    /// Jobs submitted to the drain but not yet claimed for processing.
    pub pending: usize,
    /// Jobs claimed and currently being processed.
    pub in_flight: usize,
    /// Optional drain-specific context, human-readable (e.g. the corpus drain
    /// reports `"encoded_chunks: 7218"` so forward progress is visible). `None`
    /// when a drain has no extra detail to report.
    pub detail: Option<String>,
}

impl DrainStatus {
    /// Stable name of the corpus encode/ingest drain. The single source of
    /// truth for the string — `drain_statuses` and `encode_settled` both key
    /// on it.
    pub const CORPUS_ENCODE_NAME: &'static str = "corpus_encode";

    /// Canonical name of the subject-backfill drain lane (PR-09). The
    /// lane renders ONLY while a subject producer is registered for the
    /// estate — an always-present eligibility-count lane would hold the
    /// benchmarker's encode barrier open on healthy estates. When a
    /// rider first ships enabled, the benchmarker's non-gating denylist
    /// must gain this name in the same mission. The Rust lane is DARK in
    /// PR-09: no producer ships; tests inject stubs. Twin of Swift
    /// `DrainStatus.subjectBackfillName`.
    pub const SUBJECT_BACKFILL_NAME: &'static str = "subject_backfill";

    /// True while the drain has outstanding work on either frontier. False
    /// means idle: everything submitted has been processed.
    pub fn is_draining(&self) -> bool {
        self.pending + self.in_flight > 0
    }

    /// T5 finisher gate: true when the ENCODE drain is idle (or absent), so a
    /// detached `mootx01 drain` finisher may exit and release the encode
    /// DrainLease.
    ///
    /// Deliberately ignores every drain except "corpus_encode" — the T5
    /// finisher's CONTRACT is the encode queue and its DrainLease, nothing
    /// else (PERF_W1_DRAIN_RIDER_2026-07-28 Finding 3 established the gate).
    /// Since DISTILL_SEED_STALL routed the wing-seed hints through the encode
    /// stream, the "distillation" entry also settles under a normal drain
    /// (every enqueued drawer distills via the drain-stage rider before its
    /// job replies); the gate stays encode-only anyway so the finisher's
    /// lease tenure is bounded by its own queue, not by any other lane's
    /// accounting. Mirrors Swift `DrainStatus.encodeSettled`.
    pub fn encode_settled(statuses: &[DrainStatus]) -> bool {
        !statuses
            .iter()
            .any(|s| s.name == Self::CORPUS_ENCODE_NAME && s.is_draining())
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
            subject_producers: HashMap::new(),
            vector_stores: HashMap::new(),
            mount_states: HashMap::new(),
            audit_logs: HashMap::new(),
            matrix_tiers: HashMap::new(),
            graph_caches: HashMap::new(),
            preference_stores: HashMap::new(),
            node_topology_providers: HashMap::new(),
            node_stores: HashMap::new(),
            storages: HashMap::new(),
            migration_fault_token: None,
            sync_engines: HashMap::new(),
            dreaming_queues: RefCell::new(HashMap::new()),
            // Test seams start clear; only `inject_*` methods set them.
            #[cfg(any(test, feature = "test-seams"))]
            test_force_vector_hamming_error: std::cell::RefCell::new(None),
            #[cfg(any(test, feature = "test-seams"))]
            test_force_embed_error: std::cell::RefCell::new(None),
        }
    }

    /// Arm a transient encode-ingest failure injector on the estate's Corpus
    /// (test seam). Each source's FIRST ingest attempt fails once; the retry
    /// then succeeds — a transient fault that clears, exercising the at-least-
    /// once bounded-retry path now owned by CorpusKit. The encode pipeline was
    /// relocated into the Corpus, so this forwards to `Corpus::arm_ingest_
    /// failure_hook`. Mirrors the Swift test arming `corpus._armIngestFailureHook`.
    /// No-op when no Corpus is registered for the handle.
    #[cfg(any(test, feature = "test-seams"))]
    pub fn arm_transient_encode_ingest_failures(&self, handle: &EstateHandle) {
        use std::collections::HashSet;
        use std::sync::Mutex;
        if let Some(corpus) = self.corpus_for(handle) {
            let failed: Mutex<HashSet<String>> = Mutex::new(HashSet::new());
            corpus.arm_ingest_failure_hook(Some(Box::new(move |source_id: &str| {
                let mut set = failed.lock().expect("transient-failure set lock");
                // insert() returns true the FIRST time this source is seen.
                if set.insert(source_id.to_string()) {
                    Err(()) // simulate a transient fault on the first attempt
                } else {
                    Ok(())
                }
            })));
        }
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

    // ── Dreaming queue inspection seams (test-only) ──────────────────────────
    //
    // Integration tests verify that `recall_scored` with `External` origin
    // mounts and populates the dreaming queue. The queue itself is private
    // state managed by `ensure_dreaming_queue` and `enqueue_dreaming_item`;
    // these accessors expose only the observable properties tests need.
    // They follow the same `#[cfg(any(test, ...))]` pattern as the
    // `inject_*` seams above.

    /// Returns `true` if a dreaming queue has been mounted for `handle`.
    ///
    /// Tests use this to confirm that `recall_scored` with an `Internal` origin
    /// (or `recall_external`) does NOT mount the queue (B-10a guard).
    #[cfg(any(test, feature = "test-seams"))]
    pub fn dreaming_queue_is_mounted(&self, handle: &EstateHandle) -> bool {
        self.dreaming_queues.borrow().contains_key(handle)
    }

    /// Returns the number of jobs pending on the `"dreaming"` stream for
    /// `handle`, or `None` if the queue is not yet mounted.
    ///
    /// Tests use this to assert that exactly one dreaming job is enqueued per
    /// qualifying `recall_scored` call.
    #[cfg(any(test, feature = "test-seams"))]
    pub fn dreaming_queue_pending_count(&self, handle: &EstateHandle) -> Option<usize> {
        let map = self.dreaming_queues.borrow();
        let (queue, _) = map.get(handle)?;
        let stream = queuekit::StreamId("dreaming".to_string());
        queue.pending_count_for_stream(&stream).ok()
    }

    /// Production dreaming-queue pending-count probe.
    ///
    /// Returns the number of jobs pending on the `"dreaming"` stream for
    /// `handle`, or `None` if the queue is not yet mounted for this estate
    /// (no external-origin recall has fired yet).
    ///
    /// This is the cheap trigger used by the autonomic governor before
    /// building an `EstateDreamingReader` snapshot: `None` or `Some(0)` ⇒
    /// skip the dreaming cycle entirely — no reader, no scan, no drain.
    /// Only `Some(n)` where `n > 0` proceeds to the full cycle.
    ///
    /// Non-claiming: does NOT drain or acknowledge any jobs. The probe is a
    /// lightweight `borrow()` + `pending_count_for_stream` call — no lock
    /// contention beyond the RefCell borrow itself, and no queue-state change.
    ///
    /// Mirrors Swift `GeniusLocusKit.dreamingQueuePendingCount(for:)`.
    pub fn dreaming_queue_pending_count_for_gate(&self, handle: &EstateHandle) -> Option<usize> {
        let map = self.dreaming_queues.borrow();
        let (queue, _) = map.get(handle)?;
        let stream = queuekit::StreamId("dreaming".to_string());
        queue.pending_count_for_stream(&stream).ok()
    }

    /// Force-mount the dreaming queue for `handle` so that
    /// `dreaming_queue_pending_count_for_gate` returns a real count rather than
    /// `None` on a fresh open.
    ///
    /// The dreaming queue is normally lazy-mounted on the first external-origin
    /// recall event via `enqueue_dreaming_item`. This method mounts it eagerly so
    /// the `mootx01 dream` command can probe the persistent `queue.sqlite` backlog
    /// immediately after opening the estate — before any recall has fired in this
    /// session. Idempotent: a second call returns immediately when the queue is
    /// already mounted.
    ///
    /// On mount failure (e.g. `queue.sqlite` cannot be opened), falls back to a
    /// transient in-memory backend — the same degradation path as `enqueue_dreaming_item`.
    ///
    /// Mirrors Swift `GeniusLocusKit.mountDreamingQueue(for:)`.
    pub fn mount_dreaming_queue(&self, handle: &EstateHandle) {
        self.ensure_dreaming_queue(handle);
    }

    /// Reclaim stale in-flight ("cur") dreaming jobs after acquiring the dreaming
    /// DrainLease. Called by the `mootx01 dream` command immediately after a
    /// successful `try_acquire`.
    ///
    /// A successful `try_acquire` means the prior holder is dead (lease absent or
    /// stale > TTL = 15 s), so every "dreaming" cur row in `queue.sqlite` is an
    /// orphan from a crashed prior dreamer. This resets them to "new" so the
    /// REM-ALPHA cycle below re-processes them.
    ///
    /// Non-fatal: a reclaim failure is logged and does not abort the dreaming cycle.
    /// Idempotent: content-addressed ingest makes re-processing harmless.
    ///
    /// Mirrors Swift `GeniusLocusKit.reclaimStaleDreamingJobs(for:)`.
    pub fn reclaim_stale_dreaming_jobs(&self, handle: &EstateHandle) {
        let map = self.dreaming_queues.borrow();
        let (queue, _) = match map.get(handle) {
            Some(entry) => entry,
            None => return,
        };
        let stream = queuekit::StreamId("dreaming".to_string());
        match queue.reclaim_in_flight_for_stream(&stream) {
            Ok(n) if n > 0 => {
                eprintln!(
                    "mootx01 dream: reclaimed {} orphaned dreaming job(s) — prior dreamer died mid-cycle",
                    n
                );
            }
            Ok(_) => {}
            Err(e) => {
                eprintln!(
                    "mootx01 dream: reclaim_in_flight_for_stream failed: {:?}",
                    e
                );
            }
        }
    }

    /// Periodic GC sweep: reclaim stale in-flight jobs for streams whose drainer
    /// has died without the daemon restarting (mid-run worker death case).
    ///
    /// For each swept stream, creates a read-only probe `DrainLease` and checks
    /// `is_held_by_other(now)`. If false — no live holder — and cur rows exist for
    /// that stream, reset them to "new" so the next drain pass re-processes them.
    ///
    /// Covered streams:
    ///   - "dreaming": `mootx01 dream` is a separate process; a killed dream
    ///     process leaves its lease stale after TTL = 15 s.
    ///
    /// The "encode" stream is NOT swept here — the encode drainer is a background
    /// thread in the same resident process. When it dies, the process restarts
    /// entirely, triggering the on-mount reclaim in `run_ingest_drain_loop`.
    ///
    /// Only applies to SQLite estates — in-memory estates are single-process and
    /// never have stale cross-process leases.
    ///
    /// Non-fatal: sweep errors are logged and never propagate.
    ///
    /// Mirrors Swift `GeniusLocusKit.sweepStaleInFlightJobs(for:now:)`.
    pub fn sweep_stale_in_flight_jobs(&self, handle: &EstateHandle, now_epoch_secs: f64) {
        // Derive the estate directory for probe lease files. Only applicable to
        // SQLite-backed estates — in-memory estates need no cross-process GC.
        let storage = self.storages.get(handle);
        let sqlite_path = match storage.as_ref().map(|s| s.configuration().backend.clone()) {
            Some(BackendConfiguration::Sqlite { path, .. }) => path,
            _ => return,
        };
        let estate_dir = match Path::new(&sqlite_path).parent() {
            Some(d) => d.to_path_buf(),
            None => return,
        };

        // Stable probe owner: never heartbeats, so a deterministic name per estate
        // is fine. Using the estate UUID keeps it stable across ticks.
        let uuid_hex = handle.estate_uuid.iter().map(|b| format!("{b:02x}")).collect::<String>();
        let probe_owner = format!("gc-probe-{uuid_hex}");

        // ── "dreaming" stream ──────────────────────────────────────────────────
        // `mootx01 dream` is a separate process; a killed dream process leaves its
        // "dreaming" lease stale after TTL. Probe and reclaim if stale.
        {
            let map = self.dreaming_queues.borrow();
            if let Some((dream_queue, _)) = map.get(handle) {
                let dream_probe = DrainLease::new(&estate_dir, "dreaming", probe_owner.clone());
                if !dream_probe.is_held_by_other(now_epoch_secs) {
                    let stream = queuekit::StreamId("dreaming".to_string());
                    match dream_queue.reclaim_in_flight_for_stream(&stream) {
                        Ok(n) if n > 0 => {
                            eprintln!(
                                "AutonomicGovernor GC sweep: reclaimed {} orphaned dreaming job(s) — prior dreamer lease stale",
                                n
                            );
                        }
                        Ok(_) => {}
                        Err(e) => {
                            eprintln!(
                                "AutonomicGovernor GC sweep: dreaming reclaim failed: {:?}",
                                e
                            );
                        }
                    }
                }
            }
        }
    }

    /// Production dreaming-queue drain: returns one Vec of drawer IDs per
    /// drained `DreamingItem`, consuming the jobs (replies Done to each).
    ///
    /// Mirrors Swift `GeniusLocusKit.drainDreamingItems(for:)`. Called by the
    /// Rust `EstateDreamingReader.drain_dreaming_window` adapter (T8 v2).
    ///
    /// Returns an empty Vec when the queue is not mounted for `handle` (no
    /// recall has fired yet) or when there are no pending jobs. Corrupt
    /// payloads are silently skipped and replied Blocked — non-fatal.
    ///
    /// `now_epoch_secs` is the caller-injected drain timestamp (determinism
    /// rule — no SystemTime reads inside this method). Used for drain telemetry.
    pub fn drain_dreaming_items(
        &self,
        handle: &EstateHandle,
        now_epoch_secs: f64,
    ) -> Result<Vec<Vec<String>>, ()> {
        // If the queue is not mounted, there are no items to drain.
        let map = self.dreaming_queues.borrow();
        let (queue, _) = match map.get(handle) {
            Some(entry) => entry,
            None => return Ok(vec![]),
        };

        let stream = queuekit::StreamId("dreaming".to_string());
        let leases = match queue.drain_for_stream(&stream, now_epoch_secs) {
            Ok(l) => l,
            Err(_) => return Ok(vec![]),
        };

        if leases.is_empty() {
            return Ok(vec![]);
        }

        let mut windows: Vec<Vec<String>> = Vec::with_capacity(leases.len());
        for (job, _session_id) in &leases {
            match serde_json::from_slice::<DreamingItem>(&job.payload) {
                Ok(item) => windows.push(item.drawer_ids),
                Err(_) => {
                    // Corrupt payload: reply Blocked (does not disappear) and skip.
                    // Non-fatal: same error handling as the Swift drain path.
                    let _ = queue.reply(&job.id, queuekit::ObservationStatus::Blocked, vec![]);
                    continue;
                }
            }
            // Reply Done to consume the job — drain-once semantics.
            let _ = queue.reply(&job.id, queuekit::ObservationStatus::Done, vec![]);
        }

        Ok(windows)
    }

    /// Drains the `"dreaming"` stream for `handle` and returns the leases, or
    /// `None` if the queue is not mounted.
    ///
    /// Tests use this to inspect the `DreamingItem` payload that
    /// `enqueue_dreaming_item` serialised.
    #[cfg(any(test, feature = "test-seams"))]
    pub fn dreaming_queue_drain(
        &self,
        handle: &EstateHandle,
        now_epoch_secs: f64,
    ) -> Option<Vec<(queuekit::Job, queuekit::SessionId)>> {
        let map = self.dreaming_queues.borrow();
        let (queue, _) = map.get(handle)?;
        let stream = queuekit::StreamId("dreaming".to_string());
        queue.drain_for_stream(&stream, now_epoch_secs).ok()
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
        // Capture the underlying Storage before Estate::open moves the
        // DrawerStore Arc. Used below for auto-registering the substrate
        // topology provider (node-tree integrity, NT-G1).
        let topology_storage = store.storage();
        let estate =
            Estate::open(store, owner).map_err(|e| GeniusLocusKitError::EstateOpenFailed {
                detail: format!("{e:?}"),
            })?;
        let estate_uuid: EstateUuid = estate.estate_uuid().into_bytes();
        let handle = EstateHandle::new(estate_uuid, zoom_window_low, zoom_window_high)?;
        // Duplicate detection is keyed by estate UUID ALONE, not the full
        // handle. The handle's Eq/Hash include the caller-supplied zoom window,
        // so `contains_key(&handle)` would let the same backing estate be opened
        // a second time under a different window — two registry entries for one
        // UUID, each overlapping a different lattice region in fan-out. Estate
        // UUIDs are immutable (spec §7.7), so any repeat UUID is the same store.
        if self.registry.keys().any(|h| h.estate_uuid == estate_uuid) {
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
        // Auto-register substrate-native topology provider (node-tree integrity,
        // NT-G1). Wraps the estate's NodeStore so NodeTreeNative recall
        // works without a host-supplied provider.
        if let Some(storage) = topology_storage {
            // Retain the Storage arc for the explicit transaction boundary
            // (GLK_BATCH1 `capture_batch`). Stored alongside the topology
            // provider so both can share the same Arc without a second clone.
            self.storages.insert(handle, Arc::clone(&storage));
            let ns = Arc::new(locus_kit::node_store::NodeStore::new(storage, None));
            self.node_stores.insert(handle, Arc::clone(&ns));
            let adapter = Arc::new(
                crate::substrate_node_topology_provider::SubstrateNodeTopologyProvider::new(ns),
            );
            self.node_topology_providers.insert(handle, adapter);
        }
        // Mint an empty unified audit log for the estate (GLK-03 parity). The
        // log starts empty so a verify pass before any feed reports a clean,
        // zero-entry chain. Nothing populates this registry entry on demand
        // any more — `current_audit_log`
        // / `verify_audit_chain` build a fresh transient log per call instead
        // (see the `audit_logs` field doc). Only `set_audit_log` (the
        // hydrate-on-launch path) ever overwrites this entry. Mirrors Swift
        // `auditLogs[handle] = UnifiedAuditLog()`.
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
    /// subsequent `estate_for` lookups return `EstateNotOpen`.
    ///
    /// Drops EVERY per-estate registry entry for the handle, not a subset:
    /// handles are stable across reopens, so anything left behind resolves on
    /// the next open of the same estate as state the caller never registered.
    /// `tests/estate_close_completeness.rs` enforces that this stays complete
    /// as registries are added.
    pub fn close(&mut self, handle: &EstateHandle) -> Result<(), GeniusLocusKitError> {
        if self.registry.remove(handle).is_none() {
            return Err(GeniusLocusKitError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            });
        }
        self.grant_stores.remove(handle);
        self.scope_vaults.remove(handle);
        // CorpusKit owns the encode pipeline: cancel the Corpus's ingest drain
        // worker and drop its queue BEFORE releasing the corpus registration, so
        // no orphan worker outlives the estate. (Was a GLK-side encode_queues
        // entry; relocated into the Corpus — see corpus_kit::corpus_ingest_queue.)
        if let Some(corpus) = self.corpus_kits.get(handle) {
            corpus.drop_ingest_queue();
        }
        self.corpus_kits.remove(handle);
        self.vector_stores.remove(handle);
        // Drop the subject-backfill rider (PR-09). A producer is registered
        // against a handle, and handles are stable across reopens of the same
        // estate (`handle.rs` — `estate_uuid` comes from the manifest, so
        // reopening yields an EQUAL handle). Leaving the entry here would let a
        // reopened estate resolve to a producer that was never re-registered:
        // `drain_statuses` would render the `subject_backfill` lane as live and
        // `subject_backfill_sweep` — which authorises on map presence alone —
        // would hand full drawer content to it. Dropping the entry returns the
        // lane to its dark default, which is what a freshly-opened estate must
        // see.
        self.subject_producers.remove(handle);
        // Drop the audit log and matrix tier with the estate — a closed handle
        // must not resolve to a live log or a stale recall tier (GLK-03 parity).
        self.audit_logs.remove(handle);
        self.matrix_tiers.remove(handle);
        // Drop the graph cache and preference store with the estate — a closed
        // handle must not resolve to a stale recall accelerator. Both are pure
        // score lookups registered by the caller (`register_graph_cache` /
        // `register_preference_store`); nothing re-mints them lazily, so a
        // reopened estate correctly scores their columns at 0.0 until the
        // caller registers again.
        self.graph_caches.remove(handle);
        self.preference_stores.remove(handle);
        // Drop the node topology provider (w5-nodetree-native). A closed handle
        // must not resolve to a stale provider; parity of Swift `close` which
        // drops `nodeTopologyProviders[handle]`.
        self.node_topology_providers.remove(handle);
        // Drop the node store (node-tree integrity name resolution). Mirrors the
        // topology provider cleanup above.
        self.node_stores.remove(handle);
        // Drop the retained Storage arc (GLK_BATCH1 `capture_batch`). Mirrors
        // Swift `close` which drops `storages[handle]`.
        self.storages.remove(handle);
        // Drop the sync engine so no engine reference outlives the estate.
        // Parity of Swift `close` which drops `syncEngines[handle]`.
        self.sync_engines.remove(handle);
        // Drop the dreaming queue + HLC. No drain worker to
        // cancel — T6 is enqueue-only; the lease is a T9 drainer concern.
        // Mirrors Swift `close` which nils `dreamingQueues[handle]` and
        // `dreamingHLCs[handle]`.
        self.dreaming_queues.borrow_mut().remove(handle);
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
        // Default in-memory grant store; hydration replaces this with a GrantStore
        // backed by the hydrated storage so replicated authorization rows are live.
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

    /// Replace the grant store for an already-registered estate.
    ///
    /// Hydration uses this to bind authorization checks to the hydrated
    /// backing storage that now contains replicated grant rows.
    pub(crate) fn set_grant_store(&mut self, handle: EstateHandle, grant_store: GrantStore) {
        self.grant_stores.insert(handle, grant_store);
    }

    /// Wire a `Corpus` into the scored-recall BM25 lane for `handle`.
    ///
    /// Activates the BM25 recall lane in `recall_scored` for Hybrid,
    /// CorpusOnly, and UnionBest modes. Replaces any previously registered
    /// corpus for this handle (idempotent). Mirrors Swift
    /// `GeniusLocusKit.registerCorpus(_:for:)`.
    pub fn register_corpus(&mut self, handle: &EstateHandle, corpus: Arc<CorpusContentEngine>) {
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
    /// captured drawer into the estate's BM25/vector lanes, and (cross-crate,
    /// hence `pub`) by the autonomic governor to pass the corpus into
    /// `default_standing_signal_specs` so the vector-similarity signal can
    /// mine the chunk-keyed corpus lane — the vector-row population
    /// production estates actually hold. Mirrors the Swift actor's
    /// `corpusKits[handle]` lookup.
    pub fn corpus_for(&self, handle: &EstateHandle) -> Option<Arc<CorpusContentEngine>> {
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
    /// `registeredVectorStore(for:)` accessor (which is `public`).
    ///
    /// Two consumers, both cross-checked against Swift:
    ///   - the expunge orchestration path invalidates the standalone store's
    ///     resident slot after `Corpus::remove` deletes from the shared backing
    ///     table (in-crate);
    ///   - the AriaMcpKit autonomic governor reads the live store to build the
    ///     default standing-signal specs at registration time (cross-crate),
    ///     mirroring the Swift resident's `kit.registeredVectorStore(for:)`
    ///     bootstrap step. The latter is why this accessor is `pub`.
    pub fn vector_store_for(&self, handle: &EstateHandle) -> Option<Arc<VectorStore>> {
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

    /// Narrow host seams for separately compiled historical migrations.
    #[doc(hidden)]
    pub fn migration_storage(&self, handle: &EstateHandle) -> Option<Arc<dyn Storage>> {
        self.storages.get(handle).map(Arc::clone)
    }

    #[doc(hidden)]
    pub fn migration_registered_corpus(
        &self,
        handle: &EstateHandle,
    ) -> Option<Arc<CorpusContentEngine>> {
        self.corpus_kits.get(handle).map(Arc::clone)
    }

    #[doc(hidden)]
    pub fn migration_fault_token(&self) -> Option<&str> {
        self.migration_fault_token.as_deref()
    }

    #[doc(hidden)]
    pub fn set_migration_fault_token(&mut self, token: Option<String>) {
        self.migration_fault_token = token;
    }

    /// Status of every long-running drain the estate addressed by `handle`
    /// currently runs, for AI/operator monitoring (the `moot_drain_status`
    /// tool and the `mootx01 query drain_status` CLI surface).
    ///
    /// Today the only drain is the corpus encode/ingest drain: it reports the
    /// queue depth (pending + in-flight encode jobs) and, as detail, the live
    /// encoded-chunk count so forward progress is visible while the queue
    /// drains. A bare estate with no Corpus registered runs no encode drain,
    /// so its list is empty.
    ///
    /// Read-only: assembles the report by OBSERVING each drain's frontiers; it
    /// never claims, drains, or mutates, so it is safe to poll while drains run.
    /// Returns `Err(EstateNotOpen)` if the handle is stale. Mirrors Swift
    /// `GeniusLocusKit.drainStatuses(_:)`.
    pub fn drain_statuses(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<DrainStatus>, GeniusLocusKitError> {
        // Validate the handle up front so a stale handle surfaces EstateNotOpen
        // rather than silently returning an empty list — an empty list means
        // "this estate runs no drains", which must not be confused with a dead
        // handle.
        self.estate_for(handle)?;

        let mut statuses: Vec<DrainStatus> = Vec::new();

        // Drain 1 of N: the corpus encode/ingest drain. Present only when a
        // Corpus is registered for this estate (a provisioned/wired estate).
        // Future drains append their own entries below this one.
        if let Some(corpus) = self.corpus_kits.get(handle) {
            let (pending, in_flight) = corpus.ingest_queue_depth().map_err(|e| {
                GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!("corpus ingest depth: {e:?}"),
                }
            })?;
            let encoded_chunks = corpus.count().map_err(|e| {
                GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!("corpus chunk count: {e:?}"),
                }
            })?;
            statuses.push(DrainStatus {
                name: DrainStatus::CORPUS_ENCODE_NAME.to_string(),
                pending,
                in_flight,
                detail: Some(format!("encoded_chunks: {encoded_chunks}")),
            });
        }

        // Drain 2 of N: distillation accounting (SPEC_DISTILLATION_STORAGE
        // §7.1). Present on every estate — distillation is a row-level
        // obligation, not a corpus feature. `pending` is the §7.1
        // eligibility-predicate count measured off the rows themselves
        // (stronger than a queue-depth proxy; also covers lazy
        // regeneration after a pipeline-version bump). "Fully drained"
        // therefore cannot read true while any row still owes a
        // representation (FINDING_11X_MAINTENANCE_WALK constraint 6).
        // Mirrors the Swift drainStatuses entry.
        let estate = self.estate_for(handle)?;
        let undistilled = estate
            .count_undistilled(substrate_ml::token_compaction::DISTILLATION_PIPELINE_VERSION)
            .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("count_undistilled: {e:?}"),
            })?;
        statuses.push(DrainStatus {
            name: "distillation".to_string(),
            pending: undistilled,
            in_flight: 0,
            detail: Some(format!(
                "pipeline: {}",
                substrate_ml::token_compaction::DISTILLATION_PIPELINE_VERSION
            )),
        });

        // Drain 3 of N: subject backfill (PR-09). Rendered ONLY while a
        // subject producer is registered (rider-gated). `pending` is the
        // NULL-only presence debt (`count_subject_debt`), a row-level
        // eligibility count like the distillation lane's; `in_flight` is
        // 0 — sweeps are synchronous bounded batches, never a queue.
        // Mirrors the Swift drainStatuses entry.
        if let Some(producer) = self.subject_producers.get(handle) {
            let debt = estate
                .count_subject_debt_including(&producer.regenerates_pipelines())
                .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!("count_subject_debt: {e:?}"),
                })?;
            statuses.push(DrainStatus {
                name: DrainStatus::SUBJECT_BACKFILL_NAME.to_string(),
                pending: debt,
                in_flight: 0,
                detail: Some(format!("pipeline: {}", producer.pipeline_version())),
            });
        }

        Ok(statuses)
    }

    /// Register (or replace) the subject producer for `handle` (PR-09).
    /// The subject_backfill drain lane renders from the next
    /// `drain_statuses` call on; `subject_backfill_sweep` becomes
    /// runnable. DARK-LANE default: nothing calls this in production
    /// Rust until a model exists; tests inject stubs. Mirrors Swift
    /// `registerSubjectProducer`.
    pub fn register_subject_producer(
        &mut self,
        handle: &EstateHandle,
        producer: Arc<dyn SubjectProducer>,
    ) -> Result<(), GeniusLocusKitError> {
        self.estate_for(handle)?;
        self.subject_producers.insert(handle.clone(), producer);
        Ok(())
    }

    /// The registered producer's pipeline version, or None while the
    /// lane is dark. Mirrors Swift `subjectProducerPipeline(for:)`.
    pub fn subject_producer_pipeline(&self, handle: &EstateHandle) -> Option<String> {
        self.subject_producers
            .get(handle)
            .map(|p| p.pipeline_version().to_string())
    }

    /// Run ONE bounded subject-backfill sweep (PR-09): enumerate up to
    /// `batch_limit` subject-debt rows (deterministic filedAt-then-id
    /// order), produce + validate + write each, and report. Settled-work
    /// skip is structural — written rows leave the debt predicate, so
    /// reruns never revisit them. Refuses while the lane is dark (no
    /// producer): the interactive consent-gated backfill is the only
    /// subject path until a rider exists. Mirrors Swift
    /// `subjectBackfillSweep`.
    pub fn subject_backfill_sweep(
        &self,
        handle: &EstateHandle,
        batch_limit: usize,
        now: i64,
    ) -> Result<SubjectBackfillReport, GeniusLocusKitError> {
        let Some(producer) = self.subject_producers.get(handle) else {
            return Err(GeniusLocusKitError::UnderlyingEstateFailure {
                reason: "subject_backfill_sweep: no subject producer registered — \
                         the rider lane is dark until a model registers; use the \
                         interactive backfill (missing_subject → setSubject)"
                    .to_string(),
            });
        };
        let estate = self.estate_for(handle)?;
        let batch = estate
            .subject_debt_batch_including(batch_limit, &producer.regenerates_pipelines())
            .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("subject_debt_batch: {e:?}"),
            })?;
        let mut written = 0usize;
        let mut skipped = 0usize;
        for drawer in &batch {
            let candidate = producer.subject_for_content(&drawer.content).map_err(|e| {
                GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!("subject producer: {e}"),
                }
            })?;
            if !locus_kit::subject_register::violations(&candidate).is_empty() {
                // Inadmissible output is skipped, never stored — the row
                // stays debt and re-enumerates next sweep.
                skipped += 1;
                continue;
            }
            estate
                .set_subject_representation(
                    &drawer.id,
                    &candidate,
                    producer.pipeline_version(),
                    now,
                )
                .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!("set_subject_representation: {e:?}"),
                })?;
            written += 1;
        }
        let remaining = estate
            .count_subject_debt_including(&producer.regenerates_pipelines())
            .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("count_subject_debt: {e:?}"),
            })?;
        Ok(SubjectBackfillReport {
            written,
            skipped_inadmissible: skipped,
            remaining_debt: remaining,
        })
    }

    /// Set the encode SPEED (drain QoS) for the estate's corpus drain, mapping
    /// the `mode` arg of an import (`foreground` / `background`) onto the Corpus's
    /// encode speed. No-op when no Corpus is registered (a bare estate has no
    /// encode drain). Affects embed fan-outs sized after this call. Mirrors Swift
    /// `GeniusLocusKit.setEncodeSpeed(_:for:)`.
    pub fn set_encode_speed(&self, handle: &EstateHandle, speed: EncodeSpeed) {
        if let Some(corpus) = self.corpus_kits.get(handle) {
            corpus.set_encode_speed(speed);
        }
    }

    // Internal: resolve to an estate, mapping the not-open case into the
    // verb-dispatch error domain (parity of `estate(for:)` propagating
    // `estateNotOpen` out of a verb).
    //
    // Quiesce gate (secfix-glk-aria): quiesced and draining estates reject all
    // verb calls so the admin-plane quiesce→drain→close sequence is enforced at
    // the substrate boundary. VerbDispatchError::EstateQuiesced is the fail-closed
    // response. This mirrors the Swift requireMounted(_:verb:) gate in VerbSurface.swift.
    //
    // A handle absent from mount_states (estate opened before this gate, or a
    // handle that slipped through) is treated as Mounted so existing callers are
    // not broken by a missing-map entry. The not-open check runs after the quiesce
    // gate so a quiesced estate produces EstateQuiesced, not EstateNotOpen.
    fn estate_for_verb(&self, handle: &EstateHandle) -> Result<&Estate, VerbDispatchError> {
        match self.mount_states.get(handle) {
            Some(EstateMountState::Quiesced) | Some(EstateMountState::Draining) => {
                return Err(VerbDispatchError::EstateQuiesced {
                    estate_uuid: handle.estate_uuid,
                });
            }
            Some(EstateMountState::Mounted)
            | Some(EstateMountState::Unmounted)
            | None => {
                // Mounted is the expected fast path.
                // Unmounted and None: let the registry check below surface
                // EstateNotOpen if the handle is truly stale.
            }
        }
        self.registry
            .get(handle)
            .ok_or(VerbDispatchError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            })
    }

    // MARK: - Merkle composition

    /// Create a snapshot with composed Merkle attestations from both
    /// LocusKit and CorpusKit (content-hash
    /// integrity). All attestations land in one atomic snapshot row.
    ///
    /// When no Corpus is registered for the handle, falls back to
    /// LocusKit-only attestations.
    pub fn create_composed_snapshot(
        &self,
        handle: &EstateHandle,
        label: Option<&str>,
        now: i64,
    ) -> Result<locus_kit::merkle_rollup::SnapshotRecord, GeniusLocusKitError> {
        let estate = self.estate_for(handle)?;
        let mut corpus_attestations: Vec<locus_kit::merkle_rollup::SnapshotAttestation> = Vec::new();

        if let Some(corpus) = self.corpus_kits.get(handle) {
            // Per-corpus attestations: one per source document.
            // Propagate errors rather than silencing them — a snapshot that
            // silently omits corpus attestations on a CorpusKit read failure
            // misrepresents the estate's integrity state (secfix/ws2-coredelete
            // §Cluster E, "fail-open on CorpusKit errors" finding).
            // Shared-content 1.1: canonical-content integrity is the LocusKit
            // Drawer content root — CorpusKit builds NO second content Merkle
            // hierarchy. The engine attests derived-index COVERAGE instead:
            // per content ID, the canonical (revision, digest) its derived
            // rows reflect. Mirrors Swift MerkleComposition.
            let mut coverage = corpus
                .index_coverage_attestations()
                .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!(
                        "create_composed_snapshot: index_coverage_attestations failed: {:?}",
                        e
                    ),
                })?;
            coverage.sort_by(|a, b| a.0.cmp(&b.0));
            for (content_id, _revision, digest) in &coverage {
                corpus_attestations.push(locus_kit::merkle_rollup::SnapshotAttestation {
                    snapshot_id: locus_kit::merkle_rollup::SnapshotId::new(""),
                    subject_kind: "corpus_index".to_string(),
                    subject_id: content_id.clone(),
                    merkle_root: digest.clone(),
                    key_version: None,
                });
            }
            // Global coverage attestation: one digest over the sorted rows.
            let folded = coverage
                .iter()
                .map(|(id, revision, digest)| format!("{id}:{revision}:{digest}"))
                .collect::<Vec<_>>()
                .join("\n");
            corpus_attestations.push(locus_kit::merkle_rollup::SnapshotAttestation {
                snapshot_id: locus_kit::merkle_rollup::SnapshotId::new(""),
                subject_kind: "corpus_index_global".to_string(),
                subject_id: Uuid::from_bytes(handle.estate_uuid).to_string(),
                merkle_root: corpus_kit::content_digest(&folded),
                key_version: None,
            });
        }

        estate
            .create_snapshot(label, now, &corpus_attestations)
            .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure { reason: e.to_string() })
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

    // MARK: - capture_batch

    /// Bulk-capture `frames` into the estate in a single SQLite transaction.
    ///
    /// All frames are FDC-classified upfront (same one-door classification as
    /// `capture_with_mode`). A single `BEGIN IMMEDIATE` wraps all inserts;
    /// on success the transaction commits and all drawers are returned. On any
    /// failure the transaction is rolled back and the error propagates — no
    /// partial import is left in the database.
    ///
    /// The encode queue is intentionally skipped: bulk import paths (`moot_palace_import`,
    /// `moot_vault_import`) follow batch capture with `moot_reindex` + `moot_dream`,
    /// which hydrate the BM25 and vector lanes in bulk. Enqueueing N encode jobs
    /// during import would merely duplicate that work.
    ///
    /// An empty `frames` slice is a no-op that returns an empty Vec without
    /// touching the database.
    ///
    /// Mirrors Swift `GeniusLocusKit.captureBatch(_:_:)` in `EncodeIntake.swift`.
    pub fn capture_batch(
        &mut self,
        handle: &EstateHandle,
        frames: Vec<CaptureFrame>,
        now: i64,
    ) -> Result<Vec<Drawer>, VerbDispatchError> {
        if frames.is_empty() {
            return Ok(Vec::new());
        }
        // Validate the handle before touching the transaction.
        let storage = self.storages.get(handle).cloned().ok_or_else(|| {
            VerbDispatchError::EstateNotOpen {
                estate_uuid: handle.estate_uuid,
            }
        })?;
        // Batch capture must preserve the same lattice anchoring guarantee as
        // the normal capture path: classifiable sentinel frames are anchored
        // before storage so latticeSubtree grants never authorize them under
        // the wrong UDC scope. Explicit non-sentinel anchors are preserved.

        // Parallel FDC classify — Pattern B (encode-perf #31, Phase 1).
        //
        // 49k-drawer palace import pegged one core for many minutes because this
        // classify loop was purely serial and string/hashmap bound. Fan it across
        // cap workers: each frame is independent, and
        // Fdc::encode_anchor_no_record is a pure read over the immutable pinned
        // codebook — concurrent calls are safe (OnceLock + RwLock<Arc<…>>).
        //
        // secfix/fdc-pool: use encode_anchor_no_record (not encode_anchor) so novel
        // tokens from batch import content are NOT accumulated into
        // SHARED_NOVEL_CACHE and do NOT flush to plaintext pool files — same
        // guarantee as capture_with_mode in intake.rs. Result is byte-identical.
        //
        // Results gathered by index, giving byte-identical output to the serial
        // version. Serial fast-path for small batches avoids thread spawn overhead.
        // Shape mirrors CorpusKit's embed_concurrency_cap + thread::scope fan-out.

        // Nested classify helper — pure over the pinned codebook, no capture needed.
        // Uses encode_anchor_no_record (secfix/fdc-pool).
        fn classify_one_frame_for_batch(frame: CaptureFrame) -> CaptureFrame {
            if frame.lattice_anchor.udc_code == crate::intake::UNCLASSIFIED_SENTINEL
                && !frame.content.is_empty()
            {
                // encode_anchor_no_record: batch import content must not leak novel
                // tokens into the plaintext pool pipeline (secfix/fdc-pool, same
                // rationale as capture_with_mode in intake.rs). Result is
                // byte-identical to encode_anchor.
                let content_kind = if frame.kind == ContentKind::Code {
                    lattice_lib::FdcContentKind::Code
                } else {
                    lattice_lib::FdcContentKind::Text
                };
                let (code_opt, qid_opt) = lattice_lib::Fdc::encode_anchor_for_content_no_record(
                    &frame.content, content_kind);
                match code_opt {
                    Some(code) if !code.is_empty() => {
                        let mut f = frame;
                        f.lattice_anchor = LatticeAnchor {
                            udc_code: code,
                            udc_facets: f.lattice_anchor.udc_facets.clone(),
                            wikidata_qid: qid_opt,
                            wikidata_qids_secondary: f.lattice_anchor.wikidata_qids_secondary.clone(),
                        };
                        f
                    }
                    _ => frame,
                }
            } else {
                frame
            }
        }

        let cap = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1);

        let classified: Vec<CaptureFrame> = if frames.len() <= cap {
            // Serial fast-path: avoid thread spawn overhead for small batches.
            frames.into_iter().map(classify_one_frame_for_batch).collect()
        } else {
            // Fan-out across cap workers, chunked. Chunk size == cap keeps exactly
            // cap threads in flight per barrier — same shape as CorpusKit's Rust
            // embed fan-out. thread::scope borrows from the current stack; no Arc.
            // Results gathered by index for byte-identical output order.
            let mut frames_opt: Vec<Option<CaptureFrame>> =
                frames.into_iter().map(Some).collect();
            let n = frames_opt.len();
            let mut results: Vec<Option<CaptureFrame>> = (0..n).map(|_| None).collect();
            let mut start = 0;
            while start < n {
                let end = (start + cap).min(n);
                std::thread::scope(|s| {
                    let mut handles: Vec<(usize, std::thread::ScopedJoinHandle<'_, CaptureFrame>)> =
                        Vec::with_capacity(end - start);
                    for i in start..end {
                        let frame = frames_opt[i]
                            .take()
                            .expect("each frame taken exactly once");
                        handles.push((i, s.spawn(move || classify_one_frame_for_batch(frame))));
                    }
                    for (i, handle) in handles {
                        results[i] =
                            Some(handle.join().expect("FDC classify thread panicked"));
                    }
                });
                start = end;
            }
            results.into_iter().map(|r| r.unwrap()).collect()
        };

        // Quiesce check BEFORE opening the transaction. `estate_for_verb`
        // returns `EstateQuiesced` when the mount state is Quiesced or
        // Draining. Placing this check after `begin_transaction` would hold
        // the WAL write lock open indefinitely when the estate is quiesced,
        // blocking all subsequent writes (planned security hardening — B1).
        let estate = self.estate_for_verb(handle)?;
        let row_store = storage.row_store();
        row_store.begin_transaction()
            .map_err(|e| VerbDispatchError::Verb(VerbError::UnderlyingEstateFailure {
                verb: "captureBatch".to_string(),
                reason: format!("begin_transaction: {e:?}"),
            }))?;
        // Delegate to estate-level capture_batch which omits per-drawer
        // rollup_merkle_roots (NT_R1 deferral). Single-item self.capture()
        // would fire rollup on every frame — O(N²) on 37K drawers.
        let result = estate.capture_batch(classified, now);
        match result {
            Ok(drawers) => {
                row_store.commit_transaction()
                    .map_err(|e| VerbDispatchError::Verb(VerbError::UnderlyingEstateFailure {
                        verb: "captureBatch".to_string(),
                        reason: format!("commit_transaction: {e:?}"),
                    }))?;
                Ok(drawers)
            }
            Err(e) => {
                let _ = row_store.rollback_transaction();
                Err(VerbDispatchError::Verb(VerbError::UnderlyingEstateFailure {
                    verb: "captureBatch".to_string(),
                    reason: format!("{e:?}"),
                }))
            }
        }
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
    ///
    /// Frame-size cap: mirrors Swift `VerbSurface.recall(_:_:)` which passes
    /// `GLKRecallRequest(limit: frame.limit ?? 50)` through the RecallDirector.
    /// When no explicit limit is set, results are capped at 50, matching the
    /// Swift default so all lens and recipe outputs compare cross-port. Callers
    /// that need the full estate (e.g. VaultBridge) must set an explicit
    /// `frame.limit` before calling.
    pub fn recall(
        &self,
        handle: &EstateHandle,
        frame: RecallFrame,
        now: i64,
    ) -> Result<Vec<Drawer>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        // trace_limit intentionally None — internal caller, no trace rows (B-10a).
        // Cap mirrors Swift VerbSurface.recall (frame.limit ?? 50).
        let cap = frame.limit.unwrap_or(50);
        let all = estate.recall(frame, now).collect_all();
        Ok(all.into_iter().take(cap).collect())
    }

    /// External-facing recall used by the ARIA boundary: sets `trace_limit`
    /// on the frame so the reward cycle records the surfaced rows.
    ///
    /// Only call this from the ARIA_MCP boundary. All internal callers
    /// (dreaming, lenses, recipes, migration) must use `recall` above (B-10a).
    ///
    /// Unlike `recall`, this variant does NOT apply the default-50 cap —
    /// external callers receive exactly what `frame.limit` requests (or the
    /// engine's `RECALL_CANDIDATE_CAP` ceiling when no limit is set). The
    /// caller-facing limit is the explicit `frame.limit` from the MCP
    /// request, not a cross-port analytics default.
    ///
    /// Note: dreaming-item enqueue is NOT performed here. The dreaming enqueue
    /// lives in `recall_scored` (guarded by `request.origin == RecallOrigin::External`)
    /// — the production ARIA boundary uses `recall_scored` for all three external
    /// recall tools (moot_memory_search, moot_recall_precise, moot_recall_shaped).
    /// This method provides the trace-limit wiring for the legacy flat-array
    /// surface; it is not the dreaming enqueue site (recall-driven dreaming, B-10a).
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

    /// Frame-aware by-id drawer hydration.
    ///
    /// Loads only the drawers identified by `ids`, then applies the frame's
    /// filter chain through `BitmapEvaluator::evaluate`. `insert_defaults`
    /// prepends `SensitivityAtMost(Elevated)`, `Trustworthy`, and
    /// `CurrentlyBelieve` when the caller passes an empty chain — the same
    /// defaults the full estate `recall` path enforces.
    ///
    /// Returns only the admissible subset: drawers that passed every filter.
    /// Drawers absent from the estate (or rejected by the filter) are silently
    /// omitted — callers gate on `admissible.is_empty()` or a `find` over the
    /// result.
    ///
    /// Parity peer of Swift `RecallDirector.hydrate(_:ids:matchingFrame:)`.
    /// Unlike `recall`, which scans the full estate and applies a page limit,
    /// this method is inherently bounded to the `ids` slice — no `limit` field
    /// is required and no `now` clock token is needed (`BitmapEvaluator`
    /// derives any `as_of` reconstruction from the frame's optional HLC field,
    /// not a separate clock parameter).
    ///
    /// Internal callers only (B-10a). No recall-trace rows are written.
    pub fn get_drawers_matching_frame(
        &self,
        handle: &EstateHandle,
        ids: &[String],
        frame: &RecallFrame,
    ) -> Result<Vec<Drawer>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        let result = estate
            .get_drawers_matching_frame(ids, frame)
            .map_err(|e| {
                VerbDispatchError::Verb(remap(
                    "get_drawers_matching_frame",
                    &uuid_to_str(&handle.estate_uuid),
                    e,
                ))
            })?;
        Ok(result.admissible)
    }

    // MARK: - dreaming queue

    /// Lazy-mount the per-estate dreaming queue and its HLC generator.
    ///
    /// Called by `enqueue_dreaming_item` on the first external-origin scored recall
    /// (`recall_scored` with `request.origin == RecallOrigin::External`) for an estate.
    /// Subsequent calls are no-ops when the entry is already present in the map.
    ///
    /// Takes `&self` via `RefCell` interior mutability so callers from `recall_scored`
    /// (which is `&self` and has many callers) do not need to become `&mut self`.
    ///
    /// Backend selection mirrors `build_signals_queue` in NeuronKit:
    ///   - SQLite estate → `queue_sibling("queue.sqlite")` → `SqliteStorage` →
    ///     `PersistenceKitBackend`. Same encrypted sibling the encode and signals
    ///     streams already share (one queue, three streams — recall-driven dreaming).
    ///   - InMemory / absent → transient `InMemoryStorage`-backed backend.
    ///     No `DrainLease` is acquired — T6 is enqueue-only; the lease is a T9
    ///     drainer concern.
    ///
    /// HLC nodeID derivation (byte-identical to Swift `ensureDreamingQueue` and
    /// `ensureScheduler`): first four estate UUID bytes big-endian → u32 → i32
    /// bit-cast. Each estate produces a distinguishable HLC family.
    ///
    /// On SQLite open failure: falls back to a transient in-memory backend and
    /// logs to stderr. The dreaming lane degrades silently; recall is unaffected.
    fn ensure_dreaming_queue(&self, handle: &EstateHandle) {
        // Fast path: entry already present — skip all construction work.
        if self.dreaming_queues.borrow().contains_key(handle) {
            return;
        }

        // Derive HLC nodeID from the estate UUID (byte-identical to Swift formula and
        // NeuronKit's build_signals_queue). `estate_uuid` is `[u8; 16]` so indexing
        // directly gives the raw UUID bytes in memory order.
        let uuid_bytes = handle.estate_uuid;
        let node_id_u32 = u32::from_be_bytes([
            uuid_bytes[0], uuid_bytes[1], uuid_bytes[2], uuid_bytes[3],
        ]);
        let node_id = node_id_u32 as i32;
        let hlc = substrate_types::hlc::HLCGenerator::new(node_id);

        let storage = self.storages.get(handle);
        let backend_config = storage.as_ref().map(|s| s.configuration().backend.clone());

        let queue: queuekit::QueueKit<Box<dyn queuekit::QueueBackend>> =
            match backend_config {
                Some(BackendConfiguration::Sqlite { .. }) => {
                    // Persistent estate: open the shared queue.sqlite sibling
                    // (same file encode and signals use). Encrypted at rest.
                    let sibling_result = storage
                        .as_ref()
                        .expect("storage is Some when backend is Sqlite")
                        .configuration()
                        .queue_sibling("queue.sqlite");
                    let sibling_cfg = match sibling_result {
                        Ok(cfg) => cfg,
                        Err(e) => {
                            eprintln!(
                                "DreamingQueue: queue_sibling failed for estate {:?}: {:?}. \
                                 Degrading dreaming lane to transient backend.",
                                handle.estate_uuid, e
                            );
                            let (q, _) = Self::build_inmemory_dreaming_queue(handle);
                            self.dreaming_queues.borrow_mut().insert(handle.clone(), (q, hlc));
                            return;
                        }
                    };
                    let qs = match SqliteStorage::new(sibling_cfg) {
                        Ok(qs) => Arc::new(qs),
                        Err(e) => {
                            eprintln!(
                                "DreamingQueue: SqliteStorage::new failed (estate {:?}): {:?}. \
                                 Degrading to transient backend.",
                                handle.estate_uuid, e
                            );
                            let (q, _) = Self::build_inmemory_dreaming_queue(handle);
                            self.dreaming_queues.borrow_mut().insert(handle.clone(), (q, hlc));
                            return;
                        }
                    };
                    if let Err(e) = PersistenceKitBackend::open_schema(qs.as_ref()) {
                        eprintln!(
                            "DreamingQueue: open_schema failed (estate {:?}): {:?}. \
                             Degrading to transient backend.",
                            handle.estate_uuid, e
                        );
                        let (q, _) = Self::build_inmemory_dreaming_queue(handle);
                        self.dreaming_queues.borrow_mut().insert(handle.clone(), (q, hlc));
                        return;
                    }
                    let backend = PersistenceKitBackend::new(qs);
                    queuekit::QueueKit::new(Box::new(backend) as Box<dyn queuekit::QueueBackend>)
                }
                _ => {
                    // InMemory estate, Postgres estate (deferred per recall-driven dreaming), or no
                    // storage: all get a transient in-memory backend. No crash recovery
                    // needed for ephemeral estates.
                    let (q, _) = Self::build_inmemory_dreaming_queue(handle);
                    self.dreaming_queues.borrow_mut().insert(handle.clone(), (q, hlc));
                    return;
                }
            };
        self.dreaming_queues.borrow_mut().insert(handle.clone(), (queue, hlc));
    }

    /// Build a transient in-memory dreaming queue. Used for in-memory estates
    /// and as the degraded fallback when SQLite open fails.
    fn build_inmemory_dreaming_queue(
        handle: &EstateHandle,
    ) -> (queuekit::QueueKit<Box<dyn queuekit::QueueBackend>>, ()) {
        // Use the estate UUID as the InMemory store ID for diagnostic correlation.
        // `estate_uuid` is `[u8; 16]` — convert to `uuid::Uuid` for `with_estate`.
        let estate_uuid = Uuid::from_bytes(handle.estate_uuid);
        let storage = Arc::new(InMemoryStorage::with_estate(estate_uuid));
        PersistenceKitBackend::open_schema(storage.as_ref())
            .expect("InMemoryStorage open_schema cannot fail");
        let backend = PersistenceKitBackend::new(storage);
        let queue: queuekit::QueueKit<Box<dyn queuekit::QueueBackend>> =
            queuekit::QueueKit::new(Box::new(backend) as Box<dyn queuekit::QueueBackend>);
        (queue, ())
    }

    /// Enqueue a dreaming item for the surfaced drawer set, if the set qualifies.
    ///
    /// Guard (spec §12.2): enqueue only when the deduplicated drawer id set has
    /// ≥ 2 distinct ids. Fewer than 2 → no-op.
    ///
    /// Payload: `DreamingItem` encoded as JSON — `recall_event_id` (fresh UUID,
    /// 32-hex) and `drawer_ids` (surfaced ids in result order). Stamped with a
    /// monotone HLC derived from `now`. Submitted as `stream_id = "dreaming"` with
    /// priority 50.
    ///
    /// `now` is epoch-SECONDS — the same unit `recall_scored` receives from
    /// `wall_now()` in the dispatch layer. Internally this function converts to
    /// epoch-milliseconds before calling `hlc.send` (the HLC substrate convention).
    /// Tests may pass either unit: epoch-ms values (e.g. `NOW_MS = 1_720_000_000_000`)
    /// still produce valid strictly-increasing HLC stamps because the ms conversion
    /// multiplies by 1000, keeping ordering intact.
    ///
    /// Takes `&self` via `RefCell` interior mutability on `dreaming_queues` so it
    /// can be called from `recall_scored` (which is `&self`). The `RefCell` borrow
    /// is held only for the duration of the `send` call; no other code path holds a
    /// simultaneous borrow (the coordinator is accessed under the transport lock).
    ///
    /// Failures are non-fatal: logged to stderr, recall result unaffected. Mirrors
    /// the signal lane's `fire_signal` error handling in `serial_lane.rs`.
    fn enqueue_dreaming_item(
        &self,
        handle: &EstateHandle,
        drawers: &[Drawer],
        now: i64,
    ) {
        // Deduplicate ids while preserving result order (first occurrence wins).
        let mut seen = std::collections::HashSet::new();
        let distinct_ids: Vec<String> = drawers
            .iter()
            .filter(|d| seen.insert(d.id.clone()))
            .map(|d| d.id.clone())
            .collect();

        // Guard: fewer than 2 distinct ids → no pair possible, skip enqueue.
        if distinct_ids.len() < 2 {
            return;
        }

        let item = DreamingItem {
            // 32-hex UUID (no hyphens), matching the JobId shape convention used
            // by the signal lane (uuid::Uuid::new_v4().simple().to_string()).
            recall_event_id: uuid::Uuid::new_v4().simple().to_string(),
            drawer_ids: distinct_ids,
        };
        let payload = match serde_json::to_vec(&item) {
            Ok(p) => p,
            Err(e) => {
                eprintln!(
                    "DreamingQueue: DreamingItem serialization failed (estate {:?}): {:?}",
                    handle.estate_uuid, e
                );
                return;
            }
        };

        // Lazy-mount the dreaming queue for this estate. Returns immediately if
        // already mounted; idempotent. Uses RefCell interior mutability so this
        // call site can remain &self (matching recall_scored's &self signature).
        self.ensure_dreaming_queue(handle);

        // Borrow the map mutably for the HLC send + queue send. The borrow
        // is scoped to this block and released before we return. No other
        // code path holds a simultaneous mutable borrow — the coordinator is
        // single-threaded under the transport lock.
        let mut map = self.dreaming_queues.borrow_mut();
        let (queue, hlc) = match map.get_mut(handle) {
            Some(entry) => entry,
            None => {
                // ensure_dreaming_queue always inserts an entry (SQLite or InMemory).
                // A missing entry here is a contract violation — log and bail.
                eprintln!(
                    "DreamingQueue: queue entry missing after ensure_dreaming_queue (estate {:?})",
                    handle.estate_uuid
                );
                return;
            }
        };

        // HLC physical time and the `now` parameter from dispatch are both epoch
        // milliseconds, so the value needs no conversion.
        let submitted_at = hlc.send(now);
        let job = queuekit::Job {
            id: queuekit::JobId(uuid::Uuid::new_v4().simple().to_string()),
            stream_id: queuekit::StreamId("dreaming".to_string()),
            submitted_at,
            priority: 50,
            payload,
            extensions: serde_json::Map::new(),
        };

        if let Err(e) = queue.send(&job) {
            eprintln!(
                "DreamingQueue: dreaming enqueue failed (estate {:?}): {:?}",
                handle.estate_uuid, e
            );
        }
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
        self.recall_tunnels_with_ceiling(handle, wing, false)
    }

    /// `including_restricted` forwards to the LocusKit tunnel sensitivity
    /// gate's one sanctioned widening: the vault export's private-scope
    /// opt-in. The default keeps the no-claims Normal-tier ceiling;
    /// secret-tier edges are excluded unconditionally either way. Mirrors
    /// Swift `recallTunnels(_:wing:includingRestricted:)`.
    pub fn recall_tunnels_with_ceiling(
        &self,
        handle: &EstateHandle,
        wing: &str,
        including_restricted: bool,
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
            .tunnels_from_wing_with_ceiling(wing, including_restricted)
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

    // MARK: - find_nearest_distilled

    /// Find the nearest distilled-tier vectors to `engram` in the estate
    /// addressed by `handle`. Parity of the Swift
    /// `findNearestDistilled(_:engram:limit:)`.
    ///
    /// Thin wrapper over `VectorStore::find_nearest` scoped to the
    /// `"distillation-features-v1"` model lane. Called by the DistilledRecall
    /// recipe for no-inference Hamming NN on the distilled tier — the probe
    /// Engram is produced by `DistillationPipeline::query_fingerprint`, so no
    /// embedding model call is needed at search time.
    ///
    /// `limit = 0` returns an empty `Vec` without error (the inner
    /// `find_nearest` guards `k > 0` and returns early).
    ///
    /// Returns `VerbDispatchError::EstateNotOpen` for a stale handle;
    /// `VerbDispatchError::Verb(VerbError::NotSupportedByEstate)` when no
    /// VectorStore is registered for the estate.
    pub fn find_nearest_distilled(
        &self,
        handle: &EstateHandle,
        engram: &Engram,
        limit: usize,
    ) -> Result<Vec<VectorMatch>, VerbDispatchError> {
        // Validate that the handle is open before accessing the VectorStore.
        // Returns VerbDispatchError::EstateNotOpen for stale handles —
        // parity of the Swift surface's `estate(for:)` guard.
        self.estate_for_verb(handle)?;
        let store = self.vector_store_for(handle).ok_or_else(|| {
            // Estate is open but no VectorStore is registered. The distillation
            // tier requires a VectorStore; raise NotSupportedByEstate so callers
            // receive a typed, structured error — parity of the Swift surface.
            VerbDispatchError::Verb(VerbError::NotSupportedByEstate {
                verb: "find_nearest_distilled".to_string(),
            })
        })?;
        // Dispatch to the distillation lane. model_id is the fixed string for
        // the structural fingerprint lane — "distillation-features-v1" — not
        // the estate's semantic embedding model. limit = 0 returns an empty
        // Vec without error (VectorStore::find_nearest guards k > 0 internally).
        store
            .find_nearest(engram, "distillation-features-v1", limit)
            .map_err(|e| {
                VerbDispatchError::Verb(VerbError::UnderlyingEstateFailure {
                    verb: "find_nearest_distilled".to_string(),
                    reason: format!("{e:?}"),
                })
            })
    }

    // MARK: - distill_items_sweep

    /// Per-item distillation sweep — SPEC_DISTILLATION_STORAGE §7.1
    /// (the `moot_distill` tool path).
    ///
    /// Rust parity of Swift `GeniusLocusKit.distillItemsSweep`.
    ///
    /// For each active drawer with non-empty content whose representation
    /// is NULL or was produced under a different pipeline contract, this
    /// method performs exactly the two §7.2 writes:
    ///   1. The four representation columns on the SOURCE drawer row,
    ///      atomically (`set_distilled_representation`).
    ///   2. One `distillation-features-v1` lane entry keyed by the SOURCE
    ///      drawer id (§8) — upsert-replace, only when the structural
    ///      fingerprint is non-zero (columns and lane independently valid).
    ///
    /// Rendering paths (p1 contract — `DistillationPipeline::default_extractor`
    /// on BOTH legs, so renderings are byte-identical Swift/Rust):
    ///   • ≥3 sentences: intra-item matrix pipeline; Stage 5 renders
    ///     core-first compacted prose (§7.4).
    ///   • <3 sentences: the §7.6 token-compaction transform over the
    ///     content; fingerprint via the query_fingerprint construction
    ///     (§7.5).
    ///
    /// It captures no drawer, writes no tunnel, and touches no lifecycle
    /// or lineage field (§11). Idempotent by the NULL predicate — no
    /// provenance scan.
    ///
    /// `now` is epoch milliseconds — deterministic clock, mirrors Swift's
    /// `Date` parameter (`distilled_at` is audit-only, §4). `limit` caps
    /// items distilled this sweep (`None` = all eligible).
    ///
    /// # Errors
    ///
    /// Returns `VerbDispatchError` for stale handles. Individual item
    /// failures (row vanished mid-sweep) are skipped; VectorStore absence
    /// is non-fatal (the lane is simply dark).
    /// Distill a SINGLE item into its on-row representation (§7.2) — the
    /// one write seam every distillation caller shares.
    ///
    /// Writes the four representation columns on the source drawer row in
    /// one atomic UPDATE, then replaces the item's
    /// `distillation-features-v1` lane entry when a non-zero structural
    /// fingerprint was computed. VectorStore absence is non-fatal: the
    /// columns are still written (the lane is simply dark, matching the
    /// estate's semantic-tier wiring).
    ///
    /// A FREE function, not a method: the drain-stage `on_encoded` callback
    /// is a `'static` closure that cannot borrow the coordinator, so every
    /// dependency is passed explicitly. That is what lets the rider, the
    /// seeding path (`seed_default_wings`), and `distill_items_sweep` all
    /// traverse this same call tree instead of keeping private copies of
    /// the transform.
    ///
    /// Callers own the dense-over-distillate recompose (Stream F) that
    /// follows a successful write — it needs the Corpus, which not every
    /// caller has.
    ///
    /// `now` is passed in, never read here. Returns true when the columns
    /// were written (false when the content is empty or the row vanished).
    ///
    /// Mirrors Swift `GeniusLocusKit.distillItem(handle:drawerID:content:distillFn:now:)`.
    pub(crate) fn distill_item(
        estate: &Estate,
        vector_store: Option<&std::sync::Arc<VectorStore>>,
        drawer_id: &str,
        content: &str,
        now: i64,
    ) -> bool {
        use crate::brain::distillation_cycle::{render_distillation, DISTILLATION_LANE_MODEL_ID};
        use substrate_ml::token_compaction;

        if content.is_empty() {
            return false;
        }
        let (rendering, fingerprint) = render_distillation(drawer_id, content);

        // Write 1 of 2 (§7.2): the four representation columns, atomically.
        let token_count = token_compaction::estimate_token_count(&rendering);
        match estate.set_distilled_representation(
            drawer_id,
            &rendering,
            token_compaction::DISTILLATION_PIPELINE_VERSION,
            token_count,
            now,
        ) {
            Ok(1) => {}
            // Row vanished mid-flight or the write failed: no columns, no
            // lane entry — the next sweep recovers it.
            _ => return false,
        }

        // Write 2 of 2 (§7.2/§8): the lane entry, keyed by the SOURCE drawer
        // id. add_vector upserts on (itemID, modelID) — the §8
        // replace-on-regeneration semantic. A zero fingerprint (no extracted
        // features) writes no entry; columns and lane are independently
        // valid (§7.5). add_vector failure is non-fatal — only the Hamming
        // NN lane is affected.
        if fingerprint != substrate_types::fingerprint256::Fingerprint256::ZERO {
            if let Some(vs) = vector_store {
                let _ = vs.add_vector(drawer_id, &fingerprint, DISTILLATION_LANE_MODEL_ID, "1", now);
            }
        }
        true
    }

    pub fn distill_items_sweep(
        &self,
        handle: &EstateHandle,
        now: i64,
        limit: Option<usize>,
    ) -> Result<usize, VerbDispatchError> {
        use substrate_ml::token_compaction;

        let estate = self.estate_for_verb(handle)?;

        // Optional VectorStore for fingerprint storage. Absence is non-fatal.
        let vector_store_opt = self.vector_store_for(handle);

        let mut produced: usize = 0;

        // Rooms-first sweep: enumerate room-level fingerprint entries, skip
        // rooms whose operationalAND proves every active drawer already carries
        // bit 19 (HAS_CURRENT_REPRESENTATION), and load the remaining rooms
        // via drawers_in_wing_room.
        //
        // Safety invariant — AND is an under-approximation:
        //   Falsely-ABSENT bit 19 in operational_and → room scanned
        //   unnecessarily (harmless over-work).  Falsely-PRESENT bit 19
        //   would skip a room with eligible work (UNSAFE); rebuildAll at
        //   estate open prevents this by recomputing the AND from scratch.
        //   Mid-session, the AND can only worsen in the safe direction
        //   (capture lowers AND; only rebuildAll raises it).
        let skip_bit =
            locus_kit::drawer_operational::DrawerFeatureFlags::HAS_CURRENT_REPRESENTATION;
        let rooms = estate
            .room_level_fingerprints()
            .map_err(|e| remap("distill_items_sweep", "", e))?;

        'rooms: for entry in &rooms {
            // Skip this room when the AND proves every active drawer already
            // has bit 19 set.  The AND is an under-approximation so if it
            // shows 1 for bit 19 the true AND is also 1 — safe to skip.
            if (entry.fingerprint.operational_and & skip_bit) == skip_bit {
                continue;
            }

            let room_drawers = estate
                .drawers_in_wing_room(&entry.wing, &entry.room)
                .map_err(|e| remap("distill_items_sweep", &entry.room, e))?;

            for drawer in &room_drawers {
            if let Some(cap) = limit {
                if produced >= cap {
                        break 'rooms;
                }
            }
            if drawer.content.is_empty() {
                continue;
            }
            // Eligibility (§7.1): bit 19 (has_current_representation) set
            // AND pipeline version matches → already distilled, skip. The
            // bitmap test replaces the previous `distilled.is_some()` column-
            // presence check (cookbook §2.4.1 / SPEC §7.1). Both are correct
            // by the §4 invariant, but the bit is the authoritative indicator.
            if drawer.has_current_representation()
                && drawer.distilled_pipeline_version.as_deref()
                    == Some(token_compaction::DISTILLATION_PIPELINE_VERSION)
            {
                continue;
            }

            // Render + both writes through the shared seam (§7.2/§7.4/§7.5)
            // — the same call tree the drain-stage rider and the seeding
            // path take. A false return means the row vanished mid-sweep or
            // the write failed: skip it.
            if !Self::distill_item(
                estate,
                vector_store_opt.as_ref(),
                &drawer.id,
                &drawer.content,
                now,
            ) {
                continue;
            }

            produced += 1;
            // Dense-over-distillate (Stream F): recompose the dense float
            // vector from the newly-written distillate. The idempotence gate
            // keys on content digest (not on dense_composition_text), so a
            // normal index call would be silently skipped —
            // recompose_dense_vector passes force=true to bypass the gate.
            // Best-effort: non-fatal when corpus is absent (LocusOnly estate)
            // or when the record resolves None (expunged mid-sweep).
            // Swift parity: DistillationCycle.distillItemsSweep.
            if let Some(corpus) = self.corpus_kits.get(handle) {
                let _ = corpus.recompose_dense_vector(&drawer.id, now);
            }
            } // end for drawer in &room_drawers
        } // end 'rooms: for entry in &rooms

        Ok(produced)
    }

    // MARK: - contradiction hunt

    /// Run one contradiction-hunt pass over `handle` — the content-driven
    /// half of dreaming and the engine behind `moot_hunt_contradictions`.
    /// Rust mirror of Swift `GeniusLocusKit.huntContradictions`.
    ///
    /// Shape: sample up to `probe_limit` vector-indexed item IDs, kNN
    /// each probe through the registered VectorStore on TWO lanes —
    /// drawer-keyed rows under `model_id`, and (when a Corpus is
    /// registered) chunk-keyed rows under the corpus's own model_id with
    /// chunk hits mapped back to their owning drawers — canonicalize +
    /// deduplicate pairs, screen each pair's content with SubstrateML
    /// `conflict_cue`, then:
    ///   strong cue (score ≥ STRONG_THRESHOLD)  → capture a `contradicts`
    ///     tunnel with lifecycle `Proposed`, origin class `Derived`
    ///     (reviewable via `respond_to_tunnel`).
    ///   borderline                              → returned as candidate
    ///     pairs for the BYOAI client to adjudicate; never persisted.
    ///
    /// Dedup contract: a pair with ANY existing `contradicts` tunnel — any
    /// lifecycle, including `Withdrawn` (a rejected review) — is never
    /// proposed again. Sensitivity: `add_tunnel` stamps the tunnel with the
    /// MAX of its endpoints' sensitivities (#57), so proposed edges touching
    /// restricted drawers stay gated automatically.
    ///
    /// `filed_after` (epoch ms) is the incremental watermark: when set, a
    /// pair is screened only if at least one side was filed after it.

    // MARK: - Wave-2 consolidation (SPEC_CONSOLIDATION_VAGUE_RECALL §3, §5)

    /// One bounded consolidation sweep (§3.1 + §3.2 + §5.1). Returns the
    /// count of consolidation acts. Mirrors Swift
    /// `GeniusLocusKit.consolidationSweep`.
    pub fn consolidation_sweep(
        &self,
        handle: &EstateHandle,
        now: i64,
        config: &crate::brain::consolidation_cycle::ConsolidationConfig,
        limit: Option<usize>,
    ) -> Result<usize, VerbDispatchError> {
        Ok(self
            .consolidation_sweep_report(handle, now, config, limit)?
            .total_acts())
    }

    /// Sweep with the full report (metrics for the D10/D11 defrag policy).
    /// Mirrors Swift `GeniusLocusKit.consolidationSweepReport` /
    /// `ConsolidationCycle.swift` — see that file for the design narrative;
    /// the numbered sections here match it one for one.
    pub fn consolidation_sweep_report(
        &self,
        handle: &EstateHandle,
        now: i64,
        config: &crate::brain::consolidation_cycle::ConsolidationConfig,
        limit: Option<usize>,
    ) -> Result<crate::brain::consolidation_cycle::ConsolidationSweepReport, VerbDispatchError>
    {
        use crate::brain::consolidation_cycle::ConsolidationSweepReport;
        use crate::brain::distillation_cycle::DISTILLATION_LANE_MODEL_ID;
        use locus_kit::adjectives::State;
        use locus_kit::drawer_operational::DrawerFeatureFlags;
        use std::collections::{BTreeMap, BTreeSet};

        let none = ConsolidationSweepReport {
            new_vague_items: 0,
            fold_ins: 0,
            fold_in_rejections: 0,
            repaired_items: 0,
        };
        let estate = self.estate_for_verb(handle)?;
        let vector_store = match self.vector_store_for(handle) {
            Some(vs) => vs,
            None => return Ok(none),
        };

        // ── §D.6 #4 repair prologue: restamp under-tiered vague drawers ───
        // Before the candidate pool is built, scan all vague drawers and
        // promote any whose sensitivity tier is below the MAX of their
        // constituents. This repairs rows that were consolidated before
        // sensitivity inheritance shipped. Bounded by all_drawers_bounded(None)
        // — the same corpus budget as distillation health scans. Idempotent:
        // a correctly-stamped drawer is not touched (max == current). A
        // positive repaired_items count in the report signals the estate
        // contained pre-existing under-tiered rows (§D.6 #4 piggyback ruling).
        let mut repaired_items: usize = 0;
        {
            use substrate_kernel::bit_field;

            let all = estate
                .all_drawers_bounded(None)
                .map_err(|e| remap("consolidation_sweep_repair_prologue", "", e))?;

            for vague in all.iter().filter(|d| (d.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0) {
                // Look up constituent IDs via the _consolidated_from tunnels.
                let constituent_ids = estate
                    .constituent_ids_for_vague_item(&vague.id)
                    .map_err(|e| remap("consolidation_sweep_repair_prologue", "", e))?;
                if constituent_ids.is_empty() {
                    continue;
                }

                // Compute max adjective and provenance sensitivity over constituents
                // AND the vague item itself (monotone ceiling: only ever promote).
                let vague_adj_raw = vague.adjective_sensitivity().raw_value();
                let vague_prov_raw = vague.sensitivity().raw_value();
                let mut max_adj_raw = vague_adj_raw;
                let mut max_prov_raw = vague_prov_raw;
                for cid in &constituent_ids {
                    if let Ok(Some(constituent)) = estate.get_drawer(cid) {
                        let c_adj = constituent.adjective_sensitivity().raw_value();
                        let c_prov = constituent.sensitivity().raw_value();
                        if c_adj > max_adj_raw { max_adj_raw = c_adj; }
                        if c_prov > max_prov_raw { max_prov_raw = c_prov; }
                    }
                }

                // If the vague drawer is already at or above the max tier, skip.
                if max_adj_raw == vague_adj_raw && max_prov_raw == vague_prov_raw {
                    continue;
                }

                // Promote the vague drawer's adjective and provenance bitmaps.
                // Preserve all other adjective and provenance bits unchanged.
                let new_adj = bit_field::write_field(max_adj_raw, vague.adjective_bitmap, 6, 6);
                let new_prov = bit_field::write_field(max_prov_raw, vague.provenance, 30, 6);
                if new_adj != vague.adjective_bitmap {
                    estate
                        .repair_adjective_bitmap(&vague.id, new_adj, now)
                        .map_err(|e| remap("consolidation_sweep_repair_prologue", "", e))?;
                }
                if new_prov != vague.provenance {
                    estate
                        .repair_provenance_bitmap(&vague.id, new_prov, now)
                        .map_err(|e| remap("consolidation_sweep_repair_prologue", "", e))?;
                }

                // Restamp every _consolidated_from tunnel for this vague drawer
                // with max(vague, constituent) sensitivity in bits 6–11. The
                // max_adj_raw now equals the vague's promoted value, so every
                // tunnel is floored at max_adj_raw.
                let stamped_adj_bitmap = bit_field::write_field(max_adj_raw, 0i64, 6, 6);
                for cid in &constituent_ids {
                    let tid = format!("_consolidated_from:{}:{}", vague.id, cid);
                    // stamp_tunnel_adjective_bitmap is idempotent: writing the
                    // same value again on a correctly-stamped tunnel is harmless.
                    let _ = estate.stamp_tunnel_adjective_bitmap(&tid, stamped_adj_bitmap);
                }

                repaired_items += 1;
            }
        }

        // ── §3.1 step 1: candidate pool — aged (D1/D2), recall-quiet (D3),
        // not represented, not vague-at-cap. Bounded page walk (D9).
        let age_cutoff = now - config.minimum_age_seconds;
        let recall_cutoff_iso = epoch_secs_to_iso8601(now - config.recall_quiet_seconds);
        let now_iso = epoch_secs_to_iso8601(now);
        let recently_recalled: BTreeSet<String> = estate
            .recent_recall_traces(&recall_cutoff_iso, &now_iso)
            .map_err(|e| remap("consolidation_sweep", "", e))?
            .into_iter()
            .map(|t| t.target)
            .collect();

        let mut pool: Vec<locus_kit::drawer::Drawer> = Vec::new();
        let mut cursor: Option<String> = None;
        let mut examined: usize = 0;
        while examined < config.max_candidates_per_sweep {
            let page_limit = std::cmp::min(500, config.max_candidates_per_sweep - examined);
            let page = estate
                .active_drawers_after(cursor.as_deref(), page_limit)
                .map_err(|e| remap("consolidation_sweep", "", e))?;
            if page.is_empty() {
                break;
            }
            cursor = page.last().map(|d| d.id.clone());
            examined += page.len();
            for drawer in page {
                if drawer.filed_at > age_cutoff {
                    continue;
                }
                if (drawer.operational_bitmap & DrawerFeatureFlags::REPRESENTED_BY_VAGUE) != 0 {
                    continue;
                }
                let is_vague =
                    (drawer.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0;
                if is_vague && drawer.vague_level() >= config.vague_level_cap {
                    continue;
                }
                if recently_recalled.contains(&drawer.id) {
                    continue;
                }
                pool.push(drawer);
            }
        }
        if pool.is_empty() {
            return Ok(ConsolidationSweepReport {
                new_vague_items: 0,
                fold_ins: 0,
                fold_in_rejections: 0,
                repaired_items,
            });
        }

        // Fingerprints from the distillation-features-v1 lane; items without
        // one re-enter the pool after the next distillation sweep.
        let mut engrams: BTreeMap<String, substrate_types::Fingerprint256> = BTreeMap::new();
        for drawer in &pool {
            let stored = vector_store
                .vectors_for_item(&drawer.id)
                .map_err(|e| VerbDispatchError::RecallLaneUnavailable { reason: format!("vectors_for_item: {e:?}") })?;
            if let Some(fp) = stored.iter().find(|v| v.model_id == DISTILLATION_LANE_MODEL_ID) {
                engrams.insert(drawer.id.clone(), fp.engram.clone());
            }
        }
        let clusterable: Vec<&locus_kit::drawer::Drawer> =
            pool.iter().filter(|d| engrams.contains_key(&d.id)).collect();
        if clusterable.is_empty() {
            return Ok(ConsolidationSweepReport {
                new_vague_items: 0,
                fold_ins: 0,
                fold_in_rejections: 0,
                repaired_items,
            });
        }

        // ── D4: configured ceiling wins; otherwise derive p10 of the
        // measured pairwise distribution over a bounded sample.
        let ceiling: u32 = match config.hamming_ceiling {
            Some(c) => c,
            None => {
                let sample: Vec<&substrate_types::Fingerprint256> = clusterable
                    .iter()
                    .take(64)
                    .filter_map(|d| engrams.get(&d.id))
                    .collect();
                let mut distances: Vec<u32> = Vec::new();
                for i in 0..sample.len() {
                    for j in (i + 1)..sample.len() {
                        distances.push(substrate_types::hamming::distance(
                            sample[i], sample[j], 4,
                        ));
                    }
                }
                if distances.is_empty() {
                    return Ok(ConsolidationSweepReport {
                        new_vague_items: 0,
                        fold_ins: 0,
                        fold_in_rejections: 0,
                        repaired_items,
                    });
                }
                distances.sort_unstable();
                // p10 index, floor-clamped (mirrors Swift max(0, n/10 - 1)).
                let idx = (distances.len() / 10).saturating_sub(1);
                distances[idx.min(distances.len() - 1)]
            }
        };

        // ── §3.1 steps 2–3 + §5.1 edge typing (mirrors Swift exactly):
        //   non-vague↔non-vague → union; non-vague↔vague → fold candidate
        //   (regardless of pool membership); vague↔vague → union (§5.4).
        let pool_by_id: BTreeMap<String, &locus_kit::drawer::Drawer> =
            clusterable.iter().map(|d| (d.id.clone(), *d)).collect();
        let mut parent: BTreeMap<String, String> = BTreeMap::new();
        fn find(parent: &mut BTreeMap<String, String>, x: &str) -> String {
            let mut root = x.to_string();
            while let Some(p) = parent.get(&root) {
                if *p == root {
                    break;
                }
                root = p.clone();
            }
            parent.insert(x.to_string(), root.clone());
            root
        }
        let mut nearest_vague: BTreeMap<String, (String, u32)> = BTreeMap::new();
        let mut off_pool_matches: BTreeMap<String, Vec<(String, u32)>> = BTreeMap::new();
        let mut off_pool_ids: BTreeSet<String> = BTreeSet::new();
        for drawer in &clusterable {
            parent.entry(drawer.id.clone()).or_insert_with(|| drawer.id.clone());
            let probe = match engrams.get(&drawer.id) {
                Some(e) => e,
                None => continue,
            };
            let d_vague = (drawer.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0;
            let matches = vector_store
                .find_nearest(probe, DISTILLATION_LANE_MODEL_ID, config.neighbor_probe_limit)
                .map_err(|e| VerbDispatchError::RecallLaneUnavailable { reason: format!("find_nearest: {e:?}") })?;
            for m in matches {
                if m.item_id == drawer.id {
                    continue;
                }
                let dist = m.distance as u32;
                if let Some(mate) = pool_by_id.get(&m.item_id) {
                    let m_vague =
                        (mate.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0;
                    match (d_vague, m_vague) {
                        (false, false) | (true, true) => {
                            if dist <= ceiling {
                                parent
                                    .entry(mate.id.clone())
                                    .or_insert_with(|| mate.id.clone());
                                let ra = find(&mut parent, &drawer.id);
                                let rb = find(&mut parent, &mate.id);
                                if ra != rb {
                                    parent.insert(ra, rb);
                                }
                            }
                        }
                        (false, true) => {
                            let e = nearest_vague.get(&drawer.id);
                            if e.map(|(_, d0)| dist < *d0).unwrap_or(true) {
                                nearest_vague.insert(drawer.id.clone(), (mate.id.clone(), dist));
                            }
                        }
                        (true, false) => {
                            let e = nearest_vague.get(&mate.id);
                            if e.map(|(_, d0)| dist < *d0).unwrap_or(true) {
                                nearest_vague.insert(mate.id.clone(), (drawer.id.clone(), dist));
                            }
                        }
                    }
                } else {
                    off_pool_ids.insert(m.item_id.clone());
                    if !d_vague {
                        off_pool_matches
                            .entry(drawer.id.clone())
                            .or_default()
                            .push((m.item_id.clone(), dist));
                    }
                }
            }
        }
        // Resolve off-pool matches; fold targets must be ACTIVE vague items.
        let off_pool_vec: Vec<&str> = off_pool_ids.iter().map(|s| s.as_str()).collect();
        let off_pool = estate
            .get_drawers(&off_pool_vec)
            .map_err(|e| remap("consolidation_sweep", "", e))?;
        let mut active_vague_by_id: BTreeMap<String, locus_kit::drawer::Drawer> = off_pool
            .into_iter()
            .filter(|d| {
                (d.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0
                    && d.state() != State::Superseded
            })
            .map(|d| (d.id.clone(), d))
            .collect();
        for drawer in &clusterable {
            if (drawer.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0
                && drawer.state() != State::Superseded
            {
                active_vague_by_id.insert(drawer.id.clone(), (*drawer).clone());
            }
        }
        for (drawer_id, matches) in &off_pool_matches {
            for (mid, dist) in matches {
                if active_vague_by_id.contains_key(mid) {
                    let e = nearest_vague.get(drawer_id);
                    if e.map(|(_, d0)| dist < d0).unwrap_or(true) {
                        nearest_vague.insert(drawer_id.clone(), (mid.clone(), *dist));
                    }
                }
            }
        }

        // ── §5.1 fold-ins first; rejections feed D10.
        let mut fold_groups: BTreeMap<String, Vec<String>> = BTreeMap::new();
        let mut fold_in_rejections: usize = 0;
        let mut folded_ids: BTreeSet<String> = BTreeSet::new();
        for drawer in &clusterable {
            let (vid, dist) = match nearest_vague.get(&drawer.id) {
                Some(c) => c,
                None => continue,
            };
            let vague_item = match active_vague_by_id.get(vid) {
                Some(v) => v,
                None => continue,
            };
            if *dist <= ceiling {
                let folded_level =
                    if (drawer.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0 {
                        drawer.vague_level()
                    } else {
                        0
                    };
                if std::cmp::max(vague_item.vague_level(), folded_level + 1)
                    > config.vague_level_cap
                {
                    continue;
                }
                fold_groups.entry(vid.clone()).or_default().push(drawer.id.clone());
                folded_ids.insert(drawer.id.clone());
            } else {
                fold_in_rejections += 1;
            }
        }
        let mut fold_ins: usize = 0;
        for (vague_id, folded) in &fold_groups {
            if let Some(cap) = limit {
                if fold_ins >= cap {
                    break;
                }
            }
            let vague_item = match active_vague_by_id.get(vague_id) {
                Some(v) => v.clone(),
                None => continue,
            };
            let existing = estate
                .constituent_ids_for_vague_item(vague_id)
                .map_err(|e| remap("consolidation_sweep", "", e))?;
            let mut enlarged: Vec<String> = existing.clone();
            for fid in folded {
                if !enlarged.contains(fid) {
                    enlarged.push(fid.clone());
                }
            }
            if enlarged.len() < config.minimum_cluster_size {
                continue;
            }
            let enlarged_refs: Vec<&str> = enlarged.iter().map(|s| s.as_str()).collect();
            let mut constituents = estate
                .get_drawers(&enlarged_refs)
                .map_err(|e| remap("consolidation_sweep", "", e))?;
            constituents.sort_by(|a, b| (a.filed_at, &a.id).cmp(&(b.filed_at, &b.id)));
            let (rendering, fingerprint) =
                match Self::compose_and_distill(&constituents, config) {
                    Some(r) => r,
                    None => continue,
                };
            let max_constituent_level = constituents
                .iter()
                .map(|c| {
                    if (c.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0 {
                        c.vague_level()
                    } else {
                        0
                    }
                })
                .max()
                .unwrap_or(0);
            let level = std::cmp::max(vague_item.vague_level(), 1 + max_constituent_level);
            if level > config.vague_level_cap {
                continue;
            }
            // Fold-in v2 is a fresh derived row: same subject rule as the
            // new-cluster path — never born as debt (PR-02). Computed before
            // `rendering` moves into the constructor.
            let v2_subject_line = crate::brain::consolidation_cycle::vague_subject(&rendering);
            let mut v2 = locus_kit::drawer::Drawer::new(
                uuid::Uuid::new_v4().to_string(),
                rendering,
                vague_item.parent_node_id.clone(),
                "consolidation-daemon",
                now,
                vague_item.embedding_model_id.clone(),
            );
            v2.lineage_id = vague_item.lineage_id;
            v2.subject = Some(v2_subject_line);
            v2.subject_pipeline_version = Some(crate::brain::consolidation_cycle::CONSOLIDATION_SUBJECT_PIPELINE.to_string());
            v2.subject_at = Some(now);
            v2.operational_bitmap = DrawerFeatureFlags::IS_VAGUE
                | (((level as i64) & 0b11) << DrawerFeatureFlags::VAGUE_LEVEL_SHIFT);
            // Sensitivity inheritance (§D.1 monotone ceiling): fold-in v2 carries the MAX
            // adjective and provenance sensitivity over the enlarged constituent set and the
            // prior vague item. A fold-in must never lower the tier — cookbook §2.3 bits 6–11
            // (adjective) and §2.5 bits 30–35 (provenance at capture).
            {
                use substrate_kernel::bit_field;
                use locus_kit::adjectives::AdjectiveSensitivity;
                use locus_kit::provenance::Sensitivity;
                let prior_adj_raw = vague_item.adjective_sensitivity().raw_value();
                let prior_prov_raw = vague_item.sensitivity().raw_value();
                let max_adj_raw = constituents.iter().fold(prior_adj_raw, |best, d| {
                    let r = d.adjective_sensitivity().raw_value();
                    if r > best { r } else { best }
                });
                let max_prov_raw = constituents.iter().fold(prior_prov_raw, |best, d| {
                    let r = d.sensitivity().raw_value();
                    if r > best { r } else { best }
                });
                // Verify the values are recognised by their enums (safe fallback to Normal if
                // a stale intermediate value slips through, matching Swift's `?? .normal`).
                let max_adj = AdjectiveSensitivity::from_raw(max_adj_raw);
                let max_prov = Sensitivity::from_raw(max_prov_raw);
                v2.adjective_bitmap = bit_field::write_field(max_adj.raw_value(), 0i64, 6, 6);
                v2.provenance = bit_field::write_field(max_prov.raw_value(), 0i64, 30, 6);
            }
            estate
                .fold_in_transactionally(
                    &v2,
                    vague_id,
                    &enlarged_refs,
                    "consolidation-daemon",
                    now,
                )
                .map_err(|e| remap("consolidation_sweep", "", e))?;
            if fingerprint != substrate_types::Fingerprint256::ZERO {
                vector_store
                    .add_vector(&v2.id, &fingerprint, DISTILLATION_LANE_MODEL_ID, "1", now)
                    .map_err(|e| VerbDispatchError::RecallLaneUnavailable { reason: format!("add_vector: {e:?}") })?;
            }
            fold_ins += 1;
        }

        // ── §3.2: new clusters from the remaining components.
        let mut components: BTreeMap<String, Vec<String>> = BTreeMap::new();
        let ids: Vec<String> = clusterable.iter().map(|d| d.id.clone()).collect();
        for id in &ids {
            let root = find(&mut parent, id);
            components.entry(root).or_default().push(id.clone());
        }
        let mut produced: usize = 0;
        for member_ids in components.values() {
            if let Some(cap) = limit {
                if produced + fold_ins >= cap {
                    break;
                }
            }
            let mut constituents: Vec<locus_kit::drawer::Drawer> = member_ids
                .iter()
                .filter(|id| !folded_ids.contains(*id))
                .filter_map(|id| pool_by_id.get(id).map(|d| (*d).clone()))
                .collect();
            if constituents.len() < config.minimum_cluster_size {
                continue;
            }
            constituents.sort_by(|a, b| (a.filed_at, &a.id).cmp(&(b.filed_at, &b.id)));
            let product_level = 1 + constituents
                .iter()
                .map(|c| {
                    if (c.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0 {
                        c.vague_level()
                    } else {
                        0
                    }
                })
                .max()
                .unwrap_or(0);
            if product_level > config.vague_level_cap {
                continue;
            }
            let (rendering, fingerprint) =
                match Self::compose_and_distill(&constituents, config) {
                    Some(r) => r,
                    None => continue,
                };
            let vague_bitmap: i64 = DrawerFeatureFlags::IS_VAGUE
                | (((product_level as i64) & 0b11) << DrawerFeatureFlags::VAGUE_LEVEL_SHIFT);
            // Derived writers emit their own subject at creation (PR-02): a
            // vague item must never be born as subject debt. Computed before
            // `rendering` moves into the constructor. Mirrors Swift
            // vagueSubject/consolidationSubjectPipeline.
            let vague_subject_line = crate::brain::consolidation_cycle::vague_subject(&rendering);
            let mut vague = locus_kit::drawer::Drawer::new(
                uuid::Uuid::new_v4().to_string(),
                rendering,
                constituents[0].parent_node_id.clone(),
                "consolidation-daemon",
                now,
                constituents[0].embedding_model_id.clone(),
            );
            vague.operational_bitmap = vague_bitmap;
            vague.subject = Some(vague_subject_line);
            vague.subject_pipeline_version = Some(crate::brain::consolidation_cycle::CONSOLIDATION_SUBJECT_PIPELINE.to_string());
            vague.subject_at = Some(now);
            // Sensitivity inheritance (§D.1): the new vague drawer carries the MAX adjective
            // and provenance sensitivity over all constituents — cookbook §2.3 bits 6–11
            // (adjective) and §2.5 bits 30–35 (provenance at capture). Source tier flows to
            // derived artifact; no constituent's sensitivity is ever silently downgraded.
            {
                use substrate_kernel::bit_field;
                use locus_kit::adjectives::AdjectiveSensitivity;
                use locus_kit::provenance::Sensitivity;
                let max_adj_raw = constituents.iter().fold(0i64, |best, d| {
                    let r = d.adjective_sensitivity().raw_value();
                    if r > best { r } else { best }
                });
                let max_prov_raw = constituents.iter().fold(0i64, |best, d| {
                    let r = d.sensitivity().raw_value();
                    if r > best { r } else { best }
                });
                let max_adj = AdjectiveSensitivity::from_raw(max_adj_raw);
                let max_prov = Sensitivity::from_raw(max_prov_raw);
                vague.adjective_bitmap = bit_field::write_field(max_adj.raw_value(), 0i64, 6, 6);
                vague.provenance = bit_field::write_field(max_prov.raw_value(), 0i64, 30, 6);
            }
            let constituent_refs: Vec<&str> =
                constituents.iter().map(|c| c.id.as_str()).collect();
            estate
                .consolidate_transactionally(
                    &vague,
                    &constituent_refs,
                    "consolidation-daemon",
                    now,
                )
                .map_err(|e| remap("consolidation_sweep", "", e))?;
            if fingerprint != substrate_types::Fingerprint256::ZERO {
                vector_store
                    .add_vector(&vague.id, &fingerprint, DISTILLATION_LANE_MODEL_ID, "1", now)
                    .map_err(|e| VerbDispatchError::RecallLaneUnavailable { reason: format!("add_vector: {e:?}") })?;
            }
            produced += 1;
        }
        Ok(ConsolidationSweepReport {
            new_vague_items: produced,
            fold_ins,
            fold_in_rejections,
            repaired_items,
        })
    }

    /// D6/D7 composition + distillation shared by the consolidation act and
    /// fold-in regeneration. Mirrors Swift `composeAndDistill`.
    fn compose_and_distill(
        constituents: &[locus_kit::drawer::Drawer],
        config: &crate::brain::consolidation_cycle::ConsolidationConfig,
    ) -> Option<(String, substrate_types::Fingerprint256)> {
        use crate::brain::distillation_cycle::{compaction_rendering, item_is_distillable};
        use substrate_ml::distillation_pipeline::{DistillationInput, DistillationPipeline};

        let combined: String = if constituents.len() > config.large_cluster_fallback {
            constituents
                .iter()
                .map(|c| c.distilled.clone().unwrap_or_else(|| c.content.clone()))
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            constituents
                .iter()
                .map(|c| c.content.clone())
                .collect::<Vec<_>>()
                .join("\n\n")
        };
        let sentences: Vec<String> = eidetic_lib::segmenter::sentences(&combined);
        let (rendering, fingerprint) = if item_is_distillable(sentences.len()) {
            let input = DistillationInput::new(
                sentences,
                None,
                constituents[0].id.clone(),
                constituents.iter().map(|c| c.id.clone()).collect(),
            );
            let output = DistillationPipeline::run(
                &input,
                DistillationPipeline::default_extractor,
                true,
            );
            let rendering = if output.distilled_text.is_empty() {
                compaction_rendering(&combined)
            } else {
                output.distilled_text
            };
            (rendering, output.feature_fingerprint)
        } else {
            (
                compaction_rendering(&combined),
                DistillationPipeline::query_fingerprint(&combined, DistillationPipeline::default_extractor),
            )
        };
        if rendering.is_empty() {
            return None;
        }
        Some((rendering, fingerprint))
    }

    /// Two-hop vague recall (§4.4). Mirrors Swift
    /// `GeniusLocusKit.vagueRecall` — hop 1 probes the lane and keeps ACTIVE
    /// vague items; hop 2 hydrates constituents bounded by D12 K/M.
    pub fn vague_recall(
        &self,
        handle: &EstateHandle,
        query: &str,
        hit_limit: usize,
        constituents_per_hit: usize,
        total_constituents: usize,
    ) -> Result<crate::brain::consolidation_cycle::VagueRecallResult, VerbDispatchError> {
        use crate::brain::consolidation_cycle::VagueRecallResult;
        use crate::brain::distillation_cycle::DISTILLATION_LANE_MODEL_ID;
        use locus_kit::adjectives::State;
        use locus_kit::drawer_operational::DrawerFeatureFlags;
        use substrate_ml::distillation_pipeline::DistillationPipeline;

        let empty = VagueRecallResult {
            vague_hits: Vec::new(),
            constituents: Vec::new(),
        };
        let estate = self.estate_for_verb(handle)?;
        let vector_store = match self.vector_store_for(handle) {
            Some(vs) => vs,
            None => return Ok(empty),
        };
        let trimmed = query.trim();
        if trimmed.is_empty() || hit_limit == 0 {
            return Ok(empty);
        }
        let probe = DistillationPipeline::query_fingerprint(
            trimmed,
            DistillationPipeline::default_extractor,
        );
        if probe == substrate_types::Fingerprint256::ZERO {
            return Ok(empty);
        }
        let matches = vector_store
            .find_nearest(
                &probe,
                DISTILLATION_LANE_MODEL_ID,
                std::cmp::max(hit_limit * 4, hit_limit),
            )
            .map_err(|e| VerbDispatchError::RecallLaneUnavailable { reason: format!("find_nearest: {e:?}") })?;
        if matches.is_empty() {
            return Ok(empty);
        }
        let match_ids: Vec<&str> = matches.iter().map(|m| m.item_id.as_str()).collect();
        let fetched = estate
            .get_drawers(&match_ids)
            .map_err(|e| remap("vague_recall", "", e))?;
        let by_id: std::collections::BTreeMap<String, locus_kit::drawer::Drawer> =
            fetched.into_iter().map(|d| (d.id.clone(), d)).collect();
        // Lane order preserved; ACTIVE vague items only (a superseded fold-in
        // predecessor's lane entry lingers and must never surface).
        // Hop-1 sensitivity ceiling (§D.3): only vague items at ≤ .elevated
        // sensitivity are surfaced as hits. Restricted and Secret vague drawers
        // are silently excluded — their content must not ride a bulk-retrieval
        // path without an explicit elevated-privilege scope (cookbook §2.3).
        let mut vague_hits: Vec<locus_kit::drawer::Drawer> = Vec::new();
        for m in &matches {
            if vague_hits.len() >= hit_limit {
                break;
            }
            if let Some(d) = by_id.get(&m.item_id) {
                if (d.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0
                    && d.state() != State::Superseded
                    && d.adjective_sensitivity().is_bulk_exportable()
                {
                    vague_hits.push(d.clone());
                }
            }
        }
        // Hop 2: bounded hydration.
        let mut constituent_ids: Vec<String> = Vec::new();
        let mut seen: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
        'hydration: for hit in &vague_hits {
            let ids = estate
                .constituent_ids_for_vague_item(&hit.id)
                .map_err(|e| remap("vague_recall", "", e))?;
            for id in ids.into_iter().take(constituents_per_hit) {
                if constituent_ids.len() >= total_constituents {
                    break 'hydration;
                }
                if seen.insert(id.clone()) {
                    constituent_ids.push(id);
                }
            }
        }
        let cid_refs: Vec<&str> = constituent_ids.iter().map(|s| s.as_str()).collect();
        let fetched_constituents = estate
            .get_drawers(&cid_refs)
            .map_err(|e| remap("vague_recall", "", e))?;
        let cby: std::collections::BTreeMap<String, locus_kit::drawer::Drawer> =
            fetched_constituents.into_iter().map(|d| (d.id.clone(), d)).collect();
        let constituents: Vec<locus_kit::drawer::Drawer> = constituent_ids
            .iter()
            .filter_map(|id| cby.get(id).cloned())
            .collect();
        Ok(VagueRecallResult {
            vague_hits,
            constituents,
        })
    }

    /// §5.2 defrag — compositionally cascade + re-consolidate (no third
    /// mechanism). Mirrors Swift `defragVagueItem`.
    pub fn defrag_vague_item(
        &self,
        handle: &EstateHandle,
        vague_drawer_id: &str,
        now: i64,
        config: &crate::brain::consolidation_cycle::ConsolidationConfig,
    ) -> Result<crate::brain::consolidation_cycle::ConsolidationSweepReport, VerbDispatchError>
    {
        self.expunge(
            handle,
            vague_drawer_id,
            "wave-2 defrag: cluster drift exceeded the D10 threshold",
            true,
            now,
        )?;
        self.consolidation_sweep_report(handle, now, config, None)
    }

    pub fn hunt_contradictions(
        &self,
        handle: &EstateHandle,
        model_id: &str,
        probe_limit: usize,
        filed_after: Option<i64>,
        proximity_threshold: i32,
        now: i64,
    ) -> Result<ContradictionHuntReport, VerbDispatchError> {
        use locus_kit::frames::TunnelCaptureFrame;
        use locus_kit::tunnel_operational::{
            TunnelKind, TunnelLifecycle, TunnelOriginClass,
        };
        use substrate_ml::conflict_cue;

        let estate = self.estate_for_verb(handle)?;
        let remap_err =
            |e: locus_kit::error::LocusKitError| VerbDispatchError::from(remap("hunt_contradictions", "", e));

        let vector_store = match self.vector_stores.get(handle) {
            Some(store) => store,
            None => {
                return Ok(ContradictionHuntReport {
                    vector_store_available: false,
                    probes_scanned: 0,
                    pairs_screened: 0,
                    proposed: vec![],
                    borderline: vec![],
                    deduplicated: 0,
                })
            }
        };

        // Probe sample: the NEWEST vector-indexed item IDs (filed_at
        // descending, distinct). Recency-first is what makes a bounded
        // sweep converge: new memories are the ones that need screening
        // against the existing estate, so a probe_limit window always
        // contains the latest captures — an ascending-item_id window was a
        // UUID lottery that new content-addressed chunk IDs almost never
        // entered on a large estate. Neighbours may be ANY age
        // (find_nearest searches the whole lane), so new-vs-old conflicts
        // are found from the new side. Two row populations exist:
        // DRAWER-keyed rows (bespoke lanes and test-planted vectors) and
        // CHUNK-keyed rows (the production encode pipeline — the estate
        // lifecycle registers the corpus's shared vector store, and the
        // drain writes item_id = chunk UUID under the corpus's own
        // model_id). Both lanes are mined below.
        // A failed probe-source scan degrades to an empty pass rather than
        // failing the verb — matches the signal-layer treatment of the same
        // read (VectorSimilaritySignal's diagnostic-and-return).
        let probe_ids = vector_store.recent_item_ids(probe_limit).unwrap_or_default();
        if probe_ids.is_empty() {
            return Ok(ContradictionHuntReport {
                vector_store_available: true,
                probes_scanned: 0,
                pairs_screened: 0,
                proposed: vec![],
                borderline: vec![],
                deduplicated: 0,
            });
        }

        // Durable dedup set: every drawer pair already joined by a
        // contradicts tunnel, any lifecycle, tombstoned included.
        let pair_key = |a: &str, b: &str| -> String {
            if a < b { format!("{}||{}", a, b) } else { format!("{}||{}", b, a) }
        };
        let mut settled_pairs: std::collections::HashSet<String> =
            std::collections::HashSet::new();
        for tunnel in estate.all_tunnels().map_err(remap_err)? {
            if tunnel.kind == TunnelKind::Contradicts {
                if let (Some(s), Some(t)) =
                    (tunnel.source_drawer_id.as_deref(), tunnel.target_drawer_id.as_deref())
                {
                    settled_pairs.insert(pair_key(s, t));
                }
            }
        }

        // kNN candidate mining, canonical-pair deduplicated.
        //
        // Lane 1 — drawer-keyed rows under the caller's `model_id`. Rows
        // whose item is not in this lane fail `get_vector` and fall through.
        let mut candidate_pairs: Vec<(String, String)> = Vec::new();
        let mut seen_pairs: std::collections::HashSet<String> =
            std::collections::HashSet::new();
        for probe_id in &probe_ids {
            let probe_engram = match vector_store.get_vector(probe_id, model_id) {
                Ok(Some(e)) => e,
                _ => continue,
            };
            let matches = match vector_store.find_nearest(&probe_engram, model_id, 5) {
                Ok(m) => m,
                Err(_) => continue,
            };
            for m in matches {
                if m.item_id == *probe_id || m.distance > proximity_threshold {
                    continue;
                }
                let key = pair_key(probe_id, &m.item_id);
                if !seen_pairs.insert(key) {
                    continue;
                }
                let (a, b) = if *probe_id < m.item_id {
                    (probe_id.clone(), m.item_id.clone())
                } else {
                    (m.item_id.clone(), probe_id.clone())
                };
                candidate_pairs.push((a, b));
            }
        }

        // Drawer contents + node names. Loaded before lane 2 because the corpus
        // lane needs probe-drawer content to build its BM25 query; the screen
        // below reuses the same map.
        let all_drawers: Vec<locus_kit::drawer::Drawer> =
            estate.all_drawers().map_err(remap_err)?;
        let node_names = build_node_name_map(self.node_stores.get(handle), &all_drawers);
        let drawers_by_id: std::collections::HashMap<&str, &locus_kit::drawer::Drawer> =
            all_drawers.iter().map(|d| (d.id.as_str(), d)).collect();

        // Lane 2 — the corpus lane, the ONLY lane a production estate populates
        // (the encode drain writes chunk-keyed rows under the corpus provider's
        // model_id, so lane 1's drawer-keyed `get_vector` finds nothing there).
        // Candidate generation here is LEXICAL, via the corpus's persistent BM25
        // inverted index — NOT vectors. A contradiction is two statements about
        // the same thing that disagree; "about the same thing" is what BM25
        // answers cheaply (sub-linear WAND/BMW over posting lists), and it is
        // the same shared-term similarity the conflict-cue screen keys on. The
        // vector lanes were unusable at estate scale — the binary SimHash space
        // is degenerate (109k estate: 748 chunks within Hamming ≤ 2, true twin
        // at rank #399) and a whole-partition float scan is ~3 s/probe. BM25
        // returns SOURCE (drawer) IDs directly. `seen_pairs` keys on drawer IDs,
        // so both lanes dedupe together. Mirrors the Swift lane-2 block.
        if let Some(corpus) = self.corpus_kits.get(handle) {
            // Shared-content 1.1: vector item IDs ARE Drawer IDs — the probe
            // IDs are the probe drawers directly, no chunk→drawer remap.
            let mut probe_drawer_ids: Vec<String> = probe_ids.to_vec();
            probe_drawer_ids.sort();
            probe_drawer_ids.dedup();
            for pd_id in &probe_drawer_ids {
                let pd = match drawers_by_id.get(pd_id.as_str()) {
                    Some(d) => *d,
                    None => continue,
                };
                if pd.content.is_empty() {
                    continue;
                }
                // Cap the query length so per-probe cost is independent of body size.
                let query: String = pd
                    .content
                    .chars()
                    .take(HUNT_BM25_QUERY_CHAR_LIMIT)
                    .collect();
                let hits = corpus.bm25_top_k_by_source(&query, HUNT_BM25_CANDIDATE_K);
                for (source_id, _score) in hits {
                    if source_id == *pd_id {
                        continue;
                    }
                    let key = pair_key(pd_id, &source_id);
                    if !seen_pairs.insert(key) {
                        continue;
                    }
                    let (a, b) = if *pd_id < source_id {
                        (pd_id.clone(), source_id)
                    } else {
                        (source_id, pd_id.clone())
                    };
                    candidate_pairs.push((a, b));
                }
            }
        }

        let probes_scanned = probe_ids.len();
        let mut pairs_screened = 0usize;
        let mut deduplicated = 0usize;
        let mut proposed: Vec<ProposedContradiction> = Vec::new();
        let mut borderline: Vec<BorderlineContradiction> = Vec::new();

        for (a_id, b_id) in candidate_pairs {
            let (a, b) = match (drawers_by_id.get(a_id.as_str()), drawers_by_id.get(b_id.as_str())) {
                (Some(a), Some(b)) => (*a, *b),
                _ => continue,
            };
            if a.tombstoned_at.is_some() || b.tombstoned_at.is_some() {
                continue;
            }
            // Match BitmapEvaluator's default recall posture: callers
            // without an explicit sensitivity grant may only mine the Normal
            // tier (normal + elevated). Restricted/secret rows must not be
            // screened, proposed, or echoed as borderline snippets.
            if a.adjective_sensitivity().raw_value()
                > locus_kit::adjectives::AdjectiveSensitivity::Elevated.raw_value()
                || b.adjective_sensitivity().raw_value()
                    > locus_kit::adjectives::AdjectiveSensitivity::Elevated.raw_value()
            {
                continue;
            }
            // Incremental watermark: at least one side must be new enough.
            if let Some(watermark) = filed_after {
                if a.filed_at <= watermark && b.filed_at <= watermark {
                    continue;
                }
            }
            if settled_pairs.contains(&pair_key(&a.id, &b.id)) {
                deduplicated += 1;
                continue;
            }
            pairs_screened += 1;

            let cue = conflict_cue::evaluate(&a.content, &b.content);
            if cue.kind == conflict_cue::ConflictCueKind::None {
                continue;
            }

            if cue.score >= conflict_cue::STRONG_THRESHOLD {
                // Endpoint wings/rooms come from the node tree; a pair whose
                // endpoints cannot be resolved is skipped rather than filed
                // with fabricated coordinates.
                let (a_wing, a_room) = match node_names.get(&a.parent_node_id) {
                    Some(names) => names.clone(),
                    None => continue,
                };
                let (b_wing, b_room) = match node_names.get(&b.parent_node_id) {
                    Some(names) => names.clone(),
                    None => continue,
                };
                let mut frame = TunnelCaptureFrame::new(
                    a_wing,
                    a_room,
                    b_wing,
                    b_room,
                    format!("hunter: {} score={}", cue.kind.as_str(), cue.score),
                    "contradiction-hunter",
                );
                frame.source_drawer_id = Some(a.id.clone());
                frame.target_drawer_id = Some(b.id.clone());
                frame.kind = TunnelKind::Contradicts;
                frame.origin_class = TunnelOriginClass::Derived;
                frame.lifecycle = TunnelLifecycle::Proposed;
                let tunnel = estate.capture_tunnel(frame, now).map_err(remap_err)?;
                settled_pairs.insert(pair_key(&a.id, &b.id));
                proposed.push(ProposedContradiction {
                    tunnel_id: tunnel.id,
                    source_drawer_id: a.id.clone(),
                    target_drawer_id: b.id.clone(),
                    cue_kind: cue.kind.as_str().to_string(),
                    score: cue.score,
                });
            } else if cue.score >= conflict_cue::BORDERLINE_THRESHOLD {
                borderline.push(BorderlineContradiction {
                    source_drawer_id: a.id.clone(),
                    target_drawer_id: b.id.clone(),
                    cue_kind: cue.kind.as_str().to_string(),
                    score: cue.score,
                    source_snippet: a.content.chars().take(HUNT_SNIPPET_LIMIT).collect(),
                    target_snippet: b.content.chars().take(HUNT_SNIPPET_LIMIT).collect(),
                });
            }
        }

        Ok(ContradictionHuntReport {
            vector_store_available: true,
            probes_scanned,
            pairs_screened,
            proposed,
            borderline,
            deduplicated,
        })
    }

    /// Run one typed sweep and file a PROPOSED `contradicts` tunnel for
    /// every proven finding that survives the dedup contract (DCP M5 —
    /// mirrors Swift `proposeConflictTunnels(in:)`).
    ///
    /// Dedup contract (F14/F15): any live (active or proposed)
    /// contradicts tunnel between the pair suppresses; a WITHDRAWN
    /// typed proposal suppresses only the SAME rule@version (rejection
    /// durable, F14) — a registry version bump files a NEW instance
    /// (F15); a withdrawn LEXICAL (hunter) tunnel does not suppress a
    /// typed proof. `now` is epoch milliseconds.
    ///
    /// Sensitivity ceiling: a proven finding whose endpoint sensitivity
    /// ceiling exceeds Elevated is never proposed — the same policy, the
    /// same raw-value comparison, and the same position ahead of the dedup
    /// check that the lexical hunter applies before it screens a pair.
    /// Ceiling skips are counted apart from dedup suppressions so the
    /// gate's activity is visible in the report.
    pub fn propose_conflict_tunnels(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<crate::brain::conflict_projection_sweep::ConflictTunnelProposalReport, VerbDispatchError>
    {
        use crate::brain::conflict_projection_sweep::{pair_key, ConflictTunnelProposalReport};
        use locus_kit::frames::TunnelCaptureFrame;
        use locus_kit::tunnel_operational::{TunnelKind, TunnelLifecycle, TunnelOriginClass};

        const LABEL_PREFIX: &str = "dcp: ";

        let sweep = self.conflict_projection_sweep(handle)?;
        let estate = self.estate_for_verb(handle)?;
        let remap_err = |e: locus_kit::error::LocusKitError| {
            VerbDispatchError::from(remap("propose_conflict_tunnels", "", e))
        };

        let mut live_pairs: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut withdrawn_typed_labels: std::collections::HashMap<
            String,
            Vec<String>,
        > = std::collections::HashMap::new();
        for tunnel in estate.all_tunnels().map_err(remap_err)? {
            if tunnel.kind != TunnelKind::Contradicts {
                continue;
            }
            let (Some(s), Some(t)) =
                (tunnel.source_drawer_id.as_ref(), tunnel.target_drawer_id.as_ref())
            else {
                continue;
            };
            let pair = pair_key(s, t);
            match tunnel.lifecycle() {
                TunnelLifecycle::Active | TunnelLifecycle::Proposed => {
                    live_pairs.insert(pair);
                }
                TunnelLifecycle::Withdrawn | TunnelLifecycle::Superseded => {
                    if tunnel.label.starts_with(LABEL_PREFIX) {
                        withdrawn_typed_labels.entry(pair).or_default().push(tunnel.label.clone());
                    }
                }
            }
        }

        let all_drawers = estate.all_drawers().map_err(remap_err)?;
        let node_names = build_node_name_map(self.node_stores.get(handle), &all_drawers);
        let drawers_by_id: std::collections::HashMap<&str, &locus_kit::drawer::Drawer> =
            all_drawers.iter().map(|d| (d.id.as_str(), d)).collect();

        let mut proposed = Vec::new();
        let mut suppressed = 0usize;
        let mut ceiling_skipped = 0usize;
        for finding in &sweep.proven {
            let outcome = &finding.outcome;
            if outcome.source_drawer_ids.len() != 2 {
                continue;
            }
            // Match BitmapEvaluator's default recall posture: callers
            // without an explicit sensitivity grant may only mine the Normal
            // tier (normal + elevated). Restricted/secret rows must not be
            // screened, proposed, or echoed as borderline snippets.
            //
            // Compare the RAW ceiling, never a decoded tier: `from_raw`
            // coerces every unrecognised raw — scale-gapped intermediates
            // and beyond-spec values alike — to Normal, so a decode-based
            // check would wave through exactly the rows this gate exists to
            // stop. The sweep already computed this ceiling as the MAX
            // endpoint sensitivity, and it fails closed on an unresolvable
            // endpoint.
            if finding.sensitivity_ceiling_raw
                > locus_kit::adjectives::AdjectiveSensitivity::Elevated.raw_value()
            {
                ceiling_skipped += 1;
                continue;
            }
            let (a, b) = (&outcome.source_drawer_ids[0], &outcome.source_drawer_ids[1]);
            let pair = pair_key(a, b);
            let renewal_key =
                format!("{LABEL_PREFIX}{}@{}", outcome.rule_id, outcome.rule_version);
            let label = format!("{renewal_key} result={}", outcome.result_id);
            if live_pairs.contains(&pair) {
                suppressed += 1;
                continue;
            }
            if withdrawn_typed_labels
                .get(&pair)
                .is_some_and(|labels| labels.iter().any(|l| l.starts_with(&renewal_key)))
            {
                // F14: exact repeat of a rejected proof stays rejected;
                // a different rule VERSION misses this prefix (F15).
                suppressed += 1;
                continue;
            }
            // Endpoint coordinates from the node tree — skip rather than
            // file fabricated coordinates (hunter posture).
            let (Some(da), Some(db)) =
                (drawers_by_id.get(a.as_str()), drawers_by_id.get(b.as_str()))
            else {
                continue;
            };
            let (Some((a_wing, a_room)), Some((b_wing, b_room))) = (
                node_names.get(&da.parent_node_id),
                node_names.get(&db.parent_node_id),
            ) else {
                continue;
            };
            let mut frame = TunnelCaptureFrame::new(
                a_wing.clone(),
                a_room.clone(),
                b_wing.clone(),
                b_room.clone(),
                label,
                "conflict-projection",
            );
            frame.source_drawer_id = Some(a.clone());
            frame.target_drawer_id = Some(b.clone());
            frame.kind = TunnelKind::Contradicts;
            frame.origin_class = TunnelOriginClass::Derived;
            frame.lifecycle = TunnelLifecycle::Proposed;
            let tunnel = estate.capture_tunnel(frame, now).map_err(remap_err)?;
            live_pairs.insert(pair);
            proposed.push(tunnel.id);
        }
        Ok(ConflictTunnelProposalReport {
            sweep,
            proposed_tunnel_ids: proposed,
            suppressed,
            ceiling_skipped,
        })
    }

    /// File the ACTIVE `supersedes` tunnels for a meeting-capture
    /// report's `Replaces decision` references (F22 — mirrors Swift
    /// `fileSupersessions(in:report:now:)`): the replaced fact's source
    /// drawer is superseded by the replacing fact's source drawer.
    /// Returns (filed tunnel ids, unresolved replaced-fact ids).
    pub fn file_supersessions(
        &self,
        handle: &EstateHandle,
        report: &crate::brain::meeting_decision_capture::MeetingDecisionCaptureReport,
        now: i64,
    ) -> Result<(Vec<String>, Vec<String>), VerbDispatchError> {
        use locus_kit::frames::TunnelCaptureFrame;
        use locus_kit::tunnel_operational::{TunnelKind, TunnelLifecycle, TunnelOriginClass};
        use substrate_ml::meeting_decision_extractor::MEETING_DECISION_EXTRACTOR_ID;

        if report.replaces_by_fact_id.is_empty() {
            return Ok((Vec::new(), Vec::new()));
        }
        let estate = self.estate_for_verb(handle)?;
        let remap_err = |e: locus_kit::error::LocusKitError| {
            VerbDispatchError::from(remap("file_supersessions", "", e))
        };
        let facts_by_id: std::collections::HashMap<String, locus_kit::kg_fact::KGFact> = estate
            .all_kg_facts_including_retired()
            .map_err(remap_err)?
            .into_iter()
            .map(|f| (f.id.clone(), f))
            .collect();
        let all_drawers = estate.all_drawers().map_err(remap_err)?;
        let node_names = build_node_name_map(self.node_stores.get(handle), &all_drawers);
        let drawers_by_id: std::collections::HashMap<&str, &locus_kit::drawer::Drawer> =
            all_drawers.iter().map(|d| (d.id.as_str(), d)).collect();

        let mut filed = Vec::new();
        let mut unresolved = Vec::new();
        let mut refs: Vec<(&String, &String)> = report.replaces_by_fact_id.iter().collect();
        refs.sort();
        for (fact_id, replaced_fact_id) in refs {
            let (Some(new_fact), Some(old_fact)) =
                (facts_by_id.get(fact_id), facts_by_id.get(replaced_fact_id))
            else {
                unresolved.push(replaced_fact_id.clone());
                continue;
            };
            let (Some(nd), Some(od)) = (
                drawers_by_id.get(new_fact.source_drawer_id.as_str()),
                drawers_by_id.get(old_fact.source_drawer_id.as_str()),
            ) else {
                unresolved.push(replaced_fact_id.clone());
                continue;
            };
            let (Some((n_wing, n_room)), Some((o_wing, o_room))) = (
                node_names.get(&nd.parent_node_id),
                node_names.get(&od.parent_node_id),
            ) else {
                unresolved.push(replaced_fact_id.clone());
                continue;
            };
            // Source = the SUPERSEDING drawer, target = the superseded
            // one. ACTIVE because the controlled grammar's Replaces line
            // IS the acceptance.
            let mut frame = TunnelCaptureFrame::new(
                n_wing.clone(),
                n_room.clone(),
                o_wing.clone(),
                o_room.clone(),
                format!("{MEETING_DECISION_EXTRACTOR_ID}: replaces {replaced_fact_id}"),
                "conflict-projection",
            );
            frame.source_drawer_id = Some(new_fact.source_drawer_id.clone());
            frame.target_drawer_id = Some(old_fact.source_drawer_id.clone());
            frame.kind = TunnelKind::Supersedes;
            frame.origin_class = TunnelOriginClass::Derived;
            frame.lifecycle = TunnelLifecycle::Active;
            let tunnel = estate.capture_tunnel(frame, now).map_err(remap_err)?;
            filed.push(tunnel.id);
        }
        Ok((filed, unresolved))
    }

    /// Deterministic KGFact id for an extracted decision (replay-safe).
    /// Mirrors Swift `GeniusLocusKit.meetingDecisionFactID`.
    pub fn meeting_decision_fact_id(
        source_drawer_id: &str,
        subject: &str,
        predicate: &str,
        object: &str,
    ) -> String {
        use substrate_ml::meeting_decision_extractor::MEETING_DECISION_EXTRACTOR_ID;
        let input = format!(
            "{MEETING_DECISION_EXTRACTOR_ID}|{source_drawer_id}|{subject}|{predicate}|{object}"
        );
        substrate_kernel::sha256::hash(input.as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }

    /// Parse `transcript` under the v0.1 registry and file each accepted
    /// decision as an ACTIVE KGFact anchored to `source_drawer_id` (DCP
    /// M6 filing seam — mirrors Swift `captureMeetingDecisions(in:)`).
    ///
    /// Filing posture: extracted facts file ACTIVE — the controlled
    /// register is strict enough that an accepted line IS an assertion,
    /// and the M0 §2 proof floor requires both facts active; what stays
    /// PROPOSED downstream is the contradicts tunnel (M5), not the fact.
    /// Replay safety: deterministic ids + a pre-insert existence check,
    /// so re-extracting the same transcript skips already-filed ids.
    /// `now` is the filing instant in epoch milliseconds (the LocusKit
    /// Rust clock).
    pub fn capture_meeting_decisions(
        &self,
        handle: &EstateHandle,
        transcript: &str,
        source_drawer_id: &str,
        now: i64,
    ) -> Result<crate::brain::meeting_decision_capture::MeetingDecisionCaptureReport, VerbDispatchError>
    {
        use crate::brain::meeting_decision_capture::MeetingDecisionCaptureReport;
        use locus_kit::kg_fact::KGFact;
        use substrate_ml::conflict_projection::ConflictRuleRegistry;
        use substrate_ml::meeting_decision_extractor::extract;

        let estate = self.estate_for_verb(handle)?;
        let remap_err = |e: locus_kit::error::LocusKitError| {
            VerbDispatchError::from(remap("capture_meeting_decisions", "", e))
        };
        let extraction = extract(transcript, &ConflictRuleRegistry::v01());

        // Existing-id set for replay dedup (retired included — a
        // withdrawn decision must not silently refile).
        let existing: std::collections::HashSet<String> = estate
            .all_kg_facts_including_retired()
            .map_err(remap_err)?
            .into_iter()
            .map(|f| f.id)
            .collect();

        let mut filed = Vec::new();
        let mut skipped = Vec::new();
        let mut replaces = std::collections::HashMap::new();
        for decision in &extraction.decisions {
            let id = Self::meeting_decision_fact_id(
                source_drawer_id,
                &decision.entity,
                &decision.dimension,
                &decision.raw_value,
            );
            if let Some(replaced) = &decision.replaces_id {
                replaces.insert(id.clone(), replaced.clone());
            }
            if existing.contains(&id) {
                skipped.push(id);
                continue;
            }
            estate
                .add_kg_fact(&KGFact::new(
                    id.clone(),
                    decision.entity.clone(),
                    // The rule's canonical dimension spelling, so
                    // projection's dimension_key(predicate) round-trips.
                    decision.dimension.clone(),
                    decision.raw_value.clone(),
                    source_drawer_id.to_string(),
                    now,
                ))
                .map_err(remap_err)?;
            filed.push(id);
        }
        Ok(MeetingDecisionCaptureReport {
            extraction,
            filed_fact_ids: filed,
            skipped_existing_ids: skipped,
            replaces_by_fact_id: replaces,
        })
    }

    /// Run one typed conflict-projection sweep over `handle` (DCP M3 —
    /// the proving lane; the lexical hunter above proposes). Pure read:
    /// no tunnel proposals, no writes. Mirrors Swift
    /// `GeniusLocusKit.conflictProjectionSweep(in:)`.
    pub fn conflict_projection_sweep(
        &self,
        handle: &EstateHandle,
    ) -> Result<crate::brain::conflict_projection_sweep::ConflictProjectionSweepReport, VerbDispatchError>
    {
        use crate::brain::conflict_projection_sweep::{pair_key, run_sweep, SWEEP_DEFAULT_BUCKET_CAP};
        use locus_kit::tunnel_operational::{TunnelKind, TunnelLifecycle};
        use substrate_ml::conflict_projection::ConflictRuleRegistry;

        let estate = self.estate_for_verb(handle)?;
        let remap_err = |e: locus_kit::error::LocusKitError| {
            VerbDispatchError::from(remap("conflict_projection_sweep", "", e))
        };
        let facts = estate.all_kg_facts().map_err(remap_err)?;

        // One drawer walk for both per-drawer inputs: validity instants
        // and sensitivity ceilings. LocusKit's Rust clock is
        // epoch-millisecond; the sweep core's identity domain is whole
        // seconds (KI-003) — the division happens HERE, at the seam.
        let mut event_time_seconds = std::collections::HashMap::new();
        let mut sensitivity_raw = std::collections::HashMap::new();
        for drawer in estate.all_drawers().map_err(remap_err)? {
            event_time_seconds.insert(drawer.id.clone(), drawer.event_time.div_euclid(1000));
            sensitivity_raw
                .insert(drawer.id.clone(), drawer.adjective_sensitivity().raw_value());
        }

        // Accepted supersession: an ACTIVE supersedes tunnel between the
        // two source drawers (review-accept sets lifecycle Active).
        let mut accepted_pairs = std::collections::HashSet::new();
        for tunnel in estate.all_tunnels().map_err(remap_err)? {
            if tunnel.kind == TunnelKind::Supersedes
                && tunnel.lifecycle() == TunnelLifecycle::Active
            {
                if let (Some(s), Some(t)) =
                    (tunnel.source_drawer_id.as_ref(), tunnel.target_drawer_id.as_ref())
                {
                    accepted_pairs.insert(pair_key(s, t));
                }
            }
        }

        Ok(run_sweep(
            &facts,
            &event_time_seconds,
            &sensitivity_raw,
            &accepted_pairs,
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        ))
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

        // Step 0.5 — Pre-read for dataset cascade (MX-TAB-4).
        //
        // The storage expunge (step 1) zeroes the content blob, so any
        // DatasetHandleContent JSON must be decoded BEFORE tombstoning. A
        // pre-read failure or non-dataset kind silently yields None; step 1
        // will surface DrawerNotFound if the row genuinely doesn't exist.
        let dataset_id_to_erase: Option<uuid::Uuid> = estate
            .drawer_by_id(row_id)
            .ok()
            .flatten()
            .and_then(|d| {
                // ContentKind is imported at the top of this file.
                if d.content_kind() != ContentKind::Dataset {
                    return None;
                }
                locus_kit::dataset_handle::DatasetHandleContent::decode(&d.content)
                    .ok()
                    .map(|h| h.dataset_id)
            });

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
            // Resolve the full lineage chain so the cross-kit vector delete
            // fans out to ALL lineage members, not just the head row.
            // After the storage expunge (step 1) tombstones and
            // content-scrubs every lineage member, each member may carry
            // its own Corpus and VectorStore entries (BM25 postings,
            // semantic embeddings, distillation-lane fingerprints) that
            // must also be deleted — otherwise those entries leak
            // content-derived representations past the destruction
            // contract (secfix/ws2-coredelete).
            //
            // Mirrors Swift VerbSurface.expunge lines 739–780:
            //   let lineageIds = try await estate.lineageChain(for: frame.rowID)
            //   let idsToDelete = lineageIds.isEmpty ? [frame.rowID] : lineageIds
            //   for deleteId in idsToDelete { corpus.removeContent + vs.deleteAll… }
            //
            // lineage_chain returns all IDs sharing the lineageID column,
            // including the head row itself; the loop therefore covers the
            // head plus every predecessor in one pass. An empty result
            // (no lineageID or row not found) falls back to [row_id] to
            // guarantee the head row is always processed.
            let ids_to_delete: Vec<String> = match estate.lineage_chain(row_id) {
                Ok(chain) if !chain.is_empty() => chain,
                _ => vec![row_id.to_string()],
            };

            let step2_result: Result<(), VerbDispatchError> = (|| {
                for delete_id in &ids_to_delete {
                    if let Some(ref c) = corpus {
                        // Clear the engine's derived state for this lineage
                        // member by exact key (BM25 postings + Drawer-keyed
                        // vectors). Each lineage member's canonical text
                        // lives only in its own Drawer row — no second copy.
                        c.remove_content(delete_id).map_err(|e| {
                            VerbDispatchError::Verb(VerbError::CrossKitVectorDeleteFailed {
                                row_id: delete_id.to_string(),
                                reason: format!("{:?}", e),
                            })
                        })?;
                    }
                    if let Some(ref vs) = vector_store {
                        // Distillation lane scrub (SPEC_DISTILLATION_STORAGE
                        // §7.2/§8): the distillation-features-v1 entry is
                        // keyed by the SOURCE drawer id. Each lineage member
                        // is a source drawer and may carry its own entry.
                        // UNCONDITIONAL on the corpus handle — the lane
                        // exists independently of the semantic embedding lane,
                        // and an orphaned structural fingerprint would leak a
                        // content-derived signature past the destruction
                        // contract. Runs BEFORE the corpus-model delete so the
                        // lane is scrubbed even when the corpus-less branch
                        // below would fail the semantic-lane delete. Mirrors
                        // the Swift VerbSurface.expunge ordering.
                        vs.delete_all_vectors(
                            delete_id,
                            crate::brain::distillation_cycle::DISTILLATION_LANE_MODEL_ID,
                        )
                        .map_err(|e| {
                            VerbDispatchError::Verb(VerbError::CrossKitVectorDeleteFailed {
                                row_id: delete_id.to_string(),
                                reason: format!("{:?}", e),
                            })
                        })?;
                        if let Some(ref c) = corpus {
                            // For .glk estates: the standalone VectorStore's
                            // resident array must also be invalidated (it
                            // shares the backing table with the corpus's
                            // internal VectorStore but maintains a separate
                            // in-memory live/tombstone bitmap). Derive
                            // modelID from the corpus.
                            let model_id = c.model_id();
                            vs.delete_all_vectors(delete_id, &model_id).map_err(|e| {
                                VerbDispatchError::Verb(VerbError::CrossKitVectorDeleteFailed {
                                    row_id: delete_id.to_string(),
                                    reason: format!("{:?}", e),
                                })
                            })?;
                        } else {
                            // Standalone VectorStore registered without a
                            // Corpus (not a standard provisioning path, but
                            // handled defensively). The modelID is not
                            // available; raise a clear error rather than
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

        // Step 2.5 — Dataset table cascade (MX-TAB-4).
        //
        // When the erased drawer is a dataset handle (ContentKind::Dataset),
        // drop the backing dataset table and append a supplementary
        // "datasetTableDrop" audit event. Both the handle erase (sealed in
        // step 3 as "tombstone") and the table drop land in the audit log for
        // the same drawer row so the full erase is auditable.
        //
        // Semantics:
        //   - `drop_dataset` uses DROP TABLE IF EXISTS — a missing table is a
        //     no-op, not an error.
        //   - A `DatasetStore` may not be available on all backends; if
        //     `dataset_store()` errors the cascade is skipped silently.
        //   - Cascade failures (non-featureGated errors) propagate so callers
        //     learn of partial erase. Step 3 is NOT reached on cascade failure.
        if let Some(dataset_id) = dataset_id_to_erase {
            if let Some(storage) = self.storages.get(handle).cloned() {
                if let Ok(ds) = storage.dataset_store() {
                    ds.drop_dataset(dataset_id).map_err(|e| {
                        VerbDispatchError::Verb(VerbError::CrossKitVectorDeleteFailed {
                            row_id: row_id.to_string(),
                            reason: format!(
                                "dataset table drop failed for dataset_id {}: {:?}",
                                dataset_id, e
                            ),
                        })
                    })?;
                    // Append a supplementary audit event recording the table drop.
                    // `append_supplementary_audit` computes the SHA-256 content-ID
                    // internally (substrate_lib is a LocusKit dep, not a GLK dep —
                    // so AuditEvent construction stays in the LocusKit layer).
                    //
                    // Audit append failure after a successful table drop:
                    // log but do NOT abort — proceed to step 3 so the
                    // tombstone audit still seals. Mirrors Swift: `do { ... }
                    // catch { Self.verbLog.error(...) }` pattern.
                    if let Err(e) = estate.append_supplementary_audit(
                        &unsealed_event,
                        "datasetTableDrop",
                        &format!("dataset table dropped on handle erase: {}", dataset_id),
                    ) {
                        eprintln!(
                            "[glk-expunge] datasetTableDrop audit append failed dataset_id={} error={:?}",
                            dataset_id, e
                        );
                    }
                }
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
    ///   - Re-attempt the cross-kit vector+corpus delete. This includes:
    ///       * corpus.remove_content — scrubs BM25 + semantic-embedding index
    ///       * VectorStore.delete_all_vectors(distillation-features-v1) — scrubs
    ///         the structural fingerprint lane (unconditional on corpus presence)
    ///       * VectorStore.delete_all_vectors(corpus model id) — scrubs the
    ///         semantic embedding lane (requires corpus for model id)
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
            // corpus.remove_content scrubs chunk text + clears BM25+vector
            // index entries; VectorStore.delete_all_vectors clears the resident
            // in-memory bitmap for each lane.
            //
            // The distillation-features-v1 lane is scrubbed FIRST, UNCONDITIONAL
            // on the corpus handle — the structural fingerprint lane is independent
            // of the semantic embedding lane, and an orphaned fingerprint leaks a
            // content-derived signature past the destruction contract
            // (SPEC_DISTILLATION_STORAGE §7.2/§8; Wave-1 parity fix, addendum).
            // Mirrors the ordering in the main expunge path (coordinator.rs step 2).
            //
            // When neither corpus nor vectorStore is registered (locusOnly estate),
            // no cross-kit cleanup is needed — the audit gap is closed below
            // without attempting a delete (mirrors Swift runExpungeIntegritySweep
            // locusOnly branch, secfix/ws2-coredelete §Cluster D).
            let delete_result: Result<(), String> = (|| {
                if corpus.is_none() && vector_store.is_none() {
                    // locusOnly estate — no cross-kit stores registered.
                    // Log at info; the audit gap is closed below as remediated.
                    return Ok(());
                }
                if let Some(ref c) = corpus {
                    // Shared-content 1.1: clear derived state (no second copy
                    // exists to scrub — the Drawer row is the only text home).
                    c.remove_content(row_id)
                        .map_err(|e| format!("corpus.remove_content failed: {:?}", e))?;
                }
                if let Some(ref vs) = vector_store {
                    // Distillation lane scrub: the distillation-features-v1 entry
                    // is keyed by the SOURCE drawer id. Unconditional on corpus —
                    // the lane exists independently of the semantic embedding lane.
                    // Runs before the corpus-model delete so the fingerprint lane
                    // is scrubbed even when the corpus-less branch below would
                    // fail the semantic-lane delete.
                    vs.delete_all_vectors(
                        row_id,
                        crate::brain::distillation_cycle::DISTILLATION_LANE_MODEL_ID,
                    )
                    .map_err(|e| {
                        format!(
                            "VectorStore.delete_all_vectors(distillation-features-v1) failed: {:?}",
                            e
                        )
                    })?;
                    if let Some(ref c) = corpus {
                        let model_id = c.model_id();
                        vs.delete_all_vectors(row_id, &model_id)
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
        to_wing: Option<&str>,
        to_lattice: Option<LatticeAnchor>,
    ) -> Result<(), VerbDispatchError> {
        if to_room.is_none() && to_wing.is_none() && to_lattice.is_none() {
            return Err(VerbError::EmptyReanchor {
                row_id: row_id.to_string(),
            }
            .into());
        }
        let estate = self.estate_for_verb(handle)?;
        estate
            .reanchor(row_id, to_room, to_wing, to_lattice)
            .map_err(|e| remap("reanchor", &uuid_to_str(&handle.estate_uuid), e).into())
    }

    // MARK: - reanchor_anchor

    /// Update a drawer's lattice anchor with an explicit audit identity and
    /// reason, rather than the generic estate-owner attribution `reanchor`
    /// (above) stamps. Twin of Swift's `Estate.reanchorAnchor` — for
    /// automated tool-driven repairs (e.g. `moot_reclassify_fdc`) that must
    /// not misattribute their audit event to the estate owner or a generic
    /// reason string. Like `reanchor`, `now` is generated internally by the
    /// LocusKit layer rather than threaded through this wrapper.
    pub fn reanchor_anchor(
        &self,
        handle: &EstateHandle,
        row_id: &str,
        to_lattice: LatticeAnchor,
        changed_by: &str,
        reason: &str,
    ) -> Result<(), VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .reanchor_anchor(row_id, to_lattice, changed_by, reason)
            .map_err(|e| remap("reanchor_anchor", &uuid_to_str(&handle.estate_uuid), e).into())
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
        frame: GlkLearnFrame,
        now: i64,
    ) -> Result<locus_kit::learned_reference::LearnedReference, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        // Map GLK-level LearnFrame to the LocusKit-internal LearnFrame at the
        // dispatch boundary — same pattern as ProposeFrame → LocusProposeFrame.
        // Field layout is identical; translation is a field-level destructure.
        let locus_frame = LocusLearnFrame {
            source: frame.source,
            handle: frame.handle,
            mode: frame.mode,
            refresh_policy: frame.refresh_policy,
        };
        estate.learn(locus_frame, now).map_err(|e| remap("learn", &uuid_to_str(&handle.estate_uuid), e).into())
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
        // The GLK Brain-layer ProposeFrame is a distinct type that carries a
        // String routing kind, not the substrate's three provenance axes, so this
        // boundary stamps their established defaults (Human / DreamingDaemon /
        // Null) — the raw-0 values the LocusKit propose verb applies for an unset
        // frame — keeping the operational bitmap byte-identical at the boundary.
        let locus_frame = LocusProposeFrame {
            target: frame.target,
            kind: locus_kind,
            justification: frame.justification,
            confirmation: locus_kit::proposal_operational::ProposalConfirmationSource::Human,
            generated_by: locus_kit::proposal_operational::ProposalGeneratedByClass::DreamingDaemon,
            confidence: locus_kit::proposal_operational::ProposalConfidenceBucket::Null,
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
        // Case-insensitive substring match on subject OR object. Lowercase
        // BOTH the needle and the haystack (mirrors Swift recallKGFactTimeline,
        // which lowercases entity + subject + object). The prior code matched
        // the original-case subject/object against a caller-lowered entity, so
        // `"Voss".contains("voss")` was false and any capitalised entity filter
        // returned zero results.
        if let Some(e) = entity {
            let needle = e.to_lowercase();
            facts.retain(|f| {
                f.subject.to_lowercase().contains(&needle)
                    || f.object.to_lowercase().contains(&needle)
            });
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

    // MARK: - tombstoned_lineage_ids

    /// The set of lineage IDs whose drawer rows have been permanently erased
    /// (tombstoned via the `expunge` verb — cluster C: `tombstoned_at IS NOT NULL`).
    ///
    /// Uses `Estate::all_drawers()`, which is a full-corpus scan that explicitly
    /// INCLUDES tombstoned rows. The recall pipeline's `live_rows` pre-filters
    /// `tombstoned_at IS NULL`, so cluster C rows are invisible to any
    /// `recall`-based query. This method goes through `all_drawers` to surface
    /// them, filters for rows where `tombstoned_at` is `Some`, and returns the
    /// distinct lineage IDs — one entry per erased lineage.
    ///
    /// This is the B-1-compliant GLK passthrough: VaultKit reaches tombstoned
    /// rows through GeniusLocusKit (`EstateCoordinator`), never by importing
    /// LocusKit's `DrawerStore` directly. Parity of the Swift
    /// `GeniusLocusKit.tombstonedLineageIDs(_:)`.
    ///
    /// `now` is unused at the storage layer but kept in the signature so
    /// callers can pass it deterministically for future filtering needs without
    /// a signature change.
    pub fn tombstoned_lineage_ids(
        &self,
        handle: &EstateHandle,
    ) -> Result<std::collections::HashSet<uuid::Uuid>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        // Full-corpus scan including tombstoned rows. We filter for rows where
        // tombstoned_at is Some — these are cluster C (expunged via moot_erase_memory).
        // The cost is one full-corpus read per import run, which is acceptable
        // because erased drawers are rare and this is called once, not per-note.
        let all = estate
            .all_drawers()
            .map_err(|e| VerbDispatchError::from(remap("tombstoned_lineage_ids", "", e)))?;
        Ok(all
            .into_iter()
            .filter(|d| d.tombstoned_at.is_some())
            .map(|d| d.lineage_id)
            .collect())
    }

    // MARK: - add_kg_fact

    /// Capture a new KGFact in the estate addressed by `handle`.
    ///
    /// Allocates a UUID v4 id, constructs a `KGFact` with all-zero bitmaps,
    /// and delegates to `Estate::add_kg_fact`. Returns the stored fact so
    /// callers can retain the generated id. Mirrors the Swift
    /// `GeniusLocusKit.captureKGFact(_:subject:predicate:object:sourceDrawerID:now:)`.
    ///
    /// `now` is epoch milliseconds. Always pass the current time from
    /// the caller; never call time inside this method — keeps the coordinator deterministic.
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
    /// `now` is epoch milliseconds. `topic` and `embedding_model_id` are
    /// caller-supplied; callers that have no topic may pass `""`.
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

    // MARK: - active_drawers_after

    /// Bounded page of active (non-tombstoned) drawers ordered by `id`
    /// ascending, optionally starting strictly after `after_id`. Delegates
    /// to `Estate::active_drawers_after`. Used by `sweep_reindex_missing`
    /// (MEDIUM perf fix) to walk the drawers table in bounded,
    /// cursor-advancing pages instead of reloading the full table on
    /// every pass of a reindex backfill loop.
    pub fn active_drawers_after(
        &self,
        handle: &EstateHandle,
        after_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Drawer>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .active_drawers_after(after_id, limit)
            .map_err(|e| remap("active_drawers_after", "", e).into())
    }

    // MARK: - resolve_drawer_node_names

    /// Resolve `parent_node_id` values to human-readable `(wing, room)`
    /// display-name pairs using the estate's node tree.
    ///
    /// For each unique `parent_node_id` in `node_ids`, looks up the room
    /// node (depth 2) via the estate's `NodeStore`, then its parent wing
    /// node (depth 1). Returns a map keyed by `parent_node_id` whose
    /// values are `(wing_display_name, room_display_name)`. Missing or
    /// malformed IDs are silently omitted — callers should `unwrap_or_default`
    /// on lookup.
    ///
    /// Cost: one `get_node` per unique room + one per unique wing. The
    /// estate's fixed-depth tree (max depth 2) keeps the total bounded.
    ///
    /// Mirrors Swift `EstateCoordinator.resolveDrawerNodeNames(in:nodeIds:)`.
    pub fn resolve_drawer_node_names(
        &self,
        handle: &EstateHandle,
        node_ids: &[String],
    ) -> HashMap<String, (String, String)> {
        let ns = match self.node_stores.get(handle) {
            Some(ns) => ns,
            None => return HashMap::new(),
        };
        let mut result = HashMap::new();
        // Deduplicate input to avoid redundant lookups.
        let unique: std::collections::HashSet<&str> =
            node_ids.iter().map(|s| s.as_str()).collect();
        // Cache wing lookups — many rooms share a wing.
        let mut wing_cache: HashMap<String, String> = HashMap::new();
        for room_id_str in unique {
            let room_uuid = match uuid::Uuid::parse_str(room_id_str) {
                Ok(u) => u,
                Err(_) => continue,
            };
            let room_node = match ns.get_node(room_uuid) {
                Ok(Some(n)) => n,
                _ => continue,
            };
            let wing_name = if let Some(wing_uuid) = room_node.parent_id {
                let wing_id_str = wing_uuid.to_string();
                wing_cache
                    .entry(wing_id_str.clone())
                    .or_insert_with(|| {
                        ns.get_node(wing_uuid)
                            .ok()
                            .flatten()
                            .map(|n| n.display_name)
                            .unwrap_or_default()
                    })
                    .clone()
            } else {
                String::new()
            };
            result.insert(
                room_id_str.to_string(),
                (wing_name, room_node.display_name.clone()),
            );
        }
        result
    }

    // MARK: - glk_fingerprints_captured

    /// Fingerprints of every non-tombstoned drawer captured in the closed
    /// epoch-milliseconds window `[start_epoch, end_epoch]`, in
    /// HLC-ascending order within the window.
    ///
    /// The Moment lens (CognitionKit) folds these into an OR-reduced window
    /// signature and ranks comparison windows by Hamming proximity. Delegates
    /// to `Estate::fingerprints_captured_in`, which forwards to the backing
    /// `DrawerStore` — so aria-mcp and NeuronKit reach the per-window read
    /// through the GLK surface rather than touching the store directly
    /// (B-1 compliance). Mirrors the Swift
    /// `GeniusLocusKit.glkFingerprintsCaptured(in:window:)`.
    pub fn glk_fingerprints_captured(
        &self,
        handle: &EstateHandle,
        start_epoch: i64,
        end_epoch: i64,
    ) -> Result<Vec<substrate_types::fingerprint256::Fingerprint256>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .fingerprints_captured_in(start_epoch, end_epoch)
            .map_err(|e| remap("glk_fingerprints_captured", "", e).into())
    }

    // MARK: - fingerprint_bit_series

    /// Time-bucketed fingerprint bit-activity series for `bit` over the most
    /// recent `bucket_count` buckets of width `bucket_seconds` (a SECONDS width;
    /// the store scales it to ms internally), ending at `ending_at` (epoch
    /// milliseconds, epoch-millisecond instants — deterministic clock, never read system time).
    ///
    /// Top-level GLK surface for the Rhythm recipe. Delegates to
    /// `Estate::fingerprint_bit_series`, which passes through to
    /// `DrawerStore::fingerprint_bit_series`. Mirrors Swift
    /// `GeniusLocusKit.glkFingerprintBitSeries(in:bit:bucketSeconds:bucketCount:endingAt:)`
    /// (B-1 compliance — CognitionKit and NeuronKit call this, never the store directly).
    ///
    /// Returns `Err(VerbDispatchError)` for stale handles, `bit > 255`,
    /// or `bucket_seconds < 1`. Returns an empty `Vec` when `bucket_count == 0`.
    pub fn fingerprint_bit_series(
        &self,
        handle: &EstateHandle,
        bit: usize,
        bucket_seconds: i64,
        bucket_count: usize,
        ending_at: i64,
    ) -> Result<Vec<bool>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .fingerprint_bit_series(bit, bucket_seconds, bucket_count, ending_at)
            .map_err(|e| remap("fingerprint_bit_series", "", e).into())
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
    /// `GeniusLocusKit.auditLog(for:)` (Swift — the N+1 feedAuditLog is removed).
    ///
    /// Bug 4 fix: replaces the former N+1 per-drawer `feed_audit_log` +
    /// grow-only `audit_logs` HashMap pattern. The old approach loaded
    /// `all_drawers()` then called `audit_trail()` PER DRAWER, merged into
    /// an unbounded persistent G-Set. Now builds a transient log via the
    /// hydration bridge (same per-drawer walk, but the result is NOT
    /// accumulated into `self.audit_logs` — it is returned and dropped).
    /// This eliminates the unbounded RAM growth: each call pays O(N) once
    /// but does not leave a permanent residue. The full fix (direct
    /// AuditLog::iterate bypassing per-drawer) requires exposing Estate.store
    /// publicly, deferred to v1.1.
    pub fn current_audit_log(
        &self,
        handle: &EstateHandle,
    ) -> Result<crate::audit::UnifiedAuditLog, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        crate::hydration::feed_audit_log_from_estate(estate).map_err(|e| {
            VerbDispatchError::from(remap(
                "current_audit_log",
                &uuid_to_str(&handle.estate_uuid),
                e,
            ))
        })
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

    /// Verify the estate's audit chain AND surface the ingress-rejected
    /// entry count from the SAME freshly-replayed snapshot, read-only.
    ///
    /// AUDIT-ALERT-RESTORE (2026-07-09, Bob's option-1 ruling): additive
    /// sibling of `verify_audit_chain` — same replay, same verifier call,
    /// plus `UnifiedAuditLog::rejected_count()` off the SAME log build (no
    /// second O(N) replay). `verify_audit_chain` is left unchanged for its
    /// existing caller(s); this method exists because the maintenance
    /// reader adapter (`estate_maintenance_reader.rs`) needs both values
    /// to build the daemon's `AuditVerdict` and a second full replay per
    /// audit-check cycle would double the read cost for no benefit.
    pub fn verify_audit_chain_with_rejections(
        &self,
        handle: &EstateHandle,
    ) -> Result<(crate::audit::AuditChainReport, usize), VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        let log: crate::audit::UnifiedAuditLog =
            crate::hydration::feed_audit_log_from_estate(estate).map_err(|e| {
                VerbDispatchError::from(remap(
                    "verify_audit_chain_with_rejections",
                    &uuid_to_str(&handle.estate_uuid),
                    e,
                ))
            })?;
        let report = crate::audit::AuditChainVerifier::verify(&log);
        Ok((report, log.rejected_count()))
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

    // MARK: - graph cache + preference store (recall-scoring accelerators)

    /// Register a `GraphCache` for the given estate handle.
    ///
    /// The `matrixAware` recall lane reads this cache to populate the `graph`
    /// score column during the `unionBest` scoring pass. The cache must hold
    /// pre-built per-drawer graph centrality scores from the dreaming cycle; the
    /// recall path performs candidate-frontier lookups only and never triggers
    /// synchronous estate-wide graph traversal (spec §15).
    ///
    /// Re-registering replaces the existing entry. The `graph` column remains 0.0
    /// when no cache is registered — correct, not an error. Mirrors the Swift
    /// `GeniusLocusKit.registerGraphCache(_:for:)`.
    pub fn register_graph_cache(
        &mut self,
        handle: &EstateHandle,
        cache: Arc<dyn crate::recall::GraphCache>,
    ) {
        self.graph_caches.insert(*handle, cache);
    }

    /// The `GraphCache` registered for `handle`, if any. The `matrixAware` recall
    /// path reads this to populate the `graph` score column. Mirrors the Swift
    /// actor's `graphCaches[handle]` lookup.
    pub fn graph_cache(&self, handle: &EstateHandle) -> Option<&Arc<dyn crate::recall::GraphCache>> {
        self.graph_caches.get(handle)
    }

    /// Register a `PreferenceStore` for the given estate handle.
    ///
    /// The `matrixAware` recall lane reads this store to populate the
    /// `preference` score column during the `unionBest` scoring pass. The store
    /// must hold pre-trained per-drawer preference weights from the training
    /// daemon; the recall path performs candidate-frontier lookups only and never
    /// triggers synchronous preference model updates (spec §15).
    ///
    /// Re-registering replaces the existing entry. The `preference` column
    /// remains 0.0 when no store is registered — correct for a fresh estate.
    /// Mirrors the Swift `GeniusLocusKit.registerPreferenceStore(_:for:)`.
    pub fn register_preference_store(
        &mut self,
        handle: &EstateHandle,
        store: Arc<dyn crate::recall::PreferenceStore>,
    ) {
        self.preference_stores.insert(*handle, store);
    }

    /// The `PreferenceStore` registered for `handle`, if any. The `matrixAware`
    /// recall path reads this to populate the `preference` score column. Mirrors
    /// the Swift actor's `preferenceStores[handle]` lookup.
    pub fn preference_store(
        &self,
        handle: &EstateHandle,
    ) -> Option<&Arc<dyn crate::recall::PreferenceStore>> {
        self.preference_stores.get(handle)
    }

    /// Feed the unified audit log, rebuild the recall-scoring `MatrixTier`
    /// from it (both passes: F/O/C + T), and register the tier for `handle`.
    ///
    /// The on-demand counterpart to the hydration path's matrix rebuild —
    /// the Rust parity of the Swift `GeniusLocusKit.rebuildDerivedAccelerators(for:)`.
    /// `moot_dream` calls this so the `matrixAware` recall lane is live after a
    /// dreaming cycle rather than reading a stale (or absent) tier.
    ///
    /// Idempotent: feeding the same events is a G-Set no-op, and the
    /// loaded-then-folded tier equals a from-scratch rebuild (conformance-tested).
    ///
    /// PERSISTENCE: the matrix tier is read from its on-disk SQLite snapshot
    /// (`MatrixSnapshotStore`) and folded FORWARD over only the audit tail past
    /// the snapshot watermark — it is NOT recomputed from the whole audit log on
    /// every launch. A full rebuild runs only on cold start (no snapshot) or a
    /// stale format. After computing, the fresh tier is persisted so the next
    /// launch loads it. In-memory estates (where `storages` holds no backing
    /// storage) cannot persist, so they full-rebuild every time — the parity of
    /// Swift's `.inMemory` no-op mode. Mirrors Swift
    /// `GeniusLocusKit.rebuildDerivedAccelerators(for:now:)`.
    pub fn rebuild_derived_accelerators(
        &mut self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<(), VerbDispatchError> {
        // Step 1 — build a transient audit log snapshot (MatrixTier consumes
        // the bridged log, not raw storage events). Bug 4 fix: no longer
        // accumulates into the persistent audit_logs HashMap.
        let log = self.current_audit_log(handle)?;

        // Build the event_time map (audit row_id → authored-in-world epoch ms) so
        // the temporal (T) matrix pass keys off event_time, not the capture HLC —
        // all temporal-cognition primitives key off eventTime. A bulk
        // historical import stamps every capture with one HLC, so hlc-based lags
        // are all 0 and no causality pairs form; the real ordering lives in each
        // drawer's event_time. event_time and the fold's physical_time are both
        // epoch-ms, so it flows through directly. The row_id key mirrors
        // bridge_audit_event's `EntryUUID(row_uuid.to_be_bytes())`.
        let event_times: std::collections::HashMap<crate::audit::EntryUUID, i64> = {
            let estate = self.estate_for_verb(handle)?;
            let drawers = estate.all_drawers().map_err(|e| {
                VerbDispatchError::from(remap(
                    "rebuild_derived_accelerators",
                    &uuid_to_str(&handle.estate_uuid),
                    e,
                ))
            })?;
            drawers
                .iter()
                .filter_map(|d| {
                    uuid::Uuid::parse_str(&d.id).ok().map(|u| {
                        (
                            crate::audit::EntryUUID(u.as_u128().to_be_bytes()),
                            d.event_time,
                        )
                    })
                })
                .collect()
        };

        // The matrix snapshot store needs a durable backing storage. In-memory
        // estates don't retain one (storages holds only DrawerStore-backed
        // storages); they full-rebuild without persistence, as in Swift's
        // .inMemory mode.
        let Some(storage) = self.storages.get(handle).cloned() else {
            let tier = crate::matrix::MatrixTier::full_rebuild(&log, &event_times);
            self.register_matrix_tier(handle, tier);
            return Ok(());
        };

        let map_err = |e: persistence_kit::StorageError| -> VerbDispatchError {
            VerbError::UnderlyingEstateFailure {
                verb: "rebuild_derived_accelerators".to_string(),
                reason: e.to_string(),
            }
            .into()
        };

        // Ensure the table exists (idempotent CREATE TABLE IF NOT EXISTS under the
        // store's own kitID) and build the store.
        storage
            .migrate(&crate::matrix::MatrixSnapshotStore::schema_declaration())
            .map_err(map_err)?;
        let store = crate::matrix::MatrixSnapshotStore::new(Arc::clone(&storage));
        let estate_id = uuid_to_str(&handle.estate_uuid);

        // Step 2 — LOAD from disk + fold the tail forward, else cold-start rebuild.
        // load() is fail-soft (decode/version mismatch → None → full rebuild).
        let tier = match store.load(&estate_id).map_err(map_err)? {
            Some(snapshot) => {
                // incremental_update is conformance-proven equal to full_rebuild,
                // including cross-cursor expunge/withdraw and temporal
                // window-boundary pairs — exact, not an approximation.
                let mut loaded = snapshot.tier;
                loaded.incremental_update(&log, &event_times);
                loaded
            }
            None => crate::matrix::MatrixTier::full_rebuild(&log, &event_times),
        };

        // Step 3 — install so the matrixAware recall lane is live.
        self.register_matrix_tier(handle, tier.clone());

        // Step 4 — persist the fresh tier so the NEXT launch loads it. Watermark
        // is the F/O/C cursor. Calibration is not tracked per-estate on the
        // coordinator (Rust does not mirror Swift's calibrationRegistries map), so
        // an empty registry is persisted alongside the tier; the matrix F/O/C/T
        // state is what the launch path loads and folds forward.
        let watermark = tier.last_hlc;
        let snapshot = crate::matrix::MatrixSnapshot::new(
            tier,
            crate::matrix::MatrixCalibrationRegistry::default(),
            watermark,
        );
        store.upsert(&estate_id, &snapshot, now).map_err(map_err)?;

        // Flush the dense vector store's resident-array sidecar alongside the
        // matrix snapshot — both are derived accelerators that must live on disk so
        // a cold restart loads them instead of rebuilding from a full table scan.
        // The sidecar is write-behind; this is the periodic flush point (runs on
        // launch and on every dreaming cycle). Best-effort: the `vectors` table
        // remains the source of truth, and a no-op when no sidecar is configured.
        if let Some(vs) = self.vector_stores.get(handle) {
            let _ = vs.flush();
        }
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

    /// All non-tombstoned, non-retired tunnels across all wings.
    ///
    /// OMEGA uses this to enumerate the active dreamed-tunnel population before
    /// applying its retire predicate (`isDreamed AND not reinforced`). Retired
    /// tunnels are excluded so a re-proposed tunnel previously retired does not
    /// appear in the active set until a new `associate` verb promotes it.
    /// Delegates to `Estate::all_active_tunnels()`, which filters on bit 13 in-memory
    /// (the StoragePredicate DSL cannot express bitmap comparisons).
    ///
    /// Mirrors `GeniusLocusKit.allActiveTunnels(in:)` (Swift).
    pub fn all_active_tunnels(
        &self,
        handle: &EstateHandle,
    ) -> Result<Vec<locus_kit::tunnel::Tunnel>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate.all_active_tunnels().map_err(|e| remap("all_active_tunnels", "", e).into())
    }

    /// Retire a tunnel by flipping bit 13 of its `operational_bitmap`.
    ///
    /// Called by OMEGA through the GLK seam (B-1: NeuronKit reaches the substrate
    /// only through GLK verb surface, never directly). Delegates to
    /// `Estate::retire_tunnel(tunnel_id, changed_by, now)`.
    ///
    /// Mirrors `GeniusLocusKit.retireTunnel(in:id:changedBy:now:)` (Swift).
    ///
    /// - Returns: `Err(VerbDispatchError::TunnelNotFound)` if no non-tombstoned tunnel
    ///   with `tunnel_id` exists.
    pub fn retire_tunnel(
        &self,
        handle: &EstateHandle,
        tunnel_id: &str,
        changed_by: &str,
        now_epoch_secs: i64,
    ) -> Result<(), VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .retire_tunnel(tunnel_id, changed_by, now_epoch_secs)
            .map_err(|e| remap("retire_tunnel", tunnel_id, e).into())
    }

    // MARK: - mine_apriori_rules

    /// Hard ceiling on the number of audit entries materialized for Apriori
    /// mining. `ordered_entries()` is HLC-ascending; we take the most-recent
    /// MAX_APRIORI_AUDIT_ENTRIES entries (the tail of the sorted Vec).
    ///
    /// Rationale for 50,000:
    ///   - Each UnifiedAuditEntry is ~150–200 bytes. 50,000 entries ≈ 10 MB
    ///     of raw Vec allocation before Apriori work, well within a
    ///     single-call memory budget for a local server.
    ///   - A real human-driven estate producing 10 mutations per drawer
    ///     at 1,000 drawers yields ~10,000 entries — safely under the cap.
    ///   - Automated/adversarial loads that replay unbounded lifetime history
    ///     are bounded to the most-recent 50,000 events, keeping mining
    ///     latency and allocation predictable regardless of estate age.
    ///   - Apriori's RowAttributeView layer applies last-HLC-wins deduplication
    ///     per (tier, row, field), so the effective row count is much smaller
    ///     than 50,000 in practice; the cap is a materialization guard, not
    ///     an accuracy floor.
    ///
    /// Mirrors Swift's `maxAuditEntriesForMining` in
    /// `EstateAssociationRuleMining.swift`.
    const MAX_APRIORI_AUDIT_ENTRIES: usize = 50_000;

    /// Mine multi-antecedent Apriori association rules from the estate's
    /// audit log.
    ///
    /// Mirrors `mineAprioriRules(estate:thresholds:)` on the Swift
    /// `GeniusLocusKit` actor (`EstateAssociationRuleMining.swift:93`).
    ///
    /// Both ports read the same logical data source: the estate's audit log.
    ///
    ///   Swift: `currentAuditLog(in:)` — an in-memory `UnifiedAuditLog`
    ///   maintained by the actor through every verb call; snapshotted then
    ///   converted entry-by-entry via `toRowAuditEntry`.
    ///
    ///   Rust: `feed_audit_log_from_estate` — replays the LocusKit audit
    ///   trail (same underlying data) into a fresh `UnifiedAuditLog`, then
    ///   converts each `UnifiedAuditEntry` to `RowAuditEntry` using the
    ///   same value-mapping as Swift's `toRowAuditEntry`:
    ///     - `.Null` → `RowAuditValue::Null` (dropped, no categorical content)
    ///     - `.Bitmap(v)` → `RowAuditValue::Bitmap(v)`
    ///     - `.Integer(n)` → `RowAuditValue::Integer(n)`
    ///     - `.StringValue` → `RowAuditValue::Null` (no canonical 6-bit encoding)
    ///     - `.Bytes` → `RowAuditValue::Null` (no canonical 6-bit encoding)
    ///
    ///   `RowAttributeView::from` then decomposes each entry into per-field-path
    ///   `Item` attributes using last-HLC-wins deduplication per (tier, row, field),
    ///   identical to the Swift path.
    ///
    /// - Returns rules sorted by lift DESC, confidence DESC, evidence_count DESC.
    pub fn mine_apriori_rules(
        &self,
        handle: &EstateHandle,
        thresholds: substrate_ml::apriori_mining::AprioriThresholds,
    ) -> Result<Vec<substrate_ml::apriori_mining::AprioriRule>, VerbDispatchError> {
        self.mine_apriori_rules_with_limit(handle, thresholds, Self::MAX_APRIORI_AUDIT_ENTRIES)
    }

    /// Internal entry point for `mine_apriori_rules` that accepts an explicit
    /// entry limit. The public surface always passes `MAX_APRIORI_AUDIT_ENTRIES`;
    /// this variant exists so tests can exercise the cap at a small scale
    /// without injecting 50,000 entries. Mirrors Swift's
    /// `mineAprioriRules(estate:thresholds:entryLimit:)`.
    pub(crate) fn mine_apriori_rules_with_limit(
        &self,
        handle: &EstateHandle,
        thresholds: substrate_ml::apriori_mining::AprioriThresholds,
        entry_limit: usize,
    ) -> Result<Vec<substrate_ml::apriori_mining::AprioriRule>, VerbDispatchError> {
        use crate::audit::UnifiedAuditValue;
        use substrate_ml::row_attribute_view::{RowAuditEntry, RowAuditValue, RowAttributeView};

        let estate = self.estate_for_verb(handle)?;

        // Replay the estate's LocusKit audit trail into a UnifiedAuditLog.
        // Uses the same read-only path as `verify_audit_chain` so this function
        // can take `&self` rather than `&mut self`. The resulting log contains
        // the same entries that the Swift actor's in-memory `currentAuditLog`
        // would return after the same captures.
        let log = crate::hydration::feed_audit_log_from_estate(estate)
            .map_err(|e| VerbDispatchError::from(remap("mine_apriori_rules", "", e)))?;

        let all_ordered = log.ordered_entries();

        if all_ordered.is_empty() {
            return Ok(vec![]);
        }

        // Bound the materialization to the most-recent `entry_limit` entries
        // (HLC-ascending tail). Prevents a caller-induced OOM/hang on estates
        // with a large lifetime audit history. Entries beyond the cap are
        // oldest-first; dropping them means the oldest events are excluded,
        // which is the correct behavior for a recency-biased analysis window.
        // Mirrors Swift's suffix(entryLimit) in mineAprioriRules(estate:thresholds:entryLimit:).
        let ordered: &[_] = if all_ordered.len() > entry_limit {
            &all_ordered[all_ordered.len() - entry_limit..]
        } else {
            &all_ordered
        };

        // Convert each UnifiedAuditEntry to RowAuditEntry using the same
        // value mapping as Swift's `toRowAuditEntry` helper
        // (EstateAssociationRuleMining.swift, private extension GeniusLocusKit).
        // String and Bytes values have no canonical 6-bit Item encoding and
        // are mapped to Null so RowAttributeView drops them, exactly as Swift.
        let audit_entries: Vec<RowAuditEntry> = ordered
            .iter()
            .map(|entry| {
                // row_id.0 is a [u8; 16] UUID byte sequence; interpret as u128
                // big-endian to match UUID canonical order (network byte order).
                let row_id = u128::from_be_bytes(entry.row_id.0);

                let value = match &entry.after_value {
                    UnifiedAuditValue::Null => RowAuditValue::Null,
                    UnifiedAuditValue::Bitmap(v) => RowAuditValue::Bitmap(*v),
                    UnifiedAuditValue::Integer(n) => RowAuditValue::Integer(*n),
                    // String and Bytes have no canonical 6-bit Item encoding;
                    // map to Null so RowAttributeView drops the entry.
                    // Mirrors Swift toRowAuditEntry (EstateAssociationRuleMining.swift).
                    UnifiedAuditValue::StringValue(_) | UnifiedAuditValue::Bytes(_) => {
                        RowAuditValue::Null
                    }
                };

                RowAuditEntry::new(
                    row_id,
                    entry.tier.raw_value(),
                    &entry.field_path,
                    entry.hlc,
                    value,
                )
            })
            .collect();

        // Build RowAttributeView rows (last-HLC-wins per (tier, row, field))
        // and run the Apriori engine. Mirrors Swift's
        // `let rows = RowAttributeView.from(auditEntries: auditEntries)`.
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
    /// Batch drawer fetch by id — direct hydration (tier filters are a
    /// DEFAULT-search effect only). Parity of Swift `Estate.getDrawers(ids:)`
    /// reached through the coordinator surface (B-1).
    pub fn get_drawers(
        &self,
        handle: &EstateHandle,
        ids: &[&str],
    ) -> Result<Vec<locus_kit::drawer::Drawer>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .get_drawers(ids)
            .map_err(|e| remap("get_drawers", "", e).into())
    }

    /// Insert recall-trace rows directly — maintenance/test seeding for the
    /// Wave-2 D3 quiet clock. Parity of Swift `Estate.insertRecallTraces`.
    pub fn insert_recall_traces(
        &self,
        handle: &EstateHandle,
        items: &[locus_kit::recall_trace_item::RecallTraceItem],
    ) -> Result<(), VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .insert_recall_traces(items)
            .map_err(|e| remap("insert_recall_traces", "", e).into())
    }

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

    // MARK: - count_drawer_rows

    /// Count raw rows in the `drawers` table via `COUNT(*)`, bypassing all
    /// row-decode logic. Corrupt rows (e.g. a poison timestamp) are still
    /// counted. Used by the vault-export fail-loud path to distinguish
    /// "estate is genuinely empty" from "recall returned 0 because all rows
    /// are corrupt." Mirrors Swift `GeniusLocusKit.countDrawerRows(_:)`.
    pub fn count_drawer_rows(
        &self,
        handle: &EstateHandle,
    ) -> Result<usize, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        estate
            .count_drawer_rows()
            .map_err(|e| remap("count_drawer_rows", &uuid_to_str(&handle.estate_uuid), e).into())
    }

    // MARK: - Grant dispatch
    //
    // These methods mirror the Swift `issueGrant` and `revokeGrant` verbs on
    // `GeniusLocusKit` (Sources/GeniusLocusKit/Verbs/VerbSurface.swift §Grant).
    // The estate identity key is passed as raw `[u8; 32]` bytes — the Swift
    // surface extracts `.rawRepresentation` from a `Curve25519.Signing.PrivateKey`
    // before calling into the vault. The Rust port carries no CryptoKit types.

    /// Bit 0 of a grant audit entry's bitmap value marks the grant as in
    /// force. A `GrantIssued` entry transitions the value from `.Null` (the
    /// grant did not exist) to this bit set; a `GrantRevoked` entry
    /// transitions it from this bit set to `.Bitmap(0)` (cleared). Mirrors
    /// Swift `VerbSurface.grantActiveBit`.
    const GRANT_ACTIVE_BIT: u64 = 1;

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
    /// `now` is Unix epoch seconds (1970-01-01 UTC) on the Rust port.
    /// The Swift port passes Apple reference seconds via `Date.timeIntervalSinceReferenceDate`;
    /// the Rust port uses Unix epoch throughout for consistency with the substrate.
    pub fn issue_grant(
        &mut self,
        handle: &EstateHandle,
        options: GrantOptions,
        identity_key_raw: &[u8],
        now: f64,
    ) -> Result<IssueGrantResult, GrantError> {
        // Validate the custody mode before touching storage.
        // Mode-3 requires both IP clearance and valid Lagrange parameters.
        // `threshold=0` or `total_shares < threshold` causes reconstruct()
        // to interpolate an empty point set, producing the zero field element
        // — a constant anyone can precompute, breaking the custody model
        // (planned security hardening — B1, finding #2).
        const MAX_DECAY_SHARES: usize = 255;
        if let CustodyMode::DecayDerived {
            experimental_ip_clearance_confirmed,
            threshold,
            total_shares,
            ..
        } = &options.custody_mode
        {
            if !experimental_ip_clearance_confirmed {
                return Err(GrantError::ExperimentalModeNotActivated);
            }
            if *threshold == 0 || *total_shares < *threshold || *total_shares > MAX_DECAY_SHARES {
                return Err(GrantError::InvalidCustodyParameters);
            }
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
            // Every grant is issued at the full initial budget. The federation
            // layer debits it per recall. The canonical signing payload always
            // encodes INITIAL_INFERENCE_BUDGET (not the current debited value)
            // so the signature is stable across the grant's lifetime — the same
            // invariant enforced in Swift `VerbSurface.issueGrant` (hardcoded
            // `inferenceRemainingBudget: 1.0`).
            inference_remaining_budget: Self::INITIAL_INFERENCE_BUDGET,
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

        // Emit the grant-issued audit entry now that the grant is persisted
        // and the scope key is in custody, so the estate's unified chain
        // records the grant lifecycle (FUP-C / GLK-03 seam). Mirrors Swift
        // `issueGrant`'s `appendGrantAuditEntry(verb: .grantIssued, ...)`
        // call, placed after the same two prerequisites.
        self.append_grant_audit_entry(
            handle,
            crate::audit::UnifiedAuditVerb::GrantIssued,
            grant.id,
            grant.custody_mode.column_token(),
            crate::audit::UnifiedAuditValue::Null,
            crate::audit::UnifiedAuditValue::Bitmap(Self::GRANT_ACTIVE_BIT),
            (now * 1000.0) as i64,
        )?;

        Ok(IssueGrantResult { grant, scope_key })
    }

    /// Revoke a grant for the estate addressed by `handle`.
    ///
    /// Marks the grant revoked in the `GrantStore` and drops any mediated
    /// key from the `ScopeKeyVault`. `now` is Unix epoch seconds (Rust port).
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
        // Capture the stored grant (not just its presence) BEFORE revoking,
        // so the audit entry below can record the revoked grant's
        // custody-mode token — mirrors Swift `revokeGrant`'s `guard let
        // stored = try await store.get(id: grantID)` read-before-revoke.
        let custody_token = store.get(grant_id)
            .map_err(|_| GrantError::GrantNotFound(grant_id))?
            .ok_or(GrantError::GrantNotFound(grant_id))?
            .grant.custody_mode.column_token();
        // revoke_at_unix converts the f64 Unix epoch seconds to ISO-8601
        // before persisting — matching Swift GrantStore.revoke(id:at:).
        store.revoke_at_unix(grant_id, now)
            .map_err(|_| GrantError::GrantNotFound(grant_id))?;
        if let Some(vault) = self.scope_vaults.get_mut(handle) {
            vault.revoke(grant_id);
        }
        // Emit the grant-revoked audit entry after the revocation record is
        // written and the mode-1 key is dropped from the vault, so the
        // chain records the lifecycle close (FUP-C / GLK-03 seam). Mirrors
        // Swift `revokeGrant`'s `appendGrantAuditEntry(verb: .grantRevoked, ...)`.
        self.append_grant_audit_entry(
            handle,
            crate::audit::UnifiedAuditVerb::GrantRevoked,
            grant_id,
            custody_token,
            crate::audit::UnifiedAuditValue::Bitmap(Self::GRANT_ACTIVE_BIT),
            crate::audit::UnifiedAuditValue::Bitmap(0),
            (now * 1000.0) as i64,
        )?;
        Ok(())
    }

    // MARK: - sensitivity unlock audit verbs
    //
    // Mirror of Swift `SensitivityAuditVerbs.swift`. Uses NEW dedicated
    // `UnifiedAuditVerb` cases (sensitivityGrantIssued/Denied/Revoked,
    // sensitivityReadUnderGrant) — NOT the federation-reserved
    // grantIssued/grantRevoked (see `audit/log.rs`'s enum doc comment).
    // `issue_grant`/`revoke_grant` above append the federation-reserved
    // verbs through their own `append_grant_audit_entry` helper
    // (RUST-AUDIT-DURABILITY, 2026-07-09) — a separate helper, mirroring
    // Swift's separate `appendGrantAuditEntry` (VerbSurface.swift) vs.
    // `appendSensitivityAuditEntry` (SensitivityAuditVerbs.swift), even
    // though both durably append through the identical synthetic-entry
    // encoding (`hydration::write_synthetic_audit_event`). `tier` uses
    // LocusKit's existing `AdjectiveSensitivity` rather than a new type —
    // GeniusLocusKit must not depend on a higher-layer (AriaMcpKit) tier
    // vocabulary.

    /// Record that a sensitivity-unlock grant was approved and is now
    /// live. `grant_id` is a fresh identifier the caller mints per grant;
    /// `expires_at_ms` (epoch-milliseconds) is stored in `after_value` so
    /// expiry is derivable from the log alone (out-of-band sensitivity grants: expiry is
    /// passive, no dedicated expiry-time writer).
    pub fn record_sensitivity_grant_issued(
        &mut self,
        handle: &EstateHandle,
        tier: locus_kit::adjectives::AdjectiveSensitivity,
        grant_id: Uuid,
        expires_at_ms: i64,
        now_ms: i64,
    ) -> Result<(), GeniusLocusKitError> {
        self.estate_for(handle)?;
        self.append_sensitivity_audit_entry(
            handle,
            crate::audit::UnifiedAuditVerb::SensitivityGrantIssued,
            grant_id,
            Self::sensitivity_audit_token(tier),
            crate::audit::UnifiedAuditValue::Null,
            crate::audit::UnifiedAuditValue::Integer(expires_at_ms),
            now_ms,
        )
    }

    /// Record that a sensitivity-unlock grant request was DENIED (a
    /// failed `UnlockAuthority` verification). A fresh id is minted for
    /// the denial event itself — there is no persisted grant to
    /// correlate.
    pub fn record_sensitivity_grant_denied(
        &mut self,
        handle: &EstateHandle,
        tier: locus_kit::adjectives::AdjectiveSensitivity,
        now_ms: i64,
    ) -> Result<(), GeniusLocusKitError> {
        self.estate_for(handle)?;
        self.append_sensitivity_audit_entry(
            handle,
            crate::audit::UnifiedAuditVerb::SensitivityGrantDenied,
            Uuid::new_v4(),
            Self::sensitivity_audit_token(tier),
            crate::audit::UnifiedAuditValue::Null,
            crate::audit::UnifiedAuditValue::Null,
            now_ms,
        )
    }

    /// Record a manual revocation (`mootx01 lock`) of a live grant.
    /// `grant_id` should be the SAME id passed to
    /// `record_sensitivity_grant_issued` for the grant being revoked, so
    /// the two entries correlate by `row_id`.
    pub fn record_sensitivity_grant_revoked(
        &mut self,
        handle: &EstateHandle,
        tier: locus_kit::adjectives::AdjectiveSensitivity,
        grant_id: Uuid,
        now_ms: i64,
    ) -> Result<(), GeniusLocusKitError> {
        self.estate_for(handle)?;
        self.append_sensitivity_audit_entry(
            handle,
            crate::audit::UnifiedAuditVerb::SensitivityGrantRevoked,
            grant_id,
            Self::sensitivity_audit_token(tier),
            crate::audit::UnifiedAuditValue::Integer(1),
            crate::audit::UnifiedAuditValue::Null,
            now_ms,
        )
    }

    /// Record that a specific drawer was read only because a live
    /// sensitivity grant admitted it past the default ceiling. `row_id`
    /// here is the DRAWER's own id (parsed from `drawer_id`), not a grant
    /// id — unlike the three methods above, a read-under-grant entry is
    /// genuinely about a specific row.
    ///
    /// Malformed `drawer_id` is silently skipped (returns `Ok(())`
    /// without appending) rather than erroring — audit recording is
    /// best-effort observability, never a gate on the read path. Mirrors
    /// Swift `recordSensitivityReadUnderGrant`'s same silent-skip.
    pub fn record_sensitivity_read_under_grant(
        &mut self,
        handle: &EstateHandle,
        tier: locus_kit::adjectives::AdjectiveSensitivity,
        drawer_id: &str,
        now_ms: i64,
    ) -> Result<(), GeniusLocusKitError> {
        self.estate_for(handle)?;
        let Ok(row_uuid) = Uuid::parse_str(drawer_id) else {
            return Ok(());
        };
        self.append_sensitivity_audit_entry(
            handle,
            crate::audit::UnifiedAuditVerb::SensitivityReadUnderGrant,
            row_uuid,
            Self::sensitivity_audit_token(tier),
            crate::audit::UnifiedAuditValue::Null,
            crate::audit::UnifiedAuditValue::Null,
            now_ms,
        )
    }

    /// Shared append helper for the four methods above. Writes BOTH to the
    /// in-memory `self.audit_logs` map (live-session read-back via
    /// `audit_log(&self, handle)`, unchanged from before RUST-AUDIT-
    /// DURABILITY) AND durably through `storage.audit_log()` (new — the
    /// `_storagekit_audit` seam `feed_synthetic_audit_entries` reads back
    /// on the next hydrate). HLC physical time is `now_ms` directly
    /// (already epoch-milliseconds — the Rust dispatch layer's canonical
    /// `now` unit, `wall_now()` in aria-mcp's `dispatch.rs`); `tier` (the
    /// audit entry field) is always `Locus` since a sensitivity grant
    /// governs LocusKit-tier drawers.
    ///
    /// Best-effort on a missing storage (mirrors Swift
    /// `appendSensitivityAuditEntry`'s `guard let storage = storages[handle]
    /// else { return }`): a handle with no retained `Storage` (a test/mock
    /// `DrawerStore` that leaves `storage()` at its `None` default) still
    /// gets the in-memory entry, just not a durable one. A genuine write
    /// failure on a PRESENT storage propagates as
    /// `GeniusLocusKitError::UnderlyingEstateFailure`, mirroring Swift's
    /// `try await storage.auditLog.append(event)` (awaited, not
    /// fire-and-forget — a security-relevant write must surface, not be
    /// silently dropped).
    fn append_sensitivity_audit_entry(
        &mut self,
        handle: &EstateHandle,
        verb: crate::audit::UnifiedAuditVerb,
        row_id: Uuid,
        field_path: &'static str,
        before_value: crate::audit::UnifiedAuditValue,
        after_value: crate::audit::UnifiedAuditValue,
        now_ms: i64,
    ) -> Result<(), GeniusLocusKitError> {
        if let Some(storage) = self.storages.get(handle) {
            crate::hydration::write_synthetic_audit_event(
                storage.as_ref(),
                Uuid::from_bytes(handle.estate_uuid),
                row_id,
                verb,
                field_path,
                &before_value,
                &after_value,
                now_ms,
                "sensitivity-audit",
            )
            .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("{e:?}"),
            })?;
        }

        let hlc = substrate_types::hlc::HLC {
            physical_time: now_ms,
            logical_count: 0,
            node_id: 0,
        };
        let entry = crate::audit::UnifiedAuditEntry::new(
            crate::audit::AuditTier::Locus,
            hlc,
            verb,
            crate::audit::EntryUUID(row_id.as_u128().to_be_bytes()),
            field_path,
            before_value,
            after_value,
            None,
        );
        self.audit_logs
            .entry(*handle)
            .or_insert_with(crate::audit::UnifiedAuditLog::new)
            .add(entry);
        Ok(())
    }

    /// Shared append helper for `issue_grant`/`revoke_grant`'s
    /// grant-lifecycle audit entries. Twin of `append_sensitivity_audit_entry`
    /// above — same durable-write + in-memory-map double-write shape — but
    /// FAIL-CLOSED on a missing storage, mirroring Swift `appendGrantAuditEntry`'s
    /// `guard let storage = storages[handle] else { throw
    /// GeniusLocusKitError.estateNotOpen(...) }` (grant-lifecycle audit is
    /// not best-effort the way sensitivity-unlock's is; the FUP-C / GLK-03
    /// contract requires every issue/revoke to land). Storage-layer
    /// failures (missing storage OR a write error) are both surfaced as
    /// `GrantError::GrantNotFound(grant_id)` — the closest available
    /// `GrantError` variant, matching the existing convention `issue_grant`
    /// already uses for its own storage failures a few lines above.
    fn append_grant_audit_entry(
        &mut self,
        handle: &EstateHandle,
        verb: crate::audit::UnifiedAuditVerb,
        grant_id: Uuid,
        custody_token: &'static str,
        before_value: crate::audit::UnifiedAuditValue,
        after_value: crate::audit::UnifiedAuditValue,
        now_ms: i64,
    ) -> Result<(), GrantError> {
        let storage = self.storages.get(handle)
            .cloned()
            .ok_or(GrantError::GrantNotFound(grant_id))?;
        crate::hydration::write_synthetic_audit_event(
            storage.as_ref(),
            Uuid::from_bytes(handle.estate_uuid),
            grant_id,
            verb,
            custody_token,
            &before_value,
            &after_value,
            now_ms,
            "grant-audit",
        )
        .map_err(|_| GrantError::GrantNotFound(grant_id))?;

        let hlc = substrate_types::hlc::HLC {
            physical_time: now_ms,
            logical_count: 0,
            node_id: 0,
        };
        let entry = crate::audit::UnifiedAuditEntry::new(
            crate::audit::AuditTier::Locus,
            hlc,
            verb,
            crate::audit::EntryUUID(grant_id.as_u128().to_be_bytes()),
            custody_token,
            before_value,
            after_value,
            None,
        );
        self.audit_logs
            .entry(*handle)
            .or_insert_with(crate::audit::UnifiedAuditLog::new)
            .add(entry);
        Ok(())
    }

    /// The `field_path` token stamped onto a sensitivity-unlock audit
    /// entry — mirrors Swift `AdjectiveSensitivity.auditToken`.
    fn sensitivity_audit_token(tier: locus_kit::adjectives::AdjectiveSensitivity) -> &'static str {
        use locus_kit::adjectives::AdjectiveSensitivity;
        match tier {
            AdjectiveSensitivity::Normal => "normal",
            AdjectiveSensitivity::Elevated => "elevated",
            AdjectiveSensitivity::Restricted => "restricted",
            AdjectiveSensitivity::Secret => "secret",
        }
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

    /// Initial inference budget assigned to every newly-issued grant.
    ///
    /// Every grant leaves `issue_grant` with `inference_remaining_budget ==
    /// INITIAL_INFERENCE_BUDGET`. The canonical signing payload always uses
    /// this value at signature-verification time (step 4.5 of
    /// `federated_recall`), regardless of how much budget has been debited
    /// since issue — because the granter signed with the initial budget, not
    /// the current debited value. Mirrors Swift `VerbSurface.issueGrant`
    /// which hardcodes `inferenceRemainingBudget: 1.0` at issuance and
    /// `CrossEstateFederation` which hardcodes `inferenceRemainingBudget: 1.0`
    /// at verification.
    pub const INITIAL_INFERENCE_BUDGET: f64 = 1.0;

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
    ///    (Unix epoch seconds, Rust port). Pick the one with highest
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
    /// Both `now` (Unix epoch seconds, grant expiry) and `now_unix` (Unix
    /// epoch seconds, LocusKit bitmap evaluation) are explicit for determinism.
    /// `now` is `f64` for compatibility with grant lifetime arithmetic;
    /// `now_unix` is `i64` for LocusKit bitmap integer evaluation.
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

        // Verify the grant signature before any cross-estate recall.
        //
        // Verify the grant's Ed25519 signature against the GRANTER's registered
        // identity public key. Trust derives from the registry — the manifest-persisted
        // public key for the source estate — NOT from any field in the grant blob.
        // Same registered-key trust anchor as the F-3 pull() hardening in
        // ConvergenceKit FederationSyncEngine.
        //
        // Migration posture (D9): this path is strictly local in-process (I-13
        // invariant — no network crossing, both estates open in the same coordinator).
        // An empty signature is allowed with a logged warning because local grants
        // that predate the signing scheme carry no cross-estate exposure. A non-empty
        // signature that fails verification against the granter's registered key is
        // always rejected. Mirrors Swift CrossEstateFederation step 4.5.
        if !authorizing_grant.signature.is_empty() {
            use base64::Engine as _;
            let b64 = base64::engine::general_purpose::STANDARD;
            // Retrieve the source estate's registered public key from its manifest.
            // estate_for() is an immutable borrow on registry — safe here because
            // the mutable borrow on grant_stores (step 3 block) has been released.
            let source_estate = self.estate_for(source)
                .map_err(|_| GeniusLocusKitError::EstateNotOpen { estate_uuid: source.estate_uuid })?;
            let manifest = source_estate.manifest()
                .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!("manifest read failed during grant signature check: {e:?}"),
                })?;
            let pub_key_b64 = manifest.ed25519_public_key.ok_or_else(|| {
                GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: "source estate has no Ed25519 public key in manifest \
                             — cannot verify grant signature"
                        .to_string(),
                }
            })?;
            let pub_key_bytes = b64.decode(&pub_key_b64)
                .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!("Ed25519 public key base64 decode failed: {e:?}"),
                })?;
            // Reconstruct the canonical verification payload with the initial
            // budget (1.0), mirroring Swift CrossEstateFederation step 4.5.
            //
            // The grant store's debit_budget mutates the persisted grant's
            // inference_remaining_budget in place (step 6 below). When
            // active() returns the grant on a second or later recall, the
            // stored value is the debited budget (e.g. 0.99 after one read).
            // Calling authorizing_grant.signing_payload() at that point
            // produces different bytes than were signed at issue time —
            // breaking signature verification for every recall after the first
            // even though the grant is valid and budget remains.
            //
            // The granter always signs with inferenceRemainingBudget: 1.0 (the
            // full initial allotment). Reconstructing with 1.0 here keeps the
            // signed bytes stable across all debits. Identical to Swift's
            // Grant.canonicalPayload(... inferenceRemainingBudget: 1.0 ...).
            let signing_payload = Grant::canonical_payload(
                authorizing_grant.id,
                authorizing_grant.grantee_estate_id,
                &authorizing_grant.scope,
                authorizing_grant.content_level,
                &authorizing_grant.lifetime,
                &authorizing_grant.custody_mode,
                &authorizing_grant.re_share_permission,
                Self::INITIAL_INFERENCE_BUDGET, // canonical initial budget — byte-identical to signing time
                authorizing_grant.issued_at,
            );
            if !convergence_kit::verify_signature(
                &authorizing_grant.signature,
                &signing_payload,
                &pub_key_bytes,
            ) {
                return Err(GeniusLocusKitError::CrossEstateReadRefused {
                    source: source_uuid,
                    requester: requester_uuid,
                    reason: FederatedReadRefusalReason::InvalidGrantSignature,
                });
            }
        }
        // Empty signature: legacy pre-signing grant. Allowed on this local
        // in-process path (I-13 invariant). No cross-estate exposure.

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
            // write serialisation).
            //
            // Fail-closed: if the debit write fails, refuse the read. A storage
            // error on debit means we cannot guarantee the budget decrement was
            // recorded — returning content on a failed debit would allow unbounded
            // reads against a grant whose budget can no longer be decremented
            // (secfix/punt-g2). Mirrors Swift CrossEstateFederation, where a
            // debit write failure propagates as a thrown error and the read
            // returns no content.
            store.debit_budget(authorizing_grant.id, Self::BUDGET_DEBIT_PER_READ)
                .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!("budget debit write failed — read refused (fail-closed): {e:?}"),
                })?;
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
        // Resolve node names for Wing/Room scope matching (Drawer stores
        // parent_node_id, not wing/room strings — node-tree integrity).
        let node_names = build_node_name_map(self.node_stores.get(source), &drawers);
        let drawers: Vec<_> = match &authorizing_grant.scope {
            crate::grants::GrantScope::WholeEstate => drawers,
            crate::grants::GrantScope::Wing(name) => {
                drawers.into_iter().filter(|d| {
                    node_names.get(&d.parent_node_id)
                        .map(|(w, _)| w == name)
                        .unwrap_or(false)
                }).collect()
            }
            crate::grants::GrantScope::Room(name) => {
                drawers.into_iter().filter(|d| {
                    node_names.get(&d.parent_node_id)
                        .map(|(_, r)| r == name)
                        .unwrap_or(false)
                }).collect()
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

    /// Idempotently seed the seven default wings on an open estate.
    ///
    /// This is the single seam that owns the default-wing seeding loop.
    /// Both the `provision` path (fresh estate) and the serve open path (bare
    /// re-open of an existing estate) call this method so every served estate
    /// always has its wings, regardless of how it was originally created.
    ///
    /// **Idempotency:** reads all existing `AI_Charter_Hint` drawers from the
    /// estate once. Wings whose hint drawer already exists are skipped. Wings that
    /// are absent are seeded with their canonical hint text via `seed_wing`.
    /// Calling this multiple times on the same estate is a safe no-op once all
    /// seven wings are present.
    ///
    /// Mirrors Swift `GeniusLocusKit.seedDefaultWings(for:now:)`.
    ///
    /// **Encode routing (DISTILL_SEED_STALL):** when a Corpus is registered,
    /// hint drawers are enqueued onto the Corpus encode stream — the same
    /// change-reference path a `Regular` capture rides — so the drain-stage
    /// distillation fires for them and the "distillation" drain lane can reach
    /// zero. The enqueue predicate is representation-eligibility (bit 19
    /// `has_current_representation` clear, or a stale pipeline version) over
    /// the `AI_Charter_Hint` room only: an already-encoded-and-distilled hint
    /// is never re-enqueued, so re-opening an estate stays a no-op — no
    /// spurious encode work per open. (Deliberately does NOT key on
    /// `hint_added_by`, which is provenance-only.)
    ///
    /// - `handle`: An open estate handle in the coordinator's registry.
    /// - `now`:    Write timestamp (epoch MILLISECONDS) for any hints seeded.
    ///             Milliseconds is what the store and HLC boundary consume;
    ///             seconds here stamp every seeded hint drawer as 1970.
    ///             Pass `SystemTime::now()` from serve entry points (acceptable
    ///             at an app boundary). Pass a fixed value in tests for determinism.
    /// - Returns: `Ok(())` on success, or a `GeniusLocusKitError` if the estate
    ///   is not in the registry or a `seed_wing` write fails.
    pub fn seed_default_wings(
        &mut self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<(), GeniusLocusKitError> {
        let estate = self
            .estate_for(handle)
            .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("seed_default_wings: estate_for failed: {:?}", e),
            })?;

        // Read existing drawers to compute which wings are already present.
        // `all_drawers()` is a full corpus scan; estates are small at this stage
        // (7 hints + user content) and this is called once per open, not per request.
        let existing_drawers = estate
            .all_drawers()
            .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("seed_default_wings: all_drawers failed: {:?}", e),
            })?;
        // Identify already-seeded wings by finding drawers in room HINT_ROOM
        // ("AI_Charter_Hint") and resolving their wing names from the node tree
        // (Drawer no longer stores wing/room — node-tree integrity).
        let node_names = build_node_name_map(self.node_stores.get(handle), &existing_drawers);
        let seeded_wings: std::collections::HashSet<String> = existing_drawers
            .iter()
            .filter(|d| {
                node_names.get(&d.parent_node_id)
                    .map(|(_, room)| room == locus_kit::default_wings::HINT_ROOM)
                    .unwrap_or(false)
            })
            .filter_map(|d| {
                node_names.get(&d.parent_node_id)
                    .map(|(wing, _)| wing.clone())
            })
            .collect();

        // The hint drawer is stamped with the corpus's primary model id when a
        // corpus is registered — the normal case now that both provision and the
        // serve open path wire the Corpus BEFORE calling this. The sentinel below
        // is reached only for a corpus-less estate (LocusOnly, no semantic lane,
        // or a bare serve open before wiring); such a drawer is row-only and is
        // re-stamped under the real model on the next reindex.
        let embedding_model_id = self
            .corpus_for(handle)
            .map(|c| c.model_id().to_string())
            .unwrap_or_else(|| "estate-provision".to_string());

        // Seed each wing whose hint drawer does not yet exist.
        // For estates already provisioned via `provision`, this loop is a no-op.
        let mut seeded_count = 0usize;
        for wing in DEFAULT_WINGS {
            if seeded_wings.contains(wing.name) {
                continue;
            }
            estate
                .seed_wing(wing.name, wing.hint, &embedding_model_id, now)
                .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!(
                        "seed_default_wings: seed_wing failed for '{}': {:?}",
                        wing.name, e
                    ),
                })?;
            seeded_count += 1;
        }

        // Encode routing (DISTILL_SEED_STALL): index + distill hint drawers
        // that still owe a representation, INLINE through the encode path —
        // the same index/distill/recompose transform a queued drawer receives
        // at drain, without touching the queue. Inline (not enqueued) on
        // purpose: seeding returns with the estate SETTLED — hints
        // BM25/vector indexed, distilled (bit 19 set), and the young fallback
        // basis converged via the post-ingest settle — so nothing races the
        // first user capture and no drain worker or lease is required at
        // open. Runs AFTER the seeding loop so it covers both the hints
        // seeded just now and hints seeded by an earlier open that predates
        // this routing (their bit 19 is clear — the one-time backfill).
        // Skipped entirely when no Corpus is registered (LocusOnly / bare
        // open before wiring): a corpus-less estate has no semantic lane;
        // those hints are picked up by reindex/sweep once a corpus exists.
        // Twin of the Swift block in `seedDefaultWings`.
        let mut settled_hints = 0usize;
        if let Some(corpus) = self.corpus_for(handle) {
            // Re-scan when the loop seeded new hints (they are not in the
            // first scan); otherwise reuse it.
            let drawers = if seeded_count > 0 {
                estate
                    .all_drawers()
                    .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                        reason: format!("seed_default_wings: all_drawers (post-seed) failed: {e:?}"),
                    })?
            } else {
                existing_drawers
            };
            let node_names = build_node_name_map(self.node_stores.get(handle), &drawers);
            for hint in drawers.iter().filter(|d| {
                node_names
                    .get(&d.parent_node_id)
                    .map(|(_, room)| room == locus_kit::default_wings::HINT_ROOM)
                    .unwrap_or(false)
                    && !d.content.is_empty()
                    && (!d.has_current_representation()
                        || d.distilled_pipeline_version.as_deref()
                            != Some(substrate_ml::token_compaction::DISTILLATION_PIPELINE_VERSION))
            }) {
                // Index (BM25 + vector lanes) through the engine's direct
                // path; the post-ingest settle inside index_content keeps the
                // young basis covering the growing corpus.
                corpus
                    .index_content(&hint.id, hint.filed_at)
                    .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                        reason: format!(
                            "seed_default_wings: corpus index_content failed for '{}': {e:?}",
                            hint.id
                        ),
                    })?;
                // Drain-stage transform, inline: the same shared seam the
                // queue's on_encoded rider calls, with the seeding `now`
                // threaded for determinism.
                if Self::distill_item(
                    estate,
                    self.vector_stores.get(handle),
                    &hint.id,
                    &hint.content,
                    now,
                ) {
                    let _ = corpus.recompose_dense_vector(&hint.id, now);
                }
                settled_hints += 1;
            }
        }

        // Suppress unused-variable warnings in release builds where log is a no-op.
        let _ = seeded_count;
        let _ = settled_hints;

        Ok(())
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
    ///                       canonical five-signal default: RI/PPMI/LSA/NMF/FDC).
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
            ed25519_public_key: None,
            ed25519_private_key_wrapped: None,
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

        // Step 2b: Wire sub-stores by kind — same logic as Swift EstateLifecycle.swift §provision.
        // Wiring runs BEFORE seeding the wings (step 2c) so the hint drawers carry
        // the corpus's real model id, not a sentinel — matching the serve open path
        // and the Swift provision order.
        // backing_storage is the persistence_kit Storage used for Corpus + VectorStore;
        // falls back to the primary `storage` when no separate corpus_storage is supplied.
        let backing_storage = corpus_storage.unwrap_or(storage);
        // Fresh estates are born at the current stable estate format.
        // Historical detection/conversion lives in an optional migration crate.
        crate::estate_format::EstateFormatStore::new(Arc::clone(&backing_storage))
            .stamp(crate::estate_format::EstateFormatVersion::CURRENT, 0)
            .map_err(|error| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("estate-format stamp failed: {error:?}"),
            })?;
        let wiring_result = match params.kind {
            EstateKind::Glk => {
                // Full composition: the ATTACHED-mode CorpusContentEngine
                // (BM25 + internal vectors, Drawer-ID keyed) + standalone
                // VectorStore. EVERY GLK Corpus is constructed attached +
                // WholeContent over the LocusKit-backed adapter
                // (shared-content 1.1 decision lock); the configuration
                // constructor rejects standalone/passage registration.
                self.estate_for(&handle)
                    .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                        reason: format!("estate lookup for engine wiring failed: {:?}", e),
                    })
                    .map(|estate| estate.clone())
                    .and_then(|estate| {
                        let config = CorpusContentConfiguration::new(
                            CorpusOperatingMode::Attached,
                            CorpusIndexUnitPolicy::WholeContent,
                        )
                        .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                            reason: format!("engine configuration: {:?}", e),
                        })?;
                        CorpusContentEngine::open(
                            Arc::clone(&backing_storage),
                            config,
                            Arc::new(LocusDrawerContentSource::new(estate)),
                            embedding_models,
                        )
                        .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                            reason: format!("engine open failed for GLK estate: {:?}", e),
                        })
                        .and_then(|corpus| {
                            corpus.reconcile_configured_providers(0).map_err(|e| {
                                GeniusLocusKitError::UnderlyingEstateFailure {
                                    reason: format!("provider reconciliation failed: {e:?}"),
                                }
                            })?;
                            Ok(corpus)
                        })
                    })
                    .map(|corpus| {
                        // BORROW the engine's single dense VectorStore for
                        // GLK's scored-recall lane — one store, one resident
                        // array, one sidecar.
                        let corpus = Arc::new(corpus);
                        let vs = corpus.shared_vector_store();
                        (Some(corpus), Some(vs))
                    })
            }
            EstateKind::CorpusOnly => {
                // LocusKit core + the attached engine. No standalone
                // VectorStore registration. Same construction rule.
                self.estate_for(&handle)
                    .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                        reason: format!("estate lookup for engine wiring failed: {:?}", e),
                    })
                    .map(|estate| estate.clone())
                    .and_then(|estate| {
                        let config = CorpusContentConfiguration::new(
                            CorpusOperatingMode::Attached,
                            CorpusIndexUnitPolicy::WholeContent,
                        )
                        .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                            reason: format!("engine configuration: {:?}", e),
                        })?;
                        CorpusContentEngine::open(
                            Arc::clone(&backing_storage),
                            config,
                            Arc::new(LocusDrawerContentSource::new(estate)),
                            embedding_models,
                        )
                        .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                            reason: format!("engine open failed for CorpusOnly estate: {:?}", e),
                        })
                        .and_then(|corpus| {
                            corpus.reconcile_configured_providers(0).map_err(|e| {
                                GeniusLocusKitError::UnderlyingEstateFailure {
                                    reason: format!("provider reconciliation failed: {e:?}"),
                                }
                            })?;
                            Ok(corpus)
                        })
                    })
                    .map(|corpus| (Some(Arc::new(corpus)), None))
            }
            EstateKind::LocusOnly => {
                // LocusKit only — no sub-store wiring needed.
                Ok((None, None))
            }
        };

        match wiring_result {
            Ok((corpus_opt, vs_opt)) => {
                // Register the wired sub-stores. Arc<CorpusContentEngine> and Arc<VectorStore> are
                // what the registry holds (matching Swift's corpusKits / vectorStores dicts).
                if let Some(corpus) = corpus_opt {
                    self.corpus_kits.insert(handle, corpus);
                }
                if let Some(vs) = vs_opt {
                    self.vector_stores.insert(handle, vs);
                }
                // GLK estate: apply the composite GLK schema so all component kit
                // tables (LocusKit, VectorKit, CorpusKit) are registered under the
                // "GeniusLocusKit" composite kit ID. This ensures the version gate in
                // the replication primitive sees the correct composite version for
                // this estate. Idempotent (CREATE TABLE IF NOT EXISTS).
                //
                // Mirrors Swift `GeniusLocusKit.provision` calling
                // `storage.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)`
                // in the test fixture — here we do it automatically at provision
                // so callers do not need to apply the schema separately.
                //
                // `params.kind` is still available because `wiring_result` does not
                // consume it (only the match arms move `embedding_models`).
                if params.kind == EstateKind::Glk {
                    let glk_schema = crate::hydration::composite_schema();
                    backing_storage
                        .open(&glk_schema)
                        .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                            reason: format!("GLK composite schema open failed: {e:?}"),
                        })?;
                }
                // CorpusKit owns the encode pipeline: mount the Corpus's own
                // ingest queue + drain worker pool for estates with a Corpus to
                // feed (Glk / CorpusOnly), and wire its on_encoded callback to
                // roll up the touched LocusKit rooms for each encoded batch. GLK
                // only coordinates the two kits — it never performs the encode.
                // LocusOnly estates register no corpus, so they get no queue (a
                // regular write degrades to row-only). Mirrors Swift
                // `EstateLifecycle.swift` wireSubstores.
                if let Some(corpus) = self.corpus_kits.get(&handle).cloned() {
                    corpus.mount_ingest_queue().map_err(|e| {
                        GeniusLocusKitError::UnderlyingEstateFailure {
                            reason: format!("Corpus::mount_ingest_queue failed: {e:?}"),
                        }
                    })?;
                    // Capture cheap clones (Arc-backed, Send+Sync) so the
                    // Corpus drain worker's callback can (1) roll up rooms,
                    // (2) distill each newly-encoded drawer that is still
                    // eligible (SPEC_DISTILLATION_STORAGE §7.1 drain path —
                    // Wave 1 Rust parity gap now closed), and (3) recompose
                    // the dense float vector from the new distillate
                    // (MISSION_11X_RECALL_GAP_01 Stream F). Mirrors Swift's
                    // wireCorpusRoomRollup on_encoded callback. Best-effort:
                    // all steps are non-fatal — the next distill sweep and
                    // retrain recover any misses.
                    if let Some(estate) = self.registry.get(&handle).cloned() {
                        let corpus_for_callback = corpus.clone();
                        // VectorStore for fingerprint lane (§8); may be absent.
                        let vector_store_for_callback =
                            self.vector_stores.get(&handle).cloned();
                        corpus.set_on_encoded(move |drawer_ids| {
                            use substrate_ml::token_compaction;

                            // (1) Room-rollup — always best-effort.
                            let _ = estate.rollup_rooms_for_drawers(drawer_ids);

                            // (2) Drain-stage distillation + (3) dense recompose.
                            // The wall clock at drain time is the process boundary
                            // where `now` legitimately enters; `distilled_at` is
                            // audit-only (§4), so the epoch-millis timestamp here
                            // carries no behavioral weight. Mirrors Swift's use of
                            // `Date()` at the head of the on_encoded loop.
                            let now_ms = std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .map(|d| d.as_millis() as i64)
                                .unwrap_or(0);

                            for drawer_id in drawer_ids {
                                // Fetch the current drawer row.
                                let drawer = match estate.drawer_by_id(drawer_id) {
                                    Ok(Some(d)) => d,
                                    _ => continue,
                                };
                                if drawer.content.is_empty() {
                                    continue;
                                }
                                // Eligibility: bit 19 (has_current_representation)
                                // clear, OR pipeline version mismatch.
                                if drawer.has_current_representation()
                                    && drawer.distilled_pipeline_version.as_deref()
                                        == Some(
                                            token_compaction::DISTILLATION_PIPELINE_VERSION,
                                        )
                                {
                                    continue;
                                }

                                // Distillation through the shared seam — the
                                // same call tree `distill_items_sweep` and the
                                // seeding path take.
                                if EstateCoordinator::distill_item(
                                    &estate,
                                    vector_store_for_callback.as_ref(),
                                    &drawer.id,
                                    &drawer.content,
                                    now_ms,
                                ) {
                                    // (3) Dense-over-distillate (Stream F): recompose
                                    // the dense float vector from the new distillate.
                                    // The idempotence gate keys on content digest (not
                                    // on dense_composition_text), so a normal index
                                    // call would be skipped — recompose_dense_vector
                                    // passes force=true to bypass it.
                                    // Swift parity: on_encoded in wireCorpusRoomRollup.
                                    let _ = corpus_for_callback
                                        .recompose_dense_vector(&drawer.id, now_ms);
                                }
                            }
                        });
                    }
                }
            }
            Err(e) => {
                // Sub-store wiring failed. Close the estate to avoid a half-wired zombie
                // in the registry, mirroring Swift's `try? await close(handle)` rollback.
                let _ = self.close(&handle);
                return Err(e);
            }
        }

        // Step 2c: Seed the seven default wings (the default-wing policy) — AFTER wiring,
        // so each hint drawer is stamped with the corpus's normal model id rather
        // than the "estate-provision" sentinel (matches the serve open path and the
        // Swift provision order), and `seed_default_wings` enqueues each hint onto
        // the Corpus encode stream so the drain-stage distillation fires for hints
        // exactly as for user content (DISTILL_SEED_STALL). Seeding failure closes
        // the estate (no half-provisioned zombie). Provision-time wall clock (epoch
        // MILLISECONDS) at the app boundary — the engine interior never reads the
        // clock. Milliseconds is what the store and HLC boundary consume; seconds
        // here would stamp every default-wing hint drawer in every estate as 1970.
        {
            let seed_now: i64 = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            if let Err(e) = self.seed_default_wings(&handle, seed_now) {
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

        // In-flight work has settled — flush the dense vector store's resident-array
        // sidecar so a graceful shutdown leaves it current (a cold restart loads it
        // instead of rebuilding from a full table scan). Best-effort.
        if let Some(vs) = self.vector_stores.get(handle) {
            let _ = vs.flush();
        }

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
        // Capture references to registered sub-stores and the LocusKit estate
        // BEFORE close() drops them from the registry.
        let corpus = self.corpus_kits.get(handle).cloned();
        let vector_store = self.vector_stores.get(handle).cloned();
        let estate = self.estate_for(handle).ok().cloned();

        // Step 1: Destroy Corpus recall index (BM25 + internal vectors) BEFORE
        // close(). close() drops self.storages[handle], which releases the GLK
        // Arc to the shared storage. Sub-store teardown must complete while the
        // storage connection is still open so corpus/vector SQL writes succeed.
        // Order matches the Swift GeniusLocusKit.destroy implementation:
        //   sub-store teardown → wipe LocusKit content → close() → file deletion
        // (file deletion is done at the application layer, moot-mgr Cluster F).
        if let Some(c) = corpus {
            c.destroy_recall_index().map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("Corpus destroy failed: {:?}", e),
            })?;
        }

        // Step 2: Destroy standalone VectorStore vectors. WHOLE-ESTATE
        // PRECONDITION (shared-content 1.1 P5): the broad whole-table vector
        // teardown is permitted here ONLY because the estate itself is being
        // destroyed — every row in this estate's vectors table belongs to the
        // estate, the estate is wiped and closed immediately after, and the
        // admin plane deletes the backing file. Recall-index lifecycle paths
        // are ownership-scoped and never call destroy_all_vectors.
        if let Some(vs) = vector_store {
            vs.destroy_all_vectors().map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("VectorStore destroy failed: {:?}", e),
            })?;
        }

        // Step 3: Wipe LocusKit drawer content blobs from SQLite (destruction
        // contract — secfix/ws2-coredelete §Cluster E). Runs before close() so
        // the storage connection is still valid. Zeros the `content` column for
        // every row in the drawers table; the SQLite file itself is deleted by
        // the application layer (moot-mgr) after this method returns.
        if let Some(est) = estate {
            est.wipe_all_content()
                .map_err(|e| GeniusLocusKitError::UnderlyingEstateFailure {
                    reason: format!("LocusKit wipe_all_content failed on destroy: {:?}", e),
                })?;
        }

        // Step 4: Dispose key material (estate-key-lifetime fix, 2026-07-29).
        //
        // On Apple platforms the Swift coordinator deletes the Ed25519 identity
        // key and the SQLCipher db key from the Apple Keychain here. The Rust
        // coordinator does not interact with a system Keychain; estate files
        // are managed by the application layer (moot-mgr Cluster F). This call
        // is therefore a no-op on all Rust targets, but it exists for parity
        // so that the overall destroy() contract ("dispose key material before
        // close") is visible and testable on both legs.
        self.dispose_estate_keys(handle);

        // Step 5: Close the estate (drops registry, grant store, corpus/vector
        // refs, and storage Arc). Sub-store teardown (steps 1–4) must complete
        // before this call, matching the Swift ordering.
        if self.registry.contains_key(handle) {
            self.close(handle)?;
        }

        Ok(())
    }

    /// Dispose key material for an estate being permanently retired.
    ///
    /// On Apple platforms (Swift coordinator) this deletes the Ed25519 identity
    /// key from the Keychain (`com.mootx01.estate.identity` service) and the
    /// SQLCipher whole-file db key (`com.codedaptive.mootx01` service). On
    /// Linux and other non-Keychain targets, estate file keys are managed by
    /// the application layer (file deletion) rather than a system Keychain,
    /// so this method is a documented no-op here.
    ///
    /// It exists for API parity with the Swift coordinator so that `destroy()`
    /// explicitly names the disposal step on both legs and the parity tests
    /// can verify the calling contract.
    ///
    /// Idempotent: calling on a handle whose keys were already disposed
    /// (or were never written to a Keychain) is always safe.
    pub fn dispose_estate_keys(&self, _handle: &EstateHandle) {
        // No-op on Rust targets. File-based key material (SQLCipher key) is
        // part of the estate file itself and is removed when the application
        // layer deletes the backing file after destroy() returns. No separate
        // Keychain clean-up is needed.
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

        let result = match request.mode {
            GLKRecallMode::LocusOnly => {
                Self::recall_scored_locus_only(estate, request.clone(), plan, now)
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
                // Pass the registered GraphCache / PreferenceStore (if any) for the
                // `matrixAware` graph / preference score columns. `Arc::clone` is a
                // reference-count bump only — the trait object lives behind the Arc, so
                // the static fn reads it without &self access, mirroring how the cloned
                // `matrix_tier` is threaded through. None ⇒ the column stays 0.0, same
                // as Swift when `graphCaches[handle]` / `preferenceStores[handle]` is nil.
                let graph_cache = self.graph_caches.get(handle).cloned();
                let preference_store = self.preference_stores.get(handle).cloned();
                Self::recall_scored_multi_lane(
                    estate, request.clone(), plan, now, corpus, vector, handle,
                    matrix_tier, graph_cache, preference_store,
                    forced_vector_hamming_error, forced_embed_error,
                )
            }
            GLKRecallMode::NodeTreeNative => {
                // NodeTreeNative injects host-tree topology edges into the
                // StructureGraph via recall_tunnels (the structural lens path),
                // not via the scored drawer-recall path. For drawer retrieval,
                // delegate to the locusOnly bitmap lane so all estate drawers
                // are reachable through the normal bitmap filter.
                Self::recall_scored_locus_only(estate, request.clone(), plan, now)
            }
        }?;

        // Enqueue a dreaming item for external-origin scored recalls.
        //
        // Guard (spec §12.2 + B-10a):
        //   - origin must be External — only ARIA boundary recalls are dreaming
        //     candidates; internal reads (dreaming daemon, standing signals, recipes,
        //     migration, benchmarks) must NEVER enqueue (they would feed back into
        //     the dreaming pipeline, creating a self-referential loop).
        //   - result must have ≥ 2 distinct surfaced drawer ids — a single drawer
        //     makes no co-recall pair for the REM-ALPHA drainer. The guard is
        //     enforced inside `enqueue_dreaming_item`; zero cost if < 2.
        //
        // The enqueue is non-fatal: `enqueue_dreaming_item` catches and logs all
        // failures. `now` uses the same epoch-millisecond unit as `recall_scored`,
        // so `enqueue_dreaming_item` stamps the HLC with it directly.
        // No SystemTime::now() inside this engine — determinism rule.
        if request.origin == RecallOrigin::External {
            let drawers: Vec<Drawer> = result.hits.iter()
                .filter_map(|h| h.drawer.clone())
                .collect();
            self.enqueue_dreaming_item(handle, &drawers, now);
        }

        Ok(result)
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
        corpus: Option<Arc<CorpusContentEngine>>,
        vector: Option<Arc<VectorStore>>,
        handle: &EstateHandle,
        // MatrixTier registered for this estate — Some when the dreaming cycle has
        // run rebuild_derived_accelerators at least once. None on a fresh estate
        // with no matrix data (matrix signals are 0.0, same as Swift's fallback when
        // matrixTiers[handle] == nil).
        matrix_tier: Option<crate::matrix::MatrixTier>,
        // GraphCache / PreferenceStore registered for this estate — Some when the
        // dreaming cycle / training daemon has registered one. None on a fresh estate
        // with no graph/preference priors (the graph/preference columns read 0.0, same
        // as Swift's fallback when graphCaches[handle] / preferenceStores[handle] == nil).
        graph_cache: Option<Arc<dyn crate::recall::GraphCache>>,
        preference_store: Option<Arc<dyn crate::recall::PreferenceStore>>,
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

        // When no corpus or vector store is registered, the multi-lane path has
        // no corpus/vector signal. Handle the two distinct cases:
        //
        //   CorpusOnly + FailClosed — the request explicitly asked for a corpus/vector
        //   lane and forbade degraded fallback. Return an error rather than silently
        //   leaking locus hits that the caller did not request and may not be authorised
        //   to see through this path. Mirrors Swift RecallDirector.recallCorpusOnly which
        //   propagates RecallDirectorError.corpusUnavailable when FailClosed is set.
        //
        //   All other cases — fall back to rank-normalised locus-only scoring for
        //   Hybrid/UnionBest+Rrf/Raw. Exception: UnionBest + MatrixAware proceeds to
        //   the full pipeline even without corpus/vector — the matrix scoring pass is
        //   locus-based and does not require corpus/vector.
        let is_matrix_aware_union = request.mode == GLKRecallMode::UnionBest
            && request.scoring == GLKRecallScoring::MatrixAware;
        if !has_corpus && !has_vector && !is_matrix_aware_union {
            use crate::recall::RecallFallbackPolicy;
            if request.mode == GLKRecallMode::CorpusOnly
                && request.fallback == RecallFallbackPolicy::FailClosed
            {
                return Err(VerbDispatchError::RecallLaneUnavailable {
                    reason: "CorpusOnly recall requested with failClosed policy but \
                             no Corpus or VectorStore is registered for this estate; \
                             open the estate with a corpus backend or use AllowDegraded".into(),
                });
            }
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
        // Mutable: after the candidate set is assembled below, the semantic-lane
        // (BM25/vector/dense) source_ids that the locus lane did not return are
        // pool-loaded into this index through the SAME frame (Swift-parity fix).
        let mut drawer_index: HashMap<String, Drawer>;

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

        // --- Lane 3a: Vector Hamming (Lane A, "random-indexing-v1") ---
        // Requires corpus for embed(); vector store for find_nearest().
        // Score = (256 - hamming_distance) / 256.0, matching Swift's hamming→score mapping.
        //
        // Lane B ("distillation-features-v1", structural fingerprint) is merged into
        // vector_list below using max-score deduplication — a drawer in both lanes
        // keeps the higher Hamming similarity score. Combined, Lane A + Lane B share
        // the weights.vector * 0.5 budget slice (FINDING_11X_HAMMING_LANE_2026-07-28).
        //
        // P1 fail-loud contract (SPEC §P1_FAIL_LOUD):
        //   embed failure        → degrade "corpus.embed" (query survives on locus + BM25)
        //   find_nearest failure → degrade "vectorHamming.findNearest" (query survives)
        //   Both are RECOVERABLE: the query returns with fewer signals, not an error throw.
        //   "stage failed" (degraded_stages non-empty) is DISTINGUISHABLE from
        //   "absent evidence" (empty Vec, no matching docs) per gate criterion (3).
        let mut vector_list: Vec<(String, f32)> = if let (Some(ref c), Some(ref vs)) = (&corpus, &vector) {
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

        // --- Lane 3b: Structural fingerprint (Lane B, "distillation-features-v1") ---
        //
        // Queries per-drawer distillation fingerprints written by DistillationCycle.
        // The probe is computed via DistillationPipeline::query_fingerprint with the
        // capitalization-heuristic default_extractor — the same extractor used at
        // distillation write time, so stored and query fingerprints are self-consistent.
        //
        // Dark-lane safety: drawers without a Lane B entry are absent from fp_matches
        // and contribute zero candidates — no penalty relative to distilled drawers.
        // A zero query_fingerprint (query had no structural features) skips this block
        // entirely — same zero-contribution outcome.
        //
        // Hits are merged into vector_list with max-score deduplication: a drawer
        // already returned by Lane A keeps the higher Hamming similarity score.
        // Lane B results therefore only improve, never worsen, any candidate already
        // present from Lane A.
        //
        // Unlike Lane A, Lane B is never covered by the _testForceVectorHammingError
        // seam (that seam is single-use and consumed by Lane A). Lane B uses a plain
        // match — degraded silently (no telemetry), matching Swift's debug-log-only behavior.
        if !query_str.is_empty() {
            if let Some(ref vs) = vector {
                use substrate_ml::distillation_pipeline::DistillationPipeline;
                let fp = DistillationPipeline::query_fingerprint(
                    &query_str,
                    DistillationPipeline::default_extractor,
                );
                if fp != Engram::ZERO {
                    if let Ok(fp_matches) = vs.find_nearest(
                        &fp,
                        crate::brain::distillation_cycle::DISTILLATION_LANE_MODEL_ID,
                        plan.frontier_k,
                    ) {
                        // Max-score merge: build id→score from Lane A, then walk Lane B.
                        let mut score_by_id: HashMap<String, f32> = vector_list
                            .iter()
                            .map(|(id, s)| (id.clone(), *s))
                            .collect();
                        // Ordered id list: Lane A order first, Lane B-only appended.
                        let mut ordered_ids: Vec<String> =
                            vector_list.iter().map(|(id, _)| id.clone()).collect();
                        for m in fp_matches {
                            let score =
                                (256 - m.distance.clamp(0, 256)) as f32 / 256.0;
                            if let Some(existing) = score_by_id.get_mut(&m.item_id) {
                                // Already in Lane A — keep higher score.
                                if score > *existing {
                                    *existing = score;
                                }
                            } else {
                                // Lane B only — append to both structures.
                                score_by_id.insert(m.item_id.clone(), score);
                                ordered_ids.push(m.item_id.clone());
                            }
                        }
                        // Rebuild vector_list with updated scores, preserving order.
                        vector_list = ordered_ids
                            .into_iter()
                            .map(|id| {
                                let s = score_by_id.get(&id).copied().unwrap_or(0.0);
                                (id, s)
                            })
                            .collect();
                    }
                    // else: Lane B dark — expected for estates with no distilled entries.
                    // No telemetry: a dark Lane B is a normal operating state.
                }
            }
        }

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
        // DISCRIMINATION FACTOR (Item 3, MISSION_11X_RECALL_GAP_01): continuous
        // discount applied to the dense column in the matrixAware scoring formula.
        // Declared here (outside the corpus block) so it is in scope for the
        // scoring loop that follows. Default 1.0 = no discount. Mirrors Swift
        // RecallDirector's `denseDiscriminationFactor`. See coordinator comments
        // at the scoring loop for the full mapping.
        let mut dense_discrimination_factor: f32 = 1.0;
        if include_dense {
            if let Some(ref c) = corpus {
                if !query_str.is_empty() {
                    use corpus_kit::{FloatDiscriminationSignal, FloatLaneOutcome};
                    let estate_tag = uuid::Uuid::from_bytes(handle.estate_uuid).to_string();
                    // ANTI-SIMILARITY (6b-modifiers-antisim): a dense lane whose
                    // `dense:<model_id>` key is in `shape.anti_similar_lanes`
                    // inverts its OBJECTIVE — it surfaces the FARTHEST (most
                    // dissimilar) sources via `float_farthest_per_signal` instead
                    // of the nearest. Distinct from a negative weight (which keeps
                    // the nearest and subtracts their mass). When any dense lane is
                    // anti-similar we fetch BOTH passes and pick, per signal, by
                    // model_id; with none (the default) only the nearest pass runs
                    // — byte-identical to the pre-antisim behaviour. Mirrors Swift
                    // RecallDirector's unionBest dense lane.
                    let anti_similar_lanes: std::collections::HashSet<String> = request
                        .recall_shape
                        .as_ref()
                        .map(|s| s.anti_similar_lanes.clone())
                        .unwrap_or_default();
                    // Use the discrimination-aware call. Discrimination is always
                    // measured on the standard nearest-similarity pass — it measures
                    // "are the top-K nearest cosines near-uniform?". The outcomes are
                    // extracted for the anti-similar substitution logic below.
                    let nearest_per_signal_with_disc: Vec<(String, FloatLaneOutcome, Option<FloatDiscriminationSignal>)> =
                        c.float_nearest_per_signal_with_discrimination(&query_str, plan.frontier_k);
                    // Aggregate discrimination: mean relative spread across .Hits signals.
                    // Saturation threshold 0.15 mirrors Swift RecallDirector.
                    // linear ramp: factor = min(1.0, mean_spread / 0.15)
                    //   spread ≈ 0.05 (saturated, short turns): factor ≈ 0.33
                    //   spread ≥ 0.15 (contrastive, clear winner): factor = 1.0
                    let saturation_threshold: f32 = 0.15;
                    let spreads: Vec<f32> = nearest_per_signal_with_disc.iter()
                        .filter_map(|(_, _, d)| d.as_ref().map(|s| s.relative_spread))
                        .collect();
                    if !spreads.is_empty() {
                        let mean_spread: f32 = spreads.iter().sum::<f32>() / spreads.len() as f32;
                        dense_discrimination_factor = (mean_spread / saturation_threshold).min(1.0);
                    }
                    // Extract (model_id, outcome) pairs for the anti-similar substitution.
                    let nearest_per_signal: Vec<(String, FloatLaneOutcome)> =
                        nearest_per_signal_with_disc.into_iter().map(|(m, o, _)| (m, o)).collect();
                    let per_signal: Vec<(String, FloatLaneOutcome)> = if anti_similar_lanes
                        .is_empty()
                    {
                        nearest_per_signal
                    } else {
                        let farthest_per_signal =
                            c.float_farthest_per_signal(&query_str, plan.frontier_k);
                        let mut farthest_by_model: HashMap<String, FloatLaneOutcome> =
                            HashMap::new();
                        for (m, o) in farthest_per_signal {
                            farthest_by_model.insert(m, o);
                        }
                        nearest_per_signal
                            .into_iter()
                            .map(|(model_id, outcome)| {
                                // An anti-similar lane forwards its FARTHEST
                                // candidates; other lanes keep their nearest list.
                                if anti_similar_lanes.contains(&format!("dense:{model_id}")) {
                                    if let Some(f) = farthest_by_model.remove(&model_id) {
                                        return (model_id, f);
                                    }
                                }
                                (model_id, outcome)
                            })
                            .collect()
                    };
                    for (idx, (model_id, outcome)) in per_signal.into_iter().enumerate() {
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
                            FloatLaneOutcome::UnavailableNoVocabHit => {
                                // Trained distributional provider, all query tokens OOV.
                                // Truthful relabel: provider HAS a basis, query misses vocab.
                                // Surface string: "dark:vocabMiss". Mirrors Swift RecallDirector.
                                if idx == 0 {
                                    dense_lane_status = Some("dark:vocabMiss".to_string());
                                }
                                glk_emit!(
                                    crate::telemetry::metric_names::DENSE_LANE_DARK,
                                    1.0,
                                    [("estate_id".to_string(), estate_tag.clone()),
                                     ("reason".to_string(), "vocabMiss".to_string()),
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
                } else {
                    // Part 2 — dense_lane dark:emptyQuery. A corpus is registered
                    // but the query string is empty: the float index cannot be
                    // queried without query text. Tag explicitly so callers can
                    // distinguish "lane never attempted due to empty query" from
                    // "lane ran and returned hits" (None). Mirrors Swift
                    // RecallDirector's else branch on `!text.isEmpty`.
                    dense_lane_status = Some("dark:emptyQuery".to_string());
                }
            } else {
                // Part 2 — dense_lane dark:noCorpus. No corpus is registered for
                // this handle (corpus.is_none()): the dense lane was never attempted.
                // Previously serialized as None (indistinguishable from "active"); now
                // carries an explicit tag. Mirrors Swift RecallDirector's `else if
                // corpusKits[handle] == nil` branch.
                dense_lane_status = Some("dark:noCorpus".to_string());
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

        // Pool-load the semantic-lane candidates the locus lane did not return, so
        // they can be scored AND hydrated (Swift-parity fix — recallUnionBest step
        // 5.5 / recallHybrid extra-id load). The locus lane is capped at frontier_k
        // and ordered ByCaptureTimeDesc, so `drawer_index` currently holds only the
        // most-recently-captured frontier_k drawers. When many drawers share a
        // capture instant — a bulk palace import files tens of thousands at the same
        // ms — a valid ACTIVE drawer surfaced ONLY by BM25/vector/dense is absent
        // from `drawer_index`, and the active-state hydration filter below would drop
        // it as if it were withdrawn. Load those ids THROUGH THE SAME frame: a truly
        // withdrawn/tombstoned/non-matching drawer stays out of `admissible` and is
        // still correctly dropped, while a valid semantic hit outside the locus
        // window becomes hydratable. (The Rust port previously built `drawer_index`
        // from the locus lane alone; the Swift director always pool-loaded the full
        // candidate set by id — this closes that drift, which otherwise dark-holes
        // all semantic recall over a large single-instant import.)
        let extra_ids: Vec<String> = all_ids
            .iter()
            .filter(|id| !drawer_index.contains_key(*id))
            .cloned()
            .collect();
        if !extra_ids.is_empty() {
            match estate.get_drawers_matching_frame(&extra_ids, &request.frame) {
                Ok(filtered) => {
                    for d in filtered.admissible {
                        drawer_index.insert(d.id.clone(), d);
                    }
                }
                Err(_) => {
                    // Supplemental frame-aware load failed — DEGRADE: semantic-only
                    // hits stay unhydratable and fall out of the result, while
                    // locus-indexed hits survive. Mirrors Swift's pool.getDrawers
                    // degraded stage.
                    degraded_stages.push("locus.poolHydrate".to_string());
                }
            }
        }

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
        //         field_fit, co_occurrence, temporal, graph, preference).
        #[allow(clippy::type_complexity)]
        let fused_scored: Vec<(String, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32)>;

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
            // Graph centrality + learned-preference columns (step 5.7). Stay 0.0
            // unless a GraphCache / PreferenceStore is registered for the estate —
            // populated from the caches below, mirroring Swift RecallDirector step 5.7.
            let mut col_graph:        Vec<f32> = vec![0.0; count];
            let mut col_preference:   Vec<f32> = vec![0.0; count];

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

            // Step 5.7 — graph and preference scoring.
            // Candidate-frontier lookups only: per-drawer scores are read from
            // pre-built caches registered by the dreaming / training cycle. No
            // synchronous estate-wide analytics are performed here (spec §15).
            // Columns remain 0.0 when no cache is registered for the estate.
            // normalize_column preserves all-zero columns as 0.0 (absent signal),
            // distinguishing them from non-zero uniform columns (measured-uniform,
            // normalized to 0.5). Absent columns therefore contribute nothing on a
            // fresh estate — the correct behaviour for no priors. Mirrors Swift
            // RecallDirector step 5.7 (`graphCaches[handle]` / `preferenceStores[handle]`).
            if let Some(ref cache) = graph_cache {
                for (i, id) in ordered_ids.iter().enumerate() {
                    col_graph[i] = cache.graph_score(id);
                }
            }
            if let Some(ref store) = preference_store {
                for (i, id) in ordered_ids.iter().enumerate() {
                    col_preference[i] = store.preference_score(id);
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
            Self::normalize_column(&mut col_graph,     count);
            Self::normalize_column(&mut col_preference, count);
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
            // applied in the consensus fold where col_dense was built).
            //
            // 6b-modifiers-matrix-steer: the matrix/graph/preference columns are ALSO
            // shape-steerable — each keys on its own stable id ("fieldFit",
            // "coOccurrence", "temporal", "graph", "preference") and is scaled by that
            // key's signed weight with the same semantics, mirroring Swift. The
            // combined matrix term `weights.matrix * (co + temporal) * 0.5` is split so
            // coOccurrence and temporal steer independently; on the neutral 1.0/1.0
            // path the exact pre-steer combined expression is kept so the back-compat
            // score is byte-identical (float reassociation avoided). col_graph and
            // col_preference carry the registered GraphCache / PreferenceStore lookups
            // (0.0 only when no cache is registered for the estate, same as Swift's
            // absent-cache case); each is scaled by its signed shape weight so the graph
            // and preference lanes steer cross-port identically to Swift.
            let (sh_locus, sh_bm25, sh_hamming, sh_dense) = match &request.recall_shape {
                Some(s) => (
                    s.weight("locus"),
                    s.weight("bm25"),
                    s.weight("hamming"),
                    s.weight("dense"),
                ),
                None => (1.0, 1.0, 1.0, 1.0),
            };
            let (sh_field_fit, sh_co_occur, sh_temporal, sh_graph, sh_preference) =
                match &request.recall_shape {
                    Some(s) => (
                        s.weight("fieldFit"),
                        s.weight("coOccurrence"),
                        s.weight("temporal"),
                        s.weight("graph"),
                        s.weight("preference"),
                    ),
                    None => (1.0, 1.0, 1.0, 1.0, 1.0),
                };
            // Whether co/temporal both steer at the neutral 1.0 weight — when they do,
            // the matrix term uses the EXACT pre-steer combined expression so the
            // nil/all-ones score is byte-identical (no float reassociation).
            let matrix_neutral = sh_co_occur == 1.0 && sh_temporal == 1.0;
            let agreement_bonus: f32 = 0.05;
            for (i, v) in col_final.iter_mut().take(count).enumerate() {
                let matrix_term = if matrix_neutral {
                    let matrix_signal = (col_co_occur[i] + col_temporal[i]) * 0.5;
                    weights.matrix * matrix_signal
                } else {
                    sh_co_occur  * weights.matrix * 0.5 * col_co_occur[i]
                        + sh_temporal * weights.matrix * 0.5 * col_temporal[i]
                };
                // DISCRIMINATION DISCOUNT (Item 3, MISSION_11X_RECALL_GAP_01):
                // `dense_discrimination_factor` ∈ [0, 1] (computed above from the
                // mean relative spread of top-K nearest cosines across all signals).
                // Saturated: factor ≈ 0.33 (spread ~0.05, short-turn stopword mass).
                // Contrastive: factor = 1.0 (spread ≥ 0.15, clear semantic winner).
                // Linear ramp — no cliff. At factor = 1.0 the score is
                // byte-identical to the pre-discount formula. Mirrors Swift.
                // Budget split: Lane A+B Hamming (col_vector) and Dense float (col_dense)
                // each receive HALF the weights.vector budget. Combined they sum to at most
                // weights.vector — eliminating the 2× inflation that occurred when each
                // received the full budget (FINDING_11X_HAMMING_LANE_2026-07-28 §facts 9-10).
                // Mirrors Swift RecallDirector matrixAware scoring formula.
                // The Hamming column does not carry the saturation discount (structural
                // fingerprints are contrastive by design). dense_discrimination_factor applies
                // to col_dense only, not col_vector — parity with Swift.
                *v = sh_locus   * weights.locus              * col_locus[i]
                   + sh_bm25    * weights.bm25               * col_bm25[i]
                   + sh_hamming * weights.vector * 0.5       * col_vector[i]
                   + dense_discrimination_factor * sh_dense * weights.vector * 0.5 * col_dense[i]
                   + sh_field_fit * weights.field_fit * col_field_fit[i]
                   + matrix_term
                   // graph + preference share the `weights.graph` budget slice, exactly
                   // as Swift (RecallDirector step 9: both columns multiply weights.graph).
                   + sh_graph      * weights.graph * col_graph[i]
                   + sh_preference * weights.graph * col_preference[i]
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
                 col_temporal[i],
                 col_graph[i],
                 col_preference[i])
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
            #[allow(clippy::type_complexity)]
            let mut scored: Vec<(String, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32)> = all_ids
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
                    // Trailing zeros: fieldFit, coOccurrence, temporal, graph, preference —
                    // all absent on the non-matrixAware fusion path (no matrix/graph/
                    // preference scoring runs here), matching Swift's .raw/.rrf path.
                    Some((id.clone(), final_score, locus_raw, bm25_raw, vec_raw, dense_raw, 0.0_f32, 0.0_f32, 0.0_f32, 0.0_f32, 0.0_f32))
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
        // ACTIVE-STATE FILTER (withdrawn/tombstoned must not surface): `drawer_index`
        // is the frame-admissible set — the locus lane came from `estate.recall(frame)`
        // and every semantic-lane candidate was pool-loaded above through the SAME
        // frame (`get_drawers_matching_frame`), which excludes withdrawn/tombstoned/
        // non-matching drawers. A BM25/vector/dense candidate therefore ABSENT from
        // `drawer_index` failed that frame filter (e.g. it was withdrawn) and must NOT
        // be surfaced as an unhydrated hit — dropping it mirrors the Swift
        // RecallDirector, which pool-loads the full candidate set by id and drops the
        // frame-filtered ids. (Because the pool load now covers every candidate, this
        // drop is a genuine frame decision, NOT the old locus-frontier truncation that
        // dark-holed valid semantic hits outside the capture-time window.) CorpusOnly
        // (locus lane not scored) keeps its prior behaviour: its drawer_index is the
        // frame-filtered hydration set too, so the same drop rule holds.
        let hits: Vec<RecallHit> = fused_scored
            .into_iter()
            .filter(|(id, ..)| drawer_index.contains_key(id))
            .map(|(id, final_s, locus_s, bm25_s, vec_s, dense_s, ff_s, co_s, t_s, g_s, p_s)| {
                let drawer = drawer_index.get(&id).cloned();
                let mut sources = Vec::new();
                if locus_contributed  && locus_score_map.contains_key(&id)  { sources.push(RecallEvidencePath::LocusBitmap); }
                if bm25_contributed   && bm25_score_map.contains_key(&id)   { sources.push(RecallEvidencePath::CorpusBm25); }
                if vector_contributed && vector_score_map.contains_key(&id) { sources.push(RecallEvidencePath::VectorHamming); }
                if dense_contributed  && dense_score_map.contains_key(&id)  { sources.push(RecallEvidencePath::VectorDense); }
                // Matrix / graph / preference evidence paths when their column is
                // non-zero. This follows the Rust port's established matrix-evidence
                // convention (the matrix paths above): graphCoherence / learnedPreference
                // are surfaced exactly when col_graph[i] / col_preference[i] carry mass
                // from a registered GraphCache / PreferenceStore. (Swift's director does
                // not surface any matrix/graph/preference path in `sources`; that is a
                // pre-existing Swift↔Rust sources divergence NOT introduced here — the
                // score-column parity that closes cross-port RecallShape steering is over `final` and the
                // graph/preference columns, both of which now agree cross-port.)
                if ff_s > 0.0 { sources.push(RecallEvidencePath::MatrixFieldPresence); }
                if co_s > 0.0 { sources.push(RecallEvidencePath::MatrixCoOccurrence); }
                if t_s  > 0.0 { sources.push(RecallEvidencePath::MatrixTemporal); }
                if g_s  > 0.0 { sources.push(RecallEvidencePath::GraphCoherence); }
                if p_s  > 0.0 { sources.push(RecallEvidencePath::LearnedPreference); }
                if sources.is_empty() { sources.push(RecallEvidencePath::LocusBitmap); }
                let score = RecallScoreVector {
                    locus: locus_s,
                    bm25: bm25_s,
                    vector: vec_s,
                    field_fit: ff_s,
                    co_occurrence: co_s,
                    temporal: t_s,
                    graph: g_s,
                    preference: p_s,
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
                if g_s     > 0.0 { explanation.push("graphCoherence".to_string()); }
                if p_s     > 0.0 { explanation.push("learnedPreference".to_string()); }
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

        // Rank-normalised locus-only fallback: neither corpus nor vector is
        // registered, so the dense float lane was never attempted. For UnionBest
        // — the only mode that runs the dense lane — this is the dark:noCorpus
        // state (Wave B Part 2): an explicit tag so callers distinguish "no
        // corpus" from "lane ran and produced hits" (None). Other modes never
        // attempt the dense lane, so they carry None. Mirrors Swift
        // RecallDirector's `else if corpusKits[handle] == nil` → "dark:noCorpus".
        // (The main multi-lane path sets this in the dense block; this fallback
        // return is the no-corpus short-circuit and must carry the same tag.)
        let fallback_dense_lane_status = if matches!(request.mode, GLKRecallMode::UnionBest) {
            Some("dark:noCorpus".to_string())
        } else {
            None
        };
        Ok(GLKRecallResult {
            request,
            plan,
            union_profile,
            dense_lane_status: fallback_dense_lane_status,
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
        let err = coord.reanchor(&h, "row-1", None, None, None).unwrap_err();
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

    // DCP M3 estate seam — mirrors Swift `estateSweepProvesThenSupersedes`:
    // two captured drawers, two active facts on one coordinate with
    // exclusive values → proven: 1; then an ACTIVE supersedes tunnel
    // between the source drawers converts the pair to
    // HistoricalSuccession (F06 end-to-end).
    #[test]
    fn conflict_sweep_proves_then_supersedes() {
        use locus_kit::kg_fact::KGFact;
        use locus_kit::tunnel_operational::{TunnelKind, TunnelLifecycle};

        let (coord, h) = open_one();
        let estate = coord.estate_for(&h).expect("estate");
        let a = coord.capture(&h, cap_frame("Employer claim one."), NOW).unwrap();
        let b = coord.capture(&h, cap_frame("Employer claim two."), NOW).unwrap();
        estate
            .add_kg_fact(&KGFact::new(
                "fact-a".into(),
                "Sarah Chen C0".into(),
                "Employer".into(),
                "Acme Robotics".into(),
                a.id.clone(),
                NOW,
            ))
            .unwrap();
        estate
            .add_kg_fact(&KGFact::new(
                "fact-b".into(),
                "Sarah Chen C0".into(),
                "Employer".into(),
                "Beta Corp".into(),
                b.id.clone(),
                NOW,
            ))
            .unwrap();

        let first = coord.conflict_projection_sweep(&h).expect("sweep");
        assert_eq!(first.diagnostics.scanned, 2);
        assert_eq!(first.diagnostics.projected, 2);
        assert_eq!(first.pairs_evaluated, 1);
        assert_eq!(first.counts.proven_contradiction, 1);

        let mut frame = tunnel_frame("study", "study", "supersession accepted in review");
        frame.source_drawer_id = Some(a.id.clone());
        frame.target_drawer_id = Some(b.id.clone());
        frame.kind = TunnelKind::Supersedes;
        frame.lifecycle = TunnelLifecycle::Active;
        estate.capture_tunnel(frame, NOW).unwrap();

        let second = coord.conflict_projection_sweep(&h).expect("sweep");
        assert_eq!(second.counts.proven_contradiction, 0);
        assert_eq!(second.counts.historical_succession, 1);
    }

    // DCP M6 filing seam — mirrors Swift MeetingDecisionCaptureTests:
    // golden deterministic fact id, active filing + replay skip, the
    // replaces-reference carry, and the F21 precursor (two conflicting
    // controlled transcripts prove through the typed sweep).
    #[test]
    fn meeting_decisions_file_and_prove() {
        let (coord, h) = open_one();

        // Golden deterministic fact id (pinned in both ports).
        assert_eq!(
            EstateCoordinator::meeting_decision_fact_id(
                "drawer-t1",
                "project-phoenix",
                "decision:launch_date",
                "2026-09-15"
            ),
            "a4adaa374550adaeb5fdd72c6648f983567217fc1f6ad2b1b39dc30a8b6d89ac"
        );

        let a = coord.capture(&h, cap_frame("Monday planning meeting."), NOW).unwrap();
        let b = coord.capture(&h, cap_frame("Thursday follow-up meeting."), NOW).unwrap();

        let transcript_a = "Attendees: the platform group.\n\
                            Decision: project-phoenix.launch_date = 2026-09-15\n\
                            Decision: they.launch_date = 2026-10-01";
        let first = coord
            .capture_meeting_decisions(&h, transcript_a, &a.id, NOW)
            .expect("capture decisions");
        assert_eq!(first.filed_fact_ids.len(), 1);
        assert!(first.skipped_existing_ids.is_empty());
        assert_eq!(first.extraction.rejected.len(), 1);

        // Replay skips instead of erroring or duplicating.
        let replay = coord
            .capture_meeting_decisions(&h, transcript_a, &a.id, NOW)
            .expect("replay");
        assert!(replay.filed_fact_ids.is_empty());
        assert_eq!(replay.skipped_existing_ids, first.filed_fact_ids);

        // Replaces reference carried, keyed by the filed fact id.
        let rep = coord
            .capture_meeting_decisions(
                &h,
                "Replaces decision abc-123: project-altair.launch_date = 2026-11-01",
                &a.id,
                NOW,
            )
            .expect("replaces");
        let rep_id = rep.filed_fact_ids[0].clone();
        assert_eq!(rep.replaces_by_fact_id.get(&rep_id).map(String::as_str), Some("abc-123"));

        // F21 precursor: the conflicting second transcript proves
        // through the typed sweep.
        coord
            .capture_meeting_decisions(
                &h,
                "Decision: project-phoenix.launch_date = 2026-10-01",
                &b.id,
                NOW,
            )
            .expect("conflicting transcript");
        let report = coord.conflict_projection_sweep(&h).expect("sweep");
        assert_eq!(report.counts.proven_contradiction, 1);
        assert_eq!(report.proven[0].outcome.key, "decision:project-phoenix");
    }

    // The Elevated sensitivity ceiling on typed proposals (Codex
    // a21d636037ac81918d5c1b791b6fe210). Mirrors the Swift
    // ConflictTunnelLifecycleTests ceiling cases: restricted, secret and
    // mixed pairs are PROVEN by the sweep but never proposed and never
    // persisted; a normal+elevated pair still proposes, so the gate does
    // not over-filter the tier it is supposed to admit.
    #[test]
    fn conflict_proposal_respects_sensitivity_ceiling() {
        use locus_kit::adjectives::AdjectiveSensitivity;
        use locus_kit::kg_fact::KGFact;
        use locus_kit::tunnel_operational::TunnelKind;

        // Plant two conflicting employer claims whose source drawers carry
        // the given sensitivities, run one proposal pass, and report both
        // the pass result and how many contradicts tunnels actually reached
        // the estate. Same event time on both drawers → validity overlap →
        // the pair genuinely proves, which is what makes the gate the only
        // thing that can stop the write.
        let propose_for_pair = |sa: AdjectiveSensitivity, sb: AdjectiveSensitivity| {
            let (coord, h) = open_one();
            let estate = coord.estate_for(&h).expect("estate");
            let mut frame_a = cap_frame("Employer claim one.");
            frame_a.sensitivity = sa;
            let mut frame_b = cap_frame("Employer claim two.");
            frame_b.sensitivity = sb;
            let a = coord.capture(&h, frame_a, NOW).unwrap();
            let b = coord.capture(&h, frame_b, NOW).unwrap();
            estate
                .add_kg_fact(&KGFact::new(
                    "fact-a".into(),
                    "Sarah Chen C0".into(),
                    "Employer".into(),
                    "Acme Robotics".into(),
                    a.id.clone(),
                    NOW,
                ))
                .unwrap();
            estate
                .add_kg_fact(&KGFact::new(
                    "fact-b".into(),
                    "Sarah Chen C0".into(),
                    "Employer".into(),
                    "Beta Corp".into(),
                    b.id.clone(),
                    NOW,
                ))
                .unwrap();
            let report = coord.propose_conflict_tunnels(&h, NOW).expect("propose");
            let persisted = estate
                .all_tunnels()
                .unwrap()
                .into_iter()
                .filter(|t| t.kind == TunnelKind::Contradicts)
                .count();
            (report, persisted)
        };

        // Restricted + restricted: proven, never proposed, and counted as a
        // ceiling skip rather than folded into the dedup tally.
        let (restricted, restricted_persisted) = propose_for_pair(
            AdjectiveSensitivity::Restricted,
            AdjectiveSensitivity::Restricted,
        );
        assert_eq!(restricted.sweep.counts.proven_contradiction, 1);
        assert!(restricted.proposed_tunnel_ids.is_empty());
        assert_eq!(restricted.ceiling_skipped, 1);
        assert_eq!(restricted.suppressed, 0);
        assert_eq!(
            restricted_persisted, 0,
            "no tunnel may be written for a finding above the ceiling"
        );

        // Secret is not a special case — it is the same raw comparison.
        let (secret, secret_persisted) =
            propose_for_pair(AdjectiveSensitivity::Secret, AdjectiveSensitivity::Secret);
        assert_eq!(secret.sweep.counts.proven_contradiction, 1);
        assert!(secret.proposed_tunnel_ids.is_empty());
        assert_eq!(secret.ceiling_skipped, 1);
        assert_eq!(secret.suppressed, 0);
        assert_eq!(secret_persisted, 0);

        // MAX rule: one normal endpoint does not rescue a restricted one.
        let (mixed, mixed_persisted) = propose_for_pair(
            AdjectiveSensitivity::Normal,
            AdjectiveSensitivity::Restricted,
        );
        assert_eq!(mixed.sweep.counts.proven_contradiction, 1);
        assert!(mixed.proposed_tunnel_ids.is_empty());
        assert_eq!(mixed.ceiling_skipped, 1);
        assert_eq!(mixed_persisted, 0);

        // Elevated is INSIDE the mineable Normal tier (normal + elevated),
        // so this pair must still propose exactly one tunnel.
        let (elevated, elevated_persisted) =
            propose_for_pair(AdjectiveSensitivity::Normal, AdjectiveSensitivity::Elevated);
        assert_eq!(elevated.sweep.counts.proven_contradiction, 1);
        assert_eq!(elevated.proposed_tunnel_ids.len(), 1);
        assert_eq!(elevated.ceiling_skipped, 0);
        assert_eq!(elevated.suppressed, 0);
        assert_eq!(elevated_persisted, 1);
    }

    // DCP M5 — tunnel lifecycle. Mirrors Swift
    // ConflictTunnelLifecycleTests: F21 (one proposed tunnel from two
    // conflicting controlled transcripts, live-pair suppression on the
    // second pass), F14 (withdrawn typed rejection at the same
    // rule@version stays rejected), F15 (older-version rejection files
    // a new instance), lexical-rejection independence, and F22
    // (explicit replacement → supersedes tunnel → HistoricalSuccession,
    // proposals stop; unknown replaced ids report unresolved).
    #[test]
    fn conflict_tunnel_lifecycle_f21_f14_f15_f22() {
        use locus_kit::tunnel_operational::{TunnelKind, TunnelLifecycle, TunnelOriginClass};

        // --- F21 + live suppression ---
        let (coord, h) = open_one();
        let a = coord.capture(&h, cap_frame("Monday meeting."), NOW).unwrap();
        let b = coord.capture(&h, cap_frame("Thursday meeting."), NOW).unwrap();
        coord
            .capture_meeting_decisions(
                &h, "Decision: project-phoenix.launch_date = 2026-09-15", &a.id, NOW)
            .unwrap();
        coord
            .capture_meeting_decisions(
                &h, "Decision: project-phoenix.launch_date = 2026-10-01", &b.id, NOW)
            .unwrap();
        let first = coord.propose_conflict_tunnels(&h, NOW).expect("propose");
        assert_eq!(first.sweep.counts.proven_contradiction, 1);
        assert_eq!(first.proposed_tunnel_ids.len(), 1, "F21: one proposed tunnel");
        assert_eq!(first.suppressed, 0);
        let estate = coord.estate_for(&h).unwrap();
        let tunnels: Vec<_> = estate
            .all_tunnels()
            .unwrap()
            .into_iter()
            .filter(|t| t.kind == TunnelKind::Contradicts)
            .collect();
        assert_eq!(tunnels.len(), 1);
        assert_eq!(tunnels[0].lifecycle(), TunnelLifecycle::Proposed);
        assert!(tunnels[0].label.starts_with("dcp: dim.decision.launch_date@1"));
        let second = coord.propose_conflict_tunnels(&h, NOW).expect("propose again");
        assert!(second.proposed_tunnel_ids.is_empty());
        assert_eq!(second.suppressed, 1);

        // --- F14: same-version withdrawn rejection suppresses ---
        let (coord2, h2) = open_one();
        let a2 = coord2.capture(&h2, cap_frame("Meeting A."), NOW).unwrap();
        let b2 = coord2.capture(&h2, cap_frame("Meeting B."), NOW).unwrap();
        coord2
            .capture_meeting_decisions(
                &h2, "Decision: project-phoenix.launch_date = 2026-09-15", &a2.id, NOW)
            .unwrap();
        coord2
            .capture_meeting_decisions(
                &h2, "Decision: project-phoenix.launch_date = 2026-10-01", &b2.id, NOW)
            .unwrap();
        let plant = |label: &str, lifecycle: TunnelLifecycle| {
            let estate2 = coord2.estate_for(&h2).unwrap();
            let mut frame =
                tunnel_frame("study", "study", label);
            frame.source_drawer_id = Some(a2.id.clone());
            frame.target_drawer_id = Some(b2.id.clone());
            frame.kind = TunnelKind::Contradicts;
            frame.origin_class = TunnelOriginClass::Derived;
            frame.lifecycle = lifecycle;
            estate2.capture_tunnel(frame, NOW).unwrap();
        };
        plant("dcp: dim.decision.launch_date@1 result=old", TunnelLifecycle::Withdrawn);
        let f14 = coord2.propose_conflict_tunnels(&h2, NOW).expect("propose");
        assert!(f14.proposed_tunnel_ids.is_empty(), "F14: exact repeat stays rejected");
        assert_eq!(f14.suppressed, 1);

        // --- F15: older-version rejection renews / lexical independence ---
        let (coord3, h3) = open_one();
        let a3 = coord3.capture(&h3, cap_frame("Meeting A."), NOW).unwrap();
        let b3 = coord3.capture(&h3, cap_frame("Meeting B."), NOW).unwrap();
        coord3
            .capture_meeting_decisions(
                &h3, "Decision: project-phoenix.launch_date = 2026-09-15", &a3.id, NOW)
            .unwrap();
        coord3
            .capture_meeting_decisions(
                &h3, "Decision: project-phoenix.launch_date = 2026-10-01", &b3.id, NOW)
            .unwrap();
        {
            let estate3 = coord3.estate_for(&h3).unwrap();
            let mut frame =
                tunnel_frame("study", "study", "dcp: dim.decision.launch_date@0 result=ancient");
            frame.source_drawer_id = Some(a3.id.clone());
            frame.target_drawer_id = Some(b3.id.clone());
            frame.kind = TunnelKind::Contradicts;
            frame.origin_class = TunnelOriginClass::Derived;
            frame.lifecycle = TunnelLifecycle::Withdrawn;
            estate3.capture_tunnel(frame, NOW).unwrap();
            let mut lexical =
                tunnel_frame("study", "study", "hunter: numeric_divergence score=0.9");
            lexical.source_drawer_id = Some(a3.id.clone());
            lexical.target_drawer_id = Some(b3.id.clone());
            lexical.kind = TunnelKind::Contradicts;
            lexical.origin_class = TunnelOriginClass::Derived;
            lexical.lifecycle = TunnelLifecycle::Withdrawn;
            estate3.capture_tunnel(lexical, NOW).unwrap();
        }
        let f15 = coord3.propose_conflict_tunnels(&h3, NOW).expect("propose");
        assert_eq!(
            f15.proposed_tunnel_ids.len(),
            1,
            "F15: version bump + rejected lexical guess must not suppress a typed proof"
        );

        // --- F22: explicit replacement → historical, proposals stop ---
        let (coord4, h4) = open_one();
        let a4 = coord4.capture(&h4, cap_frame("Monday meeting."), NOW).unwrap();
        let b4 = coord4.capture(&h4, cap_frame("Thursday meeting."), NOW).unwrap();
        let first4 = coord4
            .capture_meeting_decisions(
                &h4, "Decision: project-phoenix.launch_date = 2026-09-15", &a4.id, NOW)
            .unwrap();
        let original_fact_id = first4.filed_fact_ids[0].clone();
        let second4 = coord4
            .capture_meeting_decisions(
                &h4,
                &format!(
                    "Replaces decision {original_fact_id}: project-phoenix.launch_date = 2026-10-01"
                ),
                &b4.id,
                NOW,
            )
            .unwrap();
        let (filed, unresolved) =
            coord4.file_supersessions(&h4, &second4, NOW).expect("supersessions");
        assert_eq!(filed.len(), 1, "F22: one supersedes tunnel filed");
        assert!(unresolved.is_empty());
        let sweep = coord4.conflict_projection_sweep(&h4).expect("sweep");
        assert_eq!(sweep.counts.proven_contradiction, 0);
        assert_eq!(sweep.counts.historical_succession, 1);
        let proposals = coord4.propose_conflict_tunnels(&h4, NOW).expect("propose");
        assert!(proposals.proposed_tunnel_ids.is_empty());
        // Unknown replaced-fact id reports unresolved, files nothing.
        let ghost = coord4
            .capture_meeting_decisions(
                &h4,
                "Replaces decision no-such-fact: project-altair.launch_date = 2026-12-01",
                &b4.id,
                NOW,
            )
            .unwrap();
        let (ghost_filed, ghost_unresolved) =
            coord4.file_supersessions(&h4, &ghost, NOW).expect("ghost");
        assert!(ghost_filed.is_empty());
        assert_eq!(ghost_unresolved, vec!["no-such-fact".to_string()]);
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

    fn sample_learn_frame(handle: &str) -> GlkLearnFrame {
        let source = locus_kit::source_catalog_entry::SourceCatalogEntry::new(
            "src-1",
            locus_kit::source_catalog_entry::SourceKind::User,
            "https://example.com",
            LatticeAnchor::udc("004"),
            NOW,
            "cataloger",
        );
        GlkLearnFrame::new(source, handle)
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
            lifetime: EstateLifetime::Durable,
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
            lifetime: EstateLifetime::Durable,
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

    // F3: provision(.glk) registers Corpus's SINGLE shared VectorStore for the
    // scored-recall lane — not a second VectorStore over the same vectors table.
    #[test]
    fn pr_provision_glk_unifies_vector_store_with_corpus() {
        let mut coord = EstateCoordinator::new();
        let (store, storage) = make_provision_stores();
        let params = glk_params("UnifyTest");

        let handle = coord
            .provision(store, storage, None, OwnerCredentials::new("owner"), params, vec![EmbeddingModelConfig::Deterministic])
            .expect("provision should succeed");

        let registered = coord.vector_store_for(&handle).expect("vector store registered");
        let corpus = coord.corpus_for(&handle).expect("corpus registered");
        let shared = corpus.shared_vector_store();
        assert!(
            Arc::ptr_eq(&registered, &shared),
            "GLK scored-recall VectorStore must be Corpus's shared instance, not a duplicate"
        );
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
            lifetime: EstateLifetime::Durable,
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
            lifetime: EstateLifetime::Durable,
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
            lifetime: EstateLifetime::Durable,
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
            lifetime: EstateLifetime::Durable,
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
            lifetime: EstateLifetime::Durable,
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

    // CAP-1: MAX_APRIORI_AUDIT_ENTRIES constant guard. If the cap is ever
    // changed, this test fails loudly rather than silently regressing the
    // safety property. Mirrors Swift's `auditEntriesCapConstantValue` test.
    #[test]
    fn cap1_max_apriori_audit_entries_constant_is_50000() {
        assert_eq!(
            EstateCoordinator::MAX_APRIORI_AUDIT_ENTRIES,
            50_000,
            "MAX_APRIORI_AUDIT_ENTRIES must be 50,000; change only with documented rationale"
        );
    }

    // CAP-2: zero-limit edge case — mine_apriori_rules_with_limit(limit=0)
    // must not panic and must return an empty rule set (no entries, no rows,
    // no associations). Verifies the slice is bounds-safe at limit=0.
    #[test]
    fn cap2_zero_entry_limit_returns_empty_without_panic() {
        let (coord, h) = open_one();
        // Populate the estate so it has audit entries.
        for _ in 0..4 {
            coord.capture(&h, cap_frame("study"), NOW).expect("capture");
        }
        let thresholds = substrate_ml::apriori_mining::AprioriThresholds::new(
            0.0, 0.0, 0.0, 2,
        );
        // entry_limit=0 means the slice is empty; Apriori over zero rows
        // is vacuously empty. Must not panic.
        let out = coord
            .mine_apriori_rules_with_limit(&h, thresholds, 0)
            .expect("must not error on zero-limit");
        assert!(
            out.is_empty(),
            "zero-limit window must produce no rules (no transactions)"
        );
    }

    // CAP-3: behavioral — when entry_limit is smaller than the full audit log,
    // only the most-recent entries (HLC-ascending tail) are mined. Injects
    // entries via real captures, then uses mine_apriori_rules_with_limit to
    // restrict to a subset and verifies it returns without error. We cannot
    // control the exact values produced by capture, but we can prove:
    //   (a) full-limit ≥ entries (no truncation): result same as mine_apriori_rules.
    //   (b) limit=1 (one entry, one row-attribute row): cannot form associations.
    // Mirrors Swift's `auditEntriesCapExcludesOldestEntries` in spirit.
    #[test]
    fn cap3_entry_limit_restricts_mining_window() {
        let (coord, h) = open_one();
        // Capture 4 rows to populate the audit trail.
        for _ in 0..4 {
            coord.capture(&h, cap_frame("study"), NOW).expect("capture");
        }
        let thresholds = substrate_ml::apriori_mining::AprioriThresholds::new(
            0.0, 0.0, 0.0, 2,
        );

        // Full-size limit (larger than any realistic audit log for this test):
        // must agree with mine_apriori_rules.
        let full_out = coord
            .mine_apriori_rules_with_limit(&h, thresholds.clone(), 100_000)
            .expect("full limit must not error");
        let canonical_out = coord
            .mine_apriori_rules(&h, thresholds.clone())
            .expect("canonical path must not error");
        assert_eq!(
            full_out, canonical_out,
            "full-limit path and canonical path must return identical results"
        );

        // Limit=1: a single audit entry produces at most one RowAttributeView
        // row with one item; Apriori needs ≥2 items per transaction for rules.
        // Result must not panic and must be empty or rule-free.
        let single_out = coord
            .mine_apriori_rules_with_limit(&h, thresholds, 1)
            .expect("single-entry limit must not error");
        // A single-entry row can produce at most one item, which cannot form
        // an antecedent+consequent pair — no rules are possible.
        assert!(
            single_out.is_empty(),
            "single-entry window cannot produce Apriori rules"
        );
    }

    // ACC-5: current_audit_log is idempotent — re-reading the same trail
    // produces an unchanged entry count.
    //
    // Pre-existing drift fix (found while verifying the mission's cargo
    // test baseline, AUDIT-ALERT-RESTORE 2026-07-09, unrelated to this
    // mission's blast radius): this test previously called
    // `coord.feed_audit_log(&h)` / read back via the vestigial registry
    // getter `coord.audit_log(&h)`. Both belong to the pre-Bug-4-fix
    // accumulate-into-registry pattern (see `current_audit_log`'s doc
    // comment) and no longer compile against the current coordinator
    // surface — `feed_audit_log` was renamed to `current_audit_log`,
    // which builds a fresh transient log per call instead of accumulating
    // into `self.audit_logs`. Rewritten against the live API, preserving
    // the test's original intent (repeated reads of unchanged estate
    // state converge to the same entry count).
    #[test]
    fn acc5_current_audit_log_is_idempotent() {
        let (coord, h) = open_one();
        coord.capture(&h, cap_frame("alpha"), NOW).expect("capture");
        let first = coord.current_audit_log(&h).expect("current audit log 1").count();
        let second = coord.current_audit_log(&h).expect("current audit log 2").count();
        assert_eq!(first, second, "re-reading the same trail yields the same entry count");
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
        coord.rebuild_derived_accelerators(&h, NOW).expect("rebuild");
        assert!(coord.matrix_tier(&h).is_some(), "tier present after rebuild");
        // The audit log was fed as part of the rebuild.
        //
        // Pre-existing drift fix (found while verifying the mission's cargo
        // test baseline, AUDIT-ALERT-RESTORE 2026-07-09, unrelated to this
        // mission's blast radius): `rebuild_derived_accelerators` no longer
        // accumulates into the registry `self.audit_logs` (Bug 4 fix — see
        // its doc comment), so the registry getter `coord.audit_log(&h)`
        // returns `EstateNotOpen` here for a non-hydrated test estate
        // regardless of the rebuild. `current_audit_log` is the live
        // replacement that rebuilds the same transient snapshot the rebuild
        // step itself consumed.
        assert!(!coord.current_audit_log(&h).expect("log").is_empty());
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

        // Case-insensitivity (the FT entity-filter bug): a capitalised subject/
        // object must match a lower/upper/mixed-case entity. Pre-fix the
        // coordinator matched the original-case subject/object against a lowered
        // entity, so `"Voss".contains("voss")` was false and any capitalised
        // entity filtered to zero — exactly the field-reported regression.
        let voss = coord
            .add_kg_fact(&h, "Voss", "commands", "East Spire", "drawer-ft2", NOW + 2)
            .expect("add Voss fact");
        for needle in ["voss", "VOSS", "Voss", "spire", "EAST SPIRE"] {
            let hit = coord
                .recall_kg_fact_timeline(&h, Some(needle))
                .expect("recall with case-variant entity");
            assert!(
                hit.iter().any(|f| f.id == voss.id),
                "entity {needle:?} must match subject 'Voss' / object 'East Spire' case-insensitively"
            );
        }
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

    // CO-DIST-SEC-1: distill_items_sweep must not distill restricted or secret
    //                source drawers — secfix/punt-g2 sensitivity ceiling parity.
    //
    // Parity with Swift distillItemsSweep which filters candidates through
    //   `getDrawers(ids:matchingFrame: RecallFrame(filterChain: []))`,
    // which goes through insert_defaults → SensitivityAtMost(Elevated).
    // Restricted (32) and Secret (48) exceed the Elevated (16) ceiling and must
    // be silently skipped, producing zero factoids for their content even when
    // the content is long enough to be distillable (≥3 sentences).
    #[test]
    fn co_dist_sec1_sweep_distills_all_sensitivities_on_row(){
        use locus_kit::adjectives::AdjectiveSensitivity;
        use locus_kit::frames::CaptureFrame as LkCaptureFrame;
        use locus_kit::drawer_operational::CaptureChannel;
        use locus_kit::estate_types::LatticeAnchor;

        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            locus_kit::drawer_store_inmemory::InMemoryDrawerStore::new(NOW, None).unwrap()
        );
        let handle = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        let long_content = "Both Memory and Rust implement the same segmenter algorithm. \
                            Memory retains context across Rust sentences. \
                            Rust uses Memory to store recurring entities for distillation.";

        // Drawers at three sensitivity tiers. The representation is a VIEW of
        // the row and lives ON the row whose sensitivity governs it
        // (SPEC_DISTILLATION_STORAGE §2) — there is no cross-row sensitivity
        // floor, so restricted and secret rows distill too (§13.1).
        let mut frame = LkCaptureFrame::new(
            long_content,
            CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("0"),
            "tester",
            "test-v1",
        );
        let normal_id = coord.capture(&handle, frame.clone(), NOW).expect("capture normal").id;
        frame.sensitivity = AdjectiveSensitivity::Restricted;
        let restricted_id = coord.capture(&handle, frame.clone(), NOW).expect("capture restricted").id;
        frame.sensitivity = AdjectiveSensitivity::Secret;
        let secret_id = coord.capture(&handle, frame.clone(), NOW).expect("capture secret").id;

        let drawer_count_before = coord
            .estate_for_verb(&handle).expect("estate")
            .all_drawers().expect("all_drawers").len();

        // No VectorStore registered: the lane is dark but the column writes
        // still land (non-fatal absence, parity with the Swift path).
        let produced = coord
            .distill_items_sweep(&handle, NOW, None)
            .expect("sweep must not error");
        // At least the three fixture drawers distill (seeded system drawers
        // with non-empty content distill too — §13.1 covers EVERY active item).
        assert!(produced >= 3, "all three sensitivity tiers must distill; got {produced}");

        let estate = coord.estate_for_verb(&handle).expect("estate_for_verb");
        let all = estate.all_drawers().expect("all_drawers");
        // §7.2/§11: no drawer was captured by the sweep — the writes are
        // on-row column updates only.
        assert_eq!(all.len(), drawer_count_before, "the sweep must capture no drawers");
        assert!(all.iter().all(|d| d.added_by != "distillation-daemon"));
        for id in [&normal_id, &restricted_id, &secret_id] {
            let row = all.iter().find(|d| &d.id == id).expect("row");
            assert!(row.distilled.is_some(), "row {id} must carry a representation");
            assert_eq!(
                row.distilled_pipeline_version.as_deref(),
                Some(substrate_ml::token_compaction::DISTILLATION_PIPELINE_VERSION)
            );
            assert!(row.distilled_token_count.is_some());
            assert!(row.distilled_at.is_some());
        }
    }

    // CO-DIST-AND-1: UNSAFE direction — a room with 199 distilled + 1
    // undistilled drawer must NEVER be skipped by the sweep.  The
    // operationalAND for the room has bit 19 = 0 (captures lower it) so
    // the sweep must enter the room and find the 1 undistilled drawer.
    #[test]
    fn co_dist_and1_unsafe_direction_room_with_one_undistilled_never_skipped() {
        use locus_kit::frames::CaptureFrame as LkCaptureFrame;
        use locus_kit::drawer_operational::CaptureChannel;
        use locus_kit::estate_types::LatticeAnchor;

        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            locus_kit::drawer_store_inmemory::InMemoryDrawerStore::new(NOW, None).unwrap()
        );
        let handle = coord.open(store, OwnerCredentials::new("owner"), 0, 100).expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        let long_content = "Each item is three sentences long for matrix path. \
                            Second sentence provides context. \
                            Third sentence completes the fixture.";

        // Capture 200 drawers in the same room.
        let mut ids: Vec<String> = Vec::new();
        for i in 0..200i64 {
            let frame = LkCaptureFrame::new(
                long_content,
                CaptureChannel::Typed,
                "lab",
                LatticeAnchor::udc("0"),
                "tester",
                "test-v1",
            );
            let drawer = coord.capture(&handle, frame, NOW + i).expect("capture");
            ids.push(drawer.id);
        }

        // Distill the first 199 via set_distilled_representation directly
        // so we control exactly which drawer remains undistilled.
        let estate = coord.estate_for_verb(&handle).expect("estate");
        for id in ids.iter().take(199) {
            estate
                .set_distilled_representation(
                    id, "rendered",
                    substrate_ml::token_compaction::DISTILLATION_PIPELINE_VERSION,
                    3, NOW,
                )
                .expect("set_distilled_representation");
        }

        // The 200th drawer (ids[199]) is still undistilled.
        // The sweep MUST enter the room and distill it.
        let produced = coord
            .distill_items_sweep(&handle, NOW, None)
            .expect("sweep");
        assert!(
            produced >= 1,
            "one undistilled drawer must be found regardless of the 199 distilled ones; got {produced}"
        );
    }

    // CO-DIST-AND-2: Win fixture — fully-distilled rooms are skipped after
    // the estate is reopened (rebuildAll tightens the AND aggregate so
    // operationalAND bit 19 = 1 for all-distilled rooms, causing the
    // sweep to skip them).
    #[test]
    fn co_dist_and2_win_fixture_fully_distilled_rooms_skipped_after_rebuild() {
        use locus_kit::frames::CaptureFrame as LkCaptureFrame;
        use locus_kit::drawer_operational::CaptureChannel;
        use locus_kit::estate_types::LatticeAnchor;

        // Open two coordinators backed by the SAME store (simulating close +
        // reopen which triggers rebuildAll).
        let storage =
            Arc::new(locus_kit::drawer_store_inmemory::InMemoryDrawerStore::new(NOW, None).unwrap())
                as Arc<dyn DrawerStore>;

        let mut coord = EstateCoordinator::new();
        let handle = coord
            .open(Arc::clone(&storage), OwnerCredentials::new("owner"), 0, 100)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        let long_content = "First sentence sets context. \
                            Second sentence adds detail. \
                            Third sentence is the conclusion.";

        let frame = LkCaptureFrame::new(
            long_content, CaptureChannel::Typed, "lab",
            LatticeAnchor::udc("0"), "tester", "test-v1",
        );
        coord.capture(&handle, frame, NOW).expect("capture");

        // First sweep: distills the one item.
        let first = coord.distill_items_sweep(&handle, NOW, None).expect("first sweep");
        assert!(first >= 1, "item must distill on first sweep; got {first}");

        // Mid-session second sweep: room is entered (operationalAND bit 19 is
        // still 0 from the capture), but nothing to distill.
        let mid = coord.distill_items_sweep(&handle, NOW, None).expect("mid sweep");
        assert_eq!(mid, 0, "mid-session sweep must produce 0 (all distilled already)");

        // Check that the AND is still 0 for bit 19 mid-session.
        let skip_bit =
            locus_kit::drawer_operational::DrawerFeatureFlags::HAS_CURRENT_REPRESENTATION;
        let estate1 = coord.estate_for_verb(&handle).expect("estate1");
        let entries1 = estate1.room_level_fingerprints().expect("entries1");
        let lab_entry1 = entries1.iter().find(|e| e.room == "lab");
        if let Some(lab) = lab_entry1 {
            assert_eq!(
                lab.fingerprint.operational_and & skip_bit, 0,
                "mid-session AND must have bit 19 = 0 (rebuildAll not yet called)"
            );
        }

        // "Reopen" by opening a second coordinator on the same store.
        // This triggers rebuild_container_fingerprints (called inside open)
        // which recomputes the AND from all active drawers.
        let mut coord2 = EstateCoordinator::new();
        let handle2 = coord2
            .open(Arc::clone(&storage), OwnerCredentials::new("owner"), 0, 100)
            .expect("reopen");

        // After rebuildAll (via reopen) the sweep must skip the
        // fully-distilled room and produce 0.
        let post_reopen = coord2.distill_items_sweep(&handle2, NOW, None).expect("post-reopen sweep");
        assert_eq!(
            post_reopen, 0,
            "after rebuildAll (via reopen) the fully-distilled room must be skipped; got {post_reopen}"
        );

        // Fingerprint sanity: bit 19 must be 1 in operationalAND after rebuildAll.
        let estate2 = coord2.estate_for_verb(&handle2).expect("estate2");
        let entries2 = estate2.room_level_fingerprints().expect("entries2");
        if let Some(lab) = entries2.iter().find(|e| e.room == "lab") {
            assert_eq!(
                lab.fingerprint.operational_and & skip_bit, skip_bit,
                "operationalAND bit 19 must be 1 after rebuildAll when all drawers carry it"
            );
        }
    }

    // ── Contradiction hunt (mirrors Swift ContradictionHuntTests) ──────

    fn open_one_with_vectors() -> (EstateCoordinator, EstateHandle, Arc<VectorStore>) {
        let (mut coord, h) = open_one();
        let storage: Arc<dyn persistence_kit::Storage> =
            Arc::new(persistence_kit::inmemory::InMemoryStorage::with_estate(
                uuid::Uuid::new_v4(),
            ));
        storage
            .open(&VectorStore::schema_declaration())
            .expect("open vector schema");
        let vs = Arc::new(VectorStore::new(storage, None));
        coord.register_vector_store(&h, vs.clone());
        (coord, h, vs)
    }

    fn hunt_near() -> engram_lib::Engram {
        substrate_types::fingerprint256::Fingerprint256::new(0xAAAA, 0xBBBB, 0xCCCC, 0xDDDD)
    }

    fn hunt_plant(
        coord: &EstateCoordinator,
        h: &EstateHandle,
        vs: &VectorStore,
        content: &str,
        engram: &engram_lib::Engram,
    ) -> locus_kit::drawer::Drawer {
        let drawer = coord.capture(h, cap_frame(content), NOW).expect("capture");
        vs.add_vector(&drawer.id, engram, "minilm-v6", "1.0", NOW)
            .expect("add_vector");
        drawer
    }

    #[test]
    fn hunt_strong_cue_proposes_tunnel() {
        let (coord, h, vs) = open_one_with_vectors();
        let near = hunt_near();
        let a = hunt_plant(&coord, &h, &vs, "the api timeout is 30 seconds", &near);
        let b = hunt_plant(&coord, &h, &vs, "the api timeout is 90 seconds", &near);

        let report = coord
            .hunt_contradictions(&h, "minilm-v6", 50, None, 64, NOW)
            .expect("hunt");
        assert!(report.vector_store_available);
        assert_eq!(report.proposed.len(), 1);
        let proposal = &report.proposed[0];
        assert_eq!(proposal.cue_kind, "value_divergence");
        let ids: std::collections::HashSet<&str> =
            [proposal.source_drawer_id.as_str(), proposal.target_drawer_id.as_str()]
                .into_iter()
                .collect();
        assert_eq!(ids, [a.id.as_str(), b.id.as_str()].into_iter().collect());

        // The tunnel persisted with the hunter's review state.
        let estate = coord.estate_for_verb(&h).unwrap();
        let tunnels = estate.all_tunnels().unwrap();
        let tunnel = tunnels.iter().find(|t| t.id == proposal.tunnel_id).unwrap();
        assert_eq!(tunnel.kind, locus_kit::tunnel_operational::TunnelKind::Contradicts);
        assert_eq!(
            tunnel.lifecycle(),
            locus_kit::tunnel_operational::TunnelLifecycle::Proposed
        );
        assert_eq!(
            tunnel.origin_class(),
            locus_kit::tunnel_operational::TunnelOriginClass::Derived
        );
        assert_eq!(tunnel.added_by, "contradiction-hunter");
    }

    #[test]
    fn hunt_dedup_is_durable_across_rejection() {
        let (coord, h, vs) = open_one_with_vectors();
        let near = hunt_near();
        hunt_plant(&coord, &h, &vs, "the api timeout is 30 seconds", &near);
        hunt_plant(&coord, &h, &vs, "the api timeout is 90 seconds", &near);

        let first = coord
            .hunt_contradictions(&h, "minilm-v6", 50, None, 64, NOW)
            .expect("hunt 1");
        assert_eq!(first.proposed.len(), 1);

        let second = coord
            .hunt_contradictions(&h, "minilm-v6", 50, None, 64, NOW)
            .expect("hunt 2");
        assert!(second.proposed.is_empty());
        assert_eq!(second.deduplicated, 1);

        // Reject the proposal — the withdrawn tunnel still settles the pair.
        let estate = coord.estate_for_verb(&h).unwrap();
        estate
            .respond_to_tunnel(&first.proposed[0].tunnel_id, false, "tests", None, NOW + 1)
            .expect("reject");
        let third = coord
            .hunt_contradictions(&h, "minilm-v6", 50, None, 64, NOW)
            .expect("hunt 3");
        assert!(third.proposed.is_empty());
        assert_eq!(third.deduplicated, 1);
    }

    #[test]
    fn hunt_borderline_is_returned_not_persisted() {
        let (coord, h, vs) = open_one_with_vectors();
        let near = hunt_near();
        hunt_plant(&coord, &h, &vs, "Bob lives in Paris", &near);
        hunt_plant(&coord, &h, &vs, "Bob does not live in Paris", &near);

        let report = coord
            .hunt_contradictions(&h, "minilm-v6", 50, None, 64, NOW)
            .expect("hunt");
        assert!(report.proposed.is_empty());
        assert_eq!(report.borderline.len(), 1);
        assert_eq!(report.borderline[0].cue_kind, "negation_asymmetry");
        assert!(!report.borderline[0].source_snippet.is_empty());

        let estate = coord.estate_for_verb(&h).unwrap();
        let contradicts = estate
            .all_tunnels()
            .unwrap()
            .into_iter()
            .filter(|t| t.kind == locus_kit::tunnel_operational::TunnelKind::Contradicts)
            .count();
        assert_eq!(contradicts, 0);
    }

    #[test]
    fn hunt_protected_candidates_are_excluded_by_default_ceiling() {
        let (coord, h, vs) = open_one_with_vectors();
        let near = hunt_near();
        let normal = coord
            .capture(&h, cap_frame("Bob lives in Paris"), NOW)
            .expect("capture normal");
        let mut secret_frame = cap_frame("Bob does not live in Paris SECRET-DO-NOT-ECHO");
        secret_frame.sensitivity = locus_kit::adjectives::AdjectiveSensitivity::Secret;
        let secret = coord
            .capture(&h, secret_frame, NOW)
            .expect("capture secret");
        for drawer in [&normal, &secret] {
            vs.add_vector(&drawer.id, &near, "minilm-v6", "1.0", NOW)
                .expect("add vector");
        }

        let report = coord
            .hunt_contradictions(&h, "minilm-v6", 50, None, 64, NOW)
            .expect("hunt");
        assert!(report.proposed.is_empty());
        assert!(report.borderline.is_empty());
        assert_eq!(report.pairs_screened, 0);
    }

    #[test]
    fn hunt_guards_and_missing_vector_store() {
        let (coord, h, vs) = open_one_with_vectors();
        let near = hunt_near();
        hunt_plant(&coord, &h, &vs, "the deploy pipeline is green", &near);
        hunt_plant(&coord, &h, &vs, "quarterly budget review notes", &near);

        let report = coord
            .hunt_contradictions(&h, "minilm-v6", 50, None, 64, NOW)
            .expect("hunt");
        assert!(report.proposed.is_empty());
        assert!(report.borderline.is_empty());
        assert_eq!(report.pairs_screened, 1);

        // A coordinator with no registered VectorStore reports the gap honestly.
        let (bare, bare_h) = open_one();
        let bare_report = bare
            .hunt_contradictions(&bare_h, "minilm-v6", 50, None, 64, NOW)
            .expect("bare hunt");
        assert!(!bare_report.vector_store_available);
    }

    #[test]
    fn hunt_watermark_skips_old_pairs() {
        let (coord, h, vs) = open_one_with_vectors();
        let near = hunt_near();
        hunt_plant(&coord, &h, &vs, "the api timeout is 30 seconds", &near);
        hunt_plant(&coord, &h, &vs, "the api timeout is 90 seconds", &near);

        // Watermark after both captures: nothing is new enough.
        let report = coord
            .hunt_contradictions(&h, "minilm-v6", 50, Some(i64::MAX), 64, NOW)
            .expect("hunt");
        assert!(report.proposed.is_empty());
        assert_eq!(report.pairs_screened, 0);
    }

    #[test]
    fn hunt_corpus_lane_maps_chunk_rows_to_drawer_pairs() {
        // Production estates never hold drawer-keyed vectors: the estate
        // lifecycle registers the corpus's shared vector store and the encode
        // pipeline keys every row by CHUNK UUID under the corpus's own
        // model_id. Reproduce that wiring shape and prove lane-2 mining maps
        // chunk kNN hits back to the owning drawers. Mirrors the Swift
        // `corpusLaneFindsContradictions` test.
        let (mut coord, h) = open_one();
        let storage: Arc<dyn persistence_kit::Storage> =
            Arc::new(persistence_kit::inmemory::InMemoryStorage::with_estate(
                uuid::Uuid::new_v4(),
            ));
        // Token-bag provider: sums a per-token deterministic vector so
        // sentences sharing most tokens land near each other in engram space
        // — the semantic property production's distributional ensemble
        // provides (the whole-text Deterministic hash does not; it leaves
        // every distinct sentence ~128 bits apart).
        let provider = vectorkit::FloatSimHashEmbeddingProvider::new(
            "hunt-token-bag-v1",
            "1.0",
            0xC0FF_EE00,
            |text: &str| {
                let mut acc = vec![0.0f32; 32];
                for token in text
                    .to_lowercase()
                    .split(|c: char| !c.is_ascii_alphanumeric())
                    .filter(|t| !t.is_empty())
                {
                    let mut h = token.bytes().fold(14_695_981_039_346_656_037u64, |a, b| {
                        (a ^ u64::from(b)).wrapping_mul(1_099_511_628_211)
                    });
                    for slot in acc.iter_mut() {
                        h = h
                            .wrapping_mul(6_364_136_223_846_793_005)
                            .wrapping_add(1_442_695_040_888_963_407);
                        let mantissa = (h >> 40) as f32 / (1u64 << 24) as f32;
                        *slot += mantissa * 2.0 - 1.0;
                    }
                }
                Ok(acc)
            },
        );
        // Fdc is the plain pass-through provider slot (stateless, no
        // training) — the vehicle for injecting the token-bag provider.
        let corpus = Arc::new(
            CorpusContentEngine::standalone_on(
                storage,
                vec![EmbeddingModelConfig::Fdc { provider: Box::new(provider) }],
            )
            .expect("open corpus engine"),
        );
        coord.register_vector_store(&h, corpus.shared_vector_store());
        coord.register_corpus(&h, corpus.clone());

        let a = coord
            .capture(&h, cap_frame("the api timeout is 30 seconds"), NOW)
            .expect("capture a");
        let b = coord
            .capture(&h, cap_frame("the api timeout is 90 seconds"), NOW)
            .expect("capture b");
        let filler = coord
            .capture(&h, cap_frame("grocery list apples and oranges"), NOW)
            .expect("capture filler");
        for drawer in [&a, &b, &filler] {
            corpus
                .ingest(&drawer.content, &drawer.id, NOW)
                .expect("ingest");
        }

        // Default model_id "minilm-v6" matches no corpus row — lane 1 is
        // empty by construction; only the corpus lane can find the pair.
        let report = coord
            .hunt_contradictions(&h, "minilm-v6", 50, None, 64, NOW)
            .expect("hunt");
        assert!(report.vector_store_available);
        assert_eq!(
            report.proposed.len(),
            1,
            "corpus lane must propose the value-divergent pair"
        );
        let p = &report.proposed[0];
        assert_eq!(p.cue_kind, "value_divergence");
        let got: std::collections::HashSet<&str> =
            [p.source_drawer_id.as_str(), p.target_drawer_id.as_str()]
                .into_iter()
                .collect();
        let want: std::collections::HashSet<&str> =
            [a.id.as_str(), b.id.as_str()].into_iter().collect();
        assert_eq!(got, want);
    }
}
