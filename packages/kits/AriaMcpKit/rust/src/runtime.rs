//! runtime.rs — the full server runtime: backend selection, telemetry
//! wiring, transport select (stdio vs resident HTTP + Autonomic Governor).
//!
//! Extracted verbatim from the binary's `main.rs` so that BOTH entry points —
//! the `aria-mcp` dev binary and the product `mootx01 serve` (apps/mootx01/rust)
//! — run the identical resident-daemon logic from one source of truth. The
//! caller prepares the environment (`ARIA_MCP_SQLITE_PATH`,
//! `MOOTX01_HTTP_PORT`, `ARIA_MCP_STATS_STORE`, …) and calls `run()`; this
//! function does not return until the transport stops (stdin closes, or the
//! HTTP loop exits). On fatal config errors it exits the process, same as
//! the original main.

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use neuron_kit::autonomic_governor::AutonomicGovernor;
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
/// hosting the runtime.
pub fn run(banner: &str) {
    eprintln!("{banner}: starting Rust MCP server");
    // from_env reads ARIA_MCP_POSTGRES_URL and ARIA_MCP_SQLITE_PATH and applies
    // the four-state precedence ladder. Exits with a nonzero code on ambiguous
    // config or an unusable path/URL (unreachable PostgreSQL fails fast here).
    let mut config = ServerConfig::from_env();
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

    // Telemetry wiring (durable default for resident mode, opt-in for stdio).
    //
    // stats_store_path_from_env() resolves: ARIA_MCP_STATS_STORE env override
    // first; if absent in resident HTTP mode, the moot-mgr platform default
    // path (<data-dir>/com.mootx01.ce/moot-mgr/stats.sqlite). stdio mode
    // returns None when the env var is absent (telemetry off by default there).
    //
    // is_http_mode = MOOTX01_HTTP_PORT is set (determined here before the
    // transport branch below so telemetry is wired once before the governor
    // thread is spawned).
    let is_http_mode = !std::env::var("MOOTX01_HTTP_PORT").unwrap_or_default().is_empty();
    let mut gov_stats_store: Option<Arc<observer_sink::StatsStore>> = None;
    let stats_store_path_opt = stats_store_path_from_env(is_http_mode);
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
            let mut governor = AutonomicGovernor::new_with_topology_sink(
                gov_coord, gov_handle, gov_store, topology_sink,
            );
            // Bootstrap the architecture-spec §11.2 default standing signals
            // before the loop starts, mirroring the Swift resident's
            // `kit.registerDefaultStandingSignals(...)` step. Best-effort: a
            // missing VectorStore (or any registration error) logs and the
            // governor still runs — `signal_tick` benign-skips exactly as
            // before activation. The signals' VectorStore is read from the live
            // coordinator inside `register_default_standing_signals`, so no
            // throwaway store is fabricated when none is registered. The model
            // id matches the Swift resident default ("minilm-v6").
            match governor.register_default_standing_signals("minilm-v6", SystemTime::now()) {
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
/// HTTP daemon (`MOOTX01_HTTP_PORT` set), a platform default is computed so
/// the daemon self-reports out-of-the-box without operator configuration.
///
/// Resolution order:
///
/// 1. `ARIA_MCP_STATS_STORE` set and non-empty → use that exact path.
/// 2. `use_default` is `true` (resident HTTP mode) → fall back to
///    `<data-dir>/com.mootx01.ce/moot-mgr/stats.sqlite`:
///    - Linux:   `~/.local/share/com.mootx01.ce/moot-mgr/stats.sqlite`
///    - macOS:   `~/Library/Application Support/com.mootx01.ce/moot-mgr/stats.sqlite`
///    - Windows: `%LOCALAPPDATA%\com.mootx01.ce\moot-mgr\stats.sqlite`
///    - Fallback (home var absent): `/tmp/...` on POSIX, `.\...` on Windows.
///    This is the same file the `moot-mgr` manager process owns.
/// 3. `use_default` is `false` (stdio mode) → return `None` (telemetry off).
///
/// Mirrors Swift `AriaResident.statsStorePathFromEnv(env:useDefault:)` (Apple-
/// only; the Windows branch is Rust-only since Swift has no Windows target).
pub fn stats_store_path_from_env(use_default: bool) -> Option<String> {
    let raw = std::env::var("ARIA_MCP_STATS_STORE").unwrap_or_default();
    if !raw.is_empty() {
        return Some(raw);
    }
    if !use_default {
        // stdio mode: no default — telemetry off unless explicitly configured.
        return None;
    }
    // Resident HTTP mode: compute the moot-mgr default path.
    //
    // Path: <data-dir>/com.mootx01.ce/moot-mgr/stats.sqlite
    //   Linux:   ~/.local/share  (XDG_DATA_HOME, or ~/.local/share as fallback)
    //   macOS:   ~/Library/Application Support
    //   Windows: %LOCALAPPDATA%  (USERPROFILE\AppData\Local as fallback)
    //
    // The store file and its parent directories are created by SqliteStorage
    // when StatsStore::new opens the connection — no pre-creation needed here.
    #[cfg(target_os = "macos")]
    let base = {
        // macOS: $HOME/Library/Application Support
        std::env::var("HOME")
            .map(|h| format!("{h}/Library/Application Support"))
            .unwrap_or_else(|_| "/tmp".to_string())
    };
    #[cfg(target_os = "windows")]
    let base = {
        // Windows: %LOCALAPPDATA% — there is no XDG and no /tmp. USERPROFILE\
        // AppData\Local is the fallback when LOCALAPPDATA is unset; "." is the
        // last resort (avoids the bare "/tmp" that does not exist on Windows).
        std::env::var("LOCALAPPDATA")
            .ok()
            .filter(|s| !s.is_empty())
            .or_else(|| std::env::var("USERPROFILE").ok().map(|h| format!("{h}\\AppData\\Local")))
            .unwrap_or_else(|| ".".to_string())
    };
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let base = {
        // Linux / other: XDG_DATA_HOME if set, else ~/.local/share
        std::env::var("XDG_DATA_HOME")
            .or_else(|_| std::env::var("HOME").map(|h| format!("{h}/.local/share")))
            .unwrap_or_else(|_| "/tmp".to_string())
    };
    Some(format!("{base}/com.mootx01.ce/moot-mgr/stats.sqlite"))
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
