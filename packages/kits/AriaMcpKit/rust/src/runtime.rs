//! runtime.rs — the full server runtime: backend selection, telemetry
//! wiring, transport select (stdio vs resident HTTP + Autonomic Governor).
//!
//! Extracted verbatim from the binary's `main.rs` so that BOTH entry points —
//! the `aria-mcp` dev binary and the product `mootx01 serve` (apps/mootx01/rust)
//! — run the identical resident-daemon logic from one source of truth. The
//! caller prepares the transport environment (`MOOTX01_HTTP_PORT`, …) and calls
//! `run()`; this
//! function does not return until the transport stops (stdin closes, or the
//! HTTP loop exits). On fatal config errors it exits the process, same as
//! the original main.
//!
//! The estate is passed in as a `RuntimeEstate`: the caller resolved it from
//! the estate catalog (`--db`, `--in-memory`), and no environment value names
//! an estate here.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::dream_runner::configure_hnsw_from_registry;
use crate::governor_topology_adapter::StatsStoreTopologySink;
use crate::http_server::{
    bind_loopback, run_http_loop, GLOBAL_4XX_COUNTER, GLOBAL_5XX_COUNTER, GLOBAL_INFLIGHT_COUNTER,
    GLOBAL_INFLIGHT_HWM, GLOBAL_LATENCY_FAST, GLOBAL_LATENCY_MID, GLOBAL_LATENCY_NS_TOTAL,
    GLOBAL_LATENCY_SLOW, GLOBAL_RPC_COUNTER, GLOBAL_SHED_COUNTER,
};
use crate::server::{run_stdio_loop, ServerConfig};
use genius_locus_kit::brain::scheduler::api::{
    SignalID as SchedulerSignalID, SignalSpec as SchedulerSignalSpec,
};
use genius_locus_kit::brain::signals::{
    ByReferenceValiditySignal, ConsolidationSignal, ContradictionSweepSignal, DecaySweepSignal,
    EndOfDayTournamentSignal, FactExtractionSignal, MaintenanceSignal, TemporalCausalitySignal,
    TrainingSignal,
};
use neuron_kit::autonomic_governor::AutonomicGovernor;

fn reconcile_runtime_signal<F>(
    governor: &mut AutonomicGovernor,
    registered: &mut HashMap<String, SchedulerSignalID>,
    name: &str,
    enabled: bool,
    now: SystemTime,
    make_spec: F,
) -> Result<(), String>
where
    F: FnOnce() -> Option<SchedulerSignalSpec>,
{
    match (enabled, registered.get(name).cloned()) {
        (false, Some(id)) => {
            governor.unregister_standing_signal(&id);
            registered.remove(name);
        }
        (true, None) => {
            if let Some(spec) = make_spec() {
                let id = governor.register_standing_signal(spec, now);
                registered.insert(name.to_string(), id);
            }
        }
        _ => {}
    }
    Ok(())
}

const MANAGED_PREFERENCE_SIGNAL_NAMES: [&str; 9] = [
    FactExtractionSignal::SIGNAL_NAME,
    ConsolidationSignal::SIGNAL_NAME,
    ContradictionSweepSignal::SIGNAL_NAME,
    MaintenanceSignal::SIGNAL_NAME,
    DecaySweepSignal::SIGNAL_NAME,
    ByReferenceValiditySignal::SIGNAL_NAME,
    TemporalCausalitySignal::SIGNAL_NAME,
    TrainingSignal::SIGNAL_NAME,
    EndOfDayTournamentSignal::SIGNAL_NAME,
];

fn fail_closed_runtime_signals(
    governor: &mut AutonomicGovernor,
    registered: &mut HashMap<String, SchedulerSignalID>,
) {
    for name in MANAGED_PREFERENCE_SIGNAL_NAMES {
        if let Some(id) = registered.get(name) {
            if governor.unregister_standing_signal(id) {
                registered.remove(name);
            }
        }
    }
}

/// Bound for the observer program's in-process recent window (DEBT-3).
/// 256 samples proves liveness and shows a recent slice without retaining
/// meaningful memory. Mirrors Swift `Observer.defaultWindowCapacity`.
const OBSERVER_WINDOW_CAPACITY: usize = 256;

/// Decide whether the resident observer should be enabled, from config.
///
/// Enabled when EITHER the `ARIA_MCP_OBSERVER` env var is truthy ("1", "true",
/// "yes", "on", case-insensitive) OR the persisted store monitoring flag is on.
/// The env var is the operator's explicit opt-in; the store flag is moot-mgr's
/// broadcast signal. Mirrors Swift `Observer.shouldEnable(env:storeFlag:)`.
pub fn observer_should_enable(store_flag: bool) -> bool {
    if env_observer_enabled() {
        return true;
    }
    store_flag
}

/// Parse `ARIA_MCP_OBSERVER` as a boolean opt-in. Truthy: "1", "true", "yes",
/// "on" (case-insensitive). Absent/empty/other → false. Mirrors Swift
/// `Observer.envObserverEnabled(_:)`.
fn env_observer_enabled() -> bool {
    match std::env::var("ARIA_MCP_OBSERVER") {
        Ok(raw) => matches!(raw.to_lowercase().as_str(), "1" | "true" | "yes" | "on"),
        Err(_) => false,
    }
}

