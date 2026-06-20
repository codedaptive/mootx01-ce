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
//! The READ seam (recall traces, co-occurrence, tunnels) is backable by
//! the Rust `Estate` today. The WRITE seam's `propose` goes through
//! `EstateDreamingSink` (the production adapter, shipped in both Swift and
//! Rust). The Rust adapter calls `store.add_proposal` directly rather than
//! routing through the GLK coordinator (B-1-compliant; no circular crate
//! dependency). The orchestration is pure: it talks to the
//! `DreamingSubstrateReader` / `DreamingProposalSink` / `RewardSource`
//! traits, exactly as the Swift actor talks to its protocols, and is gated
//! with deterministic fakes (the same shape as the Swift DreamingDaemonTests
//! fakes).
//!
//! Determinism: no clock, no RNG. The daemon carries `cycle_count` and the
//! caller supplies any time-derived inputs through the seam.

use std::collections::{BTreeMap, BTreeSet};

use intellectus_lib::{report, StatSample};

use crate::dreaming_decision::{self, candidate_key};
use crate::solver_bandit::DreamingTriggerMode;

/// Minimal identity-free projection of a recall-trace row — the only two
/// fields the cycle reads (the reward source maps `used` to a reward).
#[derive(Clone, Debug, PartialEq)]
pub struct RecallTraceItem {
    pub target: String,
    pub used: bool,
}

/// Identity-free co-occurrence candidate, mirroring the Swift
/// `CoOccurrenceObservation` seam value type.
#[derive(Clone, Debug, PartialEq)]
pub struct CoOccurrenceObservation {
    pub endpoint_a: String,
    pub endpoint_b: String,
    pub attempts: i64,
    pub evidence_targets: Vec<String>,
}

/// Identity-free projection of a tunnel — only the two drawer endpoints
/// matter for duplicate suppression. A room-level tunnel has `None`
/// endpoints and cannot duplicate a drawer-pair candidate.
#[derive(Clone, Debug, PartialEq)]
pub struct TunnelLink {
    pub source_drawer_id: Option<String>,
    pub target_drawer_id: Option<String>,
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
#[derive(Clone, Copy, Debug, PartialEq)]
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
    /// Minimum co-occurrence observation count that triggers a cycle in
    /// `.event` and `.hybrid` modes. The caller passes the count from
    /// `DreamingSubstrateReader::co_occurrence_observations()` to
    /// `pump_on_event`; a cycle fires when that count meets or exceeds
    /// this threshold. Spec default 1 (any non-empty observation set).
    /// Ignored by `.timer` mode.
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
/// saves the policy through this trait. The production adapter binds
/// these methods to the estate manifest once GLK exposes a manifest
/// accessor; until then the seam is satisfied by an in-memory store.
/// Mirrors `DreamingPolicyStore` (Swift `DreamingPolicy.swift`).
pub trait DreamingPolicyStore {
    /// Load the persisted policy, or `None` if none has been saved (the
    /// daemon then falls back to `DreamingPolicy::default()`).
    fn load_policy(&self) -> Option<DreamingPolicy>;

    /// Persist the policy. Subsequent `load_policy()` calls return it.
    fn save_policy(&mut self, policy: DreamingPolicy);
}

/// In-memory `DreamingPolicyStore` for tests and for hosts that do not
/// persist policy across process restarts.
/// Mirrors `InMemoryDreamingPolicyStore` (Swift `DreamingPolicy.swift`).
#[derive(Clone, Debug, Default)]
pub struct InMemoryDreamingPolicyStore {
    stored: Option<DreamingPolicy>,
}

impl InMemoryDreamingPolicyStore {
    /// Create an empty store, or seed it with an initial policy.
    pub fn new(initial: Option<DreamingPolicy>) -> Self {
        Self { stored: initial }
    }
}

impl DreamingPolicyStore for InMemoryDreamingPolicyStore {
    fn load_policy(&self) -> Option<DreamingPolicy> {
        self.stored
    }

