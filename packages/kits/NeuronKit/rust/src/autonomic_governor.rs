//! Resident Autonomic Governor (see ADR-LOOPBACKHTTP-001 §17).
//!
//! The Rust vertical's parity of the Swift `AutonomicGovernor` actor
//! (packages/kits/NeuronKit/Sources/NeuronKit/Governor/AutonomicGovernor.swift).
//! Drives the Brain's cadence work — dreaming (NeuronKit) and maintenance
//! (NeuronKit) — on each daemon's own interval.
//!
//! # Layering
//!
//! The governor lives in NeuronKit. AriaMcpKit is the HOST that starts it and
//! injects host-coupled concerns as abstractions so NeuronKit never imports
//! AriaMcpKit or observer-sink. The topology snapshot write is injected via the
//! `GovernorTopologySink` trait (this crate); the AriaMcpKit host provides an
//! implementation backed by `observer_sink::StatsStore`.
//!
//! # Live estate wiring
//!
//! The governor holds the SAME `Arc<Mutex<EstateCoordinator>>` and `EstateHandle`
//! as the HTTP transport — they are the same Arc, so both the governor thread and
//! `run_http_loop` operate on the same live estate. The Mutex serializes all
//! coordinator access. This is the Rust parity of the Swift governor receiving
//! `kit: GeniusLocusKit` and `handle: EstateHandle` at construction.
//!
//! Per tick:
//!   1. Lock the coordinator, snapshot readers (EstateDreamingReader,
//!      EstateMaintenanceReader). Snapshots are built at construction; the
//!      lock can be released immediately after both readers are built.
//!   2. Construct sinks over the live `Arc<dyn DrawerStore>` (same store the
//!      coordinator was opened with — held as `registry.default.store`).
//!   3. Run `dreaming.pump(now, &reader, &reward, &mut sink)` and
//!      `maintenance.pump(now, &reader, &mut sink)` with the lock released,
//!      so the coordinator is available for HTTP tool-calls during the cycle.
//!
//! # Lock contention note
//!
//! The reader snapshot step acquires `Arc<Mutex<EstateCoordinator>>` briefly.
//! At 30 s / 5 min cadences this is negligible contention, but any HTTP
//! tool-call that arrives while the reader snapshot is in progress will block
//! for the duration of the three coordinator reads (all_drawers, all_tunnels,
//! recent_recall_traces). These reads are fast in-memory scans for the default
//! in-memory backend and WAL-mode reads for SQLite. Acceptable at the current
//! cadence; revisit if the estate grows to >100 k rows or the cadence shrinks
//! below 5 s.
//!
//! # Determinism (ARIA_MCP_SPEC §9 / §17)
//!
//! The loop is the ONLY scheduler. It reads the clock once per tick (via
//! `SystemTime::now()` in `run_loop`) and injects that `now_epoch_secs` into
//! every daemon's `pump` call. The daemons themselves NEVER read the system
//! clock — the conformance contract. Each daemon self-gates on its own
//! interval; `pump(now)` returns `None` until the interval has elapsed, so the
//! loop ticks at a coarse base granularity and lets each daemon decide whether
//! to fire.
//!
//! # Resilience
//!
//! An error in one daemon's pump is logged to stderr and the loop continues —
//! the Autonomic Governor must never crash the daemon. The stop flag breaks the
//! loop cleanly for tests and process shutdown.
//!
//! # Policy (P2)
//!
//! Cadence policy comes from in-memory stores seeded with spec defaults
//! (dreaming 30 s, maintenance 5 min). P3 swaps these for the manifest store
//! so an operator's policy survives restarts; the seam is unchanged.
//!
//! # Standing signals
//!
//! The governor owns this estate's standing-signal scheduler (a
//! `SerialLaneScheduler<CoordinatorDispatcher>` from GLK) and ticks it each
//! iteration, mirroring the Swift governor's `kit.signalTick(in:handle:now:)`.
//! Until signals are registered the scheduler is absent and the tick
//! benign-skips (`signals_ticked == false`) — the Swift `schedulerNotStarted`
//! benign-skip. The resident bootstrap (runtime.rs, resident HTTP path) calls
//! `register_default_standing_signals` once at startup so the live path ticks
//! the architecture-spec §11.2 signals through real propose/associate verbs.
//!
//! The scheduler lives in the governor rather than the GLK coordinator because
//! the production dispatcher (`CoordinatorDispatcher`) holds an
//! `Arc<Mutex<EstateCoordinator>>`; a coordinator-owned scheduler would close a
//! reference cycle. The governor already holds `coord`/`handle`/`store`, the
//! exact inputs `CoordinatorDispatcher::new` needs. The registration methods
//! (`register_default_standing_signals` / `register_standing_signal`) are the
//! producer SEAM: Track 2 (graph-centrality) and Track 3 (Bradley-Terry)
//! register their signal specs here and write outputs to GLK
//! `recall::{GraphCache, PreferenceStore}` — the producers themselves are NOT
//! part of this harness.
//!
//! # Graph analytics (Rust gap)
//!
//! The Swift AutonomicGovernor dispatches `graphAnalyticsScan` on a 10-minute
//! cadence (TOPOLOGY-GA1), calling CognitionKit's Keystones and Constellation
//! lenses per wing. The Rust governor drives dreaming + maintenance ONLY — there
//! is no Rust CognitionKit equivalent for this path. Rust graph analytics are a
//! separate feature tracked in the backlog; this omission is intentional and
//! documented here so future implementers know exactly what is missing.
//!
//! # Topology snapshot duty
//!
//! The Swift AutonomicGovernor fires a topology snapshot duty on a 5-minute
//! cadence (default, `MOOTX01_TOPOLOGY_CADENCE_SECONDS` overrides). It reads
//! the full estate, runs `NeuronKit.graphTopology` (Louvain + centrality), and
//! writes the payload to `observer_sink::StatsStore::write_topology_snapshot`.
//!
//! The Rust governor mirrors that exactly: store reads →
//! `neuron_kit::topology_analysis::graph_topology` (Louvain + centrality) →
//! wire-shape serialization → snapshot write. Two cheap escapes precede the
//! expensive work, mirroring Swift:
//!   1. the monitoring gate — the duty is skipped while the stats store's
//!      live monitoring flag is off ("off is free"; store-read failures fail
//!      OPEN so a transient error never silently freezes topology);
//!   2. the inputs dirty token — an unchanged estate skips the math, encode,
//!      and write, so `generatedTs` means "when the content last changed".
//!
//! `stats_store` is wired at construction from `main.rs` when
//! `ARIA_MCP_STATS_STORE` is set. Tests pass `None` (no store needed).
//!
//! # Pool reducer (novel-token merge-back) + live tagger swap
//!
//! NEAR-REALTIME (`MOOTX01_POOL_REDUCE_CADENCE_SECONDS`, default 0 = every tick)
//! the governor drives `lattice::pool_reduce`, folding accumulated novel-token
//! submissions from the LatticeLib pool directory into the writable
//! WordClassTable artifact, then atomically swaps the running tagger onto the
//! merged table via `lattice_lib::swap_global_table_from_precedence`. This is the
//! Rust parity of the Swift governor's PoolReducer + live-swap trigger — both
//! ports gate identically and call the same-shaped reducer and swap. The reduce
//! is no-op-safe on an empty/absent pool and idempotent on a drained pool. On a
//! NON-NOOP merge the running tagger / FDC encode path adopts the merged tokens
//! IN-SESSION on its next read — no process restart (cookbook §1.3/§2.2). The
//! reduce latency floor is the base tick (`MOOTX01_BRAIN_TICK_MS`).
//!
//! # Base tick
//!
//! Read from env `MOOTX01_BRAIN_TICK_MS` at construction (default 5000 ms).
//! This is the sampling resolution for the daemons' own (longer) cadences,
//! not a cadence itself.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use genius_locus_kit::{
    default_standing_signal_specs, EstateCoordinator, EstateHandle,
    SchedulerCoordinatorDispatcher, SchedulerError, SchedulerSignalID, SchedulerSignalReport,
    SchedulerSignalSpec, SerialLaneScheduler,
};
use intellectus_lib::{report, EventKind, StatSample};
use uuid::Uuid;
use locus_kit::drawer_store::DrawerStore;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::sqlite::SqliteStorage;
use persistence_kit::storage::BackendConfiguration;
use queuekit::{DrainLease, PersistenceKitBackend, QueueBackend, QueueKit};
use substrate_types::hlc::HLCGenerator;
use crate::{
    DreamingDaemon, DreamingPolicy, DreamingPolicyStore, EstateDreamingReader,
    EstateDreamingSink, EstateMaintenanceReader, EstateMaintenanceSink, MaintenanceDaemon,
    MaintenancePolicyStore, RecallTraceRewardSource,
};
use crate::estate_manifest_policy_store::{
    EstateManifestDreamingPolicyStore, EstateManifestMaintenancePolicyStore,
};
use crate::governor_topology_sink::GovernorTopologySink;

// ── Default constants ─────────────────────────────────────────────────────────

/// Default base-tick interval in milliseconds when `MOOTX01_BRAIN_TICK_MS`
/// is absent or invalid. Matches the Swift AutonomicGovernor default.
const DEFAULT_TICK_MS: u64 = 5_000;

/// Default topology snapshot cadence in milliseconds (300 000 = 5 minutes).
/// Override with `MOOTX01_TOPOLOGY_CADENCE_SECONDS` env var.
const DEFAULT_TOPOLOGY_CADENCE_MS: u64 = 300_000;

/// Default graph-centrality producer cadence in milliseconds (600 000 =
/// 10 minutes). Matches the Swift `graphCentralityIntervalMs` default — both
/// ports ride the estate structure graph on the same cadence.
const DEFAULT_GRAPH_CENTRALITY_CADENCE_MS: u64 = 600_000;

/// Default preference producer cadence in milliseconds (600 000 = 10 minutes).
/// Matches the Swift `preferenceIntervalMs` default — both ports ride the
/// estate's recall-trace reward history on the same cadence as graph centrality.
const DEFAULT_PREFERENCE_CADENCE_MS: u64 = 600_000;

/// Default minimum spacing between pool-reduce passes, in milliseconds. 0 =
/// NEAR-REALTIME: the reducer is considered every tick, gated by its own
/// no-op-safe scan, then live-swaps the running tagger on a non-noop merge. When
/// the novel-token pool crosses the submission threshold a file lands in the
/// pool directory and the next tick folds it in; the reduce latency floor is the
/// base tick (`MOOTX01_BRAIN_TICK_MS`), not a fixed hour. A positive
/// `MOOTX01_POOL_REDUCE_CADENCE_SECONDS` reinstates a minimum spacing (test
/// determinism / load throttling). This supersedes the prior hourly cadence
/// (cookbook §2.2 rewrite).
const DEFAULT_POOL_REDUCE_CADENCE_MS: u64 = 0;

// ── Planned-hardening caps ────────────────────────────────────────────────────

/// Maximum number of live drawers scored per graph-centrality scan.
///
/// Planned hardening: prevents per-tick O(n²) edge build on large estates.
/// Drawers beyond the cap score 0.0 (spec C-16 — correct, identical to
/// "no cache registered"). Applied to live (non-tombstoned) drawers sorted
/// ascending by id before building the centrality graph, so the capped subset
/// is stable and deterministic. Parity: matches `graphCentralityScanNodeCap`
/// in AutonomicGovernor.swift.
pub const GRAPH_CENTRALITY_SCAN_NODE_CAP: usize = 10_000;

/// Maximum number of pool submissions the pool-reduce duty drains per tick.
///
/// The reduce runs synchronously on the governor tick, so it processes at most
/// this many of the OLDEST submissions per run; a larger backlog drains over
/// successive ticks (bounded near-realtime drain). This replaced an earlier
/// "defer the reduce when the pool exceeds this cap" behaviour, which deadlocked:
/// over cap, the very reduce that would shrink the pool was skipped, so the pool
/// grew without bound. Parity: matches `poolReduceFileCap` in
/// AutonomicGovernor.swift.
pub const POOL_REDUCE_FILE_CAP: usize = 500;

// ── ISO8601 helpers ───────────────────────────────────────────────────────────

/// Format epoch seconds as an ISO8601 UTC string (`YYYY-MM-DDTHH:MM:SSZ`).
///
/// This is the canonical timestamp format the substrate's TEXT date columns use.
/// `EstateDreamingReader::new` takes `since`/`now` as ISO8601 strings matching
/// this format.
fn epoch_secs_to_iso8601(epoch_secs: i64) -> String {
    // Hand-rolled to avoid a chrono dependency. Correct for the range of
    // epoch values the governor will ever see (year 2001–2100, UTC).
    let secs = epoch_secs.max(0) as u64;
    let s = secs % 60;
    let m = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    // Gregorian calendar from days since 1970-01-01.
    let (year, month, day) = days_to_ymd(days);
    format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}Z")
}