/// Run the server to completion. See module docs. The `banner` is the
/// stderr identity line (e.g. "aria-mcp" or "mootx01"), so logs say who is
/// hosting the runtime. `version_skew` is the plugin-ownership rule's advisory — empty when
/// the caller detected no plugin/binary version mismatch (the common case,
/// and the only option for `aria-mcp-server`, which has no plugin concept),
/// or the advisory text to surface verbatim in `moot_estate_ping` /
/// `moot_estate_status`. The caller computes it (this kit does not read
/// `~/.claude/plugins/` or know a product version itself — see
/// `mootx01-cli`'s `commands::serve::version_skew_advisory`, the Rust twin
/// of Swift's `MootInstallerCore.VersionSkewAdvisory`).
///
/// `update_advisory` is the upstream-release advisory provider surfaced as
/// an `update_available:` line by ping/status (see
/// `crate::dispatcher::UpdateAdvisoryProvider`). The caller owns the
/// network boundary, rate limiting, and the resident-only gate — pass
/// `None` from stdio one-shots and hosts with no release feed (the
/// aria-mcp dev server). Rust twin of Swift ServeCommand's
/// `updateAdvisoryProvider` wiring.
pub fn run(
    banner: &str,
    version_skew: &str,
    update_advisory: Option<crate::dispatcher::UpdateAdvisoryProvider>,
    estate: crate::server::RuntimeEstate,
) {
    eprintln!("{banner}: starting Rust MCP server");
    // Registered estates use the install-wide settings directory. Transient
    // estates use their own directory, so a benchmark never consults the
    // user's live config.json. The staged model beside the executable remains
    // the no-config fallback in both cases.
    let fact_settings_directory = match &estate {
        crate::server::RuntimeEstate::Sqlite { record, .. }
            if record.kind == genius_locus_kit::EstateRecordKind::Transient =>
        {
            record.directory.clone()
        }
        _ => moot_product_identity::storage::configuration_directory(),
    };
    // Duty limits and the Signal 14 cadence come from the same settings
    // directory (§ DUTY_LIFECYCLE).
    let duty_settings = moot_product_identity::settings::load(&fact_settings_directory);
    // Exits with a nonzero code when the estate cannot be opened (an
    // unreachable PostgreSQL estate fails fast here).
    let mut config = match ServerConfig::for_estate(estate) {
        Ok(config) => config,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(1);
        }
    };
    // Inject the host identity so rows filed by this server are stamped with
    // the correct source. The banner ("mootx01" for the product binary and the
    // aria-mcp dev binary alike) is the canonical name for whichever binary is
    // hosting the runtime. Mirrors Swift's `ToolDispatcher(serverIdentity:)`.
    config.registry.server_identity = banner.to_owned();
    // The MCP `serverInfo.name` reported to the client must match the host
    // identity too — otherwise the product (`mootx01 serve`) presents itself to
    // an MCP client as the stale default "ARIA_MCP_Rust". Drive it from the
    // banner so the Rust product reports "mootx01", byte-for-byte matching the
    // Swift product's `ServerInfo(name: "mootx01")` in ServeCommand.swift.
    config.server_name = banner.to_owned();
    config.version_skew = version_skew.to_owned();
    config.update_advisory = update_advisory;

    // Telemetry wiring (durable default for resident mode, opt-in for stdio).
    //
    // stats_store_path() resolves the moot-mgr stats store path from
    // the configuration directory in resident HTTP mode, and returns None for
    // stdio mode (telemetry off by default there). The ARIA_MCP_STATS_STORE
    // env override was removed (R6, 2026-09-08) to align with Swift.
    //
    // is_http_mode = MOOTX01_HTTP_PORT is set (determined here before the
    // transport branch below so telemetry is wired once before the governor
    // thread is spawned).
    let is_http_mode = !std::env::var("MOOTX01_HTTP_PORT")
        .unwrap_or_default()
        .is_empty();
    let mut gov_stats_store: Option<Arc<observer_sink::StatsStore>> = None;
    let stats_store_path_opt = stats_store_path(is_http_mode, None);
    if let Some(ref stats_store_path) = stats_store_path_opt {
        match observer_sink::StatsStore::new(stats_store_path) {
            Ok(store) => {
                if let Err(e) = store.open() {
                    eprintln!("{banner}: stats store open failed: {e:?}; telemetry disabled");
                } else {
                    // Read the persisted monitoring flag to drive the Intellectus
                    // gate — mirrors Swift's installManagerTelemetry which calls
                    // store.isMonitoringEnabled() rather than forcing it on.
                    // The moot-mgr manager sets the flag to "1" when it is ready to
                    // receive data; the daemon respects the persisted value so a
                    // restart does not toggle the operator's monitoring setting.
                    let store_flag = store.is_monitoring_enabled().unwrap_or(false);
                    let dropbox_id = format!("mootx01-rust-{}", config.registry.default.estate_id);
                    let store_arc = Arc::new(store);
                    gov_stats_store = Some(Arc::clone(&store_arc));
                    // The observer program (DEBT-3): a bounded RecentWindowSink
                    // forwarding to the durable PersistenceStatsSink, so a single
                    // installed sink both retains the in-process recent window AND
                    // persists. The window proves emitted samples are not dead
                    // letters; the store is the durable record moot-mgr reads.
                    let persistence_sink: Arc<dyn intellectus_lib::StatsSink> = Arc::new(
                        observer_sink::PersistenceStatsSink::new(store_arc, dropbox_id),
                    );
                    let window = Arc::new(intellectus_lib::RecentWindowSink::new(
                        OBSERVER_WINDOW_CAPACITY,
                        Some(persistence_sink),
                    ));
                    intellectus_lib::Intellectus::install(window);
                    // Enable when EITHER ARIA_MCP_OBSERVER is truthy (operator
                    // opt-in) OR the persisted store flag is on (moot-mgr's
                    // broadcast signal). Mirrors Swift Observer::should_enable.
                    let monitoring_on = observer_should_enable(store_flag);
                    intellectus_lib::Intellectus::set_enabled(monitoring_on);
                    eprintln!(
                        "{banner}: observer wired (stats store: {stats_store_path:?}, window: {OBSERVER_WINDOW_CAPACITY}, monitoring: {})",
                        if monitoring_on { "on" } else { "off" }
                    );
                }
            }
            Err(e) => {
                eprintln!("{banner}: stats store init failed: {e:?}; telemetry disabled");
            }
        }
    }

    // Transport select. stdio is the default (testing, migrations, one-shot).
    // When MOOTX01_HTTP_PORT is set, run the resident loopback HTTP MCP
    // transport plus the Autonomic Governor (ARIA_MCP_SPEC §17.1: the resident
    // daemon owns the Brain; stdio mode does NOT start the governor).
    let http_port = std::env::var("MOOTX01_HTTP_PORT").unwrap_or_default();
    if !http_port.is_empty() {
        let port: u16 = match http_port.parse() {
            Ok(p) => p,
            Err(_) => {
                eprintln!(
                    "{banner}: MOOTX01_HTTP_PORT={http_port:?} is not a valid TCP port (0–65535)"
                );
                std::process::exit(1);
            }
        };
        let max_body = parse_max_body_bytes(banner);

        // The governor and the HTTP transport share the same
        // Arc<Mutex<EstateCoordinator>>; the Mutex serializes access.
        let gov_coord = Arc::clone(&config.registry.coord);
        let gov_handle = config.registry.default.handle;
        let gov_store = Arc::clone(&config.registry.default.store);

        // Spawn and detach: run_http_loop below is the process-lifetime
        // anchor; on bind failure the process exits and the OS reaps the
        // governor thread.
        let http_stats_store = gov_stats_store.clone();

        std::thread::spawn(move || {
            // Build the host-injected topology sink from the stats store (if
            // configured). The governor holds the sink as Box<dyn
            // GovernorTopologySink>, keeping NeuronKit free of observer_sink.
            let topology_sink: Option<
                Box<dyn neuron_kit::governor_topology_sink::GovernorTopologySink>,
            > = gov_stats_store.map(|s| {
                Box::new(StatsStoreTopologySink::new(s))
                    as Box<dyn neuron_kit::governor_topology_sink::GovernorTopologySink>
            });
            // Snapshot the coord Arc and handle before they are moved into the
            // governor constructor. EstateHandle is Copy; Arc::clone is O(1).
            // These are used immediately after construction to inject the HNSW
            // maintenance adapter before the governor loop starts.
            let coord_for_hnsw = Arc::clone(&gov_coord);
            let handle_for_hnsw = gov_handle;
            let mut governor = AutonomicGovernor::new_with_topology_sink(
                gov_coord,
                gov_handle,
                gov_store,
                topology_sink,
            );
            // Wire the HNSW maintenance handle via the single named wiring point
            // (VEC-SHADOWSWAP-01, finding 13b8e1a). `configure_hnsw_from_registry`
            // locks the coordinator, reads the registered VectorStore for this estate,
            // and if present installs a `VectorStoreHNSWAdapter` via
            // `set_hnsw_maintenance`. A LocusOnly estate (no VectorStore) returns
            // false; BETA still runs the base EWC prune, which is correct.
            //
            // Coverage, stated precisely so nobody over-reads it: the
            // integration tests in AriaMcpKit drive
            // `configure_hnsw_from_registry` directly, so they discriminate
            // that the wiring FUNCTION works. They do not prove that THIS
            // line calls it. Deleting this line leaves the suite green.
            // Closing that last gap would need a construct-without-run seam
            // in this function, which today ends in a blocking `run_loop()`
            // inside a spawned thread. Keeping the wiring as one named call
            // is what makes the remaining risk a single reviewable line.
            configure_hnsw_from_registry(&mut governor, &coord_for_hnsw, &handle_for_hnsw);
            // Bootstrap the architecture-spec §11.2 default standing signals
            // before the loop starts, mirroring the Swift resident's
            // `kit.registerDefaultStandingSignals(...)` step. Best-effort: a
            // missing VectorStore (or any registration error) logs and the
            // governor still runs — `signal_tick` benign-skips exactly as
            // before activation. The signals' VectorStore is read from the live
            // coordinator inside `register_default_standing_signals`, so no
            // throwaway store is fabricated when none is registered. The model
            // id matches the Swift resident default ("minilm-v6").
            //
            // Live hunt closure (signal 10 — ContradictionScoutSignal): mirrors
            // Swift resident's `huntCycle: { now in kit.huntContradictions(...) }`.
            // Fires one incremental hunt pass over the last four hourly windows so
            // drawers filed between fires are never missed. `filed_after` is
            // DEFAULT_CADENCE_SECONDS * 4 ms ago. The hunt persists proposed
            // contradicts tunnels itself; the closure returns counts only
            // (single-write invariant, same as dreamingCycle).
            let hunt_coord = Arc::clone(&coord_for_hnsw);
            let hunt_handle = handle_for_hnsw;
            let hunt_cycle: Arc<dyn Fn() -> Result<(usize, usize), String> + Send + Sync> =
                Arc::new(move || {
                    let now_ms = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as i64;
                    // Four-cadence lookback: matches Swift resident's
                    // `filedAfter: now.addingTimeInterval(-ContradictionScoutSignal.defaultCadenceSeconds * 4)`.
                    // ContradictionScoutSignal::DEFAULT_CADENCE_SECONDS = 3 600 (1 hour).
                    let filed_after = now_ms.saturating_sub(
                        (genius_locus_kit::brain::signals::ContradictionScoutSignal::DEFAULT_CADENCE_SECONDS
                            * 4
                            * 1_000) as i64,
                    );
                    match hunt_coord.lock() {
                        Ok(coord) => coord
                            .hunt_contradictions(
                                &hunt_handle,
                                "minilm-v6",
                                50, // probe_limit: DEFAULT_PROBE_LIMIT from VectorSimilaritySignal
                                Some(filed_after),
                                64, // proximity_threshold: architecture-spec Hamming cap
                                now_ms,
                            )
                            .map(|report| (report.proposed.len(), report.borderline.len()))
                            .map_err(|e| format!("{e:?}")),
                        Err(e) => Err(format!("coordinator lock poisoned: {e}")),
                    }
                });
            // Live anomaly closure (signal 12 — AnomalySweepSignal): enqueue
            // only (§ DUTY_LIFECYCLE). The anomaly duty worker scores owed
            // rooms off the tick, and only the rooms touched since their last
            // scoring. Twin of the Swift resident's `anomalyCycle`.
            let anomaly_coord = Arc::clone(&coord_for_hnsw);
            let anomaly_handle = handle_for_hnsw;
            let anomaly_cycle: Arc<dyn Fn() -> Result<i64, String> + Send + Sync> = Arc::new(
                move || {
                    let now_ms = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as i64;
                    match anomaly_coord.lock() {
                        Ok(coord) => coord
                            .enqueue_duty(
                                &anomaly_handle,
                                genius_locus_kit::brain::duty_queue::DutyKind::AnomalySweep,
                                now_ms,
                            )
                            .map(|_| 0)
                            .map_err(|e| format!("{e:?}")),
                        Err(e) => Err(format!("coordinator lock poisoned: {e}")),
                    }
                },
            );
            // Live span-encode cycle (Encoder Rerank contract sheet §10):
            // mirrors the Swift resident's `spanEncodeCycle: { now in
            // kit.runSpanEncodeBatch(handle:now:) }`. Encodes drawers whose
            // bit 27 is clear under the registered encoder; 0 when no encoder
            // is active for the estate.
            let span_coord = Arc::clone(&coord_for_hnsw);
            let span_handle = handle_for_hnsw;
            let span_encode_cycle: Arc<dyn Fn() -> Result<i64, String> + Send + Sync> =
                Arc::new(move || {
                    let now_ms = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as i64;
                    // Enqueue only (§ DUTY_LIFECYCLE): the duty worker thread
                    // pays the batch off the tick.
                    match span_coord.lock() {
                        Ok(coord) => {
                            use genius_locus_kit::brain::duty_queue::DutyKind;
                            coord.enqueue_duty(&span_handle, DutyKind::SpanEncode, now_ms).map_err(|e| format!("{e:?}"))?;
                            Ok(0)
                        }
                        Err(e) => Err(format!("coordinator lock poisoned: {e}")),
                    }
                });
            // Signal 14 (FactExtractionDutySignal): activate the estate's
            // selected provider when the master setting is On. `None` is a
            // fail-quiet unavailable-provider result, not a server error.
            if let Ok(mut coord) = coord_for_hnsw.lock() {
                coord.configure_duty_limits(
                    &handle_for_hnsw,
                    genius_locus_kit::brain::duty_queue::DutyLimits::from_settings(&duty_settings),
                );
            }
            let fact_extraction_cycle = build_fact_extraction_cycle(
                &coord_for_hnsw,
                handle_for_hnsw.clone(),
                Some(&fact_settings_directory),
            );
            // The duty workers (§ DUTY_LIFECYCLE): the tick and the signals only
            // enqueue owed duties; ONE thread per duty pays ONE bounded batch per
            // cadence, off the tick, so a model-bound batch never stalls the
            // brain and a fast lane (span encode, 30 s) never waits behind a
            // slow one. Span and subject batches run under the coordinator (no
            // model call); the fact batch runs through the one-batch cycle,
            // which holds the coordinator only around the claim and the row
            // write. The two on-demand duties are drained when something queued
            // them, never enqueued here.
            {
                use genius_locus_kit::brain::duty_queue::DutyKind;
                use genius_locus_kit::brain::signals::SpanEncodeSignal;
                let fast = SpanEncodeSignal::DEFAULT_CADENCE_SECONDS.max(1);
                let cadence = duty_settings.duty_fact_extraction_cadence_seconds.max(1);
                let now_millis = || SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as i64;
                for (kind, seconds, enqueues) in [
                    (DutyKind::SpanEncode, fast, true),
                    (DutyKind::SubjectBackfill, cadence, true),
                    (DutyKind::AnomalySweep, cadence, true),
                    (DutyKind::FactsBackfill, fast, false),
                    (DutyKind::RetrainBasis, fast, false),
                ] {
                    let worker_coord = Arc::clone(&coord_for_hnsw);
                    let worker_handle = handle_for_hnsw.clone();
                    std::thread::spawn(move || loop {
                        let now_ms = now_millis();
                        if let Ok(mut coord) = worker_coord.lock() {
                            let queued = if enqueues {
                                coord.enqueue_duty(&worker_handle, kind, now_ms).map(|_| ())
                            } else { Ok(()) };
                            match queued.and_then(|_| coord.drain_duty(&worker_handle, kind, now_ms)) {
                                Ok(r) if r.jobs_run > 0 => eprintln!(
                                    "AriaResident duty {}: {} paid, {} remaining",
                                    kind.wire_name(), r.units_paid, r.remaining_debt),
                                Ok(_) => {}
                                Err(e) => eprintln!("AriaResident duty {} failed: {e:?}", kind.wire_name()),
                            }
                        }
                        std::thread::sleep(std::time::Duration::from_secs(seconds));
                    });
                }
                if let Some(cycle) = fact_extraction_cycle.clone() {
                    std::thread::spawn(move || loop {
                        match cycle() {
                            Ok(n) if n > 0 => eprintln!("AriaResident duty fact-extraction: {n} source(s) settled"),
                            Ok(_) => {}
                            Err(e) => eprintln!("AriaResident duty fact-extraction failed: {e}"),
                        }
                        std::thread::sleep(std::time::Duration::from_secs(cadence));
                    });
                }
            }
            // Signal 11 (ConsolidationSignal) and the contradiction sweep are
            // preference-gated: each cycle is built only when the estate's
            // switch is not Off, and `None` registers no signal at all.
            let consolidation_cycle = build_consolidation_cycle(&coord_for_hnsw, handle_for_hnsw);
            let contradiction_sweep_cycle =
                build_contradiction_sweep_cycle(&coord_for_hnsw, handle_for_hnsw);
            // Maintenance family (maintenance-daemon, decay-sweep,
            // by-reference-validity): each drives one category of the
            // governor's own maintenance engine and registers only while the
            // estate's `maintenance` preference is not Off. An unreadable
            // preference registers nothing, the same posture as the two
            // sweeps above. The governor tick does not pump the engine; these
            // signals are its only drive.
            let maintenance_on = read_estate_preference(
                &coord_for_hnsw,
                &handle_for_hnsw,
                genius_locus_kit::EstatePreferenceKey::Maintenance,
            )
            .map(|setting| setting != genius_locus_kit::EstatePreferenceValue::Off)
            .unwrap_or(false);
            let maintenance_cycle = governor.maintenance_tombstone_cycle();
            let decay_cycle = governor.maintenance_decay_cycle();
            let by_reference_cycle = governor.maintenance_by_reference_cycle();
            // Adaptive-recall trio (temporal-causality-fold, training-daemon,
            // end-of-day-tournament): the hourly T-population fold, the hourly
            // training-daemon tick over the coordinator's matrix tier, and the
            // daily tournament that folds the day's recall traces into
            // `recall_ratings`. Registered only while
            // the estate's `adaptive_recall` preference is not Off; an
            // unreadable preference registers nothing, the same posture as
            // the maintenance family above. Each fire locks the coordinator
            // and reads the wall clock once, like the other resident cycles.
            let adaptive_recall_on = read_estate_preference(
                &coord_for_hnsw,
                &handle_for_hnsw,
                genius_locus_kit::EstatePreferenceKey::AdaptiveRecall,
            )
            .map(|setting| setting != genius_locus_kit::EstatePreferenceValue::Off)
            .unwrap_or(false);
            let (fold_cycle, training_cycle, tournament_cycle) = {
                let fold_coord = Arc::clone(&coord_for_hnsw);
                let fold_handle = handle_for_hnsw;
                let fold_cycle: Arc<dyn Fn() -> Result<(), String> + Send + Sync> =
                    Arc::new(move || {
                        let now_ms = SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;
                        match fold_coord.lock() {
                            Ok(mut coord) => coord
                                .run_temporal_causality_fold(&fold_handle, now_ms)
                                .map_err(|e| format!("{e:?}")),
                            Err(e) => Err(format!("coordinator lock poisoned: {e}")),
                        }
                    });
                let training_coord = Arc::clone(&coord_for_hnsw);
                let training_handle = handle_for_hnsw;
                let training_cycle: Arc<dyn Fn() -> Result<String, String> + Send + Sync> =
                    Arc::new(move || {
                        let now_ms = SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;
                        match training_coord.lock() {
                            Ok(mut coord) => coord
                                .run_training_tick(&training_handle, now_ms)
                                .map_err(|e| format!("{e:?}")),
                            Err(e) => Err(format!("coordinator lock poisoned: {e}")),
                        }
                    });
                let tournament_coord = Arc::clone(&coord_for_hnsw);
                let tournament_handle = handle_for_hnsw;
                let tournament_cycle: Arc<
                    dyn Fn() -> Result<
                            genius_locus_kit::brain::end_of_day_tournament::TournamentReport,
                            String,
                        > + Send
                        + Sync,
                > = Arc::new(move || {
                    let now_ms = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as i64;
                    match tournament_coord.lock() {
                        Ok(coord) => coord
                            .end_of_day_tournament(&tournament_handle, now_ms)
                            .map_err(|e| format!("{e:?}")),
                        Err(e) => Err(format!("coordinator lock poisoned: {e}")),
                    }
                });
                (fold_cycle, training_cycle, tournament_cycle)
            };
            let consolidation_on = read_estate_preference(
                &coord_for_hnsw,
                &handle_for_hnsw,
                genius_locus_kit::EstatePreferenceKey::Consolidation,
            )
            .map(|v| v != genius_locus_kit::EstatePreferenceValue::Off)
            .unwrap_or(false);
            let contradiction_on = read_estate_preference(
                &coord_for_hnsw,
                &handle_for_hnsw,
                genius_locus_kit::EstatePreferenceKey::ContradictionSweep,
            )
            .map(|v| v != genius_locus_kit::EstatePreferenceValue::Off)
            .unwrap_or(false);
            let fact_on = read_estate_preference(
                &coord_for_hnsw,
                &handle_for_hnsw,
                genius_locus_kit::EstatePreferenceKey::FactExtraction,
            )
            .map(|v| v != genius_locus_kit::EstatePreferenceValue::Off)
            .unwrap_or(false);

            let registered = governor.register_default_standing_signals(
                "minilm-v6",
                SystemTime::now(),
                Some(hunt_cycle),
                Some(anomaly_cycle),
                Some(span_encode_cycle),
                if fact_on {
                    fact_extraction_cycle.clone()
                } else {
                    None
                },
                if consolidation_on {
                    consolidation_cycle.clone()
                } else {
                    None
                },
                if contradiction_on {
                    contradiction_sweep_cycle.clone()
                } else {
                    None
                },
                maintenance_on.then(|| Arc::clone(&maintenance_cycle)),
                maintenance_on.then(|| Arc::clone(&decay_cycle)),
                maintenance_on.then(|| Arc::clone(&by_reference_cycle)),
                adaptive_recall_on.then(|| Arc::clone(&fold_cycle)),
                adaptive_recall_on.then(|| Arc::clone(&training_cycle)),
                adaptive_recall_on.then(|| Arc::clone(&tournament_cycle)),
            );
            let mut registered_ids: HashMap<String, SchedulerSignalID> = match registered {
                Ok(registered) => {
                    eprintln!(
                        "AriaResident standing signals registered ({} defaults)",
                        registered.len()
                    );
                    registered.into_iter().collect()
                }
                Err(e) => {
                    eprintln!(
                        "AriaResident standing signals NOT registered (governor signal_tick will benign-skip): {e}"
                    );
                    HashMap::new()
                }
            };
            let reconcile_coord = Arc::clone(&coord_for_hnsw);
            governor.run_loop_with_before_tick(move |governor, now| {
                // Row-debt duties ride QueueKit (duty_queue): drain the duties
                // no signal owns (queued on the previous tick), then queue what
                // the estate owes now; the span and fact signals drain their
                // own streams inside their cycles. Twin of Swift `signalTick`.
                {
                    let now_ms = now
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as i64;
                    // Enqueue only (§ DUTY_LIFECYCLE): the duty worker thread
                    // pays the batches off the tick.
                    match reconcile_coord.lock() {
                        Ok(coord) => {
                            if let Err(e) = coord.enqueue_owed_duties(&handle_for_hnsw, now_ms) {
                                eprintln!("AriaResident duty enqueue failed: {e:?}");
                            }
                        }
                        Err(e) => eprintln!("AriaResident duty tick skipped — coordinator lock poisoned: {e}"),
                    }
                }
                let reconciliation = (|| -> Result<(), String> {
                    let enabled = |key| {
                        read_estate_preference(&reconcile_coord, &handle_for_hnsw, key)
                            .map(|v| v != genius_locus_kit::EstatePreferenceValue::Off)
                            .ok_or_else(|| format!("preference {} unreadable", key.as_str()))
                    };
                    reconcile_runtime_signal(
                        governor,
                        &mut registered_ids,
                        FactExtractionSignal::SIGNAL_NAME,
                        enabled(genius_locus_kit::EstatePreferenceKey::FactExtraction)?,
                        now,
                        || {
                            fact_extraction_cycle
                                .clone()
                                .map(|_cycle| {
                                    // Enqueue only (§ DUTY_LIFECYCLE): the duty
                                    // worker pays the batch off the tick.
                                    let signal_coord = Arc::clone(&coord_for_hnsw);
                                    let signal_handle = handle_for_hnsw.clone();
                                    FactExtractionSignal::spec_with_cadence(
                                        duty_settings.duty_fact_extraction_cadence_seconds,
                                        Arc::new(move || {
                                            let now_ms = SystemTime::now().duration_since(UNIX_EPOCH)
                                                .unwrap_or_default().as_millis() as i64;
                                            let coord = signal_coord.lock().map_err(|e| format!("coordinator lock poisoned: {e}"))?;
                                            coord.enqueue_duty(&signal_handle,
                                                genius_locus_kit::brain::duty_queue::DutyKind::FactExtraction, now_ms)
                                                .map(|_| 0)
                                                .map_err(|e| format!("{e:?}"))
                                        }))
                                })
                        },
                    )?;
                    reconcile_runtime_signal(
                        governor,
                        &mut registered_ids,
                        ConsolidationSignal::SIGNAL_NAME,
                        enabled(genius_locus_kit::EstatePreferenceKey::Consolidation)?,
                        now,
                        || {
                            consolidation_cycle
                                .clone()
                                .map(|cycle| ConsolidationSignal::spec(Arc::new(move || cycle())))
                        },
                    )?;
                    reconcile_runtime_signal(
                        governor,
                        &mut registered_ids,
                        ContradictionSweepSignal::SIGNAL_NAME,
                        enabled(genius_locus_kit::EstatePreferenceKey::ContradictionSweep)?,
                        now,
                        || {
                            contradiction_sweep_cycle.clone().map(|cycle| {
                                ContradictionSweepSignal::spec(Arc::new(move || cycle()))
                            })
                        },
                    )?;
                    let maintenance = enabled(genius_locus_kit::EstatePreferenceKey::Maintenance)?;
                    reconcile_runtime_signal(
                        governor,
                        &mut registered_ids,
                        MaintenanceSignal::SIGNAL_NAME,
                        maintenance,
                        now,
                        || {
                            let cycle = Arc::clone(&maintenance_cycle);
                            Some(MaintenanceSignal::spec(Arc::new(move || cycle())))
                        },
                    )?;
                    reconcile_runtime_signal(
                        governor,
                        &mut registered_ids,
                        DecaySweepSignal::SIGNAL_NAME,
                        maintenance,
                        now,
                        || {
                            let cycle = Arc::clone(&decay_cycle);
                            Some(DecaySweepSignal::spec(Arc::new(move || cycle())))
                        },
                    )?;
                    reconcile_runtime_signal(
                        governor,
                        &mut registered_ids,
                        ByReferenceValiditySignal::SIGNAL_NAME,
                        maintenance,
                        now,
                        || {
                            let cycle = Arc::clone(&by_reference_cycle);
                            Some(ByReferenceValiditySignal::spec(Arc::new(move || cycle())))
                        },
                    )?;
                    let adaptive = enabled(genius_locus_kit::EstatePreferenceKey::AdaptiveRecall)?;
                    reconcile_runtime_signal(
                        governor,
                        &mut registered_ids,
                        TemporalCausalitySignal::SIGNAL_NAME,
                        adaptive,
                        now,
                        || {
                            let cycle = Arc::clone(&fold_cycle);
                            Some(TemporalCausalitySignal::spec(Arc::new(move || cycle())))
                        },
                    )?;
                    reconcile_runtime_signal(
                        governor,
                        &mut registered_ids,
                        TrainingSignal::SIGNAL_NAME,
                        adaptive,
                        now,
                        || {
                            let cycle = Arc::clone(&training_cycle);
                            Some(TrainingSignal::spec(Arc::new(move || cycle())))
                        },
                    )?;
                    reconcile_runtime_signal(
                        governor,
                        &mut registered_ids,
                        EndOfDayTournamentSignal::SIGNAL_NAME,
                        adaptive,
                        now,
                        || {
                            let cycle = Arc::clone(&tournament_cycle);
                            Some(EndOfDayTournamentSignal::spec(Arc::new(move || cycle())))
                        },
                    )?;
                    Ok(())
                })();
                if reconciliation.is_err() {
                    fail_closed_runtime_signals(governor, &mut registered_ids);
                }
                reconciliation
            });
        });

        // Load the derived accelerators (matrix tier) once at launch so the
        // matrix-aware recall lane is live from the first query — parity with
        // Swift's ServeCommand, which kicks `rebuildDerivedAccelerators` in a
        // background Task on the resident daemon (and aria-mcp-server's
        // post-open rebuild). Runs in a detached thread so the HTTP transport
        // starts accepting calls immediately; matrix recall degrades to zeros
        // until the load finishes — correct degradation, not a stall.
        //
        // The GLK worker loads normalized records, folds count matrices forward,
        // recomputes decay, and publishes a complete generation in bounded row
        // batches. Existing counts can serve while refresh proceeds.
        //
        // RESIDENT ONLY: the matrix tier is a long-lived brain-layer structure
        // only the resident daemon's recall scoring + dreaming consume. This
        // branch is the resident-HTTP path; the stdio one-shot path below does
        // not build it, matching ServeCommand's `residentPort != nil` gate — a
        // one-shot query must not pay the load cost or persist a snapshot it
        // will never reuse.
        //
        // Hold the coordinator mutex only to obtain a ticket; never while waiting.
        // Concurrent dream/temporal requests coalesce inside the worker.
        let accel_coord = Arc::clone(&config.registry.coord);
        let accel_handle = config.registry.default.handle;
        std::thread::spawn(move || {
            let now = crate::dispatch::wall_now();
            let requested = {
                accel_coord.lock().unwrap()
                    .request_matrix_refresh(&accel_handle, now, Default::default(), false)
            };
            match requested {
                Ok((_, ticket)) => match ticket.wait() {
                    Ok(_) => eprintln!("derived accelerators rebuilt (background)"),
                    Err(e) => eprintln!("warning: matrix refresh failed: {e}"),
                },
                Err(e) => eprintln!("warning: matrix refresh request failed: {e:?}"),
            }
        });

        // Server-metrics task: emit transport counters via Intellectus every 30
        // seconds when monitoring is on (mirrors Swift AriaResident's
        // serverMetricsTask). Only spawned when telemetry is wired; "off is free"
        // preserved.
        //
        // Metric namespace mirrors the Swift server metrics exactly so dashboards
        // see the same series regardless of which vertical is running:
        //   server.rpc_count, server.connections, server.connections_hwm,
        //   server.4xx_count, server.5xx_count, server.shed_count,
        //   server.latency_ns_total, server.latency_fast/mid/slow_count
        // arch: arm64 in Rust targets Apple Silicon (macOS/iOS; the Rust binary
        // also runs on x86_64 Linux — kernel kind is "scalar" there).
        #[cfg(target_arch = "aarch64")]
        let kernel_kind = "simd";
        #[cfg(not(target_arch = "aarch64"))]
        let kernel_kind = "scalar";
        let proto_version = "2025-11-25";
        std::thread::spawn(move || {
            let interval = Duration::from_secs(30);
            loop {
                std::thread::sleep(interval);
                if !intellectus_lib::Intellectus::is_enabled() {
                    continue;
                }
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs_f64())
                    .unwrap_or(0.0);
                use std::sync::atomic::Ordering;
                let tags = std::collections::HashMap::from([(
                    "kit".to_string(),
                    "AriaResident".to_string(),
                )]);
                let emit = |name: &str, value: f64| {
                    intellectus_lib::Intellectus::report_sample(
                        intellectus_lib::StatSample::metric(
                            name.to_string(),
                            value,
                            tags.clone(),
                            now,
                        ),
                    );
                };
                emit(
                    "server.rpc_count",
                    GLOBAL_RPC_COUNTER.load(Ordering::Relaxed) as f64,
                );
                emit(
                    "server.connections",
                    GLOBAL_INFLIGHT_COUNTER.load(Ordering::Relaxed) as f64,
                );
                emit(
                    "server.connections_hwm",
                    GLOBAL_INFLIGHT_HWM.load(Ordering::Relaxed) as f64,
                );
                emit(
                    "server.4xx_count",
                    GLOBAL_4XX_COUNTER.load(Ordering::Relaxed) as f64,
                );
                emit(
                    "server.5xx_count",
                    GLOBAL_5XX_COUNTER.load(Ordering::Relaxed) as f64,
                );
                emit(
                    "server.shed_count",
                    GLOBAL_SHED_COUNTER.load(Ordering::Relaxed) as f64,
                );
                emit(
                    "server.latency_ns_total",
                    GLOBAL_LATENCY_NS_TOTAL.load(Ordering::Relaxed) as f64,
                );
                emit(
                    "server.latency_fast_count",
                    GLOBAL_LATENCY_FAST.load(Ordering::Relaxed) as f64,
                );
                emit(
                    "server.latency_mid_count",
                    GLOBAL_LATENCY_MID.load(Ordering::Relaxed) as f64,
                );
                emit(
                    "server.latency_slow_count",
                    GLOBAL_LATENCY_SLOW.load(Ordering::Relaxed) as f64,
                );
                // Protocol and kernel presence metrics.
                let mut ptags = tags.clone();
                ptags.insert("version".to_string(), proto_version.to_string());
                intellectus_lib::Intellectus::report_sample(intellectus_lib::StatSample::metric(
                    "server.proto_version".to_string(),
                    1.0,
                    ptags,
                    now,
                ));
                let mut ktags = tags.clone();
                ktags.insert("backend".to_string(), kernel_kind.to_string());
                intellectus_lib::Intellectus::report_sample(intellectus_lib::StatSample::metric(
                    "substrate.kernel.backend_selected".to_string(),
                    1.0,
                    ktags,
                    now,
                ));
            }
        });

        let listener = match bind_loopback(port) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("{}", http_bind_failure_line(banner, port, &e));
                std::process::exit(1);
            }
        };
        if let Err(e) = run_http_loop(listener, max_body, config, http_stats_store, None) {
            eprintln!("{}", http_serve_failure_line(banner, port, &e));
            std::process::exit(1);
        }
        eprintln!("{banner}: HTTP transport stopped, exiting");
    } else {
        let stdin = std::io::stdin();
        let stdout = std::io::stdout();
        let mut stdout = stdout.lock();
        run_stdio_loop(stdin.lock(), &mut stdout, config);
        eprintln!("{banner}: stdin closed, exiting");
    }
}

