//! Resident Autonomic Governor (see ADR-LOOPBACKHTTP-001 §17).
//!
//! The Rust vertical's parity of the Swift `AutonomicGovernor` actor
//! (packages/kits/AriaMcpKit/Sources/AriaMCP/AutonomicGovernor.swift). Drives the Brain's
//! cadence work — dreaming (NeuronKit) and maintenance (NeuronKit) — on each
//! daemon's own interval.
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
//! # Standing signals (Rust gap)
//!
//! The Rust GLK has no standing-signal scheduler (no `signal_tick`). The Swift
//! AutonomicGovernor ticks signals each iteration (benign no-op until a signal
//! is registered). The Rust governor drives dreaming + maintenance ONLY. Rust
//! standing signals are a separate GLK-rust feature tracked in the backlog —
//! this omission is intentional and documented here so future implementers know
//! exactly what is missing.
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

use genius_locus_kit::{EstateCoordinator, EstateHandle};
use intellectus_lib::{report, EventKind, StatSample};
use uuid::Uuid;
use locus_kit::drawer_store::DrawerStore;
use neuron_kit::{
    DreamingDaemon, DreamingPolicy, DreamingPolicyStore, EstateDreamingReader,
    EstateDreamingSink, EstateMaintenanceReader, EstateMaintenanceSink,
    InMemoryDreamingPolicyStore, InMemoryMaintenancePolicyStore, MaintenanceDaemon,
    MaintenancePolicy, MaintenancePolicyStore, RecallTraceRewardSource,
};
use observer_sink::StatsStore;

// ── Default constants ─────────────────────────────────────────────────────────

/// Default base-tick interval in milliseconds when `MOOTX01_BRAIN_TICK_MS`
/// is absent or invalid. Matches the Swift AutonomicGovernor default.
const DEFAULT_TICK_MS: u64 = 5_000;

/// Default topology snapshot cadence in milliseconds (300 000 = 5 minutes).
/// Override with `MOOTX01_TOPOLOGY_CADENCE_SECONDS` env var.
const DEFAULT_TOPOLOGY_CADENCE_MS: u64 = 300_000;

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

// ── AutonomicGovernor ─────────────────────────────────────────────────────────

/// What one governor tick fired — returned from `tick()` for tests.
#[derive(Debug, Clone, PartialEq)]
pub struct GovernorReport {
    pub dreaming_fired: bool,
    pub maintenance_fired: bool,
    /// Topology snapshot duty fired this tick. True when the cadence elapsed
    /// and `stats_store` is Some (or cadence elapsed and store is None — the
    /// field reflects cadence gate only, not store presence, matching Swift).
    pub topology_snapshot_fired: bool,
    /// Encode queue drain BACKSTOP fired this tick. True when
    /// `drain_encode_queue_once` was called (regardless of jobs processed — an
    /// empty-queue drain is still a valid pump tick). False only on a drain error
    /// (logged to stderr; the loop continues). Called on EVERY tick because
    /// `drain_encode_queue_once` is idempotent on an empty queue (`Ok(0)`,
    /// zero-cost) — no cadence gating is needed.
    ///
    /// The PRIMARY drain is now the watch-driven background worker spawned at
    /// `mount_encode_queue` (GLK intake): the storage observer wakes it the
    /// instant an EncodeJob is committed, so a regular capture becomes
    /// BM25/vector searchable in near-realtime — NOT bounded by this tick. This
    /// tick-driven drain remains as an idempotent backstop (it cannot
    /// double-process: the maildir claim transition serialises both paths).
    pub encode_drain_fired: bool,
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
    /// Optional stats store for writing topology snapshots. None = no write
    /// (telemetry disabled). Wired from main.rs when ARIA_MCP_STATS_STORE is
    /// set. The cadence gate fires regardless of whether the store is present.
    stats_store: Option<Arc<StatsStore>>,
    /// Topology snapshot cadence in milliseconds (default 300 000 = 5 min).
    /// Overridden by MOOTX01_TOPOLOGY_CADENCE_SECONDS at construction.
    topology_cadence_ms: u64,
    /// Epoch-seconds of the last topology snapshot fire. None = never fired.
    last_topology_snapshot_secs: Option<f64>,
    /// Process-local dirty token of the most recent COMPUTED topology snapshot
    /// inputs. A matching token at the next due cadence skips the math/encode/
    /// write — the stored snapshot is still current. In-memory only: None at
    /// every process start, never persisted, never compared across processes.
    /// Mirrors Swift `lastTopologyInputsToken`.
    last_topology_inputs_token: Option<TopologyInputsToken>,
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
    /// No stats store — telemetry writes are skipped. Use `new_with_stats_store`
    /// when `ARIA_MCP_STATS_STORE` is configured.
    pub fn new(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
    ) -> Self {
        Self::build(coord, handle, store, Arc::new(AtomicBool::new(false)), None)
    }