/// Convert days since 1970-01-01 to (year, month, day). Gregorian only.
fn days_to_ymd(days: u64) -> (u64, u64, u64) {
    // Algorithm: J.P. Lemay / Wikipedia "Julian day" proleptic Gregorian.
    let z = days + 719468; // days since March 1, year 0
    let era = z / 146097;
    let doe = z % 146097; // day of era [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // year of era [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // day of year [0, 365]
    let mp = (5 * doy + 2) / 153; // month of year [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // day [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // month [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

// ── Signals queue construction helper (T5, ADR-021 Decision 7) ───────────────

/// Fixed estate identity for the transient in-memory signals-queue backend on
/// non-SQLite estates. A constant avoids UUID nondeterminism in the engine.
/// Matches the CorpusKit pattern for its in-memory ingest-queue store ID.
fn signals_queue_inmemory_id() -> uuid::Uuid {
    uuid::Uuid::from_u128(0x5169_5161_5561_7565_0000_0000_0000_0000)
}

/// Build the signals `QueueKit` facade and optional `DrainLease` for an estate.
///
/// Backend selection (mirrors Swift `SignalAPI.ensureScheduler`):
///   - SQLite estate → shared encrypted `queue.sqlite` beside the estate, derived
///     via `EstateConfiguration::queue_sibling("queue.sqlite")`. A `DrainLease`
///     keyed on `"signals"` ensures exactly one drainer per (estate, stream) across
///     processes (ADR-021 Decision 7). On open failure, falls back to in-memory
///     (the signals lane degrades to transient rather than crashing the resident).
///   - InMemory / no storage → transient PersistenceKitBackend + `None` lease.
///
/// Called once per estate at scheduler-mint time (inside `ensure_scheduler`).
fn build_signals_queue(
    store: &Arc<dyn DrawerStore>,
    handle_id: &str,
) -> (QueueKit<Box<dyn QueueBackend>>, Option<DrainLease>) {
    // Retrieve the estate's Storage to inspect its backend configuration.
    // `DrawerStore::storage()` returns `None` for the test-double/mock drawer
    // stores that don't back a real Storage; those fall through to in-memory.
    let storage = store.storage();

    let backend_config = storage
        .as_ref()
        .map(|s| s.configuration().backend.clone());

    match backend_config {
        Some(BackendConfiguration::Sqlite { ref path, .. }) => {
            // Derive the sibling config from the estate's configuration.
            // `queue_sibling` is deterministic — same estate → same sibling UUID
            // and path — so all processes that open the estate share one queue.sqlite.
            let sibling_result = storage
                .as_ref()
                .expect("storage is Some when backend is Sqlite")
                .configuration()
                .queue_sibling("queue.sqlite");

            let sibling_cfg = match sibling_result {
                Ok(cfg) => cfg,
                Err(e) => {
                    eprintln!(
                        "AutonomicGovernor: queue_sibling failed for estate {handle_id}: {:?}. \
                         Degrading signals lane to transient in-memory backend.",
                        e
                    );
                    return build_inmemory_signals_queue();
                }
            };

            let qs = match SqliteStorage::new(sibling_cfg) {
                Ok(qs) => Arc::new(qs),
                Err(e) => {
                    eprintln!(
                        "AutonomicGovernor: SqliteStorage::new for queue.sqlite failed \
                         (estate {handle_id}): {:?}. Degrading to in-memory.",
                        e
                    );
                    return build_inmemory_signals_queue();
                }
            };

            if let Err(e) = PersistenceKitBackend::open_schema(qs.as_ref()) {
                eprintln!(
                    "AutonomicGovernor: open_schema for queue.sqlite failed \
                     (estate {handle_id}): {:?}. Degrading to in-memory.",
                    e
                );
                return build_inmemory_signals_queue();
            }

            let backend = PersistenceKitBackend::new(qs);
            let queue: QueueKit<Box<dyn QueueBackend>> =
                QueueKit::new(Box::new(backend) as Box<dyn QueueBackend>);

            // Owner token: PID + handle_id string, so a reused PID after a crash
            // cannot impersonate the prior holder (mirrors Swift's instanceToken).
            let estate_dir = std::path::Path::new(path)
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_else(|| std::path::PathBuf::from("."));
            let owner = format!("pid-{}-{}", std::process::id(), handle_id);
            let lease = DrainLease::new(&estate_dir, "signals", owner);

            (queue, Some(lease))
        }
        _ => {
            // InMemory estate, Postgres estate, or no storage: all get the
            // transient in-memory backend. Postgres deferred per ADR-021
            // SQLite-first sequencing.
            build_inmemory_signals_queue()
        }
    }
}

/// Build a transient in-memory signals queue with no drain lease. Used for
/// in-memory estates and as the degraded fallback when SQLite open fails.
fn build_inmemory_signals_queue() -> (QueueKit<Box<dyn QueueBackend>>, Option<DrainLease>) {
    let storage = Arc::new(InMemoryStorage::with_estate(signals_queue_inmemory_id()));
    PersistenceKitBackend::open_schema(storage.as_ref())
        .expect("InMemoryStorage open_schema cannot fail");
    let backend = PersistenceKitBackend::new(storage);
    let queue: QueueKit<Box<dyn QueueBackend>> =
        QueueKit::new(Box::new(backend) as Box<dyn QueueBackend>);
    (queue, None)
}

// ── AutonomicGovernor ─────────────────────────────────────────────────────────

/// What one governor tick fired — returned from `tick()` for tests.
#[derive(Debug, Clone, PartialEq)]
pub struct GovernorReport {
    pub dreaming_fired: bool,
    pub maintenance_fired: bool,
    /// Standing-signal scheduler ticked this tick. Mirrors Swift
    /// `GovernorReport.signalsTicked`. True when a scheduler is registered and
    /// its `tick` ran; false on the benign no-scheduler skip (no standing
    /// signals registered yet — the governor advances the scheduler only when
    /// one has been minted via `register_default_standing_signals` /
    /// `register_standing_signal`). Never an error: an unregistered scheduler is
    /// a benign skip exactly as Swift's `schedulerNotStarted` → `signalsTicked
    /// == false`.
    pub signals_ticked: bool,
    /// Graph-centrality producer duty fired this tick. True when the cadence
    /// elapsed: the duty read the estate structure graph, computed per-drawer
    /// eigenvalue centrality via the keystones oracle, and registered the
    /// `GraphCache` the recall `graph` column reads. Mirrors Swift
    /// `GovernorReport.graphCentralityFired`. The flag reflects the cadence gate;
    /// the registration happens whenever the gate fires (an empty estate
    /// registers an empty cache — every score 0.0, which is correct).
    pub graph_centrality_fired: bool,
    /// Preference producer duty fired this tick. True when the cadence elapsed:
    /// the duty read the estate's recall-trace reward history, fitted per-drawer
    /// Bradley-Terry preference strengths via the `learned_preference` oracle, and
    /// registered the `PreferenceStore` the recall `preference` column reads.
    /// Mirrors Swift `GovernorReport.preferenceFired`. The flag reflects the
    /// cadence gate; the registration happens whenever the gate fires (an estate
    /// with no traces registers an empty store — every score 0.0, which is
    /// correct).
    pub preference_fired: bool,
    /// Topology snapshot duty fired this tick. True when the cadence elapsed
    /// regardless of whether `topology_sink` is Some — the field reflects the
    /// cadence gate only, not sink presence (matching Swift's contract).
    pub topology_snapshot_fired: bool,
    /// Pool reducer ran this tick (novel-token merge-back). True when the
    /// near-realtime gate elapsed (default every tick) — true even on an
    /// empty-pool no-op (idempotent contract), false on a reduce error (logged;
    /// the loop continues). On a NON-NOOP merge the running tagger adopts the
    /// merged tokens IN-SESSION via the live swap below (cookbook §1.3/§2.2).
    pub pool_reduce_fired: bool,
    /// True when this tick LIVE-SWAPPED the word-class table after a non-noop
    /// reduce — the running tagger adopted the new table in-session (no restart).
    /// False on a noop/absent reduce.
    pub table_swapped: bool,
    /// The word-class table version after this tick. Bumped on every live swap;
    /// lets tests/telemetry observe in-session learning. Mirrors Swift
    /// `GovernorReport.tableVersion`.
    pub table_version: u64,
    /// True when this tick dispatched a GC sweep: probed stream drain leases and
    /// reclaimed orphaned cur→new rows for stale streams (Mission #54). False
    /// when the cadence has not yet elapsed (30 s default). Mirrors Swift
    /// `GovernorReport.gcSweepFired`.
    pub gc_sweep_fired: bool,
}

/// The resident Autonomic Governor.
///
/// Wired to the LIVE default estate through:
/// - `coord`: the same `Arc<Mutex<EstateCoordinator>>` the HTTP transport uses
/// - `handle`: the default estate's handle
/// - `store`: the `Arc<dyn DrawerStore>` backing that estate (sink write path)
///
/// Construction:
///   `AutonomicGovernor::new(coord, handle, store)` — mirrors the Swift governor
///   receiving `kit: GeniusLocusKit` and `handle: EstateHandle`.
///
/// `run_loop` drives the governor until `stop()` is called or the stop flag is
/// set. `tick(now)` exposes one iteration for deterministic tests.
pub struct AutonomicGovernor {
    dreaming: DreamingDaemon,
    maintenance: MaintenanceDaemon,
    /// Manifest-backed policy stores (F6 / ADR-020). The governor saves each
    /// daemon's cycle state through these after every fired cycle so a restart
    /// resumes the prior run's idempotency/cycle memory. Held as boxed trait
    /// objects so the in-memory store can still be swapped in by future callers.
    dreaming_policy_store: Box<dyn DreamingPolicyStore + Send>,
    maintenance_policy_store: Box<dyn MaintenancePolicyStore + Send>,
    /// Policy: tick_interval_ms for computing the dreaming reward window.
    dreaming_policy: DreamingPolicy,
    /// Shared coordinator — same Arc as the HTTP transport; Mutex serializes
    /// all estate reads (coordinator snapshot) and HTTP tool-call writes.
    coord: Arc<Mutex<EstateCoordinator>>,
    /// The estate targeted by this governor.
    handle: EstateHandle,
    /// The live DrawerStore backing `handle`. Used by the sinks to write
    /// proposals and diary entries directly to the live estate.
    store: Arc<dyn DrawerStore>,
    /// Base tick interval — the sampling resolution for the daemons' own
    /// (longer) intervals. Not a cadence itself.
    base_tick_ms: u64,
    /// Cancellation flag. `stop()` sets this; `run_loop` checks it between
    /// ticks. Set from any thread (AtomicBool).
    stop_flag: Arc<AtomicBool>,
    /// Host-injected topology snapshot sink. None = no write (telemetry
    /// disabled). The AriaMcpKit host provides an implementation backed by
    /// `observer_sink::StatsStore` when `ARIA_MCP_STATS_STORE` is configured.
    /// The cadence gate fires regardless of whether the sink is present —
    /// topology_snapshot_fired reflects cadence only, not sink presence.
    topology_sink: Option<Box<dyn GovernorTopologySink>>,
    /// Topology snapshot cadence in milliseconds (default 300 000 = 5 min).
    /// Overridden by MOOTX01_TOPOLOGY_CADENCE_SECONDS at construction.
    topology_cadence_ms: u64,
    /// Epoch-seconds of the last topology snapshot fire. None = never fired.
    last_topology_snapshot_secs: Option<f64>,
    /// Graph-centrality producer cadence in milliseconds (default 600 000 =
    /// 10 min, mirroring Swift `graphCentralityIntervalMs`). The producer reads
    /// the estate structure graph, computes per-drawer eigenvalue centrality via
    /// the keystones oracle, and registers the `GraphCache` the recall `graph`
    /// column reads.
    graph_centrality_cadence_ms: u64,
    /// Epoch-seconds of the last graph-centrality producer fire. None = never
    /// fired, so the first tick produces immediately (the `graph` column is live
    /// from startup rather than dark for one cadence). Mirrors Swift
    /// `lastGraphCentralityFired`.
    last_graph_centrality_secs: Option<f64>,
    /// Preference producer cadence in milliseconds (default 600 000 = 10 min,
    /// mirroring Swift `preferenceIntervalMs`). The producer reads the estate's
    /// recall-trace reward history, fits per-drawer Bradley-Terry preference
    /// strengths via the `learned_preference` oracle, and registers the
    /// `PreferenceStore` the recall `preference` column reads.
    preference_cadence_ms: u64,
    /// Epoch-seconds of the last preference producer fire. None = never fired, so
    /// the first tick produces immediately (the `preference` column is live from
    /// startup rather than dark for one cadence). Mirrors Swift
    /// `lastPreferenceFired`.
    last_preference_secs: Option<f64>,
    /// Stable fingerprint of the most recent COMPUTED (or confirmed-current)
    /// topology snapshot inputs. A matching fingerprint at the next due cadence
    /// skips the math/encode/write — the stored snapshot is still current.
    /// Persisted beside the snapshot and loaded once on the first post-restart
    /// duty (F5), so the skip holds across process restarts. Mirrors Swift
    /// `lastTopologyFingerprint`.
    last_topology_fingerprint: Option<String>,
    /// True once the persisted fingerprint has been loaded (one-shot, on the
    /// first topology duty). Mirrors Swift `topologyFingerprintLoaded`.
    topology_fingerprint_loaded: bool,
    /// Watermark: drawer count at last graph-centrality computation. When the
    /// active drawer count hasn't changed since last cadence, the full
    /// eigenvalue recompute is skipped (scores re-registered from estate.meta
    /// cache). None = never computed, forces first computation. Mirrors Swift
    /// `centralityCount` stored in estate.meta.
    last_centrality_drawer_count: Option<usize>,
    /// Watermark: drawer count at last preference computation. Same skip
    /// logic as centrality. Mirrors Swift `preferenceCount` in estate.meta.
    last_preference_drawer_count: Option<usize>,
    /// Watermark: drawer count at last topology snapshot. Gates the full
    /// allDrawers+allTunnels+allKGFacts load. Mirrors Swift topology
    /// audit-count watermark.
    last_topology_drawer_count: Option<usize>,
    /// Pool-reduce cadence in milliseconds (default 3 600 000 = 1 hour).
    /// Overridden by `MOOTX01_POOL_REDUCE_CADENCE_SECONDS` at construction.
    /// Mirrors Swift `poolReduceCadenceMs`.
    pool_reduce_cadence_ms: u64,
    /// Epoch-seconds of the last pool-reduce fire. None = never fired (so the
    /// first tick reduces immediately, folding any pool accumulated while the
    /// daemon was down). Mirrors Swift `lastPoolReduceFired`.
    last_pool_reduce_secs: Option<f64>,
    /// Pool directory the reducer scans, resolved once at construction from the
    /// LatticeLib convention (`LATTICE_POOL_DIR` or the platform default).
    pool_dir: PathBuf,
    /// Writable WordClassTable artifact the reducer merges into (sibling of the
    /// pool directory). Resolved once at construction.
    pool_table_artifact: PathBuf,
    /// GC sweep cadence in milliseconds. Default 30 000 (30 s = 2× DrainLease TTL).
    /// When elapsed, `tick` probes the dreaming and signals stream drain leases and
    /// reclaims orphaned cur rows for stale streams (Mission #54 crash recovery).
    /// Pass 0 in tests to fire every tick. Mirrors Swift `gcSweepIntervalMs`.
    gc_sweep_cadence_ms: u64,
    /// Epoch-seconds of the last GC sweep. None = never fired (so the first tick
    /// sweeps immediately, catching orphaned cur rows from a prior crash before the
    /// first drain pass). Mirrors Swift `lastGCSweepFired`.
    last_gc_sweep_secs: Option<f64>,
    /// Standing-signal scheduler for this estate. `None` until signals are
    /// registered via `register_default_standing_signals` (production bootstrap)
    /// or `register_standing_signal` (custom signals / tests). When `None`, the
    /// governor tick benign-skips `signal_tick` and reports `signals_ticked ==
    /// false` — the same behaviour as the Swift governor's `schedulerNotStarted`
    /// benign skip before any signal is registered.
    ///
    /// # Why the scheduler lives in the governor, not the coordinator
    ///
    /// Swift puts the per-estate scheduler registry on the `GeniusLocusKit`
    /// actor (`schedulers: [EstateHandle: StandingSignalScheduler]`) and the
    /// governor calls `kit.signalTick`. The Rust port cannot mirror that: the
    /// production dispatcher `CoordinatorDispatcher` holds an
    /// `Arc<Mutex<EstateCoordinator>>`, so a scheduler owned by the coordinator
    /// would close a reference cycle (coordinator → scheduler → dispatcher →
    /// coordinator). The governor already holds `coord`, `handle`, and `store`
    /// — exactly the inputs `CoordinatorDispatcher::new(coord, handle)` needs —
    /// so the governor is the natural owner. The single-serial-lane guarantee is
    /// unchanged: one scheduler per estate, one drainer, FIFO application.
    ///
    /// This is the producer SEAM for Track 2 (graph-centrality) and Track 3
    /// (Bradley-Terry): those producers register their signal specs through the
    /// `register_standing_signal` / `register_default_standing_signals` methods
    /// and write their outputs to GLK `recall::{GraphCache, PreferenceStore}`
    /// (already ported). Track 1 builds the seam only — no producer logic.
    scheduler: Option<SerialLaneScheduler<SchedulerCoordinatorDispatcher>>,
}

impl AutonomicGovernor {
    /// Construct the governor wired to the live estate.
    ///
    /// - `coord`: shared coordinator — the same Arc the HTTP transport holds.
    /// - `handle`: the default estate's handle.
    /// - `store`: the `Arc<dyn DrawerStore>` the estate was opened with; the
    ///   sinks write proposals and diary entries through this reference.
    ///
    /// Base tick is read from `MOOTX01_BRAIN_TICK_MS` (default 5000 ms).
    /// Topology cadence is read from `MOOTX01_TOPOLOGY_CADENCE_SECONDS` (default 300 s).
    /// No topology sink — topology snapshot writes are skipped. Use
    /// `new_with_topology_sink` when a sink is available (production mode).
    pub fn new(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
    ) -> Self {
        Self::build(coord, handle, store, Arc::new(AtomicBool::new(false)), None)
    }

    /// Construct with a host-injected topology sink for topology snapshot writes.
    ///
    /// The sink implements `GovernorTopologySink` — AriaMcpKit passes a
    /// `StatsStoreTopologySink` wrapping `Arc<observer_sink::StatsStore>`.
    /// NeuronKit never imports observer-sink directly; the sink is the injection
    /// seam that keeps NeuronKit free of host-layer telemetry. Called from
    /// `runtime.rs` when `ARIA_MCP_STATS_STORE` is configured.
    pub fn new_with_topology_sink(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
        topology_sink: Option<Box<dyn GovernorTopologySink>>,
    ) -> Self {
        Self::build(coord, handle, store, Arc::new(AtomicBool::new(false)), topology_sink)
    }

    /// Construct with a caller-supplied stop flag. Used by tests to stop the
    /// loop from outside without spawning a thread.
    pub fn with_stop_flag(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
        stop_flag: Arc<AtomicBool>,
    ) -> Self {
        Self::build(coord, handle, store, stop_flag, None)
    }

    /// Construct with a caller-supplied stop flag AND an explicit base tick.
    /// Passes `base_tick_ms` directly instead of reading
    /// `MOOTX01_BRAIN_TICK_MS`, so a test that wants a fast run-loop tick does
    /// NOT set a process-global env var that races sibling tests constructing
    /// governors in parallel. Mirrors the `topology_cadence_ms` override on
    /// `new_for_testing`. Test-only; production uses `with_stop_flag` / `new`.
    pub fn with_stop_flag_and_tick(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
        stop_flag: Arc<AtomicBool>,
        base_tick_ms: u64,
    ) -> Self {
        // Production cadences for everything except the base tick, which the
        // caller supplies directly (no env read).
        Self::build_inner(
            coord, handle, store, stop_flag, None,
            base_tick_ms, parse_topology_cadence_ms(),
            parse_pool_reduce_cadence_ms(), lattice_lib::default_pool_dir(),
            lattice_lib::default_table_artifact(),
        )
    }

    /// Test-support: like `with_stop_flag_and_tick` but the pool reducer targets
    /// the caller-supplied `pool_dir`/`pool_table_artifact` instead of the real
    /// user pool. Keeps run-loop tests hermetic — a tick never reads or writes
    /// the platform-default pool — without the `LATTICE_POOL_DIR` env race across
    /// parallel test threads (ce-fdcpool test isolation). Test-only.
    #[allow(clippy::too_many_arguments)]
    pub fn with_stop_flag_tick_and_pool(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
        stop_flag: Arc<AtomicBool>,
        base_tick_ms: u64,
        pool_dir: PathBuf,
        pool_table_artifact: PathBuf,
    ) -> Self {
        Self::build_inner(
            coord, handle, store, stop_flag, None,
            base_tick_ms, parse_topology_cadence_ms(),
            parse_pool_reduce_cadence_ms(), pool_dir, pool_table_artifact,
        )
    }

    /// Internal canonical constructor. All public constructors call this.
    /// `topology_cadence_ms_override`: when `Some`, skips env-var parsing and
    /// uses the provided value directly. Used by tests to avoid env-var
    /// pollution across parallel test threads.
    fn build(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
        stop_flag: Arc<AtomicBool>,
        topology_sink: Option<Box<dyn GovernorTopologySink>>,
    ) -> Self {
        let base_tick_ms = parse_tick_ms();
        let topology_cadence_ms = parse_topology_cadence_ms();
        // Pool paths use the SAME LatticeLib convention the novel-token submitter
        // writes to, so the read side (this reducer) and the write side agree.
        Self::build_inner(
            coord, handle, store, stop_flag, topology_sink, base_tick_ms, topology_cadence_ms,
            parse_pool_reduce_cadence_ms(), lattice_lib::default_pool_dir(),
            lattice_lib::default_table_artifact(),
        )
    }

    /// Construct with explicit cadences — avoids env-var pollution across
    /// parallel test threads. The `topology_cadence_ms` is passed directly
    /// rather than read from `MOOTX01_TOPOLOGY_CADENCE_SECONDS`.
    /// Use in integration tests; production code uses `new` or
    /// `new_with_topology_sink`.
    pub fn new_for_testing(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
        topology_cadence_ms: u64,
        topology_sink: Option<Box<dyn GovernorTopologySink>>,
    ) -> Self {
        let base_tick_ms = parse_tick_ms();
        // Production pool paths/cadence (resolved from env/platform default).
        Self::build_inner(
            coord, handle, store, Arc::new(AtomicBool::new(false)), topology_sink,
            base_tick_ms, topology_cadence_ms,
            parse_pool_reduce_cadence_ms(), lattice_lib::default_pool_dir(),
            lattice_lib::default_table_artifact(),
        )
    }

    /// Construct with explicit pool-reduce cadence + paths — for hermetic pool
    /// tests that must not read/write the platform default pool location nor set
    /// `LATTICE_POOL_DIR` (which would race across parallel test threads).
    /// `pool_reduce_cadence_ms = 0` fires the reducer on every tick.
    #[allow(clippy::too_many_arguments)]
    pub fn new_for_testing_with_pool(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
        topology_cadence_ms: u64,
        topology_sink: Option<Box<dyn GovernorTopologySink>>,
        pool_reduce_cadence_ms: u64,
        pool_dir: PathBuf,
        pool_table_artifact: PathBuf,
    ) -> Self {
        let base_tick_ms = parse_tick_ms();
        Self::build_inner(
            coord, handle, store, Arc::new(AtomicBool::new(false)), topology_sink,
            base_tick_ms, topology_cadence_ms,
            pool_reduce_cadence_ms, pool_dir, pool_table_artifact,
        )
    }

    /// Innermost constructor called by all build paths after cadences are resolved.
    #[allow(clippy::too_many_arguments)]
    fn build_inner(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
        stop_flag: Arc<AtomicBool>,
        topology_sink: Option<Box<dyn GovernorTopologySink>>,
        base_tick_ms: u64,
        topology_cadence_ms: u64,
        pool_reduce_cadence_ms: u64,
        pool_dir: PathBuf,
        pool_table_artifact: PathBuf,
    ) -> Self {
        // Manifest-backed policy stores (F6 / ADR-020): policy and daemon cycle
        // state persist to the estate manifest through the substrate's public KV
        // surface (DrawerStore::get_meta/set_meta), so a restart resumes the prior
        // run's state instead of re-discovering and re-proposing. The seam
        // (DreamingPolicyStore / MaintenancePolicyStore traits) is unchanged.
        let dreaming_policy_store =
            EstateManifestDreamingPolicyStore::new(Arc::clone(&store));
        let maintenance_policy_store =
            EstateManifestMaintenancePolicyStore::new(Arc::clone(&store));
        let dreaming_policy = dreaming_policy_store.load_policy().unwrap_or_default();
        let maintenance_policy = maintenance_policy_store.load_policy().unwrap_or_default();
        let mut dreaming = DreamingDaemon::new(dreaming_policy.clone());
        // Restore the learned trigger-mode bandit and the daemon's idempotency/
        // cycle memory if a prior run persisted them (NEURONKIT_SPEC § 3.4; F6).
        if let Some(bandit) = dreaming_policy_store.load_bandit() {
            dreaming.set_bandit(bandit);
        }
        if let Some(state) = dreaming_policy_store.load_daemon_state() {
            dreaming.restore_state(state);
        }
        let mut maintenance = MaintenanceDaemon::new(maintenance_policy);
        if let Some(state) = maintenance_policy_store.load_daemon_state() {
            maintenance.restore_state(state);
        }
        AutonomicGovernor {
            dreaming,
            maintenance,
            dreaming_policy_store: Box::new(dreaming_policy_store),
            maintenance_policy_store: Box::new(maintenance_policy_store),
            dreaming_policy,
            coord,
            handle,
            store,
            base_tick_ms,
            stop_flag,
            topology_sink,
            topology_cadence_ms,
            last_topology_snapshot_secs: None,
            last_topology_fingerprint: None,
            topology_fingerprint_loaded: false,
            // Graph-centrality producer cadence — fixed at the Swift default
            // (600 s). Not env-tunable today (no Swift env knob either); the
            // cadence field exists so tests can drive it via the per-tick gate
            // exactly like topology. First fire is immediate (None).
            graph_centrality_cadence_ms: DEFAULT_GRAPH_CENTRALITY_CADENCE_MS,
            last_graph_centrality_secs: None,
            // Preference producer cadence — fixed at the Swift default (600 s).
            // Not env-tunable today (no Swift env knob either); the cadence field
            // exists so tests can drive it via the per-tick gate exactly like
            // graph centrality. First fire is immediate (None).
            preference_cadence_ms: DEFAULT_PREFERENCE_CADENCE_MS,
            last_preference_secs: None,
            last_centrality_drawer_count: None,
            last_preference_drawer_count: None,
            last_topology_drawer_count: None,
            pool_reduce_cadence_ms,
            last_pool_reduce_secs: None,
            pool_dir,
            pool_table_artifact,
            // GC sweep: 30 s (2× DrainLease TTL). First fire is immediate (None).
            // Probes dreaming + signals lease files and reclaims orphaned cur rows
            // for stale streams (Mission #54 crash-recovery GC).
            gc_sweep_cadence_ms: 30_000,
            last_gc_sweep_secs: None,
            // No standing-signal scheduler until one is registered. The
            // production bootstrap (runtime.rs, resident HTTP path) calls
            // `register_default_standing_signals` after construction; tests
            // call `register_standing_signal`. Until then the tick benign-skips.
            scheduler: None,
        }
    }

    /// Stop the loop. Safe to call from any thread; idempotent.
    pub fn stop(&self) {
        self.stop_flag.store(true, Ordering::Relaxed);
    }

    /// Override the GC sweep cadence (milliseconds). Mirrors Swift `gcSweepIntervalMs`
    /// init parameter; `0` fires the sweep on every tick. Test-only knob — production
    /// uses the 30 s default. Resets the last-fired marker so the next tick fires
    /// immediately under the new cadence.
    pub fn set_gc_sweep_cadence_ms(&mut self, cadence_ms: u64) {
        self.gc_sweep_cadence_ms = cadence_ms;
        self.last_gc_sweep_secs = None;
    }

    /// Override the graph-centrality producer cadence (milliseconds). Mirrors
    /// the Swift `graphCentralityIntervalMs` init parameter; `0` fires the
    /// producer on every tick. Test-only knob — production uses the 10-minute
    /// default. Resets the last-fired marker so the next tick fires immediately
    /// under the new cadence.
    pub fn set_graph_centrality_cadence_ms(&mut self, cadence_ms: u64) {
        self.graph_centrality_cadence_ms = cadence_ms;
        self.last_graph_centrality_secs = None;
    }

    /// Override the preference producer cadence (milliseconds). Mirrors the Swift
    /// `preferenceIntervalMs` init parameter; `0` fires the producer on every
    /// tick. Test-only knob — production uses the 10-minute default. Resets the
    /// last-fired marker so the next tick fires immediately under the new cadence.
    pub fn set_preference_cadence_ms(&mut self, cadence_ms: u64) {
        self.preference_cadence_ms = cadence_ms;
        self.last_preference_secs = None;
    }

    // MARK: - Standing-signal registration seam

    /// Ensure a scheduler exists for this estate, lazily minting it on first
    /// call. Mirrors Swift `GeniusLocusKit.ensureScheduler(for:)`: one scheduler
    /// per estate, reused on subsequent registrations.
    ///
    /// The scheduler is wired to the live estate through a
    /// `CoordinatorDispatcher` over the SAME `Arc<Mutex<EstateCoordinator>>` the
    /// HTTP transport and the daemon pumps use, so scheduler-driven `propose` /
    /// `associate` emissions hit the real estate (single ownership, no duplicate
    /// state). The scheduler's `EstateHandleID` is the estate UUID string, which
    /// `CoordinatorDispatcher` validates on every dispatch.
    ///
    /// # Backend selection (T5, ADR-021 Decision 7)
    ///
    /// Mirrors Swift `SignalAPI.ensureScheduler` backend selection:
    ///   - SQLite estate → shared encrypted `queue.sqlite` beside the estate +
    ///     `DrainLease::new(estate_dir, "signals", owner)` for single-drainer
    ///     coordination across processes.
    ///   - InMemory (or no storage) estate → transient in-memory
    ///     PersistenceKitBackend + `None` lease (single-process only).
    ///
    /// On SQLite-open failure the governor degrades to the transient in-memory
    /// backend so the signals lane is always available, even if not crash-durable.
    /// The degradation is logged to stderr so the operator can diagnose the
    /// failure without crashing the resident.
    ///
    /// # Why this wiring lives in the governor, not the coordinator
    ///
    /// The production dispatcher `CoordinatorDispatcher` holds an
    /// `Arc<Mutex<EstateCoordinator>>`; a coordinator-owned scheduler would close
    /// a reference cycle. The governor already holds `coord`, `handle`, and
    /// `store` — the exact inputs needed — making it the natural owner.
    fn ensure_scheduler(&mut self) -> &mut SerialLaneScheduler<SchedulerCoordinatorDispatcher> {
        if self.scheduler.is_none() {
            let handle_id = Uuid::from_bytes(self.handle.estate_uuid).to_string();
            let dispatcher =
                SchedulerCoordinatorDispatcher::new(Arc::clone(&self.coord), self.handle);

            // The HLC node ID is derived from the estate UUID so HLC stamps are
            // deterministic per estate across process restarts — the same approach
            // Swift uses for the per-estate HLCGenerator in ensureScheduler.
            // Assemble the first four UUID bytes big-endian into a u32, then
            // bit-cast to i32. Byte-identical to the Swift mirror
            // `(UInt32(b0)<<24)|(UInt32(b1)<<16)|(UInt32(b2)<<8)|UInt32(b3)`.
            let uuid_bytes = self.handle.estate_uuid;
            let node_id = u32::from_be_bytes([
                uuid_bytes[0], uuid_bytes[1], uuid_bytes[2], uuid_bytes[3],
            ]) as i32;
            let hlc = HLCGenerator::new(node_id);

            // Backend selection: SQLite → shared queue.sqlite + DrainLease.
            // InMemory / no storage → transient in-memory backend + None lease.
            let (queue, drain_lease) = build_signals_queue(&self.store, &handle_id);

            self.scheduler = Some(SerialLaneScheduler::new(
                handle_id,
                dispatcher,
                queue,
                drain_lease,
                hlc,
            ));
        }
        self.scheduler
            .as_mut()
            .expect("scheduler just minted above")
    }

    /// Register one custom standing signal against this estate's scheduler.
    /// Lazily mints the scheduler on first call. Returns the `SignalID` the
    /// caller uses for `signal_status` / subscribe. Mirrors Swift
    /// `GeniusLocusKit.registerStandingSignal(_:in:now:)`.
    ///
    /// `now` is the deterministic clock the governor threads everywhere — never
    /// `SystemTime::now()` inside the engine. The scheduler stamps interval
    /// triggers' first-due window relative to this instant.
    pub fn register_standing_signal(
        &mut self,
        spec: SchedulerSignalSpec,
        now: SystemTime,
    ) -> SchedulerSignalID {
        let now_nanos = system_time_to_nanos(now);
        self.ensure_scheduler().register(spec, now_nanos)
    }

    /// Register the six v1 standing signals (architecture spec §11.2) against
    /// this estate's scheduler. Mirrors Swift
    /// `GeniusLocusKit.registerDefaultStandingSignals(in:vectorStore:now:)` and
    /// the resident-daemon bootstrap that calls it.
    ///
    /// Requires a `VectorStore` registered for this estate (the
    /// `VectorSimilaritySignal` queries real row embeddings on each fire). Reads
    /// it from the live coordinator via `EstateCoordinator::vector_store_for`,
    /// the same accessor the Swift resident uses
    /// (`kit.registeredVectorStore(for:)`). When no store is registered, returns
    /// `SchedulerError::SignalNotRegistered`-free `Ok(vec![])` is NOT used —
    /// instead the bootstrap caller (runtime.rs) checks store presence first and
    /// skips, exactly as the Swift resident does ("no VectorStore → governor
    /// benign-skips signalTick"). This method therefore returns an error only if
    /// no store is present, so the caller can log-and-skip without fabricating a
    /// throwaway store.
    ///
    /// Returns the registered `(name, SignalID)` pairs in registration order.
    /// `model_id` defaults to the Swift default `"minilm-v6"` at the call site.
    pub fn register_default_standing_signals(
        &mut self,
        model_id: impl Into<String>,
        now: SystemTime,
    ) -> Result<Vec<(String, SchedulerSignalID)>, String> {
        // Read the live VectorStore the same way the Swift resident does. No
        // fabricated fallback store — a missing store means "skip registration",
        // surfaced to the caller as an error string to log.
        let vector_store = {
            let coord = self
                .coord
                .lock()
                .map_err(|e| format!("coordinator lock poisoned: {e}"))?;
            coord.vector_store_for(&self.handle)
        };
        let Some(vector_store) = vector_store else {
            return Err(format!(
                "no VectorStore registered for estate {} — standing signals not registered",
                Uuid::from_bytes(self.handle.estate_uuid)
            ));
        };

        let model_id = model_id.into();
        let specs = default_standing_signal_specs(vector_store, model_id);
        let now_nanos = system_time_to_nanos(now);
        let scheduler = self.ensure_scheduler();
        let mut registered = Vec::with_capacity(specs.len());
        for spec in specs {
            let name = spec.name.clone();
            let id = scheduler.register(spec, now_nanos);
            registered.push((name, id));
        }
        Ok(registered)
    }

    /// Snapshot of every registered signal's status. Mirrors Swift
    /// `GeniusLocusKit.signalStatus(in:)`. Returns an empty Vec when no
    /// scheduler has been minted (no signals registered) — the benign
    /// no-scheduler state, not an error.
    pub fn signal_status(&self) -> Vec<SchedulerSignalReport> {
        self.scheduler
            .as_ref()
            .map(|s| s.report())
            .unwrap_or_default()
    }

    /// Number of standing signals registered against this estate's scheduler.
    /// Zero when no scheduler has been minted. Diagnostic accessor mirroring the
    /// Swift `openSchedulerCount` shape at the per-estate grain (the Rust
    /// governor owns exactly one estate's scheduler).
    pub fn open_signal_count(&self) -> usize {
        self.scheduler.as_ref().map(|s| s.open_signal_count()).unwrap_or(0)
    }

    /// Fire an event/condition-trigger signal explicitly. Mirrors Swift
    /// `GeniusLocusKit.signalRequestFire(_:in:now:)`. Errors when no scheduler
    /// is registered or the signal is unknown.
    pub fn signal_request_fire(
        &mut self,
        id: &SchedulerSignalID,
        now: SystemTime,
    ) -> Result<(), SchedulerError> {
        let now_nanos = system_time_to_nanos(now);
        match self.scheduler.as_mut() {
            Some(scheduler) => scheduler.request_fire(id, now_nanos),
            None => Err(SchedulerError::SignalNotRegistered(id.clone())),
        }
    }

    /// Run the governor loop until `stop()` is called.
    ///
    /// Each iteration:
    ///   1. Reads the clock once (the ONLY `SystemTime::now()` call in the path).
    ///   2. Calls `tick(now)` — dreaming + maintenance, errors logged.
    ///   3. Sleeps the base tick.
    ///
    /// Logs start/stop to stderr, consistent with the Swift governor.
    pub fn run_loop(&mut self) {
        eprintln!("AutonomicGovernor started (base tick {}ms)", self.base_tick_ms);
        while !self.stop_flag.load(Ordering::Relaxed) {
            // Read the clock once per iteration and inject into all daemons.
            // This is the ONLY place SystemTime::now() is called in the governor
            // path — all daemons in a single tick share the same `now`.
            let now = SystemTime::now();
            self.tick(now);
            std::thread::sleep(Duration::from_millis(self.base_tick_ms));
        }
        eprintln!("AutonomicGovernor stopped");
    }

    /// One governor iteration with an injected `now: SystemTime`. Each daemon
    /// self-gates on its own interval; errors are logged and the loop
    /// continues. Exposed for deterministic tests (no wall-clock sleeps).
    ///
    /// Accepting `SystemTime` rather than `f64` matches the Swift port's
    /// `pump(now: Date)` contract and is the prerequisite for the Rust
    /// resident daemon to host-pump the Brain (ARIA_MCP_SPEC_v0.2 §17.1).
    /// Return the dreaming daemon's current trigger mode. Exposed for deterministic
    /// tests that need to observe the bandit-selected mode after a cycle and
    /// conditionally assert on dreaming behavior. (NK-2 planned hardening: pump_on_event
    /// is now wired — tests that assumed only pump() fires need to account for the mode.)
    /// Mirrors Swift `AutonomicGovernor.dreamingTriggerMode()`.
    pub fn dreaming_trigger_mode(&self) -> crate::solver_bandit::DreamingTriggerMode {
        self.dreaming.trigger_mode
    }

    ///
    /// Per-tick flow:
    ///   1. Lock coordinator; snapshot dreaming + maintenance readers.
    ///   2. Release lock — coordinator is available for HTTP tool-calls.
    ///   3. Construct sinks over the live store.
    ///   4. Run dreaming pump, then maintenance pump, with error isolation.
    pub fn tick(&mut self, now: SystemTime) -> GovernorReport {
        let now_epoch_secs = now
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_secs_f64();
        let now_i64 = now_epoch_secs as i64;
        let now_str = epoch_secs_to_iso8601(now_i64);
        // Nanosecond form for the standing-signal scheduler (integer time, the
        // conformance scale shared with the Swift port's parity vectors). Daemon
        // pumps below use epoch-seconds (`now_i64` / `now_epoch_secs`); the
        // scheduler uses nanos.
        let now_nanos = system_time_to_nanos(now);

        // ── Snapshot readers (coordinator lock held briefly) ───────────────
        //
        // The dreaming reward window is one full interval back from `now`.
        // This mirrors the Swift EstateDreamingReader's lookback: the daemon
        // fires every tick_interval_ms, so "recent" traces are those within
        // the last interval.
        let interval_secs = (self.dreaming_policy.tick_interval_ms as f64 / 1000.0) as i64;
        let since_i64 = (now_i64 - interval_secs).max(0);
        let since_str = epoch_secs_to_iso8601(since_i64);

        // The coordinator lock is held for the entire pump cycle — both
        // EstateDreamingReader and EstateMaintenanceReader borrow coordinator
        // by reference and cannot outlive the MutexGuard. The original intent
        // was to release the lock before pumping, but the readers are demand-read
        // adapters (they borrow the coordinator, not an owned snapshot), so the
        // lock must be held until the readers are no longer in scope.
        let (dreaming_fired, maintenance_fired) = {
            let coord = self.coord.lock().expect("AutonomicGovernor: coordinator lock poisoned");

            // ── Dreaming — REM dispatch table (ADR-021 Phase 6, T11) ──────────
            // Iterate the shared REM dispatch table so all four cadences are driven
            // uniformly. Each entry's due-check self-gates; the governor builds the
            // appropriate reader snapshot only when the cycle is actually due.
            //
            // ALPHA gate: timer-due AND queue non-empty (ADR-021 Phase 4 §12.2).
            //   Building the EstateDreamingReader snapshot (recall traces, tunnels,
            //   drain) is expensive — skip it on ticks where the interval has not
            //   elapsed or the queue is empty. This is the Phase 4 goal: idle ticks
            //   cost nothing.
            // THETA gate: cadence-gated (24 h). Builds its own reader with the 24 h
            //   window (since = now − 86400 s). Run after ALPHA so a fresh THETA
            //   sees the updated co-recall counts ALPHA may have bumped this tick.
            // BETA / OMEGA: cadence-gated seams. Inert run-fns; no reader needed
            //   (the seam advances last-run and returns None). Skip reader build.
            let mut dreaming_fired = false;

            // REM-ALPHA: read pending count once; drives both the timer path and
            // the event path. None = queue not mounted (skip); 0 = empty (skip).
            let alpha_pending = coord.dreaming_queue_pending_count_for_gate(&self.handle);

            // Snapshot trigger mode BEFORE calling pump(). The bandit re-selects
            // trigger_mode at the end of every cycle (run_cycle step 8), so by the
            // time the event gate runs, self.dreaming.trigger_mode reflects the
            // POST-pump selection. The event gate must use the PRE-pump mode — the
            // mode that was active when this tick started — so that a .timer estate
            // does not accidentally fire pump_on_event after the bandit transitions
            // it to .event or .hybrid mid-tick. (Lane C NK-2 regression; ag8 witness.)
            let trigger_mode_at_tick_start = self.dreaming.trigger_mode;

            // Timer gate: drives the standard ALPHA cycle for .timer and .hybrid modes.
            if self.dreaming.timer_due(now_epoch_secs) {
                if alpha_pending.map_or(false, |n| n > 0) {
                    match EstateDreamingReader::new(&coord, &self.handle, &since_str, &now_str, now_epoch_secs) {
                        Err(e) => {
                            eprintln!("AutonomicGovernor: REM-ALPHA reader error: {e:?}");
                        }
                        Ok(reader) => {
                            let mut sink = EstateDreamingSink::new(&coord, self.handle.clone(), now_i64);
                            match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                                self.dreaming.pump(now_epoch_secs, &reader, &RecallTraceRewardSource, &mut sink)
                            })) {
                                Ok(result) => {
                                    if result.is_some() {
                                        dreaming_fired = true;
                                    }
                                    if let Some(ref cycle_report) = result {
                                        let estate_str = Uuid::from_bytes(self.handle.estate_uuid).to_string();
                                        for proposal in &cycle_report.proposals_emitted {
                                            report!(StatSample::event(
                                                EventKind::Think,
                                                4i64,
                                                proposal.target.clone(),
                                                estate_str.clone(),
                                                now_epoch_secs,
                                            ));
                                        }
                                    }
                                    if !sink.write_errors.is_empty() {
                                        eprintln!("AutonomicGovernor: REM-ALPHA sink errors: {:?}", sink.write_errors);
                                    }
                                }
                                Err(e) => {
                                    eprintln!("AutonomicGovernor: REM-ALPHA pump panic: {:?}", e);
                                }
                            }
                        }
                    }
                }
                // else: None (not mounted) or Some(0) (empty) — no-op; idle ticks cost nothing.
            }

            // Event gate: drives pump_on_event for .event and .hybrid trigger modes
            // on every tick, independent of the timer cadence. pump_on_event also
            // self-gates on .timer (returns None immediately), but we guard on the
            // PRE-pump snapshot here to prevent a mode-transition race: if the timer
            // gate ran pump() and the bandit re-selected a non-timer mode, using
            // self.dreaming.trigger_mode (post-pump) would incorrectly fire the event
            // path on a tick that started as .timer mode. The snapshot ensures the
            // event path only activates when the mode was already .event or .hybrid
            // at tick-start, matching the Swift AutonomicGovernor pumpOnEvent contract.
            // (NK-2/NK-6 planned hardening; Lane C regression fix)
            if trigger_mode_at_tick_start != crate::solver_bandit::DreamingTriggerMode::Timer
                && alpha_pending.map_or(false, |n| n > 0)
            {
                if let Some(observation_count) = alpha_pending {
                    match EstateDreamingReader::new(&coord, &self.handle, &since_str, &now_str, now_epoch_secs) {
                        Err(e) => {
                            eprintln!("AutonomicGovernor: REM-ALPHA event reader error: {e:?}");
                        }
                        Ok(reader) => {
                            let mut sink = EstateDreamingSink::new(&coord, self.handle.clone(), now_i64);
                            match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                                self.dreaming.pump_on_event(observation_count as i64, now_epoch_secs, &reader, &RecallTraceRewardSource, &mut sink)
                            })) {
                                Ok(result) => {
                                    if result.is_some() {
                                        dreaming_fired = true;
                                    }
                                    if !sink.write_errors.is_empty() {
                                        eprintln!("AutonomicGovernor: REM-ALPHA event sink errors: {:?}", sink.write_errors);
                                    }
                                }
                                Err(e) => {
                                    eprintln!("AutonomicGovernor: REM-ALPHA pump_on_event panic: {:?}", e);
                                }
                            }
                        }
                    }
                }
            }

            // REM-THETA: daily consolidation — cadence-gated, 24 h window.
            if self.dreaming.theta_due(now_epoch_secs) {
                // Build a fresh reader with the 24 h window (distinct from the 30 s
                // ALPHA window). The `since_str` for THETA is now − 86400 s.
                let theta_since_i64 = (now_i64 - DreamingDaemon::THETA_CADENCE_SECS as i64).max(0);
                let theta_since_str = epoch_secs_to_iso8601(theta_since_i64);
                match EstateDreamingReader::new(&coord, &self.handle, &theta_since_str, &now_str, now_epoch_secs) {
                    Err(e) => {
                        eprintln!("AutonomicGovernor: REM-THETA reader error: {e:?}");
                    }
                    Ok(reader) => {
                        let mut sink = EstateDreamingSink::new(&coord, self.handle.clone(), now_i64);
                        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            self.dreaming.run_theta_cycle(now_epoch_secs, &reader, &mut sink)
                        })) {
                            Ok(result) => {
                                if result.is_some() {
                                    dreaming_fired = true;
                                }
                                if !sink.write_errors.is_empty() {
                                    eprintln!("AutonomicGovernor: REM-THETA sink errors: {:?}", sink.write_errors);
                                }
                            }
                            Err(e) => {
                                eprintln!("AutonomicGovernor: REM-THETA cycle panic: {:?}", e);
                            }
                        }
                    }
                }
            }

            // REM-BETA: weekly prune/GC — T12 seam (inert; no reader needed).
            if self.dreaming.beta_due(now_epoch_secs) {
                self.dreaming.run_beta_cycle(now_epoch_secs);
            }

            // REM-OMEGA: biweekly retire — T13 / ADR-021 Phase 7.
            // Reader built with the full OMEGA window (14 days) so dreamed-active
            // tunnels and recall-trace traces for reinforcement-checking are
            // snapshotted at the correct window boundary. Pattern mirrors THETA.
            if self.dreaming.omega_due(now_epoch_secs) {
                let omega_since_i64 =
                    (now_i64 - DreamingDaemon::OMEGA_CADENCE_SECS as i64).max(0);
                let omega_since_str = epoch_secs_to_iso8601(omega_since_i64);
                match EstateDreamingReader::new(
                    &coord,
                    &self.handle,
                    &omega_since_str,
                    &now_str,
                    now_epoch_secs,
                ) {
                    Err(e) => {
                        eprintln!(
                            "AutonomicGovernor: REM-OMEGA reader error: {e:?}"
                        );
                    }
                    Ok(reader) => {
                        let mut sink =
                            EstateDreamingSink::new(&coord, self.handle.clone(), now_i64);
                        match std::panic::catch_unwind(
                            std::panic::AssertUnwindSafe(|| {
                                self.dreaming.run_omega_cycle(
                                    now_epoch_secs,
                                    &reader,
                                    &mut sink,
                                )
                            }),
                        ) {
                            Ok(result) => {
                                if result.is_some() {
                                    dreaming_fired = true;
                                }
                                if !sink.write_errors.is_empty() {
                                    eprintln!(
                                        "AutonomicGovernor: REM-OMEGA sink errors: {:?}",
                                        sink.write_errors
                                    );
                                }
                            }
                            Err(e) => {
                                eprintln!(
                                    "AutonomicGovernor: REM-OMEGA cycle panic: {:?}",
                                    e
                                );
                            }
                        }
                    }
                }
            }

            // ── Maintenance ────────────────────────────────────────────────────
            // EstateMaintenanceReader::new returns Self directly (not Result) —
            // snapshot construction is infallible; all reads happen in scan().
            // Built ONLY when its interval is due (same per-tick-snapshot waste as
            // dreaming; maintenance fires every 5 min while the governor ticks
            // sub-second).
            let maintenance_fired;
            if !self.maintenance.due(now_epoch_secs) {
                maintenance_fired = false;
            } else {
                let reader = EstateMaintenanceReader::new(&coord, &self.handle, now_i64);
                let mut sink =
                    EstateMaintenanceSink::new(Arc::clone(&self.store), now_i64);
                match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    self.maintenance.pump(now_epoch_secs, &reader, &mut sink)
                })) {
                    Ok(result) => {
                        maintenance_fired = result.is_some();
                        if !sink.write_errors.is_empty() {
                            eprintln!(
                                "AutonomicGovernor: maintenance sink write errors: {:?}",
                                sink.write_errors
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("AutonomicGovernor: maintenance pump panic: {:?}", e);
                        maintenance_fired = false;
                    }
                }
            }

            // The encode queue is drained by the Corpus's OWN background worker
            // now (CorpusKit owns the ingest pipeline — corpus_ingest_queue.rs
            // spawns a foreground poll worker at mount_ingest_queue). The governor
            // no longer pumps the encode drain: it is autonomous and runs in
            // near-realtime independent of this tick. This also restores parity
            // with the Swift governor, whose tick reports only dreaming +
            // maintenance (the Swift Corpus drain worker likewise runs on its own).
            //
            // Coordinator lock released here (end of block).
            (dreaming_fired, maintenance_fired)
        };

        // ── Persist daemon cycle state (F6 / ADR-020) ──────────────────────
        // After the coordinator lock is released, persist each daemon's
        // idempotency/cycle memory IF any dreaming cycle ran this tick, so a
        // restart resumes from here. "Ran" includes ALPHA proposals emitted
        // (dreaming_fired=true), THETA/BETA/OMEGA which mutate last-run timestamps
        // even when returning None (no proposals). The manifest-backed store writes
        // through the DrawerStore's own storage mutex (independent of the coord
        // lock); the default in-memory store no-ops.
        //
        // `dreaming_any_ran` is true when ANY table entry ran this tick. This is
        // broader than `dreaming_fired` (ALPHA-only) because THETA/BETA/OMEGA
        // advance their last-run timestamps regardless of whether proposals were
        // emitted — those timestamps must be persisted immediately so cadence gates
        // are correct after a restart.
        let dreaming_any_ran = dreaming_fired
            || self.dreaming.last_run_epoch_secs("theta") == Some(now_epoch_secs)
            || self.dreaming.last_run_epoch_secs("beta") == Some(now_epoch_secs)
            || self.dreaming.last_run_epoch_secs("omega") == Some(now_epoch_secs);
        if dreaming_any_ran {
            // Persist the re-selected bandit posterior + cycle state (the cycle
            // observed reward and re-selected the trigger mode; NEURONKIT_SPEC § 3.4).
            self.dreaming_policy_store
                .save_bandit(self.dreaming.current_bandit());
            self.dreaming_policy_store
                .save_daemon_state(self.dreaming.daemon_state());
        }
        if maintenance_fired {
            self.maintenance_policy_store
                .save_daemon_state(self.maintenance.daemon_state());
        }

        // ── Standing signals ───────────────────────────────────────────────
        //
        // Advance this estate's standing-signal scheduler at the injected `now`.
        // Mirrors the Swift governor's `kit.signalTick(in:handle:now:)` call,
        // which runs after dreaming + maintenance each iteration.
        //
        // Benign no-scheduler skip: when no signals have been registered the
        // scheduler is `None` and `signals_ticked` is false — exactly the Swift
        // governor's behaviour when `signalTick` throws `schedulerNotStarted`
        // (treated as a benign skip, never logged-per-tick, never an error). The
        // resident bootstrap (runtime.rs) registers the default signals once at
        // startup, so on the live HTTP path the scheduler is present and ticks
        // real propose/associate emissions through the CoordinatorDispatcher.
        //
        // Determinism: the scheduler engine takes `now` (as nanoseconds) — never
        // reads its own clock — so the same input sequence drains the same
        // emission order regardless of wall-clock (the conformance contract).
        // Feed the scheduler nanoseconds derived from the SAME `now` the
        // registration seam uses (`system_time_to_nanos`), so the registration
        // stamp and the tick stamp share one time scale exactly — no sub-second
        // drift between `register`'s `last_run_at` and `tick`'s due comparison.
        let signals_ticked = match self.scheduler.as_mut() {
            Some(scheduler) => {
                scheduler.tick(now_nanos);
                true
            }
            None => false,
        };

        // ── Topology snapshot ──────────────────────────────────────────────
        //
        // Cadence gating mirrors Swift: fire when elapsed >= cadence_ms or never
        // fired (last_topology_snapshot_secs == None). The `topology_snapshot_fired`
        // flag reflects the cadence gate; the sink write only happens when
        // `topology_sink` is Some. This is intentional — it lets tests drive cadence
        // logic without wiring a real SQLite store or telemetry backend.
        let topology_elapsed_ms = self.last_topology_snapshot_secs.map(|last| {
            ((now_epoch_secs - last) * 1000.0) as u64
        });
        let topology_snapshot_fired = match topology_elapsed_ms {
            None => true,                                         // never fired
            Some(ms) => ms >= self.topology_cadence_ms,          // cadence elapsed
        };
        if topology_snapshot_fired {
            self.last_topology_snapshot_secs = Some(now_epoch_secs);
            if let Some(ref sink) = self.topology_sink {
                // Monitoring gate: live sink flag read at each due cadence,
                // BEFORE any estate read or compute — "off is free". The trait
                // method returns true on any read failure (fail-open) so a
                // transient error never silently freezes topology.
                if sink.is_monitoring_enabled() {
                    // Watermark gate: skip the full allDrawers+allTunnels+allKGFacts
                    // load when drawer count is unchanged. Mirrors Swift's outer
                    // hasAuditGrown check that prevents the full-estate load.
                    let topo_count = self.store.all_drawers()
                        .map(|d| d.iter().filter(|x| x.tombstoned_at.is_none()).count())
                        .unwrap_or(0);
                    if self.last_topology_fingerprint.is_some()
                        && self.last_topology_drawer_count == Some(topo_count)
                    {
                        // Estate unchanged and we have a prior fingerprint — skip.
                    } else {
                    self.last_topology_drawer_count = Some(topo_count);
                    let estate_id = Uuid::from_bytes(self.handle.estate_uuid).to_string();
                    // F5: seed the comparison fingerprint, loading the persisted
                    // one once so the first post-restart duty skips the recompute
                    // when the estate is unchanged. Disjoint-field borrow: `sink`
                    // borrows `self.topology_sink` while these mutate other fields.
                    if !self.topology_fingerprint_loaded {
                        self.topology_fingerprint_loaded = true;
                        if self.last_topology_fingerprint.is_none() {
                            self.last_topology_fingerprint =
                                sink.load_topology_fingerprint(&estate_id);
                        }
                    }
                    self.last_topology_fingerprint = topology_snapshot_duty(
                        &estate_id,
                        now_epoch_secs,
                        sink.as_ref(),
                        self.store.as_ref(),
                        self.last_topology_fingerprint.take(),
                    );
                    } // end else (estate changed)
                }
            }
        }

        // ── Graph-centrality producer ──────────────────────────────────────
        //
        // The PRODUCER for the recall `graph` score column. Cadence gating
        // mirrors Swift: fire when elapsed >= cadence_ms or never fired
        // (last_graph_centrality_secs == None → immediate first fire). On fire,
        // the duty reads the estate structure graph (drawers + tunnels +
        // kg_facts) through the SAME coordinator the HTTP transport uses,
        // computes per-drawer eigenvalue centrality via the keystones oracle,
        // and registers the resulting `GraphCache` on the coordinator. This is
        // what takes the `unionBest`/`matrixAware` recall `graph` column from
        // dark to live (the consumption surface — `register_graph_cache` and the
        // `graph` scoring column — already shipped; nothing was computing scores
        // to register).
        //
        // Determinism: no `SystemTime::now()` here — `now_epoch_secs` is the
        // injected tick clock. The duty owns no math (eigenvalue centrality is
        // the conformance-gated SubstrateML primitive surfaced by
        // `neuron_kit::keystones`); it only shapes the graph and caches the
        // scores. Errors are logged and the loop continues — the producer must
        // never crash the daemon. An empty estate registers an empty cache
        // (every score 0.0 — correct, identical to "no cache registered").
        let graph_centrality_elapsed_ms = self
            .last_graph_centrality_secs
            .map(|last| ((now_epoch_secs - last) * 1000.0) as u64);
        let graph_centrality_fired = match graph_centrality_elapsed_ms {
            None => true,                                        // never fired
            Some(ms) => ms >= self.graph_centrality_cadence_ms, // cadence elapsed
        };
        if graph_centrality_fired {
            self.last_graph_centrality_secs = Some(now_epoch_secs);
            // Watermark gate: skip the full eigenvalue recompute when the active
            // drawer count hasn't changed since the last computation. Mirrors
            // Swift's hasAuditGrown + centralityCount estate.meta watermark.
            let current_count = self.store.all_drawers()
                .map(|d| d.iter().filter(|x| x.tombstoned_at.is_none()).count())
                .unwrap_or(0);
            if self.last_centrality_drawer_count == Some(current_count) {
                // Estate unchanged — skip recompute. Scores from last run are
                // still registered on the coordinator.
            } else {
                let estate_uuid_str = Uuid::from_bytes(self.handle.estate_uuid).to_string();
                if let Err(e) = graph_centrality_duty(&self.coord, &self.handle, &estate_uuid_str, now_epoch_secs) {
                    eprintln!(
                        "AutonomicGovernor: graph-centrality producer error for estate {:?}: {e}",
                        Uuid::from_bytes(self.handle.estate_uuid)
                    );
                } else {
                    self.last_centrality_drawer_count = Some(current_count);
                }
            }
        }

        // ── Preference producer ────────────────────────────────────────────
        //
        // The PRODUCER for the recall `preference` score column — the sibling of
        // the graph-centrality producer. Cadence gating mirrors Swift: fire when
        // elapsed >= cadence_ms or never fired (last_preference_secs == None →
        // immediate first fire). On fire, the duty reads the estate's recall-trace
        // reward history through the SAME coordinator the HTTP transport uses,
        // fits per-drawer Bradley-Terry preference strengths via the
        // `learned_preference` oracle, and registers the resulting
        // `PreferenceStore` on the coordinator. This is what takes the
        // `unionBest`/`matrixAware` recall `preference` column from dark to live
        // (the consumption surface — `register_preference_store` and the
        // `preference` scoring column — already shipped; nothing was fitting
        // strengths to register).
        //
        // Outcome source (the implicit relevance signal, C-15): each recall trace
        // records a surfaced drawer (`target`) and whether the caller picked it
        // (`used`). Surfaced-and-used is one endorsement (a win vs the neutral
        // baseline in the fitter's anchor reduction); surfaced-and-passed-over is
        // one dismissal. "What users picked vs passed over", aggregated per drawer.
        //
        // Determinism: no `SystemTime::now()` here — `now_i64` is the injected
        // tick clock. The duty owns no fitting math (Bradley-Terry is the
        // conformance-gated SubstrateML primitive surfaced by
        // `neuron_kit::learned_preference`); it only shapes the outcomes and
        // caches the strengths. Errors are logged and the loop continues — the
        // producer must never crash the daemon. An estate with no traces registers
        // an empty store (every score 0.0 — correct, identical to "no store
        // registered").
        let preference_elapsed_ms = self
            .last_preference_secs
            .map(|last| ((now_epoch_secs - last) * 1000.0) as u64);
        let preference_fired = match preference_elapsed_ms {
            None => true,                                  // never fired
            Some(ms) => ms >= self.preference_cadence_ms,  // cadence elapsed
        };
        if preference_fired {
            self.last_preference_secs = Some(now_epoch_secs);
            // Watermark gate: skip full Bradley-Terry refit when drawer count
            // unchanged. Mirrors Swift's hasAuditGrown + preferenceCount watermark.
            let pref_count = self.store.all_drawers()
                .map(|d| d.iter().filter(|x| x.tombstoned_at.is_none()).count())
                .unwrap_or(0);
            if self.last_preference_drawer_count == Some(pref_count) {
                // Unchanged — scores from last fit still registered.
            } else {
                if let Err(e) = preference_duty(&self.coord, &self.handle, now_i64) {
                    eprintln!(
                        "AutonomicGovernor: preference producer error for estate {:?}: {e}",
                        Uuid::from_bytes(self.handle.estate_uuid)
                    );
                } else {
                    self.last_preference_drawer_count = Some(pref_count);
                }
            }
        }

        // ── Pool reducer (novel-token merge-back) + LIVE TAGGER SWAP ───────
        //
        // The in-session learning loop. NEAR-REALTIME: considered every tick
        // (pool_reduce_cadence_ms default 0), fold accumulated novel-token
        // submissions from the pool directory into the writable WordClassTable
        // artifact, then atomically swap the running tagger onto the merged
        // table. `lattice::pool_reduce` is cheap on the common path — an
        // absent/empty pool dir is a single readdir that returns `is_noop()`
        // (idempotent contract), so an idle tick costs nothing. When the
        // novel-token pool crosses the submission threshold a file lands here
        // and the next tick merges it; the reduce latency floor is the base
        // tick (`MOOTX01_BRAIN_TICK_MS`).
        //
        // LIVE SWAP at the safe point: after a NON-NOOP reduce writes the merged
        // writable artifact, `swap_global_table_from_precedence` re-resolves it
        // (writable-first) and atomically publishes a new `Arc` into the live
        // process-global holder. The running tagger / FDC encode path adopts the
        // merged tokens on its very next read — in-session, no process restart
        // (cookbook §1.3/§2.2). The swap is the LAST step after the reduce
        // returns; no reader holds a long-lived snapshot, so it is a safe point.
        // A noop reduce performs no swap (the table is unchanged).
        //
        // Idempotent + no-op-safe. Errors are logged and the loop continues — a
        // reducer failure must never crash the daemon. The `now` date string is
        // the ISO8601 calendar date (the reducer's `snapshot_date` field).
        let pool_elapsed_ms = self.last_pool_reduce_secs.map(|last| {
            ((now_epoch_secs - last) * 1000.0) as u64
        });
        let pool_cadence_elapsed = match pool_elapsed_ms {
            None => true,                                        // never fired
            Some(ms) => ms >= self.pool_reduce_cadence_ms,       // cadence elapsed
        };
        // pool_reduce_fired reflects actual firing (false if deferred by back-pressure).
        // Mirrors Swift where poolReduceFired starts false and is set true only when
        // the reduce proceeds.
        let mut pool_reduce_fired = false;
        let mut table_swapped = false;
        if pool_cadence_elapsed {
            // Bounded near-realtime drain: reduce at most POOL_REDUCE_FILE_CAP of
            // the OLDEST submissions this tick. A backlog larger than the cap
            // drains over successive ticks. The reduce runs synchronously on the
            // tick, so an unbounded pass would stall it — but SKIPPING the reduce
            // when over cap (the prior "planned hardening" behaviour) deadlocked:
            // over cap, the very reduce that shrinks the pool never ran, so the
            // pool grew without bound. The batch cap keeps each tick bounded AND
            // always makes progress. Parity: mirrors AutonomicGovernor.swift.
            self.last_pool_reduce_secs = Some(now_epoch_secs);
            pool_reduce_fired = true;
            // The reducer's `now` is the calendar date (YYYY-MM-DD) for the
            // artifact's snapshot_date. Slice the date prefix off the full
            // ISO8601 instant (`YYYY-MM-DDTHH:MM:SSZ`).
            let now_date = &now_str[..now_str.len().min(10)];
            match lattice_lib::pool_reduce(
                &self.pool_dir,
                &self.pool_table_artifact,
                now_date,
                POOL_REDUCE_FILE_CAP,
            ) {
                Ok(result) => {
                    if !result.is_noop() {
                        eprintln!(
                            "AutonomicGovernor: pool reduce merged {} nouns + {} verbs (consumed {}, quarantined {})",
                            result.nouns_added, result.verbs_added, result.consumed, result.quarantined
                        );
                        // Live atomic swap at the safe point: adopt the
                        // just-merged table in-session. Only on a non-noop reduce
                        // — a noop wrote nothing new. Re-resolves writable-first
                        // from the same artifact path the reducer wrote.
                        if let Some(v) = lattice_lib::swap_global_table_from_precedence(
                            &self.pool_table_artifact,
                        ) {
                            table_swapped = true;
                            eprintln!("AutonomicGovernor: live word-class table swap → version {v}");
                        }
                    }
                }
                Err(e) => {
                    // A missing/unwritable table artifact is the expected state
                    // until a writable table is provisioned; log, never crash.
                    eprintln!("AutonomicGovernor: pool reduce skipped: {e:?}");
                }
            }
        }

        // GC sweep (Mission #54): reclaim orphaned in-flight ("cur") queue rows for
        // streams whose drainer has died without the daemon restarting. Probes the
        // dreaming DrainLease; if it is stale (no live holder), reclaims dreaming cur
        // rows. Cadence: 30 s (2× DrainLease TTL = 15 s). First tick fires immediately
        // (last_gc_sweep_secs None) to catch jobs left by a previous crashed session.
        //
        // The "encode" stream is NOT swept here — the encode drainer is a background
        // thread in the same process (CorpusKit's run_ingest_drain_loop). When it dies,
        // the process restarts entirely, triggering the on-mount reclaim there.
        // The "dreaming" stream is swept here: `mootx01 dream` is a separate process.
        //
        // This is the Rust twin of Swift `AutonomicGovernor.sweepStaleInFlightJobs`
        // (NeuronKit calls `kit.sweepStaleInFlightJobs` in Swift; here we call the
        // coordinator directly since NeuronKit owns the coordinator reference).
        let gc_elapsed_ms = self.last_gc_sweep_secs.map(|last| {
            ((now_epoch_secs - last) * 1000.0) as u64
        });
        let gc_sweep_fired = match gc_elapsed_ms {
            None => true,
            Some(ms) => ms >= self.gc_sweep_cadence_ms,
        };
        if gc_sweep_fired {
            self.last_gc_sweep_secs = Some(now_epoch_secs);
            if let Ok(coord) = self.coord.lock() {
                coord.sweep_stale_in_flight_jobs(&self.handle, now_epoch_secs);
            }
        }

        GovernorReport {
            dreaming_fired,
            maintenance_fired,
            signals_ticked,
            graph_centrality_fired,
            preference_fired,
            topology_snapshot_fired,
            pool_reduce_fired,
            table_swapped,
            table_version: lattice_lib::table_version(),
            gc_sweep_fired,
        }
    }
}