/// Resolve the stats-store path for telemetry wiring.
///
/// ## Enable path
///
/// Telemetry is opt-in for stdio (short-lived processes). For the resident
/// HTTP daemon (`MOOTX01_HTTP_PORT` set), the path is computed from the
/// product's configuration directory so the daemon self-reports without
/// operator configuration. Mirrors Swift
/// `AriaResident.statsStorePath(useDefault:configurationDirectory:)`.
///
/// Resolution:
///
/// - `use_default` is `false` (stdio mode) → return `None` (telemetry off).
/// - `use_default` is `true` (resident HTTP mode):
///   1. `daemon.stats_store` key in `<config-dir>/config.json` (R6 setting,
///      2026-09-09): a changeable value operators can edit without rebuilding.
///   2. Fallback: `<config-dir>/moot-mgr/stats.sqlite` (the same file
///      `moot-mgr`'s `resolve_store_path` targets when no override is set).
///
/// Note: this function runs on Linux and Windows, not on macOS (Swift owns
/// the macOS daemon). The absolute path differs per platform:
///   - Linux:   `${XDG_DATA_HOME:-~/.local/share}/mootx01/…`
///   - Windows: `%LOCALAPPDATA%\com.mootx01.ce\…`
///
/// The `config_dir` parameter is the directory that contains `config.json`.
/// Pass `None` in production (uses the product default). Pass `Some(dir)` in
/// tests to inject a scratch directory without touching the real config file.
/// Mirrors Swift `AriaResident.statsStorePath(useDefault:configurationDirectory:)`.
pub fn stats_store_path(use_default: bool, config_dir: Option<&std::path::Path>) -> Option<String> {
    if !use_default {
        // stdio mode: telemetry off by default.
        return None;
    }
    let owned;
    let dir: &std::path::Path = match config_dir {
        Some(p) => p,
        None => {
            owned = moot_product_identity::storage::configuration_directory();
            &owned
        }
    };
    // Step 1: check `config.json` in the configuration directory for an
    // operator-set path (R6, 2026-09-09). Reading through the injected
    // directory makes this testable without touching the real config file.
    if let Some(p) = moot_product_identity::settings::load(dir).daemon_stats_store {
        return Some(p);
    }
    // Step 2: computed default — the same file `resolve_store_path` targets
    // in manager_config.rs when no setting is set, so both processes open the
    // same store out of the box.
    Some(moot_product_identity::paths::daemon_stats_store_default(
        dir,
    ))
}