    /// Construct with an optional stats store for topology snapshot writes.
    /// Called from `main.rs` when `ARIA_MCP_STATS_STORE` is configured.
    pub fn new_with_stats_store(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
        stats_store: Option<Arc<StatsStore>>,
    ) -> Self {
        Self::build(coord, handle, store, Arc::new(AtomicBool::new(false)), stats_store)
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

    /// Internal canonical constructor. All public constructors call this.
    /// `topology_cadence_ms_override`: when `Some`, skips env-var parsing and
    /// uses the provided value directly. Used by tests to avoid env-var
    /// pollution across parallel test threads.
    fn build(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
        stop_flag: Arc<AtomicBool>,
        stats_store: Option<Arc<StatsStore>>,
    ) -> Self {
        let base_tick_ms = parse_tick_ms();
        let topology_cadence_ms = parse_topology_cadence_ms();
        // Pool paths use the SAME LatticeLib convention the novel-token submitter
        // writes to, so the read side (this reducer) and the write side agree.
        Self::build_inner(
            coord, handle, store, stop_flag, stats_store, base_tick_ms, topology_cadence_ms,
            parse_pool_reduce_cadence_ms(), lattice_lib::default_pool_dir(),
            lattice_lib::default_table_artifact(),
        )
    }

    /// Construct with explicit cadences — avoids env-var pollution across
    /// parallel test threads. The `topology_cadence_ms` is passed directly
    /// rather than read from `MOOTX01_TOPOLOGY_CADENCE_SECONDS`.
    /// Use in integration tests; production code uses `new` or `new_with_stats_store`.
    pub fn new_for_testing(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
        topology_cadence_ms: u64,
        stats_store: Option<Arc<StatsStore>>,
    ) -> Self {
        let base_tick_ms = parse_tick_ms();
        // Production pool paths/cadence (resolved from env/platform default).
        Self::build_inner(
            coord, handle, store, Arc::new(AtomicBool::new(false)), stats_store,
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
        stats_store: Option<Arc<StatsStore>>,
        pool_reduce_cadence_ms: u64,
        pool_dir: PathBuf,
        pool_table_artifact: PathBuf,
    ) -> Self {
        let base_tick_ms = parse_tick_ms();
        Self::build_inner(
            coord, handle, store, Arc::new(AtomicBool::new(false)), stats_store,
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
        stats_store: Option<Arc<StatsStore>>,
        base_tick_ms: u64,
        topology_cadence_ms: u64,
        pool_reduce_cadence_ms: u64,
        pool_dir: PathBuf,
        pool_table_artifact: PathBuf,
    ) -> Self {
        // In-memory policy stores (P2). P3 replaces with manifest-backed stores
        // so operator policy survives restarts; the seam (DreamingPolicyStore /
        // MaintenancePolicyStore traits) is unchanged.
        let dreaming_policy_store =
            InMemoryDreamingPolicyStore::new(Some(DreamingPolicy::default()));
        let maintenance_policy_store =
            InMemoryMaintenancePolicyStore::new(Some(MaintenancePolicy::default()));
        let dreaming_policy = dreaming_policy_store.load_policy().unwrap_or_default();
        let maintenance_policy = maintenance_policy_store.load_policy().unwrap_or_default();
        let dreaming = DreamingDaemon::new(dreaming_policy.clone());
        let maintenance = MaintenanceDaemon::new(maintenance_policy);
        AutonomicGovernor {
            dreaming,
            maintenance,
            dreaming_policy,
            coord,
            handle,
            store,
            base_tick_ms,
            stop_flag,
            stats_store,
            topology_cadence_ms,
            last_topology_snapshot_secs: None,
            last_topology_inputs_token: None,
            pool_reduce_cadence_ms,
            last_pool_reduce_secs: None,
            pool_dir,
            pool_table_artifact,
        }
    }

    /// Stop the loop. Safe to call from any thread; idempotent.
    pub fn stop(&self) {
        self.stop_flag.store(true, Ordering::Relaxed);
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
        let (dreaming_fired, maintenance_fired, encode_drain_fired) = {
            let mut coord = self.coord.lock().expect("AutonomicGovernor: coordinator lock poisoned");

            // ── Dreaming ───────────────────────────────────────────────────────
            let dreaming_fired;
            match EstateDreamingReader::new(&coord, &self.handle, &since_str, &now_str) {
                Err(e) => {
                    eprintln!("AutonomicGovernor: dreaming reader error: {e:?}");
                    dreaming_fired = false;
                }
                Ok(reader) => {
                    let mut sink =
                        EstateDreamingSink::new(Arc::clone(&self.store), now_i64);
                    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        self.dreaming
                            .pump(now_epoch_secs, &reader, &RecallTraceRewardSource, &mut sink)
                    })) {
                        Ok(result) => {
                            dreaming_fired = result.is_some();
                            // Emit one Think event per proposal. NounType::Proposal = 4
                            // (wire-stable, matches SubstrateTypes/NounType.swift).
                            // The estate UUID is derived from the EstateHandle's [u8;16]
                            // byte array — the canonical form the dreaming sink also uses.
                            if let Some(ref cycle_report) = result {
                                let estate_str =
                                    Uuid::from_bytes(self.handle.estate_uuid).to_string();
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
                                eprintln!(
                                    "AutonomicGovernor: dreaming sink write errors: {:?}",
                                    sink.write_errors
                                );
                            }
                        }
                        Err(e) => {
                            eprintln!("AutonomicGovernor: dreaming pump panic: {:?}", e);
                            dreaming_fired = false;
                        }
                    }
                }
            }

            // ── Maintenance ────────────────────────────────────────────────────
            // EstateMaintenanceReader::new returns Self directly (not Result) —
            // snapshot construction is infallible; all reads happen in scan().
            let maintenance_fired;
            {
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

            // ── Encode queue drain (P4 parity) ────────────────────────────────
            //
            // Drains the estate's encode queue once per tick, ingesting any
            // pending EncodeJobs into the Corpus (BM25 + vector indexed). This
            // closes the Rust production gap: `capture_with_mode(Regular)`
            // enqueues a job, and the governor tick is the production consumer
            // that drives `drain_encode_queue_once` to process it.
            //
            // Swift equivalent: the background drain Task spawned at
            // `mountEncodeQueue` (EncodeIntake.swift P4, 15 ms poll cadence).
            // The Rust port has no background thread so the governor tick is the
            // correct pump site — the same Arc<Mutex<EstateCoordinator>> the HTTP
            // transport uses, serialised by the Mutex already held here.
            //
            // Called on EVERY tick: `drain_encode_queue_once` is idempotent on an
            // empty queue (returns `Ok(0)`, no allocation, no queue read if the
            // queue is not mounted for this estate). No cadence gating needed.
            //
            // Error policy (mirrors Swift runEncodeDrainLoop): a drain error is
            // logged to stderr and the loop continues — the governor must never
            // crash the daemon. The failed job was already replied `Blocked` by
            // `drain_encode_queue_once` so it cannot wedge the queue. The drawer
            // row is already durably stored regardless.
            let encode_drain_fired = match coord.drain_encode_queue_once(&self.handle) {
                Ok(_count) => true,
                Err(e) => {
                    eprintln!(
                        "AutonomicGovernor: encode drain error for estate {:?}: {e:?}",
                        uuid::Uuid::from_bytes(self.handle.estate_uuid)
                    );
                    false
                }
            };

            // Coordinator lock released here (end of block).
            (dreaming_fired, maintenance_fired, encode_drain_fired)
        };

        // ── Topology snapshot ──────────────────────────────────────────────
        //
        // Cadence gating mirrors Swift: fire when elapsed >= cadence_ms or never
        // fired (last_topology_snapshot_secs == None). The `topology_snapshot_fired`
        // flag reflects the cadence gate; the store write only happens when
        // `stats_store` is Some. This is intentional — it lets tests drive cadence
        // logic without wiring a real SQLite store.
        let topology_elapsed_ms = self.last_topology_snapshot_secs.map(|last| {
            ((now_epoch_secs - last) * 1000.0) as u64
        });
        let topology_snapshot_fired = match topology_elapsed_ms {
            None => true,                                         // never fired
            Some(ms) => ms >= self.topology_cadence_ms,          // cadence elapsed
        };
        if topology_snapshot_fired {
            self.last_topology_snapshot_secs = Some(now_epoch_secs);
            if let Some(ref stats) = self.stats_store {
                // Monitoring gate: live store flag read at each due cadence,
                // BEFORE any estate read or compute — "off is free". Fails
                // OPEN on store errors (a transient read failure must not
                // silently freeze topology).
                let monitoring_on = stats.is_monitoring_enabled().unwrap_or(true);
                if monitoring_on {
                    let estate_id = Uuid::from_bytes(self.handle.estate_uuid).to_string();
                    self.last_topology_inputs_token = topology_snapshot_duty(
                        &estate_id,
                        now_epoch_secs,
                        stats,
                        self.store.as_ref(),
                        self.last_topology_inputs_token.take(),
                    );
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
        let pool_reduce_fired = match pool_elapsed_ms {
            None => true,                                       // never fired
            Some(ms) => ms >= self.pool_reduce_cadence_ms,      // cadence elapsed
        };
        let mut table_swapped = false;
        if pool_reduce_fired {
            self.last_pool_reduce_secs = Some(now_epoch_secs);
            // The reducer's `now` is the calendar date (YYYY-MM-DD) for the
            // artifact's snapshot_date. Slice the date prefix off the full
            // ISO8601 instant (`YYYY-MM-DDTHH:MM:SSZ`).
            let now_date = &now_str[..now_str.len().min(10)];
            match lattice_lib::pool_reduce(&self.pool_dir, &self.pool_table_artifact, now_date) {
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

        GovernorReport {
            dreaming_fired,
            maintenance_fired,
            topology_snapshot_fired,
            encode_drain_fired,
            pool_reduce_fired,
            table_swapped,
            table_version: lattice_lib::table_version(),
        }
    }
}

// ── Topology snapshot duty ────────────────────────────────────────────────────

/// A cheap, order-independent CHANGE-DETECTION token over the topology duty's
/// INPUTS, which skips recomputation when the estate is unchanged between
/// cadences. This is a PROCESS-LOCAL DIRTY TOKEN, not a stable fingerprint: it
/// is in-memory governor state, NEVER persisted to storage, and NEVER compared
/// across processes. It is built from `DefaultHasher` (process-local; the
/// hasher's keys/output are not stable across builds or processes), so two
/// processes will produce different tokens for identical estates — that is
/// correct and sufficient, because the only comparison ever made is
/// `previous == current` WITHIN a single running governor. Do NOT treat this as
/// cross-process evidence and do NOT swap in a substrate Fingerprint256/SimHash
/// primitive: that would over-engineer an in-memory change-detector whose
/// entire lifetime is one process.
///
/// Built from already-fetched rows only — counts, maximum ingest/event
/// instants, dead counts, and an order-independent inputs digest (wrapping sum
/// of per-drawer id+udc hashes, catching re-anchoring that changes neither
/// counts nor timestamps). Mirrors Swift `TopologyInputsToken`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TopologyInputsToken {
    drawer_count: usize,
    tunnel_count: usize,
    fact_count: usize,
    dead_drawer_count: usize,
    dead_tunnel_count: usize,
    max_filed_at: Option<i64>,
    max_event_time: Option<i64>,
    /// Order-independent wrapping sum of per-drawer id+udc `DefaultHasher`
    /// outputs. Process-local — only ever compared to another token from the
    /// SAME process. Never persisted.
    inputs_digest: u64,
}

impl TopologyInputsToken {
    fn new(
        drawers: &[locus_kit::drawer::Drawer],
        tunnels: &[locus_kit::tunnel::Tunnel],
        fact_count: usize,
    ) -> Self {
        use std::hash::{Hash, Hasher};
        let dead_drawer_count = drawers.iter().filter(|d| d.tombstoned_at.is_some()).count();
        let dead_tunnel_count = tunnels.iter().filter(|t| t.tombstoned_at.is_some()).count();
        let max_filed_at = drawers.iter().map(|d| d.filed_at)
            .chain(tunnels.iter().map(|t| t.filed_at))
            .max();
        let max_event_time = drawers.iter().map(|d| d.event_time).max();
        // Wrapping add keeps the digest order-independent across query order.
        let mut digest: u64 = 0;
        for d in drawers {
            let mut h = std::collections::hash_map::DefaultHasher::new();
            d.id.hash(&mut h);
            d.udc_code.hash(&mut h);
            digest = digest.wrapping_add(h.finish());
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
}

/// Compute and write a topology snapshot to the stats store.
///
/// Mirrors the Swift `AutonomicGovernor.topologySnapshotDuty`: estate store
/// reads → descriptor mapping → `neuron_kit::topology_analysis::graph_topology`
/// (Louvain + centrality, full analysis) → wire-shape JSON → snapshot write.
///
/// Dirty check: the inputs are reduced to a process-local token BEFORE the
/// math; an unchanged token returns without touching the store, so
/// `generatedTs` keeps meaning "when the content last changed". Returns the
/// token to hold as in-memory governor state (`previous` is passed back
/// unchanged on read failure so a transient error does not force a spurious
/// recompute next cadence). The token is NEVER written to the store — only the
/// JSON snapshot payload is.
///
/// Errors are logged to stderr; the governor loop continues on failure.
fn topology_snapshot_duty(
    estate_id: &str,
    now_epoch_secs: f64,
    stats: &StatsStore,
    estate: &dyn DrawerStore,
    previous: Option<TopologyInputsToken>,
) -> Option<TopologyInputsToken> {
    use neuron_kit::topology_analysis::{
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
            return previous;
        }
    };

    let token = TopologyInputsToken::new(&drawers, &tunnels, facts.len());
    if previous.as_ref() == Some(&token) {
        return previous;
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

    let topo = graph_topology(&drawer_inputs, &tunnel_inputs, &fact_inputs);

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

    if let Err(e) = stats.write_topology_snapshot(estate_id, now_epoch_secs, &payload) {
        eprintln!(
            "AutonomicGovernor: topology snapshot write failed for estate {estate_id}: {e:?}"
        );
        // Write failed: return `previous` so the next cadence recomputes.
        return previous;
    }
    Some(token)
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
