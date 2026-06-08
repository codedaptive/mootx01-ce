//! Resident Brain pump (see ADR-LOOPBACKHTTP-001 §17).
//!
//! The Rust vertical's parity of the Swift `BrainPump` actor
//! (apps/ARIA_MCP/Sources/AriaMCP/BrainPump.swift). Drives the Brain's
//! cadence work — dreaming (NeuronKit) and maintenance (NeuronKit) — on each
//! daemon's own interval.
//!
//! # Live estate wiring
//!
//! The pump holds the SAME `Arc<Mutex<EstateCoordinator>>` and `EstateHandle`
//! as the HTTP transport — they are the same Arc, so both the pump thread and
//! `run_http_loop` operate on the same live estate. The Mutex serializes all
//! coordinator access. This is the Rust parity of the Swift pump receiving
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
//! the Brain pump must never crash the daemon. The stop flag breaks the loop
//! cleanly for tests and process shutdown.
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
//! pump ticks signals each iteration (benign no-op until a signal is
//! registered). The Rust pump drives dreaming + maintenance ONLY. Rust standing
//! signals are a separate GLK-rust feature tracked in the backlog — this
//! omission is intentional and documented here so future implementers know
//! exactly what is missing.
//!
//! # Base tick
//!
//! Read from env `MOOTX01_BRAIN_TICK_MS` at construction (default 5000 ms).
//! This is the sampling resolution for the daemons' own (longer) cadences,
//! not a cadence itself.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use genius_locus_kit::{EstateCoordinator, EstateHandle};
use locus_kit::drawer_store::DrawerStore;
use neuron_kit::{
    DreamingDaemon, DreamingPolicy, DreamingPolicyStore, EstateDreamingReader,
    EstateDreamingSink, EstateMaintenanceReader, EstateMaintenanceSink,
    InMemoryDreamingPolicyStore, InMemoryMaintenancePolicyStore, MaintenanceDaemon,
    MaintenancePolicy, MaintenancePolicyStore, RecallTraceRewardSource,
};

// ── Default tick constant ─────────────────────────────────────────────────────

/// Default base-tick interval in milliseconds when `MOOTX01_BRAIN_TICK_MS`
/// is absent or invalid. Matches the Swift BrainPump default.
const DEFAULT_TICK_MS: u64 = 5_000;

// ── ISO8601 helpers ───────────────────────────────────────────────────────────