/// Resolve the HTTP request body cap from `MOOTX01_HTTP_MAX_BODY_BYTES`,
/// defaulting to 4 MiB. An invalid value falls back to the default with a
/// stderr note.
fn parse_max_body_bytes(banner: &str) -> usize {
    let raw = std::env::var("MOOTX01_HTTP_MAX_BODY_BYTES").unwrap_or_default();
    if raw.is_empty() {
        return 4 * 1024 * 1024;
    }
    match raw.parse::<usize>() {
        Ok(v) if v > 0 => v,
        _ => {
            eprintln!("{banner}: MOOTX01_HTTP_MAX_BODY_BYTES={raw:?} invalid; using 4 MiB default");
            4 * 1024 * 1024
        }
    }
}

// ---- Fact-extraction cycle (signal 14) ----------------------------------------

/// Batch limit per dreaming tick for fact-extraction signal 14.
///
/// 20 sources covers the typical burst for a single active user per governor
/// tick without blocking the governor for longer than a few seconds. Larger
/// backlogs are cleared across successive ticks, matching the Swift resident's
/// behaviour. Raising this constant is the only tuning lever — no runtime
/// setting is needed.

/// Prepare the signal-14 cycle for an already-built fact extractor.
/// Each invocation re-reads the live estate preference: Off returns zero without
/// activation; On activates the selected extractor and runs a bounded batch.
/// Deferring activation allows a later Off-to-On transition without rebuilding
/// the resident and prevents an Off tick from changing extraction state.
///
/// Called by `build_fact_extraction_cycle` in production after the
/// `NuExtractWorkerClient` is built. Called directly by tests with a stub
/// `FactExtractor` so the decision and activation path can be driven without
/// real model assets on disk.
///
/// `runtime.rs:326` always calls `build_fact_extraction_cycle`, never this
/// function directly.
///
/// A test that deletes the `Some` return in this function, removes the
/// `activate_fact_extractor` call, or breaks the cycle closure goes red on the
/// GSS-14b On-path gate in `fact_extraction_cycle_tests.rs`.
pub fn activate_and_build_extraction_cycle(
    extractor: Arc<dyn fact_extraction_kit::contract::FactExtractor>,
    coord: &Arc<std::sync::Mutex<genius_locus_kit::EstateCoordinator>>,
    handle: genius_locus_kit::EstateHandle,
) -> Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>> {
    extraction_cycle(extractor, coord, handle, false)
}