/// Convert a `SystemTime` to nanoseconds since the Unix epoch (`i64`).
///
/// The standing-signal scheduler engine uses nanosecond integer time so its
/// conformance vectors are integer-comparable across the Swift and Rust ports
/// (the Swift `StandingSignalScheduler` takes `Date`; the parity gate scales by
/// 1e9). The governor's own daemon path uses epoch-SECONDS (`now_i64`); the
/// scheduler tick is fed `now_i64 * 1e9` inline. This helper exists for the
/// registration-seam methods, which receive `SystemTime` directly. Pre-epoch
/// instants clamp to 0 (the scheduler never sees negative time in practice).
fn system_time_to_nanos(t: SystemTime) -> i64 {
    t.duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}

// ── Graph-centrality producer duty ──────────────────────────────────────────────

/// Compute per-drawer eigenvalue centrality for the whole estate and register it
/// as a `GraphCache`, taking the `unionBest` / `matrixAware` recall `graph` score
/// column from dark to live.
///
/// The Rust mirror of Swift `AutonomicGovernor.graphCentralityScan`. It reads the
/// estate structure graph (drawers + tunnels + kg_facts) through the coordinator,
/// shapes it into the (node_ids, edges) the `neuron_kit::keystones` oracle
/// consumes (identical shape to the Swift port), runs that oracle over ALL drawers
/// (`top_k = node count`), and installs the per-drawer scores on the coordinator.
///
/// Math ownership (I-17): owns NO math. Eigenvalue centrality is the
/// conformance-gated SubstrateML primitive surfaced by `neuron_kit::keystones`;
/// this duty only shapes the graph and caches the scores. A faithful cadence
/// wrapper of a direct `keystones` call on the same graph.
///
/// Determinism: no clock read — the registration is a pure function of the estate
/// state. The only side effect is the cache registration (idempotent
/// re-registration replaces the prior snapshot). An empty estate registers an
/// empty cache (every `graph_score` 0.0 — correct, C-16).
///
/// Locking: takes the coordinator `Mutex` briefly — three reads + one register.
/// Returns the lock-poison or read error as a string for the caller to log; the
/// governor loop continues on error (never crashes the daemon).
fn graph_centrality_duty(
    coord: &Arc<Mutex<EstateCoordinator>>,
    handle: &EstateHandle,
    estate_id: &str,
    now_epoch_secs: f64,
) -> Result<(), String> {
    use crate::graph_centrality::{
        build_centrality_graph, compute_centrality_scores, GraphCentralityCache,
    };

    let mut coord = coord
        .lock()
        .map_err(|e| format!("coordinator lock poisoned: {e}"))?;

    // Reads through the coordinator verb surface (same active-only KGFact
    // filter the Swift `recallKGFacts` applies, so both ports score the same
    // fact set).
    //
    // Hint drawers (AI_Charter_Hint room, added_by == "estate-provision") are
    // now normal drawers. They are included in the centrality graph — they may
    // have tunnels as any other drawer, and including them keeps the graph
    // representative of the full estate content.
    let all_drawers = coord
        .all_drawers(handle)
        .map_err(|e| format!("all_drawers failed: {e:?}"))?;
    let tunnels = coord
        .all_tunnels(handle)
        .map_err(|e| format!("all_tunnels failed: {e:?}"))?;
    let facts = coord
        .recall_kg_facts(handle)
        .map_err(|e| format!("recall_kg_facts failed: {e:?}"))?;

    // Planned hardening: cap to GRAPH_CENTRALITY_SCAN_NODE_CAP live drawers.
    // Drawers beyond the cap score 0.0 (spec C-16 — correct, identical to
    // "no cache registered"). Sort by id for determinism, matching the Swift
    // port's sorted() order so both ports cap the same subset from the same
    // estate state. Parity: mirrors graphCentralityScanNodeCap in
    // AutonomicGovernor.swift.
    let mut live_drawers: Vec<_> = all_drawers
        .iter()
        .filter(|d| d.tombstoned_at.is_none())
        .cloned()
        .collect();
    live_drawers.sort_by(|a, b| a.id.cmp(&b.id));
    if live_drawers.len() > GRAPH_CENTRALITY_SCAN_NODE_CAP {
        eprintln!(
            "AutonomicGovernor: graph-centrality scan: {} live drawers exceeds cap {}; \
             scoring first {} (planned hardening)",
            live_drawers.len(),
            GRAPH_CENTRALITY_SCAN_NODE_CAP,
            GRAPH_CENTRALITY_SCAN_NODE_CAP
        );
        live_drawers.truncate(GRAPH_CENTRALITY_SCAN_NODE_CAP);
    }

    let graph = build_centrality_graph(&live_drawers, &tunnels, &facts);
    // Thread estate_id and now_epoch_secs so VizGraph telemetry carries the
    // correct estate tag and timestamp — not empty/0 defaults.
    let scores = compute_centrality_scores(&graph, estate_id, now_epoch_secs);

    coord.register_graph_cache(handle, Arc::new(GraphCentralityCache::new(scores)));
    Ok(())
}