    fn save_policy(&mut self, policy: DreamingPolicy) {
        self.stored = Some(policy);
    }
}

/// Read seam: the three substrate reads a dreaming cycle performs.
pub trait DreamingSubstrateReader {
    /// Recall-trace rows in the reward window. (The since/now windowing is
    /// the production adapter's concern; the trait yields the in-window set.)
    fn recent_recall_traces(&self) -> Vec<RecallTraceItem>;
    /// Latent co-occurrence candidates.
    fn co_occurrence_observations(&self) -> Vec<CoOccurrenceObservation>;
    /// Existing tunnels, for duplicate suppression.
    fn existing_tunnels(&self) -> Vec<TunnelLink>;
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

/// Write seam: emit a proposal, record the cycle diary, and prune stale
/// recall-trace rows after the reward sweep. No remediation method — the daemon
/// can only propose (structural never-remediate).
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
    // topology_analysis::epoch_to_iso8601 emits `...SSZ` (no fraction); splice
    // in `.000` before the trailing `Z` to match the recalledAt format.
    let no_frac = crate::topology_analysis::epoch_to_iso8601(epoch_secs);
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

/// Chunk-count-and-retrain seam for the auto-reindex step. Mirrors the Swift
/// `CorpusGrowthProbe` protocol (NeuronKit/Sources/NeuronKit/Dreaming/CorpusGrowthProbe.swift).
///
/// Distributional embedding providers (RI / PPMI / LSA / NMF) freeze their
/// vocabulary at training time. Terms ingested after the last retrain are
/// OOV and produce zero-vectors, silently missing novel content in dense
/// recall. The daemon calls this trait after each cycle to measure growth
/// and fire a retrain when the growth threshold is crossed.
pub trait CorpusGrowthProbe {
    /// Current chunk count in the probe's Corpus. Returns 0 for un-wired
    /// estates (no Corpus) so the growth gate never fires on those.
    fn chunk_count(&self) -> i64;

    /// Trigger a full basis retrain.
    ///
    /// `now_epoch_secs` is the injected cycle timestamp (deterministic; the
    /// probe must not read the system clock). Infallible at the trait level —
    /// the Rust sync-port convention; implementations capture errors out-of-band.
    fn reindex(&mut self, now_epoch_secs: f64);
}

/// In-memory `CorpusGrowthProbe` for tests. Records reindex calls; does not
/// touch a live Corpus. Mirrors the test-only `FakeGrowthProbe` in the Swift
/// test suite.
#[derive(Default)]
pub struct InMemoryCorpusGrowthProbe {
    /// The count returned by `chunk_count()`. Tests set this to simulate growth.
    pub count: i64,
    /// Timestamps (epoch-seconds) of `reindex()` calls, in call order.
    pub reindex_calls: Vec<f64>,
    /// When true, `reindex()` is a no-op that records nothing — simulates a
    /// storage error without panicking (the trait is infallible).
    pub error_on_reindex: bool,
}

impl InMemoryCorpusGrowthProbe {
    /// Construct a probe with the given initial chunk count.
    pub fn new(count: i64) -> Self {
        Self { count, ..Default::default() }
    }
}

impl CorpusGrowthProbe for InMemoryCorpusGrowthProbe {
    fn chunk_count(&self) -> i64 {
        self.count
    }

