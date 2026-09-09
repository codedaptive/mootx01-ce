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

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use neuron_kit::autonomic_governor::AutonomicGovernor;
use crate::dream_runner::configure_hnsw_from_registry;
use crate::governor_topology_adapter::StatsStoreTopologySink;
use crate::http_server::{
    run_http_loop, GLOBAL_4XX_COUNTER, GLOBAL_5XX_COUNTER, GLOBAL_INFLIGHT_COUNTER,
    GLOBAL_INFLIGHT_HWM, GLOBAL_LATENCY_FAST, GLOBAL_LATENCY_MID, GLOBAL_LATENCY_NS_TOTAL,
    GLOBAL_LATENCY_SLOW, GLOBAL_RPC_COUNTER, GLOBAL_SHED_COUNTER,
};
use crate::server::{run_stdio_loop, ServerConfig};

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
    let is_http_mode = !std::env::var("MOOTX01_HTTP_PORT").unwrap_or_default().is_empty();
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
                    let store_flag = store.is_monitoring_enabled()
                        .unwrap_or(false);
                    let dropbox_id = format!(
                        "mootx01-rust-{}",
                        config.registry.default.estate_id
                    );
                    let store_arc = Arc::new(store);
                    gov_stats_store = Some(Arc::clone(&store_arc));
                    // The observer program (DEBT-3): a bounded RecentWindowSink
                    // forwarding to the durable PersistenceStatsSink, so a single
                    // installed sink both retains the in-process recent window AND
                    // persists. The window proves emitted samples are not dead
                    // letters; the store is the durable record moot-mgr reads.
                    let persistence_sink: Arc<dyn intellectus_lib::StatsSink> =
                        Arc::new(observer_sink::PersistenceStatsSink::new(
                            store_arc,
                            dropbox_id,
                        ));
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
                eprintln!("{banner}: MOOTX01_HTTP_PORT={http_port:?} is not a valid TCP port (0–65535)");
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
            let topology_sink: Option<Box<dyn neuron_kit::governor_topology_sink::GovernorTopologySink>> =
                gov_stats_store.map(|s| Box::new(StatsStoreTopologySink::new(s))
                    as Box<dyn neuron_kit::governor_topology_sink::GovernorTopologySink>);
            // Snapshot the coord Arc and handle before they are moved into the
            // governor constructor. EstateHandle is Copy; Arc::clone is O(1).
            // These are used immediately after construction to inject the HNSW
            // maintenance adapter before the governor loop starts.
            let coord_for_hnsw = Arc::clone(&gov_coord);
            let handle_for_hnsw = gov_handle;
            let mut governor = AutonomicGovernor::new_with_topology_sink(
                gov_coord, gov_handle, gov_store, topology_sink,
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
                                50,  // probe_limit: DEFAULT_PROBE_LIMIT from VectorSimilaritySignal
                                Some(filed_after),
                                64,  // proximity_threshold: architecture-spec Hamming cap
                                now_ms,
                            )
                            .map(|report| (report.proposed.len(), report.borderline.len()))
                            .map_err(|e| format!("{e:?}")),
                        Err(e) => Err(format!("coordinator lock poisoned: {e}")),
                    }
                });
            // Live anomaly closure (signal 12 — AnomalySweepSignal, P3a):
            // mirrors Swift resident's `anomalyCycle: { now in
            // kit.anomalyFlagSweep(handle:now:) }`. Uses the architecture-spec
            // default threshold (ANOMALY_SWEEP_DEFAULT_THRESHOLD = 2.0),
            // matching Swift's default-threshold parameter path. Returns the
            // count of drawers whose bit 26 (is_anomalous) changed state.
            let anomaly_coord = Arc::clone(&coord_for_hnsw);
            let anomaly_handle = handle_for_hnsw;
            let anomaly_cycle: Arc<dyn Fn() -> Result<i64, String> + Send + Sync> =
                Arc::new(move || {
                    let now_ms = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as i64;
                    match anomaly_coord.lock() {
                        Ok(coord) => coord
                            .anomaly_flag_sweep(
                                &anomaly_handle,
                                genius_locus_kit::brain::anomaly_flag_sweep::ANOMALY_SWEEP_DEFAULT_THRESHOLD,
                                now_ms,
                            )
                            .map(|count| count as i64)
                            .map_err(|e| format!("{e:?}")),
                        Err(e) => Err(format!("coordinator lock poisoned: {e}")),
                    }
                });
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
                    match span_coord.lock() {
                        Ok(coord) => coord.run_span_encode_batch(&span_handle, now_ms),
                        Err(e) => Err(format!("coordinator lock poisoned: {e}")),
                    }
                });
            match governor.register_default_standing_signals(
                "minilm-v6",
                SystemTime::now(),
                Some(hunt_cycle),
                Some(anomaly_cycle),
                Some(span_encode_cycle),
            ) {
                Ok(registered) => {
                    eprintln!(
                        "AriaResident standing signals registered ({} defaults)",
                        registered.len()
                    );
                }
                Err(e) => {
                    eprintln!(
                        "AriaResident standing signals NOT registered (governor signal_tick will benign-skip): {e}"
                    );
                }
            }
            governor.run_loop();
        });

        // Load the derived accelerators (matrix tier) once at launch so the
        // matrix-aware recall lane is live from the first query — parity with
        // Swift's ServeCommand, which kicks `rebuildDerivedAccelerators` in a
        // background Task on the resident daemon (and aria-mcp-server's
        // post-open rebuild). Runs in a detached thread so the HTTP transport
        // starts accepting calls immediately; matrix recall degrades to zeros
        // until the load finishes — correct degradation, not a stall.
        //
        // `rebuild_derived_accelerators` LOADS the persisted on-disk matrix
        // snapshot (MatrixSnapshotStore) and folds only the audit tail past its
        // watermark forward — it does NOT recompute the whole matrix from the
        // audit log on every launch. The first launch on a fresh estate
        // full-rebuilds once and persists; every launch after that is a cheap
        // load + tail fold. Without this the tier stays nil until the first
        // dreaming cycle, so a freshly-launched daemon scores every matrix
        // column 0.0 and the persisted snapshot is never read back.
        //
        // RESIDENT ONLY: the matrix tier is a long-lived brain-layer structure
        // only the resident daemon's recall scoring + dreaming consume. This
        // branch is the resident-HTTP path; the stdio one-shot path below does
        // not build it, matching ServeCommand's `residentPort != nil` gate — a
        // one-shot query must not pay the load cost or persist a snapshot it
        // will never reuse.
        //
        // The coordinator is shared with the governor behind a Mutex, so a
        // concurrent dream rebuild is serialized, not a race.
        let accel_coord = Arc::clone(&config.registry.coord);
        let accel_handle = config.registry.default.handle;
        std::thread::spawn(move || {
            let now = crate::dispatch::wall_now();
            match accel_coord
                .lock()
                .unwrap()
                .rebuild_derived_accelerators(&accel_handle, now)
            {
                Ok(()) => eprintln!("derived accelerators rebuilt (background)"),
                Err(e) => eprintln!(
                    "warning: derived accelerator rebuild failed: {}",
                    crate::interface_tools::describe_verb_dispatch_error(&e)
                ),
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
                let tags = std::collections::HashMap::from([
                    ("kit".to_string(), "AriaResident".to_string()),
                ]);
                let emit = |name: &str, value: f64| {
                    intellectus_lib::Intellectus::report_sample(
                        intellectus_lib::StatSample::metric(
                            name.to_string(), value, tags.clone(), now,
                        )
                    );
                };
                emit("server.rpc_count",          GLOBAL_RPC_COUNTER.load(Ordering::Relaxed) as f64);
                emit("server.connections",         GLOBAL_INFLIGHT_COUNTER.load(Ordering::Relaxed) as f64);
                emit("server.connections_hwm",     GLOBAL_INFLIGHT_HWM.load(Ordering::Relaxed) as f64);
                emit("server.4xx_count",           GLOBAL_4XX_COUNTER.load(Ordering::Relaxed) as f64);
                emit("server.5xx_count",           GLOBAL_5XX_COUNTER.load(Ordering::Relaxed) as f64);
                emit("server.shed_count",          GLOBAL_SHED_COUNTER.load(Ordering::Relaxed) as f64);
                emit("server.latency_ns_total",    GLOBAL_LATENCY_NS_TOTAL.load(Ordering::Relaxed) as f64);
                emit("server.latency_fast_count",  GLOBAL_LATENCY_FAST.load(Ordering::Relaxed) as f64);
                emit("server.latency_mid_count",   GLOBAL_LATENCY_MID.load(Ordering::Relaxed) as f64);
                emit("server.latency_slow_count",  GLOBAL_LATENCY_SLOW.load(Ordering::Relaxed) as f64);
                // Protocol and kernel presence metrics.
                let mut ptags = tags.clone();
                ptags.insert("version".to_string(), proto_version.to_string());
                intellectus_lib::Intellectus::report_sample(
                    intellectus_lib::StatSample::metric(
                        "server.proto_version".to_string(), 1.0, ptags, now,
                    )
                );
                let mut ktags = tags.clone();
                ktags.insert("backend".to_string(), kernel_kind.to_string());
                intellectus_lib::Intellectus::report_sample(
                    intellectus_lib::StatSample::metric(
                        "substrate.kernel.backend_selected".to_string(), 1.0, ktags, now,
                    )
                );
            }
        });

        if let Err(e) = run_http_loop(port, max_body, config, http_stats_store) {
            eprintln!("{banner}: cannot bind HTTP transport on 127.0.0.1:{port}: {e}");
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
    Some(
        moot_product_identity::paths::daemon_stats_store_default(dir),
    )
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