// ── Preference producer duty ──────────────────────────────────────────────────

/// Fit per-drawer Bradley-Terry preference strengths from the estate's
/// recall-trace reward history and register them as a `PreferenceStore`, taking
/// the `unionBest` / `matrixAware` recall `preference` score column from dark to
/// live.
///
/// The Rust mirror of Swift `AutonomicGovernor.preferenceScan`. It reads the
/// estate's recall-trace reward outcomes through the coordinator, shapes them
/// into the per-drawer `(label, endorsements, dismissals)` records the
/// `neuron_kit::learned_preference` fitter consumes (identical record multiset to
/// the Swift port), runs that fitter, and installs the per-drawer strengths on
/// the coordinator.
///
/// Math ownership (I-17): owns NO fitting math. Bradley-Terry is the
/// conformance-gated SubstrateML primitive surfaced by
/// `neuron_kit::learned_preference` (the `Bias` lens, anchor reduction); this
/// duty only shapes the outcomes and caches the strengths. A faithful cadence
/// wrapper of a direct `learned_preference` call on the same records.
///
/// Window: all retained recall traces up to `now` (`since` = the epoch-floor
/// ISO8601 string, mirroring Swift `Date.distantPast`). Retention is bounded by
/// the maintenance prune cycle. `now_i64` is the injected tick clock — no clock
/// read here. Deterministic: a pure function of the recorded rows and `now`.
///
/// The only side effect is the store registration (idempotent re-registration
/// replaces the prior snapshot). An estate with no traces yields no records ⇒
/// `learned_preference(&[]) == []` ⇒ an empty store (every `preference_score`
/// 0.0 — correct, C-16).
///
/// Locking: takes the coordinator `Mutex` briefly — one read + one register.
/// Returns the lock-poison, read, or fit error as a string for the caller to
/// log; the governor loop continues on error (never crashes the daemon).
fn preference_duty(
    coord: &Arc<Mutex<EstateCoordinator>>,
    handle: &EstateHandle,
    now_i64: i64,
) -> Result<(), String> {
    use crate::preference_producer::{
        compute_preference_scores, preference_outcomes, PreferenceCache,
    };

    // ISO8601 bounds for the trace read. The lower bound is the epoch floor —
    // the Rust mirror of Swift `Date.distantPast` — so the read returns the whole
    // retained trace history (retention bounded upstream by the prune cycle).
    let since = "0000-01-01T00:00:00Z";
    let now_str = epoch_secs_to_iso8601(now_i64);

    let mut coord = coord
        .lock()
        .map_err(|e| format!("coordinator lock poisoned: {e}"))?;

    // Reads through the coordinator verb surface (B-1) — the same recall-trace
    // window read the dreaming reader uses.
    let traces = coord
        .recent_recall_traces(handle, since, &now_str)
        .map_err(|e| format!("recent_recall_traces failed: {e:?}"))?;

    let records = preference_outcomes(&traces);
    let scores =
        compute_preference_scores(&records).map_err(|e| format!("learned_preference failed: {e:?}"))?;

    coord.register_preference_store(handle, Arc::new(PreferenceCache::new(scores)));
    Ok(())
}