    fn reindex(&mut self, now_epoch_secs: f64) {
        if !self.error_on_reindex {
            self.reindex_calls.push(now_epoch_secs);
        }
        // When error_on_reindex is true: drop the call silently, mirroring the
        // Swift daemon's non-fatal error handling (cycle continues, no panic).
    }
}

/// Corpus growth required to trigger an auto-reindex. Mirrors the Swift
/// `autoReindexGrowthThreshold` constant (25 chunks).
///
/// Vocabulary coverage rationale: distributional embeddings train on the full
/// vocabulary at training time. 25 new chunks represents enough vocabulary
/// drift to make a full retrain worthwhile without retraining too frequently.
/// Callers with very dense or very sparse ingestion can override via
/// `DreamingDaemon::with_growth_probe`.
pub const AUTO_REINDEX_GROWTH_THRESHOLD: i64 = 25;

// ─── DreamingDaemon ──────────────────────────────────────────────────────────

/// The dreaming daemon's across-cycle state and cycle driver — the Rust
/// parity of the Swift `DreamingDaemon` actor (without the async/timer
/// machinery, which is the runtime's concern, not the algorithm's).
pub struct DreamingDaemon {
    pub policy: DreamingPolicy,
    /// Current trigger mode. Mirrors Swift `DreamingDaemon.triggerMode`.
    pub trigger_mode: DreamingTriggerMode,
    consolidated: BTreeMap<String, f32>,
    proposed_keys: BTreeSet<String>,
    cycle_count: i64,
    /// Epoch-seconds timestamp of the last TIMER-path `pump` fire, or `None`
    /// on first call. Tracks only timer fires so event-path fires in
    /// `.hybrid` mode do not reset the timer countdown; the two paths are
    /// independent. The daemon never reads the system clock; the caller
    /// injects `now`.
    last_timer_fire_epoch_secs: Option<f64>,
    /// Chunk count at the most recent corpus basis retrain (or at daemon
    /// construction). Sentinel value -1 means "not yet initialised": the
    /// first cycle reads the live count and stores it as the baseline WITHOUT
    /// firing a retrain (the corpus was just trained on first ingest or opened
    /// from a persisted basis). Mirrors Swift `lastReindexChunkCount`.
    last_reindex_chunk_count: i64,
    /// Growth delta (in chunks) that triggers an auto-reindex. Defaults to
    /// `AUTO_REINDEX_GROWTH_THRESHOLD`. Mirrors Swift `reindexGrowthThreshold`.
    reindex_growth_threshold: i64,
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
            consolidated: BTreeMap::new(),
            proposed_keys: BTreeSet::new(),
            cycle_count: 0,
            last_timer_fire_epoch_secs: None,
            last_reindex_chunk_count: -1, // sentinel: not yet initialised
            reindex_growth_threshold: AUTO_REINDEX_GROWTH_THRESHOLD,
        }
    }

    /// Override the auto-reindex growth threshold. Use when the default 25-chunk
    /// threshold is inappropriate for the estate's ingestion rate.
    pub fn set_reindex_growth_threshold(&mut self, threshold: i64) {
        self.reindex_growth_threshold = threshold;
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
    /// The caller derives `observation_count` by calling
    /// `DreamingSubstrateReader::co_occurrence_observations()` and passing the
    /// count; this keeps the seam contract intact (the daemon calls the reader
    /// again inside `run_cycle`).
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
            start_tags.insert("cycle".to_string(), self.cycle_count.to_string());
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

        // Step 2: latent co-occurrence candidates.
        let observations = reader.co_occurrence_observations();
        let candidates_considered = observations.len();

        // Step 5 (prep): existing drawer-to-drawer tunnel keys.
        let existing_tunnel_keys: BTreeSet<String> = reader
            .existing_tunnels()
            .iter()
            .filter_map(tunnel_key)
            .collect();

        // Steps 3-6: delegate every decision to the pure core.
        let decision_obs: Vec<dreaming_decision::Observation> = observations
            .iter()
            .map(|o| dreaming_decision::Observation {
                endpoint_a: o.endpoint_a.clone(),
                endpoint_b: o.endpoint_b.clone(),
                attempts: o.attempts,
                evidence_targets: o.evidence_targets.clone(),
            })
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
            complete_tags.insert("drawers_touched".to_string(), observations.len().to_string());
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

        // ── Auto-reindex step: trigger corpus basis retrain on growth ──────
        // Mirrors Swift `DreamingDaemon.runCycle` auto-reindex block.
        // The probe is passed in by the caller via `run_cycle_with_probe`; when
        // `run_cycle` is called without a probe the block is a no-op.
        // Probe logic is intentionally post-diary so a reindex error does not
        // prevent the diary from being written (the diary write is step 7 in the
        // spec, and the reindex is an extension step, not a numbered spec step).
        //
        // Infallibility: the Rust sync-port trait is infallible. Implementations
        // are expected to capture errors out-of-band (log them, return 0 from
        // `chunk_count()`, skip `reindex_calls` on error_on_reindex). This mirrors
        // the Swift daemon's non-fatal reindex-error handling (cycle continues).
        //
        // Baseline sentinel: `last_reindex_chunk_count == -1` on the first cycle.
        // We read the live count and store it WITHOUT firing a retrain — the corpus
        // was just trained on first ingest or opened from a persisted basis.
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
            let live_count = p.chunk_count();
            if self.last_reindex_chunk_count == -1 {
                // First cycle: establish baseline, do not retrain.
                self.last_reindex_chunk_count = live_count;
            } else if live_count - self.last_reindex_chunk_count >= self.reindex_growth_threshold {
                // Growth threshold crossed — retrain.
                p.reindex(now_epoch_secs);
                // Advance baseline to live count at retrain time. Even when reindex
                // is a no-op (error_on_reindex), the baseline advances so the gate
                // does not re-fire every subsequent cycle — mirrors Swift's always-
                // advance-after-threshold-check semantics.
                self.last_reindex_chunk_count = live_count;
            }
        }