fn extraction_cycle(
    extractor: Arc<dyn fact_extraction_kit::contract::FactExtractor>,
    coord: &Arc<std::sync::Mutex<genius_locus_kit::EstateCoordinator>>,
    handle: genius_locus_kit::EstateHandle,
    settle: bool,
) -> Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>> {
    // Derive the recipe ID from the extractor's spec. Format is the cross-port
    // contract: "<provider_id>:<model_id>:<model_version>", identical to the
    // Swift twin. A recipe change clears bit 28 on all drawers estate-wide so
    // the full corpus is re-extracted against the new model.
    let spec = extractor.spec();
    let recipe_id = format!(
        "{}:{}:{}",
        spec.provider_id, spec.model_id, spec.model_version
    );

    // Activate the extractor. A changed recipe clears bit 28 on all drawers
    // estate-wide so the full corpus is re-extracted against the new model. A
    // registration failure logs and degrades gracefully — the daemon continues
    // serving without signal 14.
    // Build the cycle closure that `register_default_standing_signals` schedules
    // as signal 14. Returns the sources settled as i64 per the standing-signal
    // contract. The coordinator Arc is cloned into the closure; the Mutex
    // serializes access so dreaming ticks are safe.
    let fact_coord = Arc::clone(coord);
    let fact_handle = handle;
    let cycle: Arc<dyn Fn() -> Result<i64, String> + Send + Sync> = Arc::new(move || {
      let mut settled = 0;
      let mut lease_waits = 0;
      loop {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        let (work, jobs) = {
                let mut coord = fact_coord.lock().map_err(|e| format!("coordinator lock poisoned: {e}"))?;
                let setting = coord
                    .provisioned_preference(
                        &fact_handle,
                        genius_locus_kit::EstatePreferenceKey::FactExtraction,
                    )
                    .map_err(|e| format!("{e:?}"))?;
                if setting == genius_locus_kit::EstatePreferenceValue::Off {
                    return Ok(settled);
                }
                coord
                    .activate_fact_extractor(Arc::clone(&extractor), &recipe_id, &fact_handle)
                    .map_err(|e| format!("{e:?}"))?;
                // The batch runs as a claimed QueueKit job (duty_queue): the
                // tick queued the owed duty, this cycle drains its stream.
                coord
                    .enqueue_duty(&fact_handle, genius_locus_kit::brain::duty_queue::DutyKind::FactExtraction, now_ms)
                    .map_err(|e| format!("{e:?}"))?;
                let limit = coord.duty_limits(&fact_handle).fact_extraction_batch;
                let work = coord.prepare_fact_extraction_batch(&fact_handle, limit, now_ms)
                    .map_err(|e| format!("{e:?}"))?;
                if work.is_none() {
                    // The extractor is registered, so no batch means another
                    // process holds the stream lease. In the settle cycle wait
                    // out the lease TTL (a dead holder clears after one) a few
                    // times before reading "held" as settled.
                    if settle && lease_waits < 4
                        && coord.duty_debt(&fact_handle,
                            genius_locus_kit::brain::duty_queue::DutyKind::FactExtraction).unwrap_or(0) > 0
                    {
                        lease_waits += 1;
                        drop(coord);
                        std::thread::sleep(std::time::Duration::from_secs_f64(queuekit::DRAIN_LEASE_TTL_SECS + 1.0));
                        continue;
                    }
                    return Ok(settled);
                }
                let jobs = coord.claim_duty_jobs(&fact_handle,
                    genius_locus_kit::brain::duty_queue::DutyKind::FactExtraction, now_ms)
                    .map_err(|e| format!("{e:?}"))?;
                if jobs.is_empty() { return Ok(settled); }
                (work, jobs)
        };
        // No coordinator mutex is held during model inference or framed I/O.
        let result = work.map(|work| work.run()).transpose();
        let coord = fact_coord.lock().map_err(|e| format!("coordinator lock poisoned: {e}"))?;
        for job in jobs { coord.complete_duty_job(&fact_handle, &job, result.is_ok()); }
        if let Ok(Some(report)) = &result {
            if report.made_progress {
                coord.enqueue_duty(&fact_handle,
                    genius_locus_kit::brain::duty_queue::DutyKind::FactExtraction, now_ms)
                    .map_err(|e| format!("{e:?}"))?;
            }
        }
        let report = result.map_err(|e| format!("{e:?}"))?;
        let made_progress = report.as_ref().is_some_and(|report| report.made_progress);
        let completed = report.as_ref().map_or(0, |report| report.completed_sources as i64);
        settled += completed;
        if settle {
            let remaining = coord.duty_debt(&fact_handle,
                genius_locus_kit::brain::duty_queue::DutyKind::FactExtraction).unwrap_or(0);
            eprintln!("mootx01 drain: fact-extraction — {completed} paid, {remaining} remaining");
        }
        if !settle { return Ok(settled); }
        if !made_progress {
            // No progress plus something retrying is a wait, not settlement:
            // sleep out the earliest scheduled retry (at most 120 s; a
            // malformed response retries at 30 s, longer backoffs mean
            // provider trouble) and try again. A blocked provider is not
            // waited for.
            let status = coord.fact_extraction_work_status(&fact_handle, now_ms).map_err(|e| format!("{e:?}"))?;
            let wait = status.next_retry_at.map(|at| at - now_ms as f64 / 1000.0);
            match wait {
                Some(secs) if status.retrying > 0 && secs <= 120.0 => {
                    drop(coord);
                    std::thread::sleep(std::time::Duration::from_secs_f64(secs.max(0.0) + 1.0));
                    continue;
                }
                _ => return Ok(settled),
            }
        }
        // Drop the coordinator guard before the next batch. Deferred failures
        // never keep the settle loop spinning; enqueue requires ready work.
      }
    });
    Some(cycle)
}

