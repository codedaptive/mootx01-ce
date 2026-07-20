//! The dreaming daemon's per-cycle ORCHESTRATION (NEURONKIT_SPEC § 3.1
//! steps 1-7) over seam traits, the Rust parity of the Swift
//! `DreamingDaemon` actor's `runCycle`. Where `dreaming_decision` owns the
//! DECISIONS, this module owns the SEQUENCE that wraps them: reduce reward
//! per target (step 1), gather candidates + existing tunnels (steps 2, 5),
//! delegate to `dreaming_decision::decide` (steps 3-6), emit a proposal per
//! cleared candidate, carry `consolidated` / `proposed_keys` across cycles,
//! and write exactly one diary entry (step 7).
//!
//! ── Why seam traits, not a live estate binding ───────────────────────
//! The READ seam (recall traces, co-recall counts, dreamed tunnels) is backable by
//! the Rust `Estate` today. The WRITE seam's `propose` goes through
//! `EstateDreamingSink` (the production adapter, shipped in both Swift and
//! Rust). The Rust adapter routes all writes through the GLK
//! `EstateCoordinator` verb surface (B-1-compliant), matching the Swift
//! adapter's delegation to `GeniusLocusKit`. The orchestration is pure: it talks to the
//! `DreamingSubstrateReader` / `DreamingProposalSink` / `RewardSource`
//! traits, exactly as the Swift actor talks to its protocols, and is gated
//! with deterministic fakes (the same shape as the Swift DreamingDaemonTests
//! fakes).
//!
//! Determinism: no clock, no RNG. The daemon carries `cycle_count` and the
//! caller supplies any time-derived inputs through the seam.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use intellectus_lib::{report, StatSample};

use crate::dreaming_decision::{self, candidate_key};
use crate::solver_bandit::{DreamingTriggerMode, SolverBandit};

/// Minimal identity-free projection of a recall-trace row — the only two
/// fields the cycle reads (the reward source maps `used` to a reward).
#[derive(Clone, Debug, PartialEq)]
pub struct RecallTraceItem {
    pub target: String,
    pub used: bool,
}

/// Identity-free projection of a tunnel — only the two drawer endpoints
/// matter for duplicate suppression. A room-level tunnel has `None`
/// endpoints and cannot duplicate a drawer-pair candidate.
#[derive(Clone, Debug, PartialEq)]
pub struct TunnelLink {
    pub source_drawer_id: Option<String>,
    pub target_drawer_id: Option<String>,
}

/// Full tunnel projection for OMEGA — includes ID (for retire call) and the
/// two drawer endpoints (for reinforcement check). Mirrors the Swift path that
/// reads `Tunnel.sourceDrawerId` / `targetDrawerId` / `id` from the dreamed-
/// active tunnel list. Only used by `run_omega_cycle` and its test fakes.
///  / recall-driven dreaming
#[derive(Clone, Debug, PartialEq)]
pub struct DreamingTunnelItem {
    /// The tunnel's persistent identifier (used to call `retire_tunnel`).
    pub id: String,
    /// Source drawer endpoint (drawer-scoped tunnel).
    pub source_drawer_id: String,
    /// Target drawer endpoint (drawer-scoped tunnel).
    pub target_drawer_id: String,
}

/// A proposal the sink receives. There is no Rust `ProposeFrame` estate
/// type (the propose verb is Brain-layer, `NotSupportedByEstate`); this is
/// the seam's value. `kind` is the proposal-kind tag ("miningPattern").
#[derive(Clone, Debug, PartialEq)]
pub struct ProposeFrameOut {
    pub target: String,
    pub kind: String,
    pub justification: String,
}

/// The one diary entry a cycle writes (step 7). The `entry` text is the
/// integer-only cycle summary, byte-identical to the Swift actor's.
#[derive(Clone, Debug, PartialEq)]
pub struct DreamingDiaryEntry {
    pub agent_name: String,
    pub entry: String,
    pub topic: String,
    pub wing: String,
    pub room: String,
}

/// What one dreaming cycle did — the Rust parity of `DreamingCycleReport`.
#[derive(Clone, Debug, PartialEq)]
pub struct DreamingCycleReport {
    pub candidates_considered: usize,
    pub proposals_emitted: Vec<ProposeFrameOut>,
    pub suppressed_duplicates: usize,
    pub below_threshold: usize,
    pub candidate_scores: BTreeMap<String, f32>,
    pub reward_by_target: BTreeMap<String, f32>,
    pub diary_entry: DreamingDiaryEntry,
}

/// Which reward signal a `RewardSource` derives reward from.
///
/// Both cases are now live. `RecallTrace` is the default implicit source
/// (`RecallTraceItem.used`, C-15). `ExplicitDiaryReward` is backed by
/// `DiaryEntry.reward`, which exists on the substrate since schema v1.
/// Mirrors `RewardSourceKind` (Swift `RewardSource.swift`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RewardSourceKind {
    /// Implicit relevance: `RecallTraceItem.used`. Default source (C-15).
    RecallTrace,
    /// Explicit quality: `DiaryEntry.reward`. Populated by callers that have
    /// a quality signal (user rating, model confidence, etc.). Live since
    /// LocusKit schema v1.
    ExplicitDiaryReward,
}

/// Dreaming-policy gates, mirroring the Swift `DreamingPolicy` fields the
/// cycle reads (NEURONKIT_SPEC § 3.1).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct DreamingPolicy {
    /// Reward threshold (spec default 0.6).
    pub min_success_rate: f32,
    /// Minimum contrastive confidence (spec default 0.7).
    pub min_confidence: f32,
    /// Minimum co-occurrence attempts (spec default 3).
    pub min_attempts: i64,
    /// Tick cadence in milliseconds (spec default 30_000). Used by the
    /// `.timer` and `.hybrid` trigger modes; ignored by `.event`.
    pub tick_interval_ms: i64,
    /// Minimum pending dreaming-queue job count that triggers a cycle in
    /// `.event` and `.hybrid` modes. The host passes the count to
    /// `pump_on_event`; a cycle fires when that count meets or exceeds
    /// this threshold, indicating the estate has accumulated enough new
    /// recall activity to warrant dreaming. Spec default 1 (any non-zero
    /// pending count triggers the event path). Ignored by `.timer` mode.
    pub event_observation_threshold: i64,
}

impl Default for DreamingPolicy {
    /// Spec defaults (NEURONKIT_SPEC § 3.1): 0.6 / 0.7 / 3 / 30_000 / 1.
    fn default() -> Self {
        Self {
            min_success_rate: 0.6,
            min_confidence: 0.7,
            min_attempts: 3,
            tick_interval_ms: 30_000,
            event_observation_threshold: 1,
        }
    }
}

/// Persistence seam for the dreaming policy ("substrate-resident in
/// manifest", NEURONKIT_SPEC § 3.1).
///
/// The daemon never touches the manifest directly (B-1). It loads and
/// saves the policy through this trait. The production adapter
/// `EstateManifestDreamingPolicyStore` binds these methods to the estate
/// manifest via the GLK estate verb surface. Tests satisfy the seam with
/// an in-memory store. Mirrors `DreamingPolicyStore` (Swift `DreamingPolicy.swift`).
pub trait DreamingPolicyStore {
    /// Load the persisted policy, or `None` if none has been saved (the
    /// daemon then falls back to `DreamingPolicy::default()`).
    fn load_policy(&self) -> Option<DreamingPolicy>;

    /// Persist the policy. Subsequent `load_policy()` calls return it.
    fn save_policy(&mut self, policy: DreamingPolicy);

    /// Load the persisted Thompson-Sampling bandit, or `None` if none has been
    /// saved (the daemon then starts from a fresh uniform-prior bandit). Loaded
    /// once at governor construction so a restart resumes the learned trigger-mode
    /// posterior (NEURONKIT_SPEC § 3.4). Default: no bandit persisted.
    /// Mirrors Swift `DreamingPolicyStore.loadBandit`.
    fn load_bandit(&self) -> Option<SolverBandit> {
        None
    }

    /// Persist the bandit state. The governor calls this after each cycle.
    /// Default: discard (in-memory only); the manifest-backed store overrides it.
    /// Mirrors Swift `DreamingPolicyStore.saveBandit`.
    fn save_bandit(&mut self, _bandit: SolverBandit) {}

    /// Load the persisted daemon cycle state, or `None` if none has been saved
    /// (the daemon then starts from its defaults). Loaded once at governor
    /// construction so a restart continues from the prior run's idempotency/cycle
    /// memory. Default: no state persisted.
    /// Mirrors Swift `DreamingPolicyStore.loadDaemonState`.
    fn load_daemon_state(&self) -> Option<DreamingDaemonState> {
        None
    }

    /// Persist the daemon cycle state. The governor calls this after each cycle.
    /// Default: discard (in-memory only); the manifest-backed store overrides it.
    /// Mirrors Swift `DreamingPolicyStore.saveDaemonState`.
    fn save_daemon_state(&mut self, _state: DreamingDaemonState) {}
}

/// The dreaming daemon's across-cycle state, captured for persistence so a
/// restart continues instead of re-discovering and re-proposing.
/// `proposed_keys` is a SORTED Vec so the serialized manifest value is byte-stable.
/// Mirrors Swift `DreamingDaemonState`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DreamingDaemonState {
    pub last_timer_fire_epoch_secs: Option<f64>,
    pub proposed_keys: Vec<String>,
    pub last_reindex_vocab: i64,
    pub consolidated: BTreeMap<String, f32>,
    pub cycle_count: i64,
    /// Per-pair co-recall counts: how many distinct recall events have co-recalled
    /// the drawer pair (a, b). Keyed by the canonical pair key (`candidate_key(a,
    /// b)` — lexicographic "min|max"), which is the same format used for
    /// `consolidated` and `proposed_keys`. Consumed by the T8 dreaming drain
    /// (not this module) to gate `minAttempts` against real co-recall evidence.
    /// `#[serde(default)]` means deserializing an older persisted state that
    /// lacks the field starts with an empty map rather than failing, preserving
    /// backward compatibility across daemon restarts.
    #[serde(default)]
    pub co_recall_counts: BTreeMap<String, u64>,
    /// Epoch-seconds timestamp of the last REM-THETA (daily consolidation) cycle
    /// run. None = never run. Used by the THETA due-check to gate on the 24 h
    /// cadence. Persisted via /manifest-backed daemon state so stdio estates consolidate on
    /// their next invocation even after a restart (D5c). `#[serde(default)]`
    /// keeps older persisted states loading cleanly when this field is absent.
    /// Mirrors Swift `DreamingDaemonState.lastThetaRunAt`.
    #[serde(default)]
    pub last_theta_run_epoch_secs: Option<f64>,
    /// Epoch-seconds timestamp of the last REM-BETA (weekly prune) cycle run.
    /// None = never run. run_beta_cycle (T12) is live. Persisted alongside
    /// THETA and OMEGA. Mirrors Swift `DreamingDaemonState.lastBetaRunAt`.
    #[serde(default)]
    pub last_beta_run_epoch_secs: Option<f64>,
    /// Epoch-seconds timestamp of the last REM-OMEGA (biweekly retire) cycle run.
    /// None = never run. run_omega_cycle (T13) is live. Persisted alongside
    /// THETA and BETA. Mirrors Swift `DreamingDaemonState.lastOmegaRunAt`.
    #[serde(default)]
    pub last_omega_run_epoch_secs: Option<f64>,
}

/// In-memory `DreamingPolicyStore` for tests and for hosts that do not
/// persist policy across process restarts.
/// Mirrors `InMemoryDreamingPolicyStore` (Swift `DreamingPolicy.swift`).
///
/// Stores policy, bandit state, and daemon cycle state in memory; all are
/// lost when the struct is dropped. Production hosts override the trait to
/// write to the estate manifest for cross-restart persistence.
/// This implementation stores daemon state so tests can exercise the full
/// save/load round-trip without a live estate (parity with Swift's
/// `InMemoryDreamingPolicyStore` which was updated in T11 for the same reason).
#[derive(Clone, Debug, Default)]
pub struct InMemoryDreamingPolicyStore {
    stored: Option<DreamingPolicy>,
    stored_daemon_state: Option<DreamingDaemonState>,
}

impl InMemoryDreamingPolicyStore {
    /// Create an empty store, or seed it with an initial policy.
    pub fn new(initial: Option<DreamingPolicy>) -> Self {
        Self { stored: initial, stored_daemon_state: None }
    }
}

impl DreamingPolicyStore for InMemoryDreamingPolicyStore {
    fn load_policy(&self) -> Option<DreamingPolicy> {
        self.stored
    }

    fn save_policy(&mut self, policy: DreamingPolicy) {
        self.stored = Some(policy);
    }

    /// Persist daemon cycle state in memory. The stored state is returned by
    /// subsequent `load_daemon_state()` calls so tests can verify the full
    /// save/load round-trip (/ manifest-backed daemon state). Mirrors Swift
    /// `InMemoryDreamingPolicyStore.saveDaemonState`.
    fn save_daemon_state(&mut self, state: DreamingDaemonState) {
        self.stored_daemon_state = Some(state);
    }

    /// Return the previously saved daemon cycle state, or `None` if none has
    /// been saved since this store was created. Mirrors Swift
    /// `InMemoryDreamingPolicyStore.loadDaemonState`.
    fn load_daemon_state(&self) -> Option<DreamingDaemonState> {
        self.stored_daemon_state.clone()
    }
}

/// Read seam: the three substrate reads a dreaming cycle performs.
/// Mirrors `DreamingSubstrateReader` (Swift `DreamingDaemon.swift`).
pub trait DreamingSubstrateReader {
    /// Recall-trace rows in the reward window. (The since/now windowing is
    /// the production adapter's concern; the trait yields the in-window set.)
    fn recent_recall_traces(&self) -> Vec<RecallTraceItem>;

    /// Drained dreaming-queue windows for the estate (step 2). Each inner
    /// Vec is the set of drawer IDs from one DreamingItem — a single recall
    /// event that co-recalled ≥ 2 distinct drawers. The daemon enumerates
    /// all distinct pairs within each window and bumps `co_recall_counts`
    /// once per pair per window. The adapter delegates to the GLK coordinator's
    /// `drain_dreaming_items`, which drains the queue and replies Done.
    /// Returns an empty Vec when the dreaming queue has no pending jobs.
    fn drain_dreaming_window(&self) -> Vec<Vec<String>>;