        report
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A configurable fake reader, the shape of the Swift FakeReader.
    struct FakeReader {
        traces: Vec<RecallTraceItem>,
        observations: Vec<CoOccurrenceObservation>,
        tunnels: Vec<TunnelLink>,
    }
    impl DreamingSubstrateReader for FakeReader {
        fn recent_recall_traces(&self) -> Vec<RecallTraceItem> {
            self.traces.clone()
        }
        fn co_occurrence_observations(&self) -> Vec<CoOccurrenceObservation> {
            self.observations.clone()
        }
        fn existing_tunnels(&self) -> Vec<TunnelLink> {
            self.tunnels.clone()
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
    fn obs(a: &str, b: &str, attempts: i64, ev: &[&str]) -> CoOccurrenceObservation {
        CoOccurrenceObservation {
            endpoint_a: a.to_string(),
            endpoint_b: b.to_string(),
            attempts,
            evidence_targets: ev.iter().map(|s| s.to_string()).collect(),
        }
    }
    fn link(a: &str, b: &str) -> TunnelLink {
        TunnelLink {
            source_drawer_id: Some(a.to_string()),
            target_drawer_id: Some(b.to_string()),
        }
    }

    // DC-1: a strong, novel candidate is proposed; report + reward map and
    // the single diary entry are assembled. (Swift C3-style happy path.)
    #[test]
    fn dc1_strong_candidate_proposes_and_reports() {
        let reader = FakeReader {
            traces: vec![trace("r1", true), trace("r2", true)],
            observations: vec![obs("a", "b", 9, &["r1", "r2"])],
            tunnels: vec![],
        };
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        // Injected now — deterministic test timestamp (epoch-seconds f64).
        let report = d.run_cycle(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink);

        assert_eq!(report.candidates_considered, 1);
        assert_eq!(report.proposals_emitted.len(), 1);
        assert_eq!(report.proposals_emitted[0].target, "a");
        assert_eq!(report.proposals_emitted[0].kind, "miningPattern");
        assert_eq!(report.reward_by_target["r1"], 1.0);
        assert_eq!(report.reward_by_target["r2"], 1.0);
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
        let reader = FakeReader {
            traces: vec![trace("r1", true)],
            observations: vec![],
            tunnels: vec![],
        };
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
    // suppressed, not proposed. (Swift duplicate-suppression test.)
    #[test]
    fn dc2_existing_tunnel_suppresses() {
        let reader = FakeReader {
            traces: vec![trace("r1", true), trace("r2", true)],
            observations: vec![obs("a", "b", 9, &["r1", "r2"])],
            tunnels: vec![link("a", "b")],
        };
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert_eq!(report.proposals_emitted.len(), 0);
        assert!(report.suppressed_duplicates >= 1);
    }

    // DC-3: EWC++ across two cycles through the daemon. Cycle 1 consolidates
    // a high score and proposes. Cycle 2 sees only-unused evidence: the
    // fresh score collapses but EWC++ keeps the consolidated score >= gate;
    // B-4 idempotency suppresses the re-proposal. (Swift EWC + B-4.)
    #[test]
    fn dc3_ewc_preserves_and_b4_suppresses_across_cycles() {
        let key = candidate_key("a", "b");
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        let mut sink = RecordingSink::default();

        let r1 = FakeReader {
            traces: vec![trace("r1", true), trace("r2", true)],
            observations: vec![obs("a", "b", 9, &["r1", "r2"])],
            tunnels: vec![],
        };
        let first = d.run_cycle(1_000_000.0, &r1, &RecallTraceRewardSource, &mut sink);
        assert_eq!(first.proposals_emitted.len(), 1);
        assert!(first.candidate_scores[&key] >= 0.7);

        let r2 = FakeReader {
            traces: vec![trace("r1", false), trace("r2", false)],
            observations: vec![obs("a", "b", 9, &["r1", "r2"])],
            tunnels: vec![],
        };
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
        let loaded = store.load_policy().unwrap_or_default();
        let mut daemon = DreamingDaemon::new(loaded);
        let reader = FakeReader {
            traces: vec![trace("r1", true), trace("r2", true)],
            observations: vec![obs("a", "b", 9, &["r1", "r2"])],
            tunnels: vec![],
        };
        let mut sink = RecordingSink::default();
        let report = daemon.run_cycle(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink);
        // 9 attempts < 100 → nothing proposes.
        assert_eq!(report.proposals_emitted.len(), 0, "strict policy blocks proposal");

        // Swap to a lenient policy via the store.
        let lenient = DreamingPolicy::default(); // min_attempts = 3
        store.save_policy(lenient);
        let loaded2 = store.load_policy().unwrap_or_default();
        let mut daemon2 = DreamingDaemon::new(loaded2);
        let mut sink2 = RecordingSink::default();
        let report2 = daemon2.run_cycle(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink2);
        // 9 attempts >= 3 → proposes.
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
        let reader = FakeReader {
            traces: vec![trace("r1", false), trace("r1", true)],
            observations: vec![],
            tunnels: vec![],
        };
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
        let reader = FakeReader { traces: vec![], observations: vec![], tunnels: vec![] };
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
        let reader = FakeReader { traces: vec![], observations: vec![], tunnels: vec![] };
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy { tick_interval_ms: 30_000, ..DreamingPolicy::default() });
        // First call fires (t=0).
        let first = d.pump(0.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(first.is_some(), "first call must fire");
        // Second call at t=29 s — interval (30 s) has not elapsed.
        let before = d.pump(29.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(before.is_none(), "call before interval must return None");
    }

    // PC-D3: a call at exactly the interval boundary fires. Mirrors Swift
    // `testDreamingPumpFiresAtInterval`.
    #[test]
    fn pc_d3_pump_fires_at_interval() {
        let reader = FakeReader { traces: vec![], observations: vec![], tunnels: vec![] };
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy { tick_interval_ms: 30_000, ..DreamingPolicy::default() });
        // First call fires at t=0.
        let _ = d.pump(0.0, &reader, &RecallTraceRewardSource, &mut sink);
        // Call at t=30 s — exactly at the interval boundary.
        let at_boundary = d.pump(30.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(at_boundary.is_some(), "call at interval boundary must fire");
    }

    // ─── Trigger-source tests (Board item 13) ───────────────────────────
    // Mirrors Swift TS-1, TS-2, TS-3, TS-4 in DreamingDaemonTests.

    // TS-1: .timer mode — pump fires on cadence; pump_on_event returns None
    // even when observation count is above threshold.
    #[test]
    fn ts1_timer_mode_fires_on_cadence_not_on_event() {
        let reader = FakeReader { traces: vec![], observations: vec![], tunnels: vec![] };
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default()); // trigger_mode = Timer

        // First pump always fires in timer mode (no prior timer tick).
        let first = d.pump(0.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(first.is_some(), ".timer: first pump must fire");

        // pump_on_event must return None regardless of observation count —
        // the event path is inactive in timer mode.
        let event_result = d.pump_on_event(100, 1.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(event_result.is_none(), ".timer: pump_on_event must return None (event path inactive)");

        // Timer fires after the cadence elapses.
        let second = d.pump(30.0, &reader, &RecallTraceRewardSource, &mut sink);
        assert!(second.is_some(), ".timer: pump fires after interval");
    }

    // TS-2: .event mode — pump_on_event fires when observation count meets
    // threshold; pump returns None (timer path inactive).
    #[test]
    fn ts2_event_mode_fires_on_event_not_on_timer() {
        let reader = FakeReader { traces: vec![], observations: vec![], tunnels: vec![] };
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
        let reader = FakeReader { traces: vec![], observations: vec![], tunnels: vec![] };
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

    fn empty_reader() -> FakeReader {
        FakeReader { traces: vec![], observations: vec![], tunnels: vec![] }
    }

    // AR-1: First cycle establishes baseline without firing reindex.
    #[test]
    fn ar1_first_cycle_establishes_baseline_without_reindex() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut probe = InMemoryCorpusGrowthProbe::new(10);
        let mut d = DreamingDaemon::new(DreamingPolicy::default());

        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        assert_eq!(probe.reindex_calls.len(), 0, "first cycle must not trigger reindex");
        // Baseline was read (probe.count was consulted) and stored internally.
        // We verify it indirectly via AR-2 (no reindex below threshold from this baseline).
    }

    // AR-2: Growth below threshold — reindex must NOT fire.
    #[test]
    fn ar2_below_threshold_no_reindex() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        // threshold = 25; start at 10.
        let mut probe = InMemoryCorpusGrowthProbe::new(10);
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        // d.reindex_growth_threshold is already AUTO_REINDEX_GROWTH_THRESHOLD (25).

        // Cycle 1: baseline = 10.
        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // Grow by 24 (below threshold 25).
        probe.count = 34;
        d.run_cycle_with_probe(1_030_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        assert_eq!(probe.reindex_calls.len(), 0, "growth of 24 (< 25) must not trigger reindex");
    }

    // AR-3: Growth at threshold triggers reindex; timestamp is the cycle's now.
    #[test]
    fn ar3_at_threshold_reindex_fires() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut probe = InMemoryCorpusGrowthProbe::new(10);
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        d.set_reindex_growth_threshold(25);

        // Cycle 1: baseline = 10.
        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // Grow by exactly 25 (10 + 25 = 35).
        probe.count = 35;
        let t1 = 1_060_000.0_f64;
        d.run_cycle_with_probe(t1, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        assert_eq!(probe.reindex_calls.len(), 1, "growth == threshold must trigger reindex");
        assert!((probe.reindex_calls[0] - t1).abs() < 1e-6, "reindex must receive cycle's now");
    }

    // AR-3b: After reindex, baseline advances; sub-threshold growth does not re-fire.
    #[test]
    fn ar3b_baseline_advances_after_reindex() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut probe = InMemoryCorpusGrowthProbe::new(10);
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        d.set_reindex_growth_threshold(25);

        // Cycle 1: baseline = 10.
        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // Grow to 35 (delta 25 == threshold): reindex fires, baseline advances to 35.
        probe.count = 35;
        d.run_cycle_with_probe(1_060_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));
        assert_eq!(probe.reindex_calls.len(), 1, "reindex must fire on first threshold crossing");

        // Grow by 5 more (35 → 40): delta 5 < 25, no reindex.
        probe.count = 40;
        d.run_cycle_with_probe(1_120_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));
        assert_eq!(probe.reindex_calls.len(), 1, "sub-threshold growth after baseline advance must not re-fire");
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
        d.set_reindex_growth_threshold(10); // small threshold for this test

        // Cycle 1: baseline = 0.
        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // First window: grow by 10 → reindex, baseline → 10.
        probe.count = 10;
        d.run_cycle_with_probe(1_030_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));
        assert_eq!(probe.reindex_calls.len(), 1, "first threshold crossing must fire");

        // Second window: grow by 10 more (10 → 20) → reindex, baseline → 20.
        probe.count = 20;
        d.run_cycle_with_probe(1_060_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));
        assert_eq!(probe.reindex_calls.len(), 2, "second threshold crossing must fire independently");
    }

    // AR-6: Reindex error (error_on_reindex) is non-fatal; baseline still advances.
    #[test]
    fn ar6_reindex_error_is_non_fatal() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut probe = InMemoryCorpusGrowthProbe { count: 10, error_on_reindex: true, ..Default::default() };
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        d.set_reindex_growth_threshold(1); // fire immediately after first cycle

        // Cycle 1: baseline = 10.
        d.run_cycle_with_probe(1_000_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // Grow by 1 (threshold = 1): reindex called but error_on_reindex suppresses it.
        probe.count = 11;
        let report = d.run_cycle_with_probe(1_030_000.0, &reader, &RecallTraceRewardSource, &mut sink, Some(&mut probe));

        // Must not panic. Report is valid.
        assert_eq!(report.candidates_considered, 0);
        // reindex_calls is empty because error_on_reindex swallows the call.
        assert_eq!(probe.reindex_calls.len(), 0, "error_on_reindex suppresses the call record");
    }
}