/// Read one on/off estate preference through the coordinator. `None` when
/// the lock is poisoned or the read fails; the caller treats `None` as Off
/// so a preference that cannot be read never schedules its signal.
fn read_estate_preference(
    coord: &Arc<std::sync::Mutex<genius_locus_kit::EstateCoordinator>>,
    handle: &genius_locus_kit::EstateHandle,
    key: genius_locus_kit::EstatePreferenceKey,
) -> Option<genius_locus_kit::EstatePreferenceValue> {
    let coord_guard = coord.lock().ok()?;
    coord_guard.provisioned_preference(handle, key).ok()
}

/// Build the consolidation-sweep cycle (signal 11) for `handle`.
/// Each fire runs one bounded `consolidation_sweep_report` pass under the
/// default `ConsolidationConfig` with no candidate-limit override; the
/// sweep persists its vague drawers itself and the closure returns only the
/// report. Mirrors the Swift resident's `consolidationCycle` wiring.
pub fn build_consolidation_cycle(
    coord: &Arc<std::sync::Mutex<genius_locus_kit::EstateCoordinator>>,
    handle: genius_locus_kit::EstateHandle,
) -> Option<
    Arc<
        dyn Fn() -> Result<
                genius_locus_kit::brain::consolidation_cycle::ConsolidationSweepReport,
                String,
            > + Send
            + Sync,
    >,