    /// Existing tunnels, for duplicate suppression.
    fn existing_tunnels(&self) -> Vec<TunnelLink>;

    /// All non-retired dreamed tunnels — the OMEGA evaluation population.
    ///
    /// Returns tunnels where `is_dreamed() == true` AND `is_retired() == false`.
    /// Declared tunnels (`is_dreamed() == false`) are excluded so OMEGA never
    /// retires them (§12.8 guard). Default: empty Vec — estates that do not
    /// implement OMEGA leave this returning empty and `run_omega_cycle` exits
    /// early without retiring anything (safe no-op).
    ///
    /// Mirrors Swift `DreamingSubstrateReader.dreamedActiveTunnels`.
    fn dreamed_active_tunnels(&self) -> Vec<DreamingTunnelItem> {
        Vec::new()
    }
}

/// Reward seam: derive a reward in `[0, 1]` from a recall-trace row.
///
/// Mirrors the Swift `RewardSource` protocol (NEURONKIT_SPEC § 3.1 step 1).
/// Implementations must report their `kind()` so callers and conformance
/// tests can assert which source is wired.
pub trait RewardSource {
    /// The signal this source derives reward from.
    fn kind(&self) -> RewardSourceKind;

    /// Derived reward for a recall-trace row, in `[0, 1]`.
    fn reward(&self, item: &RecallTraceItem) -> f32;
}

/// The implicit recall-trace reward: `used → 1.0`, otherwise `0.0` (C-15).
/// Derivation per NEURONKIT_SPEC § 3.1 step 1b. Default wiring; callers
/// that do not set `DiaryEntry.reward` continue to use this source.
/// Mirrors `RecallTraceRewardSource` (Swift `RewardSource.swift`).
pub struct RecallTraceRewardSource;

impl RewardSource for RecallTraceRewardSource {
    fn kind(&self) -> RewardSourceKind {
        RewardSourceKind::RecallTrace
    }

    fn reward(&self, item: &RecallTraceItem) -> f32 {
        if item.used {
            1.0
        } else {
            0.0
        }
    }
}

/// The explicit diary reward: `DiaryEntry.reward` (NEURONKIT_SPEC § 3.1
/// step 1a). Reads explicit quality scores keyed by `RecallTraceItem.target`
/// and returns the explicit score when present.
///
/// PRECEDENCE: explicit reward from `DiaryEntry.reward` takes priority over
/// the implicit trace-derived signal. When no explicit reward is keyed for a
/// target the fallback source (`RecallTraceRewardSource`) is consulted, so
/// existing recall-trace behaviour is preserved for rows without an explicit
/// reward.
///
/// The caller supplies a keyed lookup so this source stays deterministic and
/// free of substrate I/O — the daemon pre-reads diary entries via its
/// `DreamingSubstrateReader` seam and passes the reward map here.
/// Mirrors `ExplicitDiaryRewardSource` (Swift `RewardSource.swift`).
pub struct ExplicitDiaryRewardSource {
    /// Explicit rewards by drawer target ID. Populated from
    /// `DiaryEntry.reward` for entries linked to a target drawer.
    pub rewards_by_target: std::collections::BTreeMap<String, f32>,
    /// Fallback source when `rewards_by_target` has no entry for a target.
    /// Default: `RecallTraceRewardSource`.
    pub fallback: Box<dyn RewardSource + Send + Sync>,
}

impl ExplicitDiaryRewardSource {
    /// Construct with a reward map and the default `RecallTraceRewardSource`
    /// fallback. Mirrors `ExplicitDiaryRewardSource.init(rewardsByTarget:)`.
    pub fn new(rewards_by_target: std::collections::BTreeMap<String, f32>) -> Self {
        Self {
            rewards_by_target,
            fallback: Box::new(RecallTraceRewardSource),
        }
    }

    /// Construct with an explicit fallback source.
    pub fn with_fallback(
        rewards_by_target: std::collections::BTreeMap<String, f32>,
        fallback: Box<dyn RewardSource + Send + Sync>,
    ) -> Self {
        Self {
            rewards_by_target,
            fallback,
        }
    }
}

impl RewardSource for ExplicitDiaryRewardSource {
    fn kind(&self) -> RewardSourceKind {
        RewardSourceKind::ExplicitDiaryReward
    }

    /// Returns the explicit diary reward when present, otherwise delegates to
    /// `fallback`. Precedence: explicit → fallback (NEURONKIT_SPEC § 3.1
    /// step 1a overrides step 1b when available).
    fn reward(&self, item: &RecallTraceItem) -> f32 {
        if let Some(&explicit) = self.rewards_by_target.get(&item.target) {
            return explicit;
        }
        self.fallback.reward(item)
    }
}

/// Write seam: emit a proposal, record the cycle diary, prune stale
/// recall-trace rows after the reward sweep, and retire unreinforced dreamed
/// tunnels (OMEGA).
pub trait DreamingProposalSink {
    fn propose(&mut self, frame: ProposeFrameOut);
    fn record_cycle_diary(&mut self, entry: DreamingDiaryEntry);

    /// Delete recall-trace rows whose `recalled_at` is strictly before
    /// `cutoff_iso`. Called after the reward sweep (step 1) so the
    /// recall_trace table stays bounded. `cutoff_iso` is a canonical ISO8601
    /// string (`...SS.000Z`) matching the recalledAt storage format. The trait
    /// method is infallible (the sync-port convention); implementations that
    /// persist trace rows route the deletion through the store and capture any
    /// error out-of-band, while in-memory test fakes are a no-op. Mirrors the
    /// Swift `DreamingProposalSink.pruneRecallTraces(olderThan:)`.
    fn prune_recall_traces(&mut self, cutoff_iso: &str);

    /// Retire a tunnel by flipping bit 13 of its `operational_bitmap`.
    ///
    /// Called by `run_omega_cycle` for each unreinforced dreamed tunnel. Infallible
    /// (sync-port convention): production implementations route through the GLK
    /// seam and capture errors in `write_errors`; in-memory test fakes no-op.
    /// Default: no-op so existing fakes that do not implement OMEGA compile without
    /// changes — matching the Swift `DreamingProposalSink.retireTunnel` protocol
    /// extension default.
    ///
    /// `changed_by` is the agent tag ("dreaming-daemon") for audit logs.
    /// `now_epoch_secs` is the deterministic cycle timestamp (i64 for SQLite TEXT storage).
    ///
    /// Mirrors Swift `DreamingProposalSink.retireTunnel(id:changedBy:now:)`.
    fn retire_tunnel(&mut self, _tunnel_id: &str, _changed_by: &str, _now_epoch_secs: i64) {
        // Default: no-op. Production adapters override; test fakes that do not
        // test OMEGA retirement inherit this and compile without changes.
    }
}

/// Recall-trace retention window in calendar days. Rows older than this are
/// pruned after each reward sweep: a month of reward signal is sufficient for
/// Bradley-Terry convergence; older rows are stale and never re-enter a reward
/// window. Mirrors the Swift `recallTraceRetentionDays = 30`.
pub const RECALL_TRACE_RETENTION_DAYS: f64 = 30.0;

/// Format epoch seconds as the canonical recall-trace ISO8601 string
/// (`YYYY-MM-DDTHH:MM:SS.000Z`), matching LocusKit's `recalledAt` storage
/// format so a lexicographic `recalledAt < cutoff` comparison is exact. The
/// fractional part is always `.000` (the trace clock is epoch-seconds).
fn prune_cutoff_iso(epoch_secs: i64) -> String {
    // The dreaming daemon works internally in epoch-SECONDS (its cadence and
    // retention windows are tuned in seconds). `topology_analysis::epoch_to_iso8601`
    // consumes epoch-MILLISECONDS, so convert at this boundary. It emits
    // `...SSZ` (no fraction); splice in `.000` before the trailing `Z` to match the
    // recalledAt format (the ~30-day cutoff is days from any trace, so the
    // fractional part never affects the lexicographic comparison).
    let no_frac = crate::topology_analysis::epoch_to_iso8601(epoch_secs * 1000);
    match no_frac.strip_suffix('Z') {
        Some(prefix) => format!("{prefix}.000Z"),
        None => no_frac, // defensive: formatter always ends in Z
    }
}

const AGENT_NAME: &str = "dreaming-daemon";
const DIARY_WING: &str = "wing_dreaming-daemon";

/// Candidate key for a tunnel, or `None` when it is not drawer-to-drawer.
/// Mirrors `DreamingDaemon.tunnelKey`.
pub fn tunnel_key(link: &TunnelLink) -> Option<String> {
    match (&link.source_drawer_id, &link.target_drawer_id) {
        (Some(a), Some(b)) => Some(candidate_key(a, b)),
        _ => None,
    }
}

// ─── Corpus growth probe (auto-reindex) ─────────────────────────────────────

/// Vocabulary-growth-and-retrain seam for the auto-reindex step. Mirrors the
/// Swift `CorpusGrowthProbe` protocol (NeuronKit/Sources/NeuronKit/Dreaming/CorpusGrowthProbe.swift).
///
/// Distributional embedding providers (RI / PPMI / LSA / NMF) freeze their
/// vocabulary at training time. Terms ingested after the last retrain are
/// OOV and produce zero-vectors, silently missing novel content in dense
/// recall. The daemon calls this trait after each cycle to measure VOCABULARY
/// growth (P3 item 5) and fire a retrain when the growth trigger is crossed.
pub trait CorpusGrowthProbe {
    /// Current maintained vocabulary anchor in the probe's Corpus — the maximum
    /// maintained vocabulary size across its trainable providers. Returns 0 for
    /// un-wired estates (no Corpus / no trainable provider) so the growth gate
    /// never fires on those.
    fn vocab_anchor(&self) -> i64;

    /// Trigger a full basis retrain. Returns `true` on success, `false` on a
    /// (captured, out-of-band-logged) failure.
    ///
    /// `now_epoch_secs` is the injected cycle timestamp (deterministic; the probe
    /// must not read the system clock). The boolean lets the gate match Swift's
    /// failure policy: the vocab baseline advances ONLY on success, so a failed
    /// reindex re-fires next cycle instead of being silently skipped until more
    /// vocabulary growth accumulates. (Swift gets this for free — its
    /// `reindex(now:)` throws and the baseline assignment is skipped.)
    fn reindex(&mut self, now_epoch_secs: f64) -> bool;
}

/// In-memory `CorpusGrowthProbe` for tests. Records reindex calls; does not
/// touch a live Corpus. Mirrors the test-only `FakeGrowthProbe` in the Swift
/// test suite.
#[derive(Default)]
pub struct InMemoryCorpusGrowthProbe {
    /// The vocabulary anchor returned by `vocab_anchor()`. Tests set this to
    /// simulate vocabulary growth.
    pub vocab: i64,
    /// Timestamps (epoch-seconds) of `reindex()` calls, in call order.
    pub reindex_calls: Vec<f64>,
    /// When true, `reindex()` records nothing and returns `false` — simulates a
    /// storage error without panicking (the gate then does not advance baseline).
    pub error_on_reindex: bool,
}

impl InMemoryCorpusGrowthProbe {
    /// Construct a probe with the given initial vocabulary anchor.
    pub fn new(vocab: i64) -> Self {
        Self { vocab, ..Default::default() }
    }
}

impl CorpusGrowthProbe for InMemoryCorpusGrowthProbe {
    fn vocab_anchor(&self) -> i64 {
        self.vocab
    }

    fn reindex(&mut self, now_epoch_secs: f64) -> bool {
        if self.error_on_reindex {
            // Simulate a captured failure: record nothing and report failure so
            // the gate leaves the baseline unadvanced (retry next cycle).
            return false;
        }
        self.reindex_calls.push(now_epoch_secs);
        true
    }
}

/// Fractional vocabulary growth that triggers an auto-reindex. Mirrors the Swift
/// `autoReindexVocabGrowthFraction` (0.10). The trigger fires on vocabulary
/// drift, not raw chunk count: distributional bases freeze their vocabulary, so
/// novel terms going OOV is what degrades dense recall. Proportional, so a large
/// corpus tolerates more absolute drift before the expensive full retrain.
pub const AUTO_REINDEX_VOCAB_GROWTH_FRACTION: f64 = 0.10;

/// Absolute floor on new vocabulary terms before an auto-reindex, regardless of
/// the fraction. Mirrors the Swift `autoReindexVocabGrowthFloor` (25 terms).
/// Dominates at small vocabularies (avoids thrashing) and is the cold-start gate.
pub const AUTO_REINDEX_VOCAB_GROWTH_FLOOR: i64 = 25;

// ─── DreamingDaemon ──────────────────────────────────────────────────────────