/// Format epoch seconds as an ISO8601 UTC string (`YYYY-MM-DDTHH:MM:SSZ`).
///
/// This is the canonical timestamp format the substrate's TEXT date columns use.
/// `EstateDreamingReader::new` takes `since`/`now` as ISO8601 strings matching
/// this format.
fn epoch_secs_to_iso8601(epoch_secs: i64) -> String {
    // Hand-rolled to avoid a chrono dependency. Correct for the range of
    // epoch values the pump will ever see (year 2001–2100, UTC).
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

// ── BrainPump ────────────────────────────────────────────────────────────────

/// What one pump tick fired — returned from `tick()` for tests.
#[derive(Debug, Clone, PartialEq)]
pub struct TickReport {
    pub dreaming_fired: bool,
    pub maintenance_fired: bool,
}

/// The resident Brain pump.
///
/// Wired to the LIVE default estate through:
/// - `coord`: the same `Arc<Mutex<EstateCoordinator>>` the HTTP transport uses
/// - `handle`: the default estate's handle
/// - `store`: the `Arc<dyn DrawerStore>` backing that estate (sink write path)
///
/// Construction:
///   `BrainPump::new(coord, handle, store)` — mirrors the Swift pump receiving
///   `kit: GeniusLocusKit` and `handle: EstateHandle`.
///
/// `run_loop` drives the pump until `stop()` is called or the stop flag is set.
/// `tick(now)` exposes one iteration for deterministic tests.
pub struct BrainPump {
    dreaming: DreamingDaemon,
    maintenance: MaintenanceDaemon,
    /// Policy: tick_interval_ms for computing the dreaming reward window.
    dreaming_policy: DreamingPolicy,
    /// Shared coordinator — same Arc as the HTTP transport; Mutex serializes
    /// all estate reads (coordinator snapshot) and HTTP tool-call writes.
    coord: Arc<Mutex<EstateCoordinator>>,
    /// The estate targeted by this pump.
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
}

impl BrainPump {
    /// Construct the pump wired to the live estate.
    ///
    /// - `coord`: shared coordinator — the same Arc the HTTP transport holds.
    /// - `handle`: the default estate's handle.
    /// - `store`: the `Arc<dyn DrawerStore>` the estate was opened with; the
    ///   sinks write proposals and diary entries through this reference.
    ///
    /// Base tick is read from `MOOTX01_BRAIN_TICK_MS` (default 5000 ms).
    pub fn new(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
    ) -> Self {
        Self::with_stop_flag(coord, handle, store, Arc::new(AtomicBool::new(false)))
    }

    /// Construct with a caller-supplied stop flag. Used by tests to stop the
    /// loop from outside without spawning a thread.
    pub fn with_stop_flag(
        coord: Arc<Mutex<EstateCoordinator>>,
        handle: EstateHandle,
        store: Arc<dyn DrawerStore>,
        stop_flag: Arc<AtomicBool>,
    ) -> Self {
        let base_tick_ms = parse_tick_ms();
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
        BrainPump {
            dreaming,
            maintenance,
            dreaming_policy,
            coord,
            handle,
            store,
            base_tick_ms,
            stop_flag,
        }
    }

    /// Stop the loop. Safe to call from any thread; idempotent.
    pub fn stop(&self) {
        self.stop_flag.store(true, Ordering::Relaxed);
    }

    /// Run the pump loop until `stop()` is called.
    ///
    /// Each iteration:
    ///   1. Reads the clock once (the ONLY `SystemTime::now()` call in the path).
    ///   2. Calls `tick(now)` — dreaming + maintenance, errors logged.
    ///   3. Sleeps the base tick.
    ///
    /// Logs start/stop to stderr, consistent with the Swift pump.
    pub fn run_loop(&mut self) {
        eprintln!("BrainPump started (base tick {}ms)", self.base_tick_ms);
        while !self.stop_flag.load(Ordering::Relaxed) {
            // Read the clock once per iteration and inject into all daemons.
            // This is the ONLY place SystemTime is read in the pump path.
            let now = epoch_secs_now();
            self.tick(now);
            std::thread::sleep(Duration::from_millis(self.base_tick_ms));
        }
        eprintln!("BrainPump stopped");
    }

    /// One pump iteration with an injected `now_epoch_secs`. Each daemon
    /// self-gates on its own interval; errors are logged and the loop
    /// continues. Exposed for deterministic tests (no wall-clock sleeps).
    ///
    /// Per-tick flow:
    ///   1. Lock coordinator; snapshot dreaming + maintenance readers.
    ///   2. Release lock — coordinator is available for HTTP tool-calls.
    ///   3. Construct sinks over the live store.
    ///   4. Run dreaming pump, then maintenance pump, with error isolation.
    pub fn tick(&mut self, now_epoch_secs: f64) -> TickReport {
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

        let (dreaming_reader_result, maintenance_reader_result) = {
            let coord = self.coord.lock().expect("BrainPump: coordinator lock poisoned");
            let dr = EstateDreamingReader::new(&coord, &self.handle, &since_str, &now_str);
            let mr = EstateMaintenanceReader::new(&coord, &self.handle, now_i64);
            (dr, mr)
            // Mutex guard drops here — lock released before pump cycles run.
        };

        // ── Dreaming ───────────────────────────────────────────────────────
        let dreaming_fired;
        match dreaming_reader_result {
            Err(e) => {
                eprintln!("BrainPump: dreaming reader error: {e:?}");
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
                        if !sink.write_errors.is_empty() {
                            eprintln!(
                                "BrainPump: dreaming sink write errors: {:?}",
                                sink.write_errors
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("BrainPump: dreaming pump panic: {:?}", e);
                        dreaming_fired = false;
                    }
                }
            }
        }

        // ── Maintenance ────────────────────────────────────────────────────
        let maintenance_fired;
        match maintenance_reader_result {
            Err(e) => {
                eprintln!("BrainPump: maintenance reader error: {e:?}");
                maintenance_fired = false;
            }
            Ok(reader) => {
                let mut sink =
                    EstateMaintenanceSink::new(Arc::clone(&self.store), now_i64);
                match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    self.maintenance.pump(now_epoch_secs, &reader, &mut sink)
                })) {
                    Ok(result) => {
                        maintenance_fired = result.is_some();
                        if !sink.write_errors.is_empty() {
                            eprintln!(
                                "BrainPump: maintenance sink write errors: {:?}",
                                sink.write_errors
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("BrainPump: maintenance pump panic: {:?}", e);
                        maintenance_fired = false;
                    }
                }
            }
        }

        TickReport {
            dreaming_fired,
            maintenance_fired,
        }
    }
}

// ── Clock helpers ─────────────────────────────────────────────────────────────

/// Read the wall clock once and return epoch-seconds as f64.
///
/// This is the ONLY call to `SystemTime::now()` in the pump's code path —
/// it lives here, in the loop driver, not inside any daemon. The result is
/// passed to every daemon's `pump(now)` call so all daemons in a single tick
/// operate on the same `now`. Determinism contract matches the Swift pump.
fn epoch_secs_now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_secs_f64()
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
                "BrainPump: MOOTX01_BRAIN_TICK_MS={raw:?} invalid; using {DEFAULT_TICK_MS}ms default"
            );
            DEFAULT_TICK_MS
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