> {
    let sweep_coord = Arc::clone(coord);
    Some(Arc::new(move || {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        match sweep_coord.lock() {
            Ok(coord) => coord
                .consolidation_sweep_report(
                    &handle,
                    now_ms,
                    &genius_locus_kit::brain::consolidation_cycle::ConsolidationConfig::default(),
                    None,
                )
                .map_err(|e| format!("{e:?}")),
            Err(e) => Err(format!("coordinator lock poisoned: {e}")),
        }
    }))
}

/// Build the contradiction-sweep cycle for `handle`. Registration is reconciled
/// against the live `contradiction_sweep` preference before every tick. Each
/// fire runs one `propose_conflict_tunnels` pass under the resident's
/// embedding model ("minilm-v6"), a 50-row probe limit and a lexical top-k
/// of 10; the pass persists its tunnels itself and the closure returns only
/// the report. Mirrors the Swift resident's `contradictionSweepCycle` wiring.
pub fn build_contradiction_sweep_cycle(
    coord: &Arc<std::sync::Mutex<genius_locus_kit::EstateCoordinator>>,
    handle: genius_locus_kit::EstateHandle,
) -> Option<
    Arc<
        dyn Fn() -> Result<
                genius_locus_kit::brain::conflict_projection_sweep::ConflictTunnelProposalReport,
                String,
            > + Send
            + Sync,
    >,
> {
    let sweep_coord = Arc::clone(coord);
    Some(Arc::new(move || {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        match sweep_coord.lock() {
            Ok(coord) => coord
                .propose_conflict_tunnels(&handle, "minilm-v6", 50, 10, now_ms)
                .map_err(|e| format!("{e:?}")),
            Err(e) => Err(format!("coordinator lock poisoned: {e}")),
        }
    }))
}

/// Build a fact-extraction signal-14 cycle when the selected Rust provider and
/// its assets are available. The returned cycle checks FactExtraction on every
/// tick and activates the provider only while enabled.
///
/// - Selector `Nuextract` with configured or bundled readable worker assets
///   returns `Some(cycle)` without activation at construction.
/// - Selector `Apple` or unavailable NuExtract assets returns `None`; the daemon
///   continues serving.
///
/// `config_dir` is the settings-module directory selected by the host. Product
/// serve passes the install directory for registered estates and the estate's
/// own directory for transient estates; tests pass a scratch directory.
///
/// Activation and cycle construction delegate to `activate_and_build_extraction_cycle`.
pub fn build_fact_extraction_cycle(
    coord: &Arc<std::sync::Mutex<genius_locus_kit::EstateCoordinator>>,
    handle: genius_locus_kit::EstateHandle,
    config_dir: Option<&std::path::Path>,
) -> Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>> {
    configured_extraction_cycle(coord, handle, config_dir, false)
}

/// The settle cycle for the `drain` finisher (§ DUTY_LIFECYCLE): the same
/// claimed jobs as the resident, repeated while a batch makes progress, with
/// one progress line per batch. The resident and `dream` run one bounded batch.
pub fn build_fact_extraction_settle_cycle(
    coord: &Arc<std::sync::Mutex<genius_locus_kit::EstateCoordinator>>,
    handle: genius_locus_kit::EstateHandle,
    config_dir: Option<&std::path::Path>,
) -> Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>> {
    configured_extraction_cycle(coord, handle, config_dir, true)
}

/// Install the host's duty limits on `handle` from the settings directory
/// (`config_dir`, else the product configuration directory). Called by every
/// host that pays a duty: the resident, `dream`, `drain`.
pub fn configure_duty_limits_from_settings(
    coord: &Arc<std::sync::Mutex<genius_locus_kit::EstateCoordinator>>,
    handle: &genius_locus_kit::EstateHandle,
    config_dir: Option<&std::path::Path>,
) {
    let owned;
    let dir: &std::path::Path = match config_dir {
        Some(dir) => dir,
        None => { owned = moot_product_identity::storage::configuration_directory(); &owned }
    };
    let settings = moot_product_identity::settings::load(dir);
    if let Ok(mut coord) = coord.lock() {
        coord.configure_duty_limits(
            handle,
            genius_locus_kit::brain::duty_queue::DutyLimits::from_settings(&settings),
        );
    }
}