// ── Topology snapshot duty ────────────────────────────────────────────────────

/// A cheap, order-independent CHANGE-DETECTION token over the topology duty's
/// INPUTS, which skips recomputation when the estate is unchanged between
/// cadences. The token reduces to a STABLE `fingerprint` (process-independent)
/// that IS persisted beside the snapshot (F5) and compared across restarts: the
/// duty's dirty-check compares the freshly-computed fingerprint against the one
/// loaded from disk, so an unchanged estate skips the full topology read on the
/// first post-restart duty.
///
/// Built from already-fetched rows only — counts, maximum ingest/event
/// instants, dead counts, and an order-independent inputs digest (wrapping sum
/// of per-drawer FNV-1a(id+udc) hashes, catching re-anchoring that changes
/// neither counts nor timestamps). FNV-1a (not `DefaultHasher`) keeps the digest
/// identical across process runs so the fingerprint round-trips through disk.
/// Mirrors Swift `TopologyInputsToken`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TopologyInputsToken {
    drawer_count: usize,
    tunnel_count: usize,
    fact_count: usize,
    dead_drawer_count: usize,
    dead_tunnel_count: usize,
    max_filed_at: Option<i64>,
    max_event_time: Option<i64>,
    /// Order-independent wrapping sum of per-drawer FNV-1a(id+udc) hashes.
    /// STABLE across process launches (FNV, not `DefaultHasher`) so the
    /// `fingerprint` persists and compares across restarts.
    inputs_digest: u64,
}