/// The dreaming daemon's across-cycle state and cycle driver — the Rust
/// parity of the Swift `DreamingDaemon` actor (without the async/timer
/// machinery, which is the runtime's concern, not the algorithm's).
pub struct DreamingDaemon {
    pub policy: DreamingPolicy,
    /// Current trigger mode. Mirrors Swift `DreamingDaemon.triggerMode`. Updated
    /// after each cycle by the bandit's Thompson-Sampling re-selection.
    pub trigger_mode: DreamingTriggerMode,
    /// Thompson-Sampling Beta bandit that selects the trigger mode per estate from
    /// observed dreaming-cycle reward (NEURONKIT_SPEC § 3.4). Each cycle updates
    /// the selected arm's posterior and re-selects. Mirrors Swift
    /// `DreamingDaemon.bandit`. Persisted/restored by the host (governor) via the
    /// policy store's `load_bandit`/`save_bandit` seam.
    bandit: SolverBandit,
    consolidated: BTreeMap<String, f32>,
    proposed_keys: BTreeSet<String>,
    cycle_count: i64,
    /// Per-pair co-recall counts — the persistent store T8 bumps on each
    /// drained recall window. Keyed by `candidate_key(a, b)`. Restored
    /// from and snapshotted into `DreamingDaemonState.co_recall_counts` so
    /// counts survive daemon restarts via the governor's F6 persist path.
    /// T8 (not this module) is the only caller of `bump_co_recall`; this
    /// module only owns the store, its snapshot/restore, and the read accessor.
    co_recall_counts: BTreeMap<String, u64>,
    /// Epoch-seconds timestamp of the last TIMER-path `pump` fire, or `None`
    /// on first call. Tracks only timer fires so event-path fires in
    /// `.hybrid` mode do not reset the timer countdown; the two paths are
    /// independent. The daemon never reads the system clock; the caller
    /// injects `now`.
    last_timer_fire_epoch_secs: Option<f64>,
    /// Vocabulary size at the most recent corpus basis retrain (or at daemon
    /// construction). Sentinel value -1 means "not yet initialised": the
    /// first cycle reads the live vocabulary and stores it as the baseline
    /// WITHOUT firing a retrain (the corpus was just trained on first ingest or
    /// opened from a persisted basis). Mirrors Swift `lastReindexVocab`.
    last_reindex_vocab: i64,
    /// Fractional vocabulary growth that triggers an auto-reindex. Defaults to
    /// `AUTO_REINDEX_VOCAB_GROWTH_FRACTION`. Mirrors Swift
    /// `reindexVocabGrowthFraction`.
    reindex_vocab_growth_fraction: f64,
    /// Absolute floor on new vocabulary terms before a retrain, regardless of the
    /// fraction. Defaults to `AUTO_REINDEX_VOCAB_GROWTH_FLOOR`. Mirrors Swift
    /// `reindexVocabGrowthFloor`.
    reindex_vocab_growth_floor: i64,
    /// Epoch-seconds of the last REM-THETA daily consolidation cycle run.
    /// None = never run (THETA is overdue on the first invocation). Persisted via
    /// the /manifest-backed daemon state daemon-state snapshot so the 24 h cadence gate survives
    /// restarts. Mirrors Swift `DreamingDaemon.lastThetaRunAt`.
    last_theta_run_epoch_secs: Option<f64>,
    /// Epoch-seconds of the last REM-BETA weekly prune cycle run. run_beta_cycle
    /// (T12) is live. Mirrors Swift `DreamingDaemon.lastBetaRunAt`.
    last_beta_run_epoch_secs: Option<f64>,
    /// Epoch-seconds of the last REM-OMEGA biweekly retire cycle run.
    /// run_omega_cycle (T13) is live. Mirrors Swift `DreamingDaemon.lastOmegaRunAt`.
    last_omega_run_epoch_secs: Option<f64>,
}

impl DreamingDaemon {
    /// Construct a daemon with the given policy and timer trigger mode.
    /// Auto-reindex is disabled (no growth probe).
    pub fn new(policy: DreamingPolicy) -> Self {
        Self::with_trigger_mode(policy, DreamingTriggerMode::Timer)
    }

    /// Construct a daemon with an explicit trigger mode. Auto-reindex disabled.
    /// Prefer `new` for `.timer`-mode daemons; use this when the bandit has
    /// selected a non-default mode.
    pub fn with_trigger_mode(policy: DreamingPolicy, trigger_mode: DreamingTriggerMode) -> Self {
        Self {
            policy,
            trigger_mode,
            bandit: SolverBandit::default(),
            consolidated: BTreeMap::new(),
            co_recall_counts: BTreeMap::new(),
            proposed_keys: BTreeSet::new(),
            cycle_count: 0,
            last_timer_fire_epoch_secs: None,
            last_reindex_vocab: -1, // sentinel: not yet initialised
            reindex_vocab_growth_fraction: AUTO_REINDEX_VOCAB_GROWTH_FRACTION,
            reindex_vocab_growth_floor: AUTO_REINDEX_VOCAB_GROWTH_FLOOR,
            last_theta_run_epoch_secs: None,
            last_beta_run_epoch_secs: None,
            last_omega_run_epoch_secs: None,
        }
    }

    /// Export the daemon's across-cycle state for persistence.
    /// `proposed_keys` is emitted sorted (BTreeSet iterates in order) so the
    /// serialized value is byte-stable. Mirrors Swift `currentDaemonState()`.
    pub fn daemon_state(&self) -> DreamingDaemonState {
        DreamingDaemonState {
            last_timer_fire_epoch_secs: self.last_timer_fire_epoch_secs,
            proposed_keys: self.proposed_keys.iter().cloned().collect(),
            last_reindex_vocab: self.last_reindex_vocab,
            consolidated: self.consolidated.clone(),
            cycle_count: self.cycle_count,
            co_recall_counts: self.co_recall_counts.clone(),
            last_theta_run_epoch_secs: self.last_theta_run_epoch_secs,
            last_beta_run_epoch_secs: self.last_beta_run_epoch_secs,
            last_omega_run_epoch_secs: self.last_omega_run_epoch_secs,
        }
    }

    /// The current bandit state. Exposed so the host (governor) can persist it
    /// after each cycle. Mirrors Swift `DreamingDaemon.currentBandit()`.
    pub fn current_bandit(&self) -> SolverBandit {
        self.bandit.clone()
    }

    /// Restore the bandit state from persistence. Called once at governor
    /// construction so a restart resumes the learned trigger-mode posterior.
    /// Mirrors the Swift daemon's `loadPersistedPolicy` bandit restore.
    pub fn set_bandit(&mut self, bandit: SolverBandit) {
        self.bandit = bandit;
    }

    /// Restore the daemon's across-cycle state from persistence.
    /// Called once at governor construction so a restart resumes the prior run's
    /// idempotency/cycle memory. Mirrors the Swift daemon's `loadPersistedPolicy`
    /// daemon-state restore.
    pub fn restore_state(&mut self, state: DreamingDaemonState) {
        self.last_timer_fire_epoch_secs = state.last_timer_fire_epoch_secs;
        self.proposed_keys = state.proposed_keys.into_iter().collect();
        self.last_reindex_vocab = state.last_reindex_vocab;
        self.consolidated = state.consolidated;
        self.cycle_count = state.cycle_count;
        self.co_recall_counts = state.co_recall_counts;
        // T11: restore the periodic-cycle last-run timestamps so THETA/BETA/OMEGA
        // cadences gate correctly after a restart (D5c: stdio estates consolidate
        // lazily on invocation using these persisted timestamps).
        self.last_theta_run_epoch_secs = state.last_theta_run_epoch_secs;
        self.last_beta_run_epoch_secs = state.last_beta_run_epoch_secs;
        self.last_omega_run_epoch_secs = state.last_omega_run_epoch_secs;
    }

    /// Override the auto-reindex vocab-growth fraction. Use when the default 10%
    /// is inappropriate for the estate's vocabulary-drift rate.
    pub fn set_reindex_vocab_growth_fraction(&mut self, fraction: f64) {
        self.reindex_vocab_growth_fraction = fraction;
    }

    /// Override the auto-reindex vocab-growth floor (absolute new-term minimum).
    pub fn set_reindex_vocab_growth_floor(&mut self, floor: i64) {
        self.reindex_vocab_growth_floor = floor;
    }

    /// Increment the co-recall count for the canonical pair (a, b) by 1.
    ///
    /// The pair is canonicalized order-independently: whichever endpoint sorts
    /// lower lexicographically is placed first, so `bump_co_recall("x", "y")`
    /// and `bump_co_recall("y", "x")` update the same counter. The key format
    /// is `"min|max"`, identical to `candidate_key` in `dreaming_decision`.
    ///
    /// Each call is one increment — the caller (T8 drain) is responsible for
    /// calling once per distinct recall event, not once per pair per cycle.
    /// Mirrors Swift `DreamingDaemon.bumpCoRecall(_:_:)`.
    pub fn bump_co_recall(&mut self, a: &str, b: &str) {
        let key = candidate_key(a, b);
        let count = self.co_recall_counts.entry(key).or_insert(0);
        *count += 1;
    }

    /// Return the co-recall count for the canonical pair (a, b).
    ///
    /// Returns 0 when the pair has not been co-recalled yet. The lookup is
    /// order-independent: `co_recall_count("x", "y")` and
    /// `co_recall_count("y", "x")` return the same value. Consumed by T8
    /// (not this module) for the `minAttempts` gate.
    /// Mirrors Swift `DreamingDaemon.coRecallCount(_:_:)`.
    pub fn co_recall_count(&self, a: &str, b: &str) -> u64 {
        let key = candidate_key(a, b);
        self.co_recall_counts.get(&key).copied().unwrap_or(0)
    }

    /// Interval-gated pump — the timer-path entry point for the resident loop.
    ///
    /// Mirrors Swift `DreamingDaemon.pump(now:)`:
    ///
    /// - **`.timer`** and **`.hybrid`**: fires when `tick_interval_ms` has
    ///   elapsed since the last TIMER fire, or on the first call (no prior
    ///   timer fire). Sets `last_timer_fire_epoch_secs` on fire.
    /// - **`.event`**: returns `None` unconditionally — the timer path is
    ///   inactive for event mode. Use `pump_on_event` instead.
    ///
    /// DETERMINISM: `now_epoch_secs` is injected by the caller. The daemon
    /// never reads `SystemTime::now()`.
    pub fn pump<R, Q, S>(
        &mut self,
        now_epoch_secs: f64,
        reader: &R,
        reward_source: &Q,
        sink: &mut S,
    ) -> Option<DreamingCycleReport>
    where
        R: DreamingSubstrateReader,
        Q: RewardSource,
        S: DreamingProposalSink,
    {
        // `.event` mode: timer path is inactive — returning None here ensures
        // the mode is not an alias for `.timer`.
        if self.trigger_mode == DreamingTriggerMode::Event {
            return None;
        }

        // Gate: fire if this is the first timer call or the interval has elapsed.
        let interval_secs = self.policy.tick_interval_ms as f64 / 1000.0;
        let should_fire = match self.last_timer_fire_epoch_secs {
            None => true, // first timer call always fires
            Some(last) => (now_epoch_secs - last) >= interval_secs,
        };
        if !should_fire {
            return None;
        }
        let report = self.run_cycle(now_epoch_secs, reader, reward_source, sink);
        // Update the timer baseline AFTER a successful timer fire; event-path
        // fires do NOT update this field.
        self.last_timer_fire_epoch_secs = Some(now_epoch_secs);
        Some(report)
    }

    /// Cheap predicate: would the timer path of `pump(now)` fire at `now`?
    ///
    /// Lets the resident governor SKIP building the (expensive) substrate-reader
    /// snapshot on ticks where the timer interval has not elapsed. Without this,
    /// the governor builds an EstateDreamingReader — a full `recall_trace` window
    /// scan and dreaming-queue probe — on every base tick (sub-second), even though
    /// dreaming fires only every `tick_interval_ms` (30 s default); on a high-traffic
    /// estate that contends the estate connection with the encode drain. Mirrors the
    /// gate inside `pump`; does NOT mutate state. `.event` mode never fires on the
    /// timer path, so it returns false (the governor drives the timer path only).
    /// Swift twin: `DreamingDaemon.timerDue(now:)`.
    pub fn timer_due(&self, now_epoch_secs: f64) -> bool {
        if self.trigger_mode == DreamingTriggerMode::Event {
            return false;
        }
        let interval_secs = self.policy.tick_interval_ms as f64 / 1000.0;
        match self.last_timer_fire_epoch_secs {
            None => true,
            Some(last) => (now_epoch_secs - last) >= interval_secs,
        }
    }

    // ─── REM dispatch table — cadence constants (D5a defaults) ─────────────────

    /// Maximum used-drawer set size for THETA pair enumeration. (NK-15 planned hardening)
    ///
    /// An uncapped N-drawer set produces N×(N-1)/2 pairs, which is O(N²) in
    /// memory and CPU. At 200 the worst case is 19 900 pairs — comparable to a
    /// busy ALPHA cycle and well within memory budget. Drawers beyond the cap
    /// are sorted away deterministically (BTreeSet iteration order = sorted →
    /// first 200 lexicographically). Mirrors Swift `DreamingDaemon.thetaUsedDrawerCap`.
    pub const THETA_USED_DRAWER_CAP: usize = 200;

    /// THETA cadence: 24 h in seconds (D5a daily default). Mirrors Swift
    /// `DreamingDaemon.thetaCadenceSecs`.
    pub const THETA_CADENCE_SECS: f64 = 86_400.0;

    /// BETA cadence: 7 days in seconds (D5a weekly default). Mirrors Swift
    /// `DreamingDaemon.betaCadenceSecs`.
    pub const BETA_CADENCE_SECS: f64 = 604_800.0;

    /// OMEGA cadence: 14 days in seconds (D5a biweekly default). Mirrors Swift
    /// `DreamingDaemon.omegaCadenceSecs`.
    pub const OMEGA_CADENCE_SECS: f64 = 1_209_600.0;

    // ─── REM dispatch table — due-checks ────────────────

    /// True iff the REM-THETA daily-consolidation cycle is due at `now_epoch_secs`.
    ///
    /// Due when the elapsed time since the last run is ≥ 24 h, OR when THETA has
    /// never run (None → overdue on first invocation — the correct cold-start
    /// behaviour; a fresh estate with recall_trace data should consolidate
    /// immediately). Mirrors Swift `DreamingDaemon.thetaDue(now:)`.
    pub fn theta_due(&self, now_epoch_secs: f64) -> bool {
        match self.last_theta_run_epoch_secs {
            None => true,
            Some(last) => (now_epoch_secs - last) >= Self::THETA_CADENCE_SECS,
        }
    }

    /// True iff the REM-BETA weekly-prune cycle is due at `now_epoch_secs`.
    ///
    /// Due when `now >= last_beta_run + 7 d`, or when BETA has never run
    /// (None → overdue on first invocation). Mirrors Swift `DreamingDaemon.betaDue(now:)`.
    pub fn beta_due(&self, now_epoch_secs: f64) -> bool {
        match self.last_beta_run_epoch_secs {
            None => true,
            Some(last) => (now_epoch_secs - last) >= Self::BETA_CADENCE_SECS,
        }
    }

    /// True iff the REM-OMEGA biweekly-retire cycle is due at `now_epoch_secs`.
    ///
    /// Due when `now >= last_omega_run + 14 d`, or when OMEGA has never run
    /// (None → overdue on first invocation). Mirrors Swift `DreamingDaemon.omegaDue(now:)`.
    pub fn omega_due(&self, now_epoch_secs: f64) -> bool {
        match self.last_omega_run_epoch_secs {
            None => true,
            Some(last) => (now_epoch_secs - last) >= Self::OMEGA_CADENCE_SECS,
        }
    }

    // ─── REM-THETA cycle ─────────────────────────────────