fn configured_extraction_cycle(
    coord: &Arc<std::sync::Mutex<genius_locus_kit::EstateCoordinator>>,
    handle: genius_locus_kit::EstateHandle,
    config_dir: Option<&std::path::Path>,
    settle: bool,
) -> Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>> {
    // The second preference selects the provider. Apple Foundation Models is
    // an Apple-only runtime; the Rust product fails quiet when it is selected.
    let extractor_setting = {
        let coord_guard = coord.lock().ok()?;
        coord_guard
            .provisioned_preference(
                &handle,
                genius_locus_kit::EstatePreferenceKey::FactExtractor,
            )
            .ok()?
    };
    if extractor_setting == genius_locus_kit::EstatePreferenceValue::Apple {
        eprintln!(
            "AriaResident: fact_extractor=apple is unavailable on the Rust product; signal 14 inactive"
        );
        return None;
    }

    // Step 2: resolve the configuration directory and load any Rust-port path
    // overrides from config.json. Swift-only keys are ignored by the parser.
    let owned_dir;
    let dir: &std::path::Path = match config_dir {
        Some(p) => p,
        None => {
            owned_dir = moot_product_identity::storage::configuration_directory();
            &owned_dir
        }
    };
    let settings = moot_product_identity::settings::load(dir);
    let current_executable = std::env::current_exe().ok();
    let sibling_worker = current_executable
        .as_deref()
        .and_then(std::path::Path::parent)
        .map(|directory| directory.join("moot-nuextract-worker"));
    let configured_model_directory = dir.join("models").join("nuextract-tiny-v1.5");
    let bundled_model_directory = current_executable
        .as_deref()
        .and_then(std::path::Path::parent)
        .and_then(std::path::Path::parent)
        .map(|directory| directory.join("share/mootx01/models/nuextract-tiny-v1.5"));
    let default_model_directory = [Some(configured_model_directory), bundled_model_directory]
        .into_iter()
        .flatten()
        .find(|directory| {
            directory.join("model.gguf").is_file() && directory.join("tokenizer.json").is_file()
        });

    let worker_exe = settings
        .fact_extraction_worker_executable
        .map(std::path::PathBuf::from)
        .or(sibling_worker);
    let gguf = settings
        .fact_extraction_gguf
        .map(std::path::PathBuf::from)
        .or_else(|| {
            default_model_directory
                .as_ref()
                .map(|d| d.join("model.gguf"))
        });
    let tokenizer = settings
        .fact_extraction_tokenizer
        .map(std::path::PathBuf::from)
        .or_else(|| {
            default_model_directory
                .as_ref()
                .map(|d| d.join("tokenizer.json"))
        });
    let model_version = settings
        .fact_extraction_model_version
        .unwrap_or_else(|| "63e2e80c804d9c97f3f19a4aa25613e7beca83c9".into());
    let (worker_exe, gguf, tokenizer) = match (worker_exe, gguf, tokenizer) {
        (Some(worker), Some(model), Some(tokenizer)) => (worker, model, tokenizer),
        _ => {
            eprintln!(
                "AriaResident: NuExtract is selected but no configured or bundled worker/model is available; signal 14 inactive"
            );
            return None;
        }
    };

    // Step 3: build the worker client. Fails quietly when the binary or model
    // files are unreadable (validate() checks that each path is a regular file).
    let config = fact_extraction_kit_providers::NuExtractWorkerConfig::tiny_v1_5(
        worker_exe,
        gguf,
        tokenizer,
        &model_version,
    );
    let client = match fact_extraction_kit_providers::NuExtractWorkerClient::new(config) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("AriaResident: NuExtract worker unavailable (signal 14 inactive): {e}");
            return None;
        }
    };

    // Step 4: delegate activation and cycle construction to the testable seam.
    // The returned closure re-reads the authoritative estate setting before
    // each activation and extraction batch.
    let client: Arc<dyn fact_extraction_kit::contract::FactExtractor> = Arc::new(client);
    extraction_cycle(client, coord, handle, settle)
}

// -------------------------------------------------------------------------------

/// Build the user-visible error line for a TCP bind failure.
///
/// This message is emitted when `bind_loopback(port)` itself returns `Err`.
/// The listener does not exist yet, so the failure is specifically that the
/// address could not be claimed — distinct from a serve failure that happens
/// after the socket is already bound.
fn http_bind_failure_line(banner: &str, port: u16, error: &std::io::Error) -> String {
    format!("{banner}: cannot bind HTTP transport on 127.0.0.1:{port}: {error}")
}

/// Build the user-visible error line for a serve loop failure.
///
/// This message is emitted when `run_http_loop` returns `Err`. At that point
/// the listener is already bound; the error comes from `local_addr()` failing
/// on the handed-in socket (the only fallible expression in `serve_http` that
/// propagates through `run_http_loop`). Naming a bind failure here would be
/// false: the bind already succeeded.
fn http_serve_failure_line(banner: &str, port: u16, error: &std::io::Error) -> String {
    format!("{banner}: HTTP transport on 127.0.0.1:{port} failed while serving: {error}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::estate_registry::EstateRegistry;

    fn preference_test_governor() -> AutonomicGovernor {
        let registry = EstateRegistry::new_inmemory();
        let base = std::env::temp_dir().join(format!("sec11-reconcile-{}", uuid::Uuid::new_v4()));
        AutonomicGovernor::new_for_testing_with_pool(
            Arc::clone(&registry.coord),
            registry.default.handle,
            Arc::clone(&registry.default.store),
            300_000,
            None,
            0,
            base.join("pool"),
            base.join("WordClassTable.json"),
        )
    }

    #[test]
    fn preference_signal_reconciles_on_off_on() {
        let mut governor = preference_test_governor();
        let mut ids = HashMap::new();
        let now = UNIX_EPOCH + Duration::from_secs(1);
        let make_spec = || Some(FactExtractionSignal::spec(Arc::new(|| Ok(0))));

        reconcile_runtime_signal(
            &mut governor,
            &mut ids,
            FactExtractionSignal::SIGNAL_NAME,
            true,
            now,
            make_spec,
        )
        .unwrap();
        assert!(ids.contains_key(FactExtractionSignal::SIGNAL_NAME));
        reconcile_runtime_signal(
            &mut governor,
            &mut ids,
            FactExtractionSignal::SIGNAL_NAME,
            false,
            now,
            || None,
        )
        .unwrap();
        assert!(!ids.contains_key(FactExtractionSignal::SIGNAL_NAME));
        reconcile_runtime_signal(
            &mut governor,
            &mut ids,
            FactExtractionSignal::SIGNAL_NAME,
            true,
            now,
            make_spec,
        )
        .unwrap();
        assert!(ids.contains_key(FactExtractionSignal::SIGNAL_NAME));
    }

    #[test]
    fn preference_read_failure_unregisters_managed_signals() {
        let mut governor = preference_test_governor();
        let mut ids = HashMap::new();
        let now = UNIX_EPOCH + Duration::from_secs(1);
        for name in [
            FactExtractionSignal::SIGNAL_NAME,
            MaintenanceSignal::SIGNAL_NAME,
        ] {
            reconcile_runtime_signal(&mut governor, &mut ids, name, true, now, || {
                Some(FactExtractionSignal::spec(Arc::new(|| Ok(0))))
            })
            .unwrap();
        }
        fail_closed_runtime_signals(&mut governor, &mut ids);
        assert!(ids.is_empty());
    }

    /// The serve-failure message must NOT claim a bind failure.  A bind
    /// failure and a serve failure are distinct: the bind arm fires before any
    /// socket exists; the serve arm fires on a socket that is already bound.
    /// Mixing them up makes the operator look in the wrong place.
    #[test]
    fn serve_failure_line_does_not_claim_a_bind_failure() {
        let err = std::io::Error::new(std::io::ErrorKind::Other, "test error");
        let line = http_serve_failure_line("mootx01", 8765, &err);
        assert!(
            !line.contains("cannot bind"),
            "serve-failure line must not say 'cannot bind', got: {line:?}"
        );
        assert!(
            line.contains("127.0.0.1:8765"),
            "serve-failure line must include address, got: {line:?}"
        );
        assert!(
            line.contains("failed while serving"),
            "serve-failure line must name serving failure, got: {line:?}"
        );
    }

    /// The bind-failure line must keep the exact wording that shipped, byte
    /// for byte.  Any change to the message string would silently break
    /// operators' log parsers that grep for it.
    #[test]
    fn bind_failure_line_keeps_the_shipped_wording() {
        let err = std::io::Error::new(std::io::ErrorKind::AddrInUse, "address already in use");
        let line = http_bind_failure_line("mootx01", 8765, &err);
        assert_eq!(
            line,
            format!("mootx01: cannot bind HTTP transport on 127.0.0.1:8765: {err}"),
        );
    }

    /// Prove that handing `run_http_loop` a non-socket file descriptor makes it
    /// return `Err`, and that the resulting error, rendered through
    /// `http_serve_failure_line`, names a serve failure rather than a bind
    /// failure. What this covers is `run_http_loop`'s `Err` return and the line
    /// built from it, which confirms the error path is real rather than
    /// hypothetical. The serve arm inside `run()` is not reachable from a test,
    /// because `std::process::exit(1)` follows the `eprintln`; that the arm
    /// passes the serve builder rather than the bind builder is held by review.
    #[cfg(unix)]
    #[test]
    fn run_http_loop_error_is_a_serve_failure_not_a_bind_failure() {
        use std::os::fd::OwnedFd;

        // A regular file descriptor returns ENOTSOCK from local_addr(), so
        // serve_http returns Err before reaching accept().  This is the safe
        // route: we own the OwnedFd and TcpListener takes ownership.
        let file = std::fs::File::open("/dev/null").expect("open /dev/null");
        let listener = std::net::TcpListener::from(OwnedFd::from(file));

        let config = crate::server::ServerConfig::default_inmemory();
        let result = run_http_loop(listener, 4 * 1024 * 1024, config, None, None);
        assert!(
            result.is_err(),
            "expected Err from run_http_loop with a non-socket fd"
        );

        let err = result.unwrap_err();
        let line = http_serve_failure_line("mootx01", 8765, &err);
        assert!(
            !line.contains("cannot bind"),
            "serve-failure line must not say 'cannot bind', got: {line:?}"
        );
        assert!(
            line.contains("failed while serving"),
            "serve-failure line must name serving failure, got: {line:?}"
        );
    }
}