impl TopologyInputsToken {
    fn new(
        drawers: &[locus_kit::drawer::Drawer],
        tunnels: &[locus_kit::tunnel::Tunnel],
        fact_count: usize,
    ) -> Self {
        let dead_drawer_count = drawers.iter().filter(|d| d.tombstoned_at.is_some()).count();
        let dead_tunnel_count = tunnels.iter().filter(|t| t.tombstoned_at.is_some()).count();
        let max_filed_at = drawers.iter().map(|d| d.filed_at)
            .chain(tunnels.iter().map(|t| t.filed_at))
            .max();
        let max_event_time = drawers.iter().map(|d| d.event_time).max();
        // Overflow-add of per-drawer STABLE hashes keeps the digest
        // order-independent across query order AND identical across process runs.
        let mut digest: u64 = 0;
        for d in drawers {
            digest = digest.wrapping_add(Self::fnv1a(&format!("{}\u{1}{}", d.id, d.udc_code)));
        }
        TopologyInputsToken {
            drawer_count: drawers.len(),
            tunnel_count: tunnels.len(),
            fact_count,
            dead_drawer_count,
            dead_tunnel_count,
            max_filed_at,
            max_event_time,
            inputs_digest: digest,
        }
    }

    /// FNV-1a 64-bit over a string's UTF-8 — a small, stable, process-independent
    /// hash (no external dependency, no `DefaultHasher` salt). Mirrors Swift
    /// `TopologyInputsToken.fnv1a`.
    fn fnv1a(s: &str) -> u64 {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in s.bytes() {
            h ^= byte as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        h
    }

    /// Stable, persistable fingerprint of these inputs. Two tokens are equal iff
    /// their fingerprints are equal, so the duty's dirty-check compares
    /// fingerprints — and the same comparison holds across process restarts when
    /// one side is loaded from disk. Mirrors Swift `TopologyInputsToken.fingerprint`.
    ///
    /// `max_filed_at` / `max_event_time` are epoch instants. Swift formats the
    /// missing case as "-" and present values via `String(Date.timeIntervalSince1970)`;
    /// the Rust leg never cross-compares fingerprint strings with Swift (separate
    /// estates), so the exact present-value formatting need only be stable within
    /// this port.
    pub fn fingerprint(&self) -> String {
        let filed = self.max_filed_at.map(|v| v.to_string()).unwrap_or_else(|| "-".to_string());
        let event = self.max_event_time.map(|v| v.to_string()).unwrap_or_else(|| "-".to_string());
        format!(
            "{}:{}:{}:{}:{}:{}:{}:{}",
            self.drawer_count, self.tunnel_count, self.fact_count,
            self.dead_drawer_count, self.dead_tunnel_count, filed, event, self.inputs_digest
        )
    }
}

/// Compute and write a topology snapshot to the stats store.
///
/// Mirrors the Swift `AutonomicGovernor.topologySnapshotDuty`: estate store
/// reads → descriptor mapping → `neuron_kit::topology_analysis::graph_topology`
/// (Louvain + centrality, full analysis) → wire-shape JSON → snapshot write.
///
/// Dirty check: the inputs are reduced to a STABLE fingerprint BEFORE the math;
/// a fingerprint matching `previous_fingerprint` returns without touching the
/// store, so `generatedTs` keeps meaning "when the content last changed". The
/// fingerprint persists beside the snapshot (F5), so the skip also holds across
/// a restart when `previous_fingerprint` was loaded from disk. Returns the
/// fingerprint to hold as governor state (`previous_fingerprint` is passed back
/// unchanged on read/write failure so a transient error does not force a
/// spurious recompute next cadence).
///
/// Errors are logged to stderr; the governor loop continues on failure.
fn topology_snapshot_duty(
    estate_id: &str,
    now_epoch_secs: f64,
    sink: &dyn GovernorTopologySink,
    estate: &dyn DrawerStore,
    previous_fingerprint: Option<String>,
) -> Option<String> {
    use crate::topology_analysis::{
        graph_topology, TopologyDrawerInput, TopologyFactInput, TopologyTunnelInput,
    };

    let (drawers, tunnels, facts) = match (
        estate.all_drawers(),
        estate.all_tunnels(),
        estate.all_kg_facts(),
    ) {
        (Ok(d), Ok(t), Ok(f)) => (d, t, f),
        (d, t, f) => {
            for (name, err) in [("drawers", d.err().map(|e| format!("{e:?}")) ),
                                 ("tunnels", t.err().map(|e| format!("{e:?}")) ),
                                 ("kg_facts", f.err().map(|e| format!("{e:?}")) )] {
                if let Some(e) = err {
                    eprintln!("AutonomicGovernor: topology {name} read failed for estate {estate_id}: {e}");
                }
            }
            return previous_fingerprint;
        }
    };

    let token = TopologyInputsToken::new(&drawers, &tunnels, facts.len());
    let fingerprint = token.fingerprint();
    if previous_fingerprint.as_deref() == Some(fingerprint.as_str()) {
        return previous_fingerprint;
    }

    // Descriptor mapping. The Rust store round-trips its tombstone stamp, so
    // `tombstoned_at` alone is the dead signal (the Swift leg additionally
    // consults the state axis + audit trail).
    let drawer_inputs: Vec<TopologyDrawerInput> = drawers.iter()
        .map(|d| TopologyDrawerInput {
            id: d.id.clone(),
            udc_code: d.udc_code.clone(),
            filed_at: d.filed_at,
            event_time: d.event_time,
            tombstoned: d.tombstoned_at.is_some(),
            tombstoned_at: d.tombstoned_at,
        })
        .collect();
    let tunnel_inputs: Vec<TopologyTunnelInput> = tunnels.iter()
        .map(|t| TopologyTunnelInput {
            source_drawer_id: t.source_drawer_id.clone(),
            target_drawer_id: t.target_drawer_id.clone(),
            filed_at: t.filed_at,
            tombstoned_at: t.tombstoned_at,
        })
        .collect();
    let fact_inputs: Vec<TopologyFactInput> = facts.iter()
        .map(|f| TopologyFactInput {
            subject: f.subject.clone(),
            source_drawer_id: f.source_drawer_id.clone(),
        })
        .collect();

    // Thread estate_id and now_epoch_secs so VizGraph telemetry carries the
    // correct estate tag and timestamp — not empty/0 defaults.
    let topo = graph_topology(&drawer_inputs, &tunnel_inputs, &fact_inputs, estate_id, now_epoch_secs);

    // Wire-shape serialization — field names match the Swift snapshot payload
    // (moot-mgr's GraphNodePayload/GraphEdgePayload decode both legs' bytes).
    let nodes: Vec<serde_json::Value> = topo.nodes.iter()
        .map(|n| serde_json::json!({
            "id": n.id,
            "nounType": 0,
            "communityId": n.community_id,
            "centrality": n.centrality,
            "anomaly": false,
            "lastActiveTs": n.last_active_ts,
            "createdTs": n.created_ts,
            "tombstonedTs": n.tombstoned_ts
        }))
        .collect();
    let edges: Vec<serde_json::Value> = topo.edges.iter()
        .map(|e| serde_json::json!({
            "source": e.source,
            "target": e.target,
            "edgeType": e.edge_type,
            "weight": e.weight,
            "decayedWeight": e.weight,
            "createdTs": e.created_ts,
            "tombstonedTs": e.tombstoned_ts
        }))
        .collect();
    let communities: Vec<serde_json::Value> = topo.communities.iter()
        .map(|c| serde_json::json!({
            "id": c.id, "size": c.size, "dominantUdcCode": c.dominant_udc_code
        }))
        .collect();

    let generated_ts = epoch_secs_to_iso8601(now_epoch_secs as i64);
    let body = serde_json::json!({
        "nodes": nodes,
        "edges": edges,
        "structurePending": false,
        "communities": communities,
        "generatedTs": generated_ts
    });
    let payload = serde_json::to_string(&body)
        .unwrap_or_else(|_| format!(
            r#"{{"nodes":[],"edges":[],"structurePending":true,"communities":[],"generatedTs":"{generated_ts}"}}"#));

    if let Err(e) = sink.write_topology_snapshot(estate_id, now_epoch_secs, &payload, &fingerprint) {
        eprintln!(
            "AutonomicGovernor: topology snapshot write failed for estate {estate_id}: {e}"
        );
        // Write failed: return the previous fingerprint so the next cadence recomputes.
        return previous_fingerprint;
    }
    Some(fingerprint)
}

// ── Env config ────────────────────────────────────────────────────────────────

/// Parse `MOOTX01_BRAIN_TICK_MS` from the environment. Falls back to
/// `DEFAULT_TICK_MS` on absence or parse failure (with a stderr note).
fn parse_tick_ms() -> u64 {
    let raw = std::env::var("MOOTX01_BRAIN_TICK_MS").unwrap_or_default();
    if raw.is_empty() {
        return DEFAULT_TICK_MS;
    }
    match raw.parse::<u64>() {
        Ok(v) if v > 0 => v,
        _ => {
            eprintln!(
                "AutonomicGovernor: MOOTX01_BRAIN_TICK_MS={raw:?} invalid; using {DEFAULT_TICK_MS}ms default"
            );
            DEFAULT_TICK_MS
        }
    }
}

/// Parse `MOOTX01_TOPOLOGY_CADENCE_SECONDS` from the environment.
/// Falls back to `DEFAULT_TOPOLOGY_CADENCE_MS` (300 s) on absence or failure.
fn parse_topology_cadence_ms() -> u64 {
    let raw = std::env::var("MOOTX01_TOPOLOGY_CADENCE_SECONDS").unwrap_or_default();
    if raw.is_empty() {
        return DEFAULT_TOPOLOGY_CADENCE_MS;
    }
    match raw.parse::<u64>() {
        Ok(secs) => secs * 1000,
        _ => {
            eprintln!(
                "AutonomicGovernor: MOOTX01_TOPOLOGY_CADENCE_SECONDS={raw:?} invalid; using default"
            );
            DEFAULT_TOPOLOGY_CADENCE_MS
        }
    }
}

/// Parse `MOOTX01_POOL_REDUCE_CADENCE_SECONDS` from the environment.
/// Falls back to `DEFAULT_POOL_REDUCE_CADENCE_MS` (0 = near-realtime) on absence
/// or failure. Mirrors Swift `autonomicGovernorDefaultPoolReduceCadenceMs`.
fn parse_pool_reduce_cadence_ms() -> u64 {
    let raw = std::env::var("MOOTX01_POOL_REDUCE_CADENCE_SECONDS").unwrap_or_default();
    if raw.is_empty() {
        return DEFAULT_POOL_REDUCE_CADENCE_MS;
    }
    match raw.parse::<u64>() {
        Ok(secs) => secs * 1000,
        _ => {
            eprintln!(
                "AutonomicGovernor: MOOTX01_POOL_REDUCE_CADENCE_SECONDS={raw:?} invalid; using default"
            );
            DEFAULT_POOL_REDUCE_CADENCE_MS
        }
    }
}

// ── ISO8601 round-trip test ───────────────────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epoch_to_iso8601_known_value() {
        // 2023-11-14T22:13:20Z = epoch 1700000000
        assert_eq!(epoch_secs_to_iso8601(1_700_000_000), "2023-11-14T22:13:20Z");
    }

    #[test]
    fn epoch_to_iso8601_unix_epoch() {
        assert_eq!(epoch_secs_to_iso8601(0), "1970-01-01T00:00:00Z");
    }
}