    /// Daily bounded consolidation sweep (NEURONKIT_SPEC § 12.6 THETA row).
    ///
    /// Window: the last 24 h of `recall_trace`, bounded by the recalled set²
    /// (never estate shape). The cycle reads all recall_trace rows in the window,
    /// forms pairs from `used=true` drawers only, bumps `co_recall_counts`,
    /// calls `dreaming_decision::decide` (§ 12.5 math UNCHANGED), emits proposals,
    /// updates `consolidated`, writes one diary entry, and advances
    /// `last_theta_run_epoch_secs`. Returns `None` when there are fewer than two
    /// used drawers in the window (nothing to consolidate — mirrors Swift's
    /// `nil` return in the same branch). Mirrors Swift
    /// `DreamingDaemon.runThetaCycle(now:)`.
    ///
    /// `reader` must be constructed with the THETA 24 h window (since = now − 86400s).
    /// The dream_runner passes a fresh reader built for the THETA window; the
    /// governor's tick path does the same. Callers gate on `theta_due` first.
    ///
    /// DETERMINISM: `now_epoch_secs` is injected; no `SystemTime::now()` inside.
    pub fn run_theta_cycle<R, S>(
        &mut self,
        now_epoch_secs: f64,
        reader: &R,
        sink: &mut S,
    ) -> Option<DreamingCycleReport>
    where
        R: DreamingSubstrateReader,
        S: DreamingProposalSink,
    {
        // Step 1: read the 24 h recall_trace window (reader is pre-constructed
        // with the correct window by the caller).
        let traces = reader.recent_recall_traces();

        // Step 2: build reward by target (used → 1.0, unused → 0.0).
        // Keep the strongest signal per target across the full window.
        let mut reward_by_target: BTreeMap<String, f32> = BTreeMap::new();
        for trace in &traces {
            let r: f32 = if trace.used { 1.0 } else { 0.0 };
            let cur = reward_by_target.get(&trace.target).copied().unwrap_or(0.0);
            reward_by_target.insert(trace.target.clone(), cur.max(r));
        }

        // Collect the used-drawer set: only drawers with a `used` trace in the
        // window are eligible for co-recall pairing. Sorted for determinism.
        // Cap at THETA_USED_DRAWER_CAP to bound pair-enumeration cost: an
        // uncapped N-drawer set produces N×(N-1)/2 pairs. At the cap of 200
        // the worst case is 19 900 pairs — comparable to a busy ALPHA cycle
        // and well within memory budget. Drawers beyond the cap are sorted
        // away deterministically (sorted → first 200 lexicographically).
        // Mirrors Swift `DreamingDaemon.thetaUsedDrawerCap`. (NK-15 planned hardening)
        let full_used_set: Vec<String> = traces
            .iter()
            .filter(|t| t.used)
            .map(|t| t.target.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let used_set: Vec<String> = full_used_set
            .into_iter()
            .take(Self::THETA_USED_DRAWER_CAP)
            .collect();

        // Nothing to consolidate if fewer than 2 used drawers in the window.
        if used_set.len() < 2 {
            // Advance last-run timestamp even on a no-op so the next cadence gate
            // measures from this run (avoids a burst of empty theta cycles on a
            // low-recall estate). Mirrors Swift's guard branch.
            self.last_theta_run_epoch_secs = Some(now_epoch_secs);
            return None;
        }

        // Steps 3 & 4: enumerate all distinct co-recall pairs over the used set,
        // bump co_recall_counts once per pair. THETA bumps represent the day's
        // cross-event co-recall accumulation (the 24 h window is one logical event).
        let mut distinct_pairs: Vec<(String, String)> = Vec::new();
        let mut seen_pair_keys: BTreeSet<String> = BTreeSet::new();
        for i in 0..used_set.len() {
            for j in (i + 1)..used_set.len() {
                let a = &used_set[i];
                let b = &used_set[j];
                self.bump_co_recall(a, b);
                let key = candidate_key(a, b);
                if seen_pair_keys.insert(key) {
                    distinct_pairs.push((a.clone(), b.clone()));
                }
            }
        }

        // Build the Observation list. `attempts` is read AFTER bumping so the count
        // reflects the cumulative co-recall history including the bump THETA just applied.
        let observations: Vec<dreaming_decision::Observation> = distinct_pairs
            .iter()
            .map(|(a, b)| dreaming_decision::Observation {
                endpoint_a: a.clone(),
                endpoint_b: b.clone(),
                attempts: self.co_recall_count(a, b) as i64,
                evidence_targets: vec![a.clone(), b.clone()],
            })
            .collect();

        // Step 5 (prep): ACTIVE dreamed tunnel keys for duplicate suppression.
        // Use dreamed_active_tunnels() (not existing_tunnels()) to exclude tunnels
        // that have been tombstoned by the OMEGA stage. Using existing_tunnels() here
        // would permanently block re-formation of associations whose dreamed tunnel
        // was retired: the retired tunnel's key would always appear in the set,
        // suppressing ALPHA forever even when evidence warrants a new association.
        // dreamed_active_tunnels() filters to non-tombstoned dreamed tunnels only.
        // Mirrors Swift DreamingDaemon.swift (secfix/c-brain-glk Part 5).
        let existing_tunnel_keys: BTreeSet<String> = reader
            .dreamed_active_tunnels()
            .iter()
            .map(|t| candidate_key(&t.source_drawer_id, &t.target_drawer_id))
            .collect();

        // Step 5: delegate to decide() (§ 12.5 math UNCHANGED). EWC++ decay is
        // applied by decide() via the `consolidated` map.
        let outcome = dreaming_decision::decide(
            &observations,
            &reward_by_target,
            &existing_tunnel_keys,
            &self.proposed_keys,
            &self.consolidated,
            self.policy.min_confidence,
            self.policy.min_attempts,
            self.policy.min_success_rate,
        );

        // Step 6: fold consolidation + emit proposals ("propose + adjust").
        self.consolidated = outcome.updated_consolidated.clone();
        let mut proposals_emitted: Vec<ProposeFrameOut> = Vec::new();
        for c in &outcome.emitted {
            let frame = ProposeFrameOut {
                target: c.endpoint_a.clone(),
                kind: "miningPattern".to_string(),
                justification: format!(
                    "theta: cross-event consolidation {}<->{} (attempts {}, confidence {})",
                    c.endpoint_a, c.endpoint_b, c.attempts, c.confidence
                ),
            };
            sink.propose(frame.clone());
            self.proposed_keys.insert(c.key.clone());
            proposals_emitted.push(frame);
        }

        // Step 7: one diary entry for this THETA cycle.
        self.cycle_count += 1;
        let entry = DreamingDiaryEntry {
            agent_name: AGENT_NAME.to_string(),
            entry: format!(
                "theta cycle {}: window 24h, used-set {}, pairs {}, proposed {}, suppressed {}, below-threshold {}",
                self.cycle_count,
                used_set.len(),
                observations.len(),
                proposals_emitted.len(),
                outcome.suppressed_duplicates,
                outcome.below_threshold,
            ),
            topic: "dreaming-theta".to_string(),
            wing: DIARY_WING.to_string(),
            room: "diary".to_string(),
        };
        sink.record_cycle_diary(entry.clone());

        // Advance the THETA last-run timestamp.
        self.last_theta_run_epoch_secs = Some(now_epoch_secs);

        Some(DreamingCycleReport {
            candidates_considered: observations.len(),
            proposals_emitted,
            suppressed_duplicates: outcome.suppressed_duplicates,
            below_threshold: outcome.below_threshold,
            candidate_scores: outcome.scores,
            reward_by_target,
            diary_entry: entry,
        })
    }

    // ─── REM-BETA cycle ──────────────────────────────────

    /// Confidence floor below which a `consolidated` entry is pruned by
    /// REM-BETA. An entry strictly below this value has decayed to the point
    /// where even repeated `EWC_RETENTION` (0.9) applications can never
    /// drive it above any reasonable `min_confidence` gate (default 0.7).
    /// At 0.01 × 0.9 = 0.009 — orders of magnitude below any gate value.
    ///
    /// Chosen as an absolute constant (not policy-derived) so BETA's GC
    /// boundary is stable across policy changes. Mirrors Swift
    /// `DreamingDaemon.betaPruneFloor`.
    pub const BETA_PRUNE_FLOOR: f32 = 0.01;

    /// REM-BETA (weekly prune/GC) — recall-driven dreaming
    ///
    /// Memory-only GC that keeps the two in-memory dreaming stores bounded by
    /// recall activity. Mutates only `consolidated` and `co_recall_counts` (the
    /// two in-memory maps), then snapshot-persists the shrunken state via the
    /// caller's policy store. Makes no tunnel writes and does not touch
    /// recall_trace, the dreaming queue, or any estate row — the
    /// "Tunnel writes: none" column of the § 12.6 BETA row is enforced
    /// structurally: the function takes no sink, so it cannot emit proposals,
    /// diary entries, or tunnel prunes.
    ///
    /// ## Prune rules (symmetric both ports, documented)
    ///
    /// **`consolidated` prune:** drop keys whose confidence < `BETA_PRUNE_FLOOR`
    /// (0.01). At that level the entry can never meaningfully influence a future
    /// `decide()` outcome via EWC++ without fresh raw evidence — 0.01 × 0.9 = 0.009.
    /// Fresh raw evidence will re-insert the pair at full strength.
    ///
    /// **`co_recall_counts` prune:** drop keys absent from `consolidated` after
    /// the prune above. An orphaned count (no consolidated entry) holds memory of
    /// recall activity that the EWC store no longer supports; keeping it would let
    /// `min_attempts` gate on stale evidence with no confidence anchoring it.
    ///
    /// The caller persists daemon state after calling this method by passing
    /// `daemon.daemon_state()` to `policy_store.save_daemon_state()` — mirroring
    /// the Swift path where `runBetaCycle` calls `policyStore.saveDaemonState`
    /// directly. (In Rust, the daemon does not own the policy store; the caller
    /// does the save, consistent with the existing THETA pattern.)
    ///
    /// Returns `None` — BETA produces no proposals and writes no diary entry.
    /// Mirrors Swift `DreamingDaemon.runBetaCycle(now:)`.
    ///
    /// DETERMINISM: `now_epoch_secs` is injected; no `SystemTime::now()` inside.
    pub fn run_beta_cycle(&mut self, now_epoch_secs: f64) -> Option<DreamingCycleReport> {
        // ── Prune consolidated: drop entries decayed below BETA_PRUNE_FLOOR ──
        // Collect keys to remove first (cannot mutate map while iterating it).
        let prune_keys: Vec<String> = self
            .consolidated
            .iter()
            .filter(|(_, &v)| v < Self::BETA_PRUNE_FLOOR)
            .map(|(k, _)| k.clone())
            .collect();
        for key in &prune_keys {
            self.consolidated.remove(key);
        }

        // ── Prune co_recall_counts: drop orphaned keys (no consolidated entry) ──
        // A co-recall count is orphaned when its pair was just pruned from
        // consolidated. Keeping orphaned counts allows stale `min_attempts`
        // gating for pairs with no EWC support.
        let orphan_keys: Vec<String> = self
            .co_recall_counts
            .keys()
            .filter(|k| !self.consolidated.contains_key(*k))
            .cloned()
            .collect();
        for key in orphan_keys {
            self.co_recall_counts.remove(&key);
        }

        // ── Advance last-run timestamp ────────────────────────────────────────
        // The caller persists daemon_state() after this returns, which
        // snapshots the shrunken consolidated + co_recall_counts maps so the
        // GC is durable across restarts.
        self.last_beta_run_epoch_secs = Some(now_epoch_secs);

        // BETA returns None: no proposals, no diary entry, no tunnel writes.
        None
    }

    // ─── REM-OMEGA cycle ───────────────────────────────

    /// REM-OMEGA (biweekly retire) — recall-driven dreaming
    ///
    /// Retires dreamed tunnels that have not been reinforced by co-recall
    /// within the 14-day OMEGA window. The retire predicate is:
    ///
    ///   `isDreamed AND NOT reinforced`
    ///
    /// where "reinforced" means BOTH tunnel endpoints (`source_drawer_id`,
    /// `target_drawer_id`) appear in any recall-trace row in the
    /// `[now − OMEGA_CADENCE_SECS, now]` window (used OR unused traces count —
    /// presence in context signals the link is still active).
    ///
    /// §12.8 guard: declared tunnels (`is_dreamed() == false`) are never retired.
    /// `reader.dreamed_active_tunnels()` enforces this at the source — it returns
    /// only tunnels where `is_dreamed() == true` — so the body never sees declared
    /// tunnels.
    ///
    /// Retirement is reversible: a subsequent `associate` verb can re-promote a
    /// retired tunnel by clearing bit 13 via `unretire_tunnel`. The retired tunnel
    /// stays in `all_tunnels()` for full audit history.
    ///
    /// After retirement the recall-trace table is pruned of rows older than the
    /// window start (`now − OMEGA_CADENCE_SECS`) to keep the table bounded —
    /// mirroring the pattern ALPHA applies after its reward sweep.
    ///
    /// The caller (autonomic_governor) passes a reader built for the OMEGA window
    /// and a fresh EstateDreamingSink — the same pattern as THETA.
    ///
    /// DETERMINISM: `now_epoch_secs` is injected; no `SystemTime::now()` inside.
    ///
    /// Mirrors Swift `DreamingDaemon.runOmegaCycle(now:)`.
    pub fn run_omega_cycle<R, S>(
        &mut self,
        now_epoch_secs: f64,
        reader: &R,
        sink: &mut S,
    ) -> Option<DreamingCycleReport>
    where
        R: DreamingSubstrateReader,
        S: DreamingProposalSink,
    {
        // ── Step 1: fetch dreamed active tunnels (§12.8 guard baked in) ──────
        // `dreamed_active_tunnels()` returns only tunnels where
        // `is_dreamed() == true` AND `is_retired() == false`. Declared tunnels
        // are excluded at the source — the body never even sees them.
        let candidates = reader.dreamed_active_tunnels();

        // No dreamed-active tunnels → advance cadence and exit.
        // Common case on LocusOnly or newly-seeded estates.
        if candidates.is_empty() {
            self.last_omega_run_epoch_secs = Some(now_epoch_secs);
            return None;
        }

        // ── Step 2: build the reinforcement set from the OMEGA window ────────
        // Both `used` and `unused` traces count for reinforcement: presence in
        // any recall during the window signals the context is still active.
        // Reinforcement does not require a reward; it requires presence.
        let traces = reader.recent_recall_traces();
        let reinforced: BTreeSet<String> = traces.into_iter().map(|t| t.target).collect();

        // ── Step 3: classify and retire ──────────────────────────────────────
        // For each dreamed-active tunnel, both endpoints must appear in the
        // reinforcement set. If either is absent, retire the tunnel.
        let mut retired_count: usize = 0;
        for tunnel in &candidates {
            if !reinforced.contains(&tunnel.source_drawer_id)
                || !reinforced.contains(&tunnel.target_drawer_id)
            {
                // Retire: flip bit 13. `retire_tunnel` delegates through the
                // DreamingProposalSink seam → GLK → Estate → DrawerStore (B-1).
                // The "dreaming-daemon" changedBy tag lets audit logs distinguish
                // OMEGA retirements from manual ones.
                sink.retire_tunnel(&tunnel.id, AGENT_NAME, now_epoch_secs as i64);
                retired_count += 1;
            }
        }

        // ── Step 4: prune recall-trace table ─────────────────────────────────
        // Remove rows older than the OMEGA window start so the recall_trace
        // table stays bounded. The cutoff is the window start (not `now`) so
        // rows still in the OMEGA window are preserved for the next run.
        let window_start_secs =
            (now_epoch_secs - Self::OMEGA_CADENCE_SECS).max(0.0).floor() as i64;
        sink.prune_recall_traces(&prune_cutoff_iso(window_start_secs));

        // ── Step 5: write diary entry ─────────────────────────────────────────
        self.cycle_count += 1;
        let reinforced_count = candidates.len() - retired_count;
        let entry = DreamingDiaryEntry {
            agent_name: AGENT_NAME.to_string(),
            entry: format!(
                "omega cycle {}: window 14d, dreamed-active {}, reinforced {}, retired {}",
                self.cycle_count,
                candidates.len(),
                reinforced_count,
                retired_count,
            ),
            topic: "dreaming-omega".to_string(),
            wing: DIARY_WING.to_string(),
            room: "diary".to_string(),
        };
        sink.record_cycle_diary(entry.clone());

        // ── Step 6: advance last-run timestamp ───────────────────────────────
        // The caller (autonomic_governor) persists daemon_state() after this
        // returns, snapshotting the updated last_omega_run_epoch_secs for
        // cross-restart persistence.
        self.last_omega_run_epoch_secs = Some(now_epoch_secs);

        // ── Step 7: build report ──────────────────────────────────────────────
        // OMEGA has no candidates-considered / proposals-emitted / scores in
        // the ALPHA/THETA sense. Map retire counts onto the report fields:
        //   candidates_considered = dreamed-active tunnels evaluated
        //   proposals_emitted     = [] (OMEGA emits no proposals; see §12.6)
        //   suppressed_duplicates = reinforced tunnels (kept, not retired)
        //   below_threshold       = 0 (no threshold gate in OMEGA)
        //   candidate_scores      = {} (no scoring in OMEGA)
        //   reward_by_target      = {} (OMEGA does not use the reward model)
        Some(DreamingCycleReport {
            candidates_considered: candidates.len(),
            proposals_emitted: Vec::new(),
            suppressed_duplicates: reinforced_count,
            below_threshold: 0,
            candidate_scores: BTreeMap::new(),
            reward_by_target: BTreeMap::new(),
            diary_entry: entry,
        })
    }

    // ─── Test helper ─────────────────────────────────────────────────────────────

    /// Return the last-run epoch-seconds for the given REM cycle kind. Used by
    /// tests to assert cadence gate state without reading daemon_state().
    /// Mirrors Swift `DreamingDaemon.lastRunAt(for:)`.
    pub fn last_run_epoch_secs(&self, kind: &str) -> Option<f64> {
        match kind {
            "theta" => self.last_theta_run_epoch_secs,
            "beta" => self.last_beta_run_epoch_secs,
            "omega" => self.last_omega_run_epoch_secs,
            _ => None,
        }
    }

    /// Event-gated pump — the event-path entry point for the resident loop.
    ///
    /// Mirrors Swift `DreamingDaemon.pumpOnEvent(observationCount:now:)`:
    ///
    /// - **`.event`** and **`.hybrid`**: fires when `observation_count` meets
    ///   `policy.event_observation_threshold`. Does NOT update
    ///   `last_timer_fire_epoch_secs` — timer and event paths are independent
    ///   in `.hybrid` mode.
    /// - **`.timer`**: returns `None` unconditionally — the event path is
    ///   inactive for timer mode.
    ///
    /// The caller derives `observation_count` from the estate's pending
    /// dreaming-queue job count; this keeps the seam contract intact (the
    /// daemon drains the queue inside `run_cycle` via
    /// `DreamingSubstrateReader::drain_dreaming_window()`).
    pub fn pump_on_event<R, Q, S>(
        &mut self,
        observation_count: i64,
        now_epoch_secs: f64,
        reader: &R,
        reward_source: &Q,
        sink: &mut S,
    ) -> Option<DreamingCycleReport>
    where
        R: DreamingSubstrateReader,
        Q: RewardSource,
        S: DreamingProposalSink,
    {
        // `.timer` mode: event path is inactive.
        if self.trigger_mode == DreamingTriggerMode::Timer {
            return None;
        }

        // Gate: the estate must have enough activity to warrant dreaming.
        if observation_count < self.policy.event_observation_threshold {
            return None;
        }

        // Event fires do NOT update `last_timer_fire_epoch_secs` — the timer
        // countdown is independent of the event path.
        Some(self.run_cycle(now_epoch_secs, reader, reward_source, sink))
    }

    /// Run one dreaming cycle (steps 1-7) against the seams. Mirrors
    /// `DreamingDaemon.runCycle` step for step.
    ///
    /// DETERMINISM: `now_epoch_secs` is the injected timestamp the caller
    /// supplies for all cycle-start and cycle-complete telemetry events. No
    /// `SystemTime::now()` call exists in the cycle path — the caller (the
    /// resident pump loop via `pump`, or a test harness) owns the clock.
    /// This is the conformance contract: cycle-timestamp drift between Rust and
    /// Swift cannot occur because neither side reads the wall clock internally.
    pub fn run_cycle<R, Q, S>(
        &mut self,
        now_epoch_secs: f64,
        reader: &R,
        reward_source: &Q,
        sink: &mut S,
    ) -> DreamingCycleReport
    where
        R: DreamingSubstrateReader,
        Q: RewardSource,
        S: DreamingProposalSink,
    {
        // Self-report: cycle-start event. Off-path cost is a single
        // AtomicBool::load + branch (~1 ns). Matches the Swift DreamingDaemon
        // emit site in DreamingDaemon.swift (NEURONKIT_REPORT_001).
        //
        // The start and complete timestamps both use the injected `now_epoch_secs`
        // — the same instant the caller observed. This keeps telemetry
        // deterministic in tests (no wall-clock jitter) and enforces the
        // conformance contract (cycle timestamps are not sourced from SystemTime).
        let cycle_start_ts = now_epoch_secs;
        {
            let mut start_tags = std::collections::HashMap::new();
            start_tags.insert("status".to_string(), "start".to_string());
            start_tags.insert("cycle".to_string(), (self.cycle_count + 1).to_string());
            report!(StatSample::metric(
                "neuronkit.dream.cycle".to_string(),
                1.0,
                start_tags,
                cycle_start_ts,
            ));
        }

        // Step 1: reward retrieval. Keep the strongest signal per target.
        let traces = reader.recent_recall_traces();
        let mut reward_by_target: BTreeMap<String, f32> = BTreeMap::new();
        for trace in &traces {
            let r = reward_source.reward(trace);
            let cur = reward_by_target.get(&trace.target).copied().unwrap_or(0.0);
            reward_by_target.insert(trace.target.clone(), cur.max(r));
        }

        // Post-step-1 prune: delete trace rows older than the retention window
        // so the table does not grow unboundedly. The cutoff is derived from
        // the injected `now_epoch_secs` (never the system clock) and expressed
        // in the canonical recalledAt ISO format. Mirrors the Swift daemon's
        // post-reward-sweep prune.
        let prune_cutoff_secs =
            (now_epoch_secs - RECALL_TRACE_RETENTION_DAYS * 86_400.0).floor() as i64;
        sink.prune_recall_traces(&prune_cutoff_iso(prune_cutoff_secs));

        // Step 2: drain dreaming-queue windows and build co-recall pairs.
        // Each window is the drawer-ID set from one DreamingItem (one recall
        // event that co-recalled ≥ 2 drawers). We enumerate every distinct
        // unordered pair within each window and bump `co_recall_counts` once
        // per pair per window — counts accumulate across drain events so they
        // reflect total co-recall history, not just this cycle's windows. The
        // drain is non-exclusive; consumed jobs are replied Done inside the
        // adapter before the call returns.
        let windows = reader.drain_dreaming_window();
        let mut distinct_pairs: Vec<(String, String)> = Vec::new();
        let mut seen_pair_keys: BTreeSet<String> = BTreeSet::new();
        for window in &windows {
            if window.len() < 2 {
                continue; // cannot form a pair
            }
            for i in 0..window.len() {
                for j in (i + 1)..window.len() {
                    let a = &window[i];
                    let b = &window[j];
                    // Bump per drain event (once per pair per window).
                    self.bump_co_recall(a, b);
                    // Collect the pair once per cycle for the decide() input.
                    let key = candidate_key(a, b);
                    if seen_pair_keys.insert(key) {
                        // Canonical order: candidate_key puts smaller first.
                        let (first, second) = if a <= b {
                            (a.clone(), b.clone())
                        } else {
                            (b.clone(), a.clone())
                        };
                        distinct_pairs.push((first, second));
                    }
                }
            }
        }
        // Build the Observation list for decide(). `attempts` is read after
        // bumping so it reflects the cumulative co-recall count. `evidence_targets`
        // are [a, b] — the co-recalled drawers are their own evidence.
        let decision_obs: Vec<dreaming_decision::Observation> = distinct_pairs
            .iter()
            .map(|(a, b)| dreaming_decision::Observation {
                endpoint_a: a.clone(),
                endpoint_b: b.clone(),
                // co_recall_count returns u64; cast to i64 for the decide() interface.
                // Counts are non-negative by construction (only incremented).
                attempts: self.co_recall_count(a, b) as i64,
                evidence_targets: vec![a.clone(), b.clone()],
            })
            .collect();
        let candidates_considered = decision_obs.len();

        // Step 5 (prep): ACTIVE dreamed tunnel keys for duplicate suppression.
        // Same as the ALPHA path: use dreamed_active_tunnels() not existing_tunnels(),
        // so tombstoned (OMEGA-retired) tunnels do not permanently suppress
        // re-formation of the same association when evidence warrants it.
        let existing_tunnel_keys: BTreeSet<String> = reader
            .dreamed_active_tunnels()
            .iter()
            .map(|t| candidate_key(&t.source_drawer_id, &t.target_drawer_id))
            .collect();
        let outcome = dreaming_decision::decide(
            &decision_obs,
            &reward_by_target,
            &existing_tunnel_keys,
            &self.proposed_keys,
            &self.consolidated,
            self.policy.min_confidence,
            self.policy.min_attempts,
            self.policy.min_success_rate,
        );

        // Fold consolidation back; emit one proposal per cleared candidate.
        self.consolidated = outcome.updated_consolidated.clone();
        let mut proposals_emitted: Vec<ProposeFrameOut> = Vec::new();
        for c in &outcome.emitted {
            let frame = ProposeFrameOut {
                target: c.endpoint_a.clone(),
                kind: "miningPattern".to_string(),
                justification: format!(
                    "dreaming: latent alignment {}<->{} (attempts {}, confidence {})",
                    c.endpoint_a, c.endpoint_b, c.attempts, c.confidence
                ),
            };
            sink.propose(frame.clone());
            self.proposed_keys.insert(c.key.clone());
            proposals_emitted.push(frame);
        }

        // Step 7: exactly one diary entry. The integer summary is
        // byte-identical to the Swift actor's.
        self.cycle_count += 1;

        // Self-report: cycle-complete event with observation and proposal
        // counts. Mirrors the Swift DreamingDaemon complete emit
        // (NEURONKIT_REPORT_001). `proposals_emitted.len()` at this point is
        // the final count for the cycle.
        //
        // The complete timestamp reuses `now_epoch_secs` (the injected instant)
        // rather than reading the system clock again. The cycle duration is
        // sub-millisecond in all benchmarked cases; the conformance benefit
        // (determinism, no wall-clock dependency) outweighs the tiny imprecision.
        let cycle_complete_ts = now_epoch_secs;
        {
            let mut complete_tags = std::collections::HashMap::new();
            complete_tags.insert("status".to_string(), "complete".to_string());
            complete_tags.insert("cycle".to_string(), self.cycle_count.to_string());
            complete_tags.insert("drawers_touched".to_string(), candidates_considered.to_string());
            complete_tags.insert("proposals".to_string(), proposals_emitted.len().to_string());
            report!(StatSample::metric(
                "neuronkit.dream.cycle".to_string(),
                proposals_emitted.len() as f64,
                complete_tags,
                cycle_complete_ts,
            ));
        }

        let entry = DreamingDiaryEntry {
            agent_name: AGENT_NAME.to_string(),
            entry: format!(
                "dreaming cycle {}: considered {}, proposed {}, suppressed {}, below-threshold {}",
                self.cycle_count,
                candidates_considered,
                proposals_emitted.len(),
                outcome.suppressed_duplicates,
                outcome.below_threshold
            ),
            topic: "dreaming-cycle".to_string(),
            wing: DIARY_WING.to_string(),
            room: "diary".to_string(),
        };
        sink.record_cycle_diary(entry.clone());

        // ── Bandit reward observation and re-selection (NEURONKIT_SPEC § 3.4) ─
        // Reward is the mean recall-trace reward this cycle: high when callers
        // acted on the substrate state the trigger mode surfaced (used → 1.0),
        // low when rows went unused (0.0). An empty reward window gets a neutral
        // 0.5 so the arm is neither credited nor penalised. The bandit observes
        // the selected arm's reward and re-selects the trigger mode for the next
        // cycle. Seed is the cycle timestamp's bit pattern — deterministic for the
        // same `now`. The host persists the bandit after the cycle via the policy
        // store's `save_bandit` seam. Mirrors Swift `DreamingDaemon.runCycle`.
        let cycle_reward: f64 = if reward_by_target.is_empty() {
            0.5
        } else {
            let sum: f64 = reward_by_target.values().map(|&r| r as f64).sum();
            sum / reward_by_target.len() as f64
        };
        self.bandit.observe(self.trigger_mode, cycle_reward);
        // Match Swift `UInt64(bitPattern: Int64(now * 1000))`: truncate toward
        // zero to i64, then reinterpret the bits as u64.
        let bandit_seed = (now_epoch_secs * 1_000.0) as i64 as u64;
        self.trigger_mode = self.bandit.select(bandit_seed);

        // ── Auto-reindex step: trigger corpus basis retrain on growth ──────
        // Mirrors Swift `DreamingDaemon.runCycle` auto-reindex block.
        // The probe is passed in by the caller via `run_cycle_with_probe`; when
        // `run_cycle` is called without a probe the block is a no-op.
        // Probe logic is intentionally post-diary so a reindex error does not
        // prevent the diary from being written (the diary write is step 7 in the
        // spec, and the reindex is an extension step, not a numbered spec step).
        //
        // Failure handling: `reindex` returns a success bool (it never panics —
        // implementations capture storage errors out-of-band and report false).
        // On failure the baseline is NOT advanced, so the gate re-fires next
        // cycle (retry) — matching Swift, whose throwing `reindex(now:)` skips the
        // baseline assignment. The cycle always continues regardless.
        //
        // Baseline sentinel: `last_reindex_vocab == -1` on the first cycle.
        // We read the live vocabulary and store it WITHOUT firing a retrain — the
        // corpus was just trained on first ingest or opened from a persisted basis.
        // See `autoReindexGrowthThreshold` in Swift for the vocabulary rationale.

        let report = DreamingCycleReport {
            candidates_considered,
            proposals_emitted,
            suppressed_duplicates: outcome.suppressed_duplicates,
            below_threshold: outcome.below_threshold,
            candidate_scores: outcome.scores,
            reward_by_target,
            diary_entry: entry,
        };
        report
    }

    /// Run one dreaming cycle with an optional corpus growth probe. The probe
    /// is checked after step 7 (diary write) to gate auto-reindex on corpus
    /// growth. Mirrors the auto-reindex block in Swift `DreamingDaemon.runCycle`.
    ///
    /// Pass `probe: None` to skip auto-reindex (equivalent to `run_cycle`).
    ///
    /// DETERMINISM: `now_epoch_secs` is passed to `probe.reindex()` — the probe
    /// must not read the system clock internally.
    pub fn run_cycle_with_probe<R, Q, S, P>(
        &mut self,
        now_epoch_secs: f64,
        reader: &R,
        reward_source: &Q,
        sink: &mut S,
        probe: Option<&mut P>,
    ) -> DreamingCycleReport
    where
        R: DreamingSubstrateReader,
        Q: RewardSource,
        S: DreamingProposalSink,
        P: CorpusGrowthProbe,
    {
        let report = self.run_cycle(now_epoch_secs, reader, reward_source, sink);

        if let Some(p) = probe {
            let live_vocab = p.vocab_anchor();
            if self.last_reindex_vocab == -1 {
                // First cycle: establish baseline, do not retrain.
                self.last_reindex_vocab = live_vocab;
            } else {
                // Trigger = max(absolute floor, ceil(fraction × baseline)). The
                // floor dominates at small vocabularies (no thrashing); the
                // fraction dominates at large ones (proportional drift tolerance).
                let fractional = (self.last_reindex_vocab as f64
                    * self.reindex_vocab_growth_fraction)
                    .ceil() as i64;
                let trigger = self.reindex_vocab_growth_floor.max(fractional);
                if live_vocab - self.last_reindex_vocab >= trigger {
                    // Vocabulary drift crossed the trigger — retrain. Advance the
                    // baseline ONLY on success: a failed reindex leaves the
                    // baseline unadvanced so the gate re-fires next cycle (retry),
                    // matching Swift, where a throwing `reindex(now:)` skips the
                    // baseline assignment.
                    if p.reindex(now_epoch_secs) {
                        self.last_reindex_vocab = live_vocab;
                    }
                }
            }
        }

        report
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Drain-once FakeReader with interior-mutable window queue.
    /// The `DreamingSubstrateReader` trait takes `&self`, but drain is
    /// stateful (pop-once). We use `RefCell` for interior mutability — safe
    /// in single-threaded test contexts.
    struct FakeReaderMut {
        traces: Vec<RecallTraceItem>,
        window_batches: std::cell::RefCell<std::collections::VecDeque<Vec<Vec<String>>>>,
        // Legacy field kept for `existing_tunnels()` (used by OMEGA fake tunnels
        // in dreamed_active_tunnels tests that need TunnelLink format). ALPHA now
        // uses `dreamed_active_tunnels` — seed `dreamed_tunnels` to test dedup.
        tunnels: Vec<TunnelLink>,
        /// Active dreamed tunnels returned by dreamed_active_tunnels().
        /// Seed these to verify ALPHA duplicate suppression excludes retired tunnels.
        dreamed_tunnels: Vec<DreamingTunnelItem>,
    }
    impl FakeReaderMut {
        /// Seed with explicit batches (one per drain call) and legacy tunnel links.
        fn new(
            traces: Vec<RecallTraceItem>,
            batches: Vec<Vec<Vec<String>>>,
            tunnels: Vec<TunnelLink>,
        ) -> Self {
            Self {
                traces,
                window_batches: std::cell::RefCell::new(batches.into()),
                tunnels,
                dreamed_tunnels: vec![],
            }
        }
        /// Seed with explicit batches and active dreamed tunnels (for ALPHA dedup tests).
        fn new_with_dreamed(
            traces: Vec<RecallTraceItem>,
            batches: Vec<Vec<Vec<String>>>,
            dreamed_tunnels: Vec<DreamingTunnelItem>,
        ) -> Self {
            Self {
                traces,
                window_batches: std::cell::RefCell::new(batches.into()),
                tunnels: vec![],
                dreamed_tunnels,
            }
        }
        /// No drain windows, no tunnels.
        fn empty() -> Self {
            Self::new(vec![], vec![], vec![])
        }
        /// Seed traces only.
        fn with_traces(traces: Vec<RecallTraceItem>) -> Self {
            Self::new(traces, vec![], vec![])
        }
    }
    impl DreamingSubstrateReader for FakeReaderMut {
        fn recent_recall_traces(&self) -> Vec<RecallTraceItem> {
            self.traces.clone()
        }
        fn drain_dreaming_window(&self) -> Vec<Vec<String>> {
            let mut q = self.window_batches.borrow_mut();
            q.pop_front().unwrap_or_default()
        }
        fn existing_tunnels(&self) -> Vec<TunnelLink> {
            self.tunnels.clone()
        }
        fn dreamed_active_tunnels(&self) -> Vec<DreamingTunnelItem> {
            self.dreamed_tunnels.clone()
        }
    }

    /// Records what the cycle wrote, like the Swift RecordingSink.
    #[derive(Default)]
    struct RecordingSink {
        proposals: Vec<ProposeFrameOut>,
        diaries: Vec<DreamingDiaryEntry>,
        prune_cutoffs: Vec<String>,
    }
    impl DreamingProposalSink for RecordingSink {
        fn propose(&mut self, frame: ProposeFrameOut) {
            self.proposals.push(frame);
        }
        fn record_cycle_diary(&mut self, entry: DreamingDiaryEntry) {
            self.diaries.push(entry);
        }
        fn prune_recall_traces(&mut self, cutoff_iso: &str) {
            self.prune_cutoffs.push(cutoff_iso.to_string());
        }
    }

    fn trace(target: &str, used: bool) -> RecallTraceItem {
        RecallTraceItem {
            target: target.to_string(),
            used,
        }
    }
    /// Build one window (one co-recall event) containing the given drawer IDs.
    fn window(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }
    fn link(a: &str, b: &str) -> TunnelLink {
        TunnelLink {
            source_drawer_id: Some(a.to_string()),
            target_drawer_id: Some(b.to_string()),
        }
    }

    /// Build a DreamingTunnelItem (active dreamed tunnel) for ALPHA dedup tests.
    /// The id is synthetic — ALPHA only uses source/target for the candidate key.
    fn dreamed_link(a: &str, b: &str) -> DreamingTunnelItem {
        DreamingTunnelItem {
            id: format!("{a}-{b}-dream"),
            source_drawer_id: a.to_string(),
            target_drawer_id: b.to_string(),
        }
    }

    // DC-1: a strong, novel candidate is proposed; report + reward map and
    // the single diary entry are assembled. (Swift C3-style happy path.)
    // In v2 the reward targets are drawer IDs (a, b); 9 drain windows build
    // coRecallCount(a,b)=9 so the minAttempts gate clears easily.
    #[test]
    fn dc1_strong_candidate_proposes_and_reports() {
        // 9 co-recall events for (a, b); traces a+b used → high reward, high confidence.
        let reader = FakeReaderMut::new(
            vec![trace("a", true), trace("b", true)],
            vec![vec![
                window(&["a", "b"]), window(&["a", "b"]), window(&["a", "b"]),
                window(&["a", "b"]), window(&["a", "b"]), window(&["a", "b"]),
                window(&["a", "b"]), window(&["a", "b"]), window(&["a", "b"]),
            ]],
            vec![],
        );
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        // Injected now — deterministic test timestamp (epoch-seconds f64).
        let report = d.run_cycle(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink);

        assert_eq!(report.candidates_considered, 1);
        assert_eq!(report.proposals_emitted.len(), 1);
        assert_eq!(report.proposals_emitted[0].target, "a");
        assert_eq!(report.proposals_emitted[0].kind, "miningPattern");
        // In v2 reward targets are drawer IDs (a, b), same as the window endpoints.
        assert_eq!(report.reward_by_target["a"], 1.0);
        assert_eq!(report.reward_by_target["b"], 1.0);
        let key = candidate_key("a", "b");
        assert!(report.candidate_scores[&key] >= 0.7);
        assert_eq!(sink.proposals.len(), 1);
        assert_eq!(sink.diaries.len(), 1, "exactly one diary entry per cycle");
        assert_eq!(sink.diaries[0].wing, "wing_dreaming-daemon");
        assert_eq!(sink.diaries[0].agent_name, "dreaming-daemon");
        assert_eq!(
            sink.diaries[0].entry,
            "dreaming cycle 1: considered 1, proposed 1, suppressed 0, below-threshold 0"
        );
    }

    // DC-PRUNE: the cycle prunes recall traces once, with a 30-day cutoff
    // derived from the injected `now`. Mirrors the Swift daemon's
    // post-reward-sweep prune.
    #[test]
    fn dc_prune_recall_traces_fires_once_with_thirty_day_cutoff() {
        let reader = FakeReaderMut::with_traces(vec![trace("r1", true)]);
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        let now_secs = 1_700_000_000.0_f64;
        let _ = d.run_cycle(now_secs, &reader, &RecallTraceRewardSource, &mut sink);

        assert_eq!(sink.prune_cutoffs.len(), 1, "prune must fire exactly once per cycle");
        let expected_secs = (now_secs - RECALL_TRACE_RETENTION_DAYS * 86_400.0) as i64;
        let expected = prune_cutoff_iso(expected_secs);
        assert_eq!(sink.prune_cutoffs[0], expected, "cutoff must be now - 30 days, canonical ISO");
        // Canonical recalledAt format: fractional .000Z.
        assert!(sink.prune_cutoffs[0].ends_with(".000Z"), "cutoff must use .000Z format");
    }

    // DC-2: a candidate duplicating an existing drawer-to-drawer tunnel is
    // suppressed, not proposed. 9 windows → coRecallCount(a,b)=9; traces a+b
    // used → high confidence; but the pair duplicates an existing tunnel → suppressed.
    #[test]
    fn dc2_existing_tunnel_suppresses() {
        // ALPHA uses dreamed_active_tunnels() for duplicate suppression (not
        // existing_tunnels()). Seed an active dreamed tunnel for (a,b) so the
        // pair is suppressed. This verifies that a LIVE dreamed tunnel blocks
        // re-proposal — the retired-tunnel fix only removes TOMBSTONED tunnels
        // from the suppression set; live tunnels must still suppress.
        let reader = FakeReaderMut::new_with_dreamed(
            vec![trace("a", true), trace("b", true)],
            vec![vec![
                window(&["a", "b"]), window(&["a", "b"]), window(&["a", "b"]),
                window(&["a", "b"]), window(&["a", "b"]), window(&["a", "b"]),
                window(&["a", "b"]), window(&["a", "b"]), window(&["a", "b"]),
            ]],
            vec![dreamed_link("a", "b")],
        );
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert_eq!(report.proposals_emitted.len(), 0);
        assert!(report.suppressed_duplicates >= 1);
    }

    // DC-3: EWC++ across two cycles. Cycle 1: 9 windows for (a,b); traces a+b
    // used → consolidates high score, proposes. Cycle 2: 9 more windows for same
    // pair; traces a+b unused → fresh score collapses; EWC++ retains consolidated
    // score ≥ 0.7; B-4 suppresses the re-proposal. Mirrors Swift EWC + B-4.
    #[test]
    fn dc3_ewc_preserves_and_b4_suppresses_across_cycles() {
        let key = candidate_key("a", "b");
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        let mut sink = RecordingSink::default();

        // Cycle 1: used traces → high confidence.
        let r1 = FakeReaderMut::new(
            vec![trace("a", true), trace("b", true)],
            vec![vec![
                window(&["a", "b"]), window(&["a", "b"]), window(&["a", "b"]),
                window(&["a", "b"]), window(&["a", "b"]), window(&["a", "b"]),
                window(&["a", "b"]), window(&["a", "b"]), window(&["a", "b"]),
            ]],
            vec![],
        );
        let first = d.run_cycle(1_000_000.0, &r1, &RecallTraceRewardSource, &mut sink);
        assert_eq!(first.proposals_emitted.len(), 1);
        assert!(first.candidate_scores[&key] >= 0.7);

        // Cycle 2: same pair, traces now unused → fresh score collapses.
        // EWC++ retention: max(~0.05, 0.88 × 0.9) = 0.792 ≥ 0.7. ✓
        let r2 = FakeReaderMut::new(
            vec![trace("a", false), trace("b", false)],
            vec![vec![
                window(&["a", "b"]), window(&["a", "b"]), window(&["a", "b"]),
                window(&["a", "b"]), window(&["a", "b"]), window(&["a", "b"]),
                window(&["a", "b"]), window(&["a", "b"]), window(&["a", "b"]),
            ]],
            vec![],
        );
        let second = d.run_cycle(1_030_000.0, &r2, &RecallTraceRewardSource, &mut sink);
        assert_eq!(
            second.proposals_emitted.len(),
            0,
            "B-4 suppresses the re-proposal"
        );
        assert_eq!(second.suppressed_duplicates, 1);
        assert!(
            second.candidate_scores[&key] >= 0.7,
            "EWC++ preserved the prior association, got {}",
            second.candidate_scores[&key]
        );
        // Two cycles => two diary entries; the second counts cycle 2.
        assert_eq!(sink.diaries.len(), 2);
        assert!(sink.diaries[1].entry.starts_with("dreaming cycle 2:"));
    }

    // PS-1: InMemoryDreamingPolicyStore starts empty; save then load returns
    // the saved policy (in-memory round-trip).
    #[test]
    fn ps1_in_memory_store_empty_then_round_trip() {
        let mut store = InMemoryDreamingPolicyStore::new(None);
        // Empty store returns None.
        assert!(store.load_policy().is_none(), "empty store returns None");
        // Save a non-default policy; load returns it.
        let custom = DreamingPolicy {
            min_success_rate: 0.8,
            min_confidence: 0.9,
            min_attempts: 5,
            tick_interval_ms: 60_000,
            event_observation_threshold: 1,
        };
        store.save_policy(custom);
        let loaded = store.load_policy();
        assert_eq!(loaded, Some(custom), "load returns saved policy");
    }

    // PS-2: Store seam lets a caller swap the policy a daemon uses. The new
    // policy is loaded; the daemon then respects the new thresholds.
    #[test]
    fn ps2_store_seam_policy_swap() {
        let mut store = InMemoryDreamingPolicyStore::new(None);
        // Seed with a strict policy (min_attempts = 100 so nothing proposes).
        let strict = DreamingPolicy {
            min_success_rate: 0.6,
            min_confidence: 0.7,
            min_attempts: 100,
            tick_interval_ms: 30_000,
            event_observation_threshold: 1,
        };
        store.save_policy(strict);
        // Load it and verify the gate is strict.
        // 9 windows → coRecallCount(a,b)=9. Strict policy: min_attempts=100 → blocked.
        let loaded = store.load_policy().unwrap_or_default();
        let mut daemon = DreamingDaemon::new(loaded);
        let nine_windows: Vec<Vec<String>> = (0..9).map(|_| window(&["a", "b"])).collect();
        let reader1 = FakeReaderMut::new(
            vec![trace("a", true), trace("b", true)],
            vec![nine_windows.clone()],
            vec![],
        );
        let mut sink = RecordingSink::default();
        let report = daemon.run_cycle(1_000_000.0, &reader1, &RecallTraceRewardSource, &mut sink);
        // coRecallCount(a,b)=9 after drain; 9 < 100 → nothing proposes.
        assert_eq!(report.proposals_emitted.len(), 0, "strict policy blocks proposal");

        // Swap to a lenient policy via the store.
        let lenient = DreamingPolicy::default(); // min_attempts = 3
        store.save_policy(lenient);
        let loaded2 = store.load_policy().unwrap_or_default();
        let mut daemon2 = DreamingDaemon::new(loaded2);
        // New reader — 9 fresh windows so coRecallCount starts at 0 for daemon2.
        let reader2 = FakeReaderMut::new(
            vec![trace("a", true), trace("b", true)],
            vec![nine_windows],
            vec![],
        );
        let mut sink2 = RecordingSink::default();
        let report2 = daemon2.run_cycle(1_000_000.0, &reader2, &RecallTraceRewardSource, &mut sink2);
        // coRecallCount(a,b)=9 after drain; 9 >= 3 → proposes.
        assert_eq!(report2.proposals_emitted.len(), 1, "lenient policy allows proposal");
    }

    // RS-1: RecallTraceRewardSource.kind() returns RewardSourceKind::RecallTrace.
    #[test]
    fn rs1_recall_trace_reward_source_kind() {
        let source = RecallTraceRewardSource;
        assert_eq!(source.kind(), RewardSourceKind::RecallTrace);
    }

    // RS-2: Reward values: used → 1.0, unused → 0.0.
    #[test]
    fn rs2_recall_trace_reward_values() {
        let source = RecallTraceRewardSource;
        let used = RecallTraceItem { target: "t".to_string(), used: true };
        let unused = RecallTraceItem { target: "t".to_string(), used: false };
        assert_eq!(source.reward(&used), 1.0);
        assert_eq!(source.reward(&unused), 0.0);
    }

    // RS-3: ExplicitDiaryRewardSource returns explicit reward for known target.
    #[test]
    fn rs3_explicit_diary_reward_source_known_target() {
        let mut map = std::collections::BTreeMap::new();
        map.insert("drawer-A".to_string(), 0.9_f32);
        let src = ExplicitDiaryRewardSource::new(map);
        assert_eq!(src.kind(), RewardSourceKind::ExplicitDiaryReward);
        let item = RecallTraceItem { target: "drawer-A".to_string(), used: false };
        assert!((src.reward(&item) - 0.9).abs() < 1e-6, "explicit reward must be returned");
    }

    // RS-4: ExplicitDiaryRewardSource falls back to RecallTraceRewardSource for
    // unknown target.
    #[test]
    fn rs4_explicit_diary_reward_source_unknown_target_fallback() {
        let map = std::collections::BTreeMap::new(); // empty — no explicit rewards
        let src = ExplicitDiaryRewardSource::new(map);
        // used=true → fallback (RecallTrace) returns 1.0
        let used = RecallTraceItem { target: "drawer-B".to_string(), used: true };
        assert_eq!(src.reward(&used), 1.0);
        // used=false → fallback returns 0.0
        let unused = RecallTraceItem { target: "drawer-B".to_string(), used: false };
        assert_eq!(src.reward(&unused), 0.0);
    }

    // RS-5: explicit reward overrides trace-based used=true (precedence rule).
    #[test]
    fn rs5_explicit_overrides_trace_signal() {
        let mut map = std::collections::BTreeMap::new();
        map.insert("drawer-C".to_string(), 0.2_f32);
        let src = ExplicitDiaryRewardSource::new(map);
        // used=true would yield 1.0 via trace, but explicit is 0.2.
        let item = RecallTraceItem { target: "drawer-C".to_string(), used: true };
        assert!(
            (src.reward(&item) - 0.2).abs() < 1e-6,
            "explicit must override trace-derived 1.0"
        );
    }

    // DC-4: per-target reward keeps the strongest signal — a target used in
    // one trace and ignored in another reduces to 1.0 (used wins via max).
    #[test]
    fn dc4_reward_keeps_strongest_per_target() {
        let reader = FakeReaderMut::with_traces(vec![trace("r1", false), trace("r1", true)]);
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert_eq!(report.reward_by_target["r1"], 1.0);
        assert_eq!(report.candidates_considered, 0);
        assert_eq!(report.proposals_emitted.len(), 0);
    }

    // ─── Pump cadence tests (mirror Swift DreamingDaemonTests cadence suite) ───

    // PC-D1: first pump call always fires regardless of interval (no prior
    // fire timestamp). Mirrors Swift `testDreamingPumpFirstCallAlwaysFires`.
    #[test]
    fn pc_d1_pump_first_call_always_fires() {
        let reader = FakeReaderMut::empty();
        let mut sink = RecordingSink::default();
        // tick_interval_ms = 30_000 (30 s). At t=0 there is no prior fire,
        // so the call fires unconditionally.
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        let result = d.pump(0.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(result.is_some(), "first pump call must always fire");
    }

    // PC-D2: a call before the interval has elapsed returns None (no-fire).
    // Mirrors Swift `testDreamingPumpSkipsBeforeInterval`.
    #[test]
    fn pc_d2_pump_skips_before_interval() {
        let reader = FakeReaderMut::empty();
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy { tick_interval_ms: 30_000, ..DreamingPolicy::default() });
        // Realistic base instant (Swift t0 = 1_800_000_000) so the post-cycle
        // bandit re-selection is conformant with the Swift TS-1 base — the seed
        // keeps the trigger mode on .timer, so this exercises the interval gate
        // (not an incidental mode flip). The first call fires (no prior tick).
        let first = d.pump(1_800_000_000.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(first.is_some(), "first call must fire");
        // Second call 29 s later — interval (30 s) has not elapsed.
        let before = d.pump(1_800_000_029.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(before.is_none(), "call before interval must return None");
    }

    // BANDIT-1: a cycle wires the Thompson-Sampling bandit — it observes the
    // selected arm's reward and re-selects the trigger mode, so the bandit state
    // advances each cycle (NEURONKIT_SPEC § 3.4). Locks the F6 parity fix that
    // brought the Rust dreaming daemon up to the Swift bandit behavior.
    #[test]
    fn bandit_1_cycle_observes_and_reselects() {
        let reader = FakeReaderMut::empty();
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        let before = d.current_bandit();
        let _ = d.run_cycle(1_800_000_000.0, &reader, &RecallTraceRewardSource, &mut sink);
        let after = d.current_bandit();
        assert_ne!(before, after, "a cycle must advance the bandit (observe + re-select)");

        // The bandit restores verbatim — a restart resumes the learned posterior.
        let mut restored = DreamingDaemon::new(DreamingPolicy::default());
        restored.set_bandit(after.clone());
        assert_eq!(restored.current_bandit(), after);
    }

    // PC-D3: a call at exactly the interval boundary fires. Mirrors Swift
    // `testDreamingPumpFiresAtInterval`.
    #[test]
    fn pc_d3_pump_fires_at_interval() {
        let reader = FakeReaderMut::empty();
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy { tick_interval_ms: 30_000, ..DreamingPolicy::default() });
        // Realistic base instant (Swift t0 = 1_800_000_000) so the post-cycle
        // bandit re-selection keeps the trigger mode on .timer (conformant with
        // Swift TS-1) — this then exercises the interval boundary, not a mode flip.
        let _ = d.pump(1_800_000_000.0, &reader, &RecallTraceRewardSource, &mut sink);
        // Call 30 s later — exactly at the interval boundary.
        let at_boundary = d.pump(1_800_000_030.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(at_boundary.is_some(), "call at interval boundary must fire");
    }

    // ─── Trigger-source tests (Board item 13) ───────────────────────────
    // Mirrors Swift TS-1, TS-2, TS-3, TS-4 in DreamingDaemonTests.

    // TS-1: .timer mode — pump fires on cadence; pump_on_event returns None
    // even when observation count is above threshold.
    #[test]
    fn ts1_timer_mode_fires_on_cadence_not_on_event() {
        let reader = FakeReaderMut::empty();
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default()); // trigger_mode = Timer

        // Realistic base instant matching Swift TS-1 (t0 = 1_800_000_000) so the
        // post-cycle bandit re-selection is conformant — the seed keeps the mode
        // on .timer, so the event path stays inactive as the test asserts.
        let t0 = 1_800_000_000.0;
        // First pump always fires in timer mode (no prior timer tick).
        let first = d.pump(t0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(first.is_some(), ".timer: first pump must fire");

        // pump_on_event must return None regardless of observation count —
        // the event path is inactive in timer mode.
        let event_result = d.pump_on_event(100, 1.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(event_result.is_none(), ".timer: pump_on_event must return None (event path inactive)");

        // Timer fires after the cadence elapses.
        let second = d.pump(t0 + 30.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(second.is_some(), ".timer: pump fires after interval");
    }

    // TS-2: .event mode — pump_on_event fires when observation count meets
    // threshold; pump returns None (timer path inactive).
    #[test]
    fn ts2_event_mode_fires_on_event_not_on_timer() {
        let reader = FakeReaderMut::empty();
        let mut sink = RecordingSink::default();
        // Threshold = 2; trigger mode = Event.
        let policy = DreamingPolicy { event_observation_threshold: 2, ..DreamingPolicy::default() };
        let mut d = DreamingDaemon::with_trigger_mode(policy, DreamingTriggerMode::Event);

        // pump must return None — timer path is inactive in event mode.
        // The first pump would normally fire (no prior timer tick), but event
        // mode overrides that.
        let timer_result = d.pump(0.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(timer_result.is_none(), ".event: pump must return None (timer path inactive)");

        // pump_on_event below threshold returns None.
        let below = d.pump_on_event(1, 0.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(below.is_none(), ".event: pump_on_event below threshold must return None");

        // pump_on_event at threshold fires.
        let at = d.pump_on_event(2, 0.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(at.is_some(), ".event: pump_on_event at threshold must fire");

        // pump_on_event above threshold fires.
        let above = d.pump_on_event(5, 1.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(above.is_some(), ".event: pump_on_event above threshold must fire");
    }

    // TS-3: .hybrid mode — both pump (timer) AND pump_on_event (event) are
    // active independently. Event fires do not reset the timer countdown.
    #[test]
    fn ts3_hybrid_mode_fires_on_both_timer_and_event_independently() {
        let reader = FakeReaderMut::empty();
        let mut sink = RecordingSink::default();
        // threshold = 1, interval = 30 s; trigger mode = Hybrid.
        let policy = DreamingPolicy {
            tick_interval_ms: 30_000,
            event_observation_threshold: 1,
            ..DreamingPolicy::default()
        };
        let mut d = DreamingDaemon::with_trigger_mode(policy, DreamingTriggerMode::Hybrid);

        // Timer path: first pump fires (no prior timer tick).
        let timer_fire = d.pump(0.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(timer_fire.is_some(), ".hybrid: first pump (timer) must fire");

        // Timer not due yet (t=1 < 30).
        let timer_blocked = d.pump(1.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(timer_blocked.is_none(), ".hybrid: pump returns None before interval elapses");

        // Event path fires independently of the timer.
        let event_fire = d.pump_on_event(1, 1.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(event_fire.is_some(), ".hybrid: pump_on_event must fire independently of timer");

        // Event fire did NOT reset the timer; timer fires at t=30 (30 s after t=0).
        let timer_second = d.pump(30.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(timer_second.is_some(), ".hybrid: pump fires after interval (event fire did not reset timer)");
    }

    // TS-4: event_observation_threshold round-trips through the policy store.
    #[test]
    fn ts4_event_observation_threshold_round_trips() {
        let mut store = InMemoryDreamingPolicyStore::new(None);
        let custom = DreamingPolicy {
            event_observation_threshold: 7,
            ..DreamingPolicy::default()
        };
        store.save_policy(custom);
        let loaded = store.load_policy().unwrap();
        assert_eq!(loaded.event_observation_threshold, 7, "event_observation_threshold must round-trip");
    }

    // ─── Auto-reindex tests (mirror Swift AutoReindexTests) ─────────────────
    // Tests for the CorpusGrowthProbe seam and the auto-reindex gate in
    // `run_cycle_with_probe`. Coverage mirrors AR-1 through AR-6 in Swift.

    fn empty_reader() -> FakeReaderMut {
        FakeReaderMut::empty()
    }

    // The auto-reindex gate fires on VOCABULARY growth (P3 item 5):
    // trigger = max(floor, ceil(fraction × baseline)). Most tests use small
    // vocabularies where the floor dominates; ar7 exercises the fraction path.

    // AR-1: First cycle establishes baseline without firing reindex.
    #[test]
    fn ar1_first_cycle_establishes_baseline_without_reindex() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut probe = InMemoryCorpusGrowthProbe::new(10);
        let mut d = DreamingDaemon::new(DreamingPolicy::default());

        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        assert_eq!(probe.reindex_calls.len(), 0, "first cycle must not trigger reindex");
        // Baseline was read (probe.vocab was consulted) and stored internally.
        // We verify it indirectly via AR-2 (no reindex below the floor from this baseline).
    }

    // AR-2: Vocab growth below the floor — reindex must NOT fire.
    #[test]
    fn ar2_below_floor_no_reindex() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        // floor = 25; start at vocab 10.
        let mut probe = InMemoryCorpusGrowthProbe::new(10);
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        // d.reindex_vocab_growth_floor is already AUTO_REINDEX_VOCAB_GROWTH_FLOOR (25).

        // Cycle 1: baseline = 10.
        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // Grow by 24 (below the floor 25; fraction 10%×10=1 is dominated).
        probe.vocab = 34;
        d.run_cycle_with_probe(1_030_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        assert_eq!(probe.reindex_calls.len(), 0, "vocab growth of 24 (< 25) must not trigger reindex");
    }

    // AR-3: Vocab growth at the floor triggers reindex; timestamp is the cycle's now.
    #[test]
    fn ar3_at_floor_reindex_fires() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut probe = InMemoryCorpusGrowthProbe::new(10);
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        d.set_reindex_vocab_growth_floor(25);

        // Cycle 1: baseline = 10.
        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // Grow by exactly 25 (10 + 25 = 35).
        probe.vocab = 35;
        let t1 = 1_060_000.0_f64;
        d.run_cycle_with_probe(t1, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        assert_eq!(probe.reindex_calls.len(), 1, "growth == floor must trigger reindex");
        assert!((probe.reindex_calls[0] - t1).abs() < 1e-6, "reindex must receive cycle's now");
    }

    // AR-3b: After reindex, baseline advances; sub-floor growth does not re-fire.
    #[test]
    fn ar3b_baseline_advances_after_reindex() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut probe = InMemoryCorpusGrowthProbe::new(10);
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        d.set_reindex_vocab_growth_floor(25);

        // Cycle 1: baseline = 10.
        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // Grow to 35 (delta 25 == floor): reindex fires, baseline advances to 35.
        probe.vocab = 35;
        d.run_cycle_with_probe(1_060_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));
        assert_eq!(probe.reindex_calls.len(), 1, "reindex must fire on first floor crossing");

        // Grow by 5 more (35 → 40): trigger = max(25, ceil(35×0.1)=4) = 25; 5 < 25, no reindex.
        probe.vocab = 40;
        d.run_cycle_with_probe(1_120_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));
        assert_eq!(probe.reindex_calls.len(), 1, "sub-floor growth after baseline advance must not re-fire");
    }

    // AR-4: No probe → no auto-reindex; daemon runs normally.
    #[test]
    fn ar4_no_probe_no_reindex() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default());

        // Pass None for probe — must not panic and must produce a valid report.
        let report = d.run_cycle_with_probe::<_, _, _, InMemoryCorpusGrowthProbe>(
            1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, None,
        );
        assert_eq!(report.candidates_considered, 0);
    }

    // AR-5: Two successive growth windows both fire independently.
    #[test]
    fn ar5_two_successive_windows_fire() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut probe = InMemoryCorpusGrowthProbe::new(0);
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        d.set_reindex_vocab_growth_floor(10); // small floor for this test

        // Cycle 1: baseline = 0.
        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // First window: grow by 10 → reindex, baseline → 10.
        probe.vocab = 10;
        d.run_cycle_with_probe(1_030_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));
        assert_eq!(probe.reindex_calls.len(), 1, "first floor crossing must fire");

        // Second window: grow by 10 more (10 → 20); trigger = max(10, ceil(10×0.1)=1)
        // = 10 → reindex, baseline → 20.
        probe.vocab = 20;
        d.run_cycle_with_probe(1_060_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));
        assert_eq!(probe.reindex_calls.len(), 2, "second floor crossing must fire independently");
    }

    // AR-6: Reindex error (error_on_reindex) is non-fatal; baseline still advances.
    #[test]
    fn ar6_reindex_error_is_non_fatal() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut probe = InMemoryCorpusGrowthProbe { vocab: 10, error_on_reindex: true, ..Default::default() };
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        d.set_reindex_vocab_growth_floor(1); // fire immediately after first cycle

        // Cycle 1: baseline = 10.
        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // Grow by 1 (floor = 1): reindex called but error_on_reindex suppresses it.
        probe.vocab = 11;
        let report = d.run_cycle_with_probe(1_030_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // Must not panic. Report is valid.
        assert_eq!(report.candidates_considered, 0);
        // reindex_calls is empty because error_on_reindex swallows the call.
        assert_eq!(probe.reindex_calls.len(), 0, "error_on_reindex suppresses the call record");
    }

    // AR-7: At a large baseline the proportional fraction dominates the floor.
    #[test]
    fn ar7_fraction_dominates_at_large_baseline() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut probe = InMemoryCorpusGrowthProbe::new(1000);
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        d.set_reindex_vocab_growth_fraction(0.10); // 10% of 1000 = 100
        d.set_reindex_vocab_growth_floor(25);

        // Cycle 1: baseline = 1000.
        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // Grow by 60 (above the floor 25 but below the fractional 100): no fire.
        probe.vocab = 1060;
        d.run_cycle_with_probe(1_030_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));
        assert_eq!(probe.reindex_calls.len(), 0, "+60 is below the fractional trigger (100)");

        // Grow to +100 from baseline: meets the fractional trigger.
        probe.vocab = 1100;
        d.run_cycle_with_probe(1_060_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));
        assert_eq!(probe.reindex_calls.len(), 1, "+100 meets the fractional trigger (10% of 1000)");
    }

    // AR-8 (Codex finding 3): a FAILED reindex does not advance the baseline, so
    // the gate re-fires next cycle (retry) — matching Swift's failure policy.
    #[test]
    fn ar8_failed_reindex_retries_next_cycle() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut probe = InMemoryCorpusGrowthProbe { vocab: 10, error_on_reindex: true, ..Default::default() };
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        d.set_reindex_vocab_growth_floor(1);

        // Cycle 1: baseline = 10.
        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // Cycle 2: grow to 12 (delta 2 >= floor 1) → fires but FAILS. Because the
        // baseline is NOT advanced on failure, it stays at 10.
        probe.vocab = 12;
        d.run_cycle_with_probe(1_030_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));
        assert_eq!(probe.reindex_calls.len(), 0, "failed reindex records nothing");

        // Cycle 3: same vocab (12), now succeeding. If the baseline had advanced on
        // the cycle-2 failure (to 12), delta would be 0 and the gate would NOT fire.
        // Because it did NOT advance, delta is 12-10=2 >= 1 → retry fires now.
        probe.error_on_reindex = false;
        d.run_cycle_with_probe(1_060_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));
        assert_eq!(
            probe.reindex_calls.len(), 1,
            "failed reindex must not advance the baseline — the retry fires next cycle"
        );
    }

    // ── Co-recall counts store ───────────────────────────────────────────────

    // CR-1: increment semantics — N bumps of the same pair → count N;
    // starting count is 0 (absent pair).
    #[test]
    fn cr1_bump_increments_and_absent_returns_zero() {
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        assert_eq!(d.co_recall_count("a", "b"), 0, "absent pair returns 0");
        d.bump_co_recall("a", "b");
        assert_eq!(d.co_recall_count("a", "b"), 1);
        d.bump_co_recall("a", "b");
        assert_eq!(d.co_recall_count("a", "b"), 2);
        d.bump_co_recall("a", "b");
        assert_eq!(d.co_recall_count("a", "b"), 3);
    }

    // CR-2: canonical key order-independence — bump(a, b) is readable as
    // co_recall_count(b, a) (the canonical key is the same regardless of
    // which endpoint is supplied first).
    #[test]
    fn cr2_order_independent_key() {
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        d.bump_co_recall("alpha", "beta");
        // Reading with reversed order must return the same count.
        assert_eq!(
            d.co_recall_count("beta", "alpha"), 1,
            "co_recall_count must be order-independent"
        );
        // Both orderings also bump the same counter.
        d.bump_co_recall("beta", "alpha");
        assert_eq!(d.co_recall_count("alpha", "beta"), 2);
    }

    // CR-3: distinct pairs are independent — bumping (a, b) does not affect
    // (a, c) or any other pair.
    #[test]
    fn cr3_distinct_pairs_are_independent() {
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        d.bump_co_recall("x", "y");
        d.bump_co_recall("x", "y");
        d.bump_co_recall("x", "z");
        assert_eq!(d.co_recall_count("x", "y"), 2);
        assert_eq!(d.co_recall_count("x", "z"), 1);
        assert_eq!(d.co_recall_count("y", "z"), 0, "unseen pair returns 0");
    }

    // CR-4 (the anti-inert / persistence round-trip test): bump several pairs
    // to distinct counts → take a daemon_state() snapshot → construct a FRESH
    // daemon and restore_state() from it → assert every co_recall_count is
    // preserved exactly.
    //
    // This test fails if the field was added to the daemon but NOT threaded
    // through daemon_state()/restore_state() — the exact class of inert-wiring
    // error caught in prior missions.
    #[test]
    fn cr4_persistence_round_trip() {
        let mut original = DreamingDaemon::new(DreamingPolicy::default());
        original.bump_co_recall("a", "b"); // → 1
        original.bump_co_recall("a", "b"); // → 2
        original.bump_co_recall("a", "b"); // → 3
        original.bump_co_recall("c", "d"); // → 1
        original.bump_co_recall("d", "c"); // → 2 (same canonical key "c|d")
        original.bump_co_recall("m", "z"); // → 1

        // Snapshot — the same DreamingDaemonState the governor persists.
        let snapshot = original.daemon_state();

        // A fresh daemon has zero counts; after restore_state it must carry
        // the snapshotted counts.
        let mut restored = DreamingDaemon::new(DreamingPolicy::default());
        assert_eq!(restored.co_recall_count("a", "b"), 0, "fresh daemon starts at 0");
        restored.restore_state(snapshot);

        assert_eq!(restored.co_recall_count("a", "b"), 3, "a|b must be 3 after restore");
        assert_eq!(restored.co_recall_count("c", "d"), 2, "c|d must be 2 after restore");
        assert_eq!(restored.co_recall_count("m", "z"), 1, "m|z must be 1 after restore");
        assert_eq!(restored.co_recall_count("x", "y"), 0, "unseen pair still 0 after restore");
    }

    // CR-5: key format parity — the canonical pair key produced by
    // bump_co_recall / co_recall_count must match candidate_key exactly,
    // so the co-recall store and the proposed_keys/consolidated maps share
    // one key format. Assert the key string for a known pair so cross-port
    // drift is detectable.
    #[test]
    fn cr5_key_format_matches_candidate_key() {
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        d.bump_co_recall("omega", "alpha");
        // "alpha" < "omega" lexicographically → canonical key is "alpha|omega".
        let expected_key = candidate_key("omega", "alpha");
        assert_eq!(expected_key, "alpha|omega");
        // The store must hold exactly one entry under that key.
        let state = d.daemon_state();
        assert!(
            state.co_recall_counts.contains_key("alpha|omega"),
            "state must use the canonical key format 'min|max'"
        );
        assert_eq!(state.co_recall_counts["alpha|omega"], 1);
    }

    // CR-6: forward-compat decode — persisted DreamingDaemonState written
    // before co_recall_counts existed (T7) must still deserialize, with the
    // missing field defaulting to an empty map rather than failing the whole
    // decode (so a version upgrade preserves the rest of the daemon state).
    // This is the cross-version "old data still loads" guard; the matching
    // Swift test asserts the same against its custom init(from:). Without the
    // `#[serde(default)]` on the field this test fails with a missing-field
    // error.
    #[test]
    fn cr6_pre_t7_state_decodes_with_empty_counts() {
        // A DreamingDaemonState JSON with NO `co_recall_counts` key (the
        // shape persisted before T7).
        let pre_t7 = r#"{
            "last_timer_fire_epoch_secs": null,
            "proposed_keys": ["alpha|beta"],
            "last_reindex_vocab": -1,
            "consolidated": {"alpha|beta": 0.8},
            "cycle_count": 4
        }"#;
        let state: DreamingDaemonState =
            serde_json::from_str(pre_t7).expect("pre-T7 state must still decode");
        assert!(
            state.co_recall_counts.is_empty(),
            "missing co_recall_counts defaults to empty"
        );
        // The pre-existing fields survive intact.
        assert_eq!(state.cycle_count, 4);
        assert_eq!(state.consolidated["alpha|beta"], 0.8);
        assert_eq!(state.proposed_keys, vec!["alpha|beta".to_string()]);
    }
}
