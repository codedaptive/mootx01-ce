// resident_host.rs — Rust twin of the Swift moot-mgr ResidentHost.swift.
//
// The long-lived resident host: a single process that
//   1. Owns the MootManager (and therefore the ObserverSink stats store).
//   2. Owns the EstateAdmin engine (the admin/control plane).
//   3. Serves the loopback HTTP read-API (HttpReadApi, 127.0.0.1 only).
//   4. Exposes the gated control channel over a Unix domain socket (0600).
//   5. Runs the retention loop on the configured cadence.
//
// This is the "two-plane" host: the read plane (HTTP) and the admin/control
// plane (UDS + token-gated HTTP control), kept separate by surface and by auth,
// both fed from the one owned store.
//
// ── Necessary Rust shape difference (documented) ──────────────────────────────
// The Swift host is an actor composing other actors, with the retention loop as
// a detached Task. The synchronous Rust host owns its manager + admin directly
// and exposes a `run_retention_tick(now)` the binary's serve loop calls on the
// configured cadence (the binary owns the timer thread). The clock boundary is
// the caller's: every tick takes `now` explicitly, so determinism holds.
// The HTTP listener + UDS control channel are owned by the host and started in
// `start`; the serve loops run on dedicated threads spun up by the binary.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::estate_admin::EstateAdmin;
use crate::manager::{ManagerError, MootManager};
use crate::manager_config::ManagerConfig;

/// Env var overriding the loopback HTTP read-API port.
pub const HTTP_PORT_ENV_KEY: &str = "MOOT_MGR_HTTP_PORT";
/// Env var supplying the bearer token gating the HTTP control surface.
pub const CONTROL_TOKEN_ENV_KEY: &str = "MOOT_MGR_CONTROL_TOKEN";
/// Env var overriding the UDS control-socket path.
pub const CONTROL_SOCKET_ENV_KEY: &str = "MOOT_MGR_CONTROL_SOCKET";
/// Env var overriding the admin-plane estates directory.
pub const ESTATES_DIR_ENV_KEY: &str = "MOOT_MGR_ESTATES_DIR";

/// Default loopback HTTP port for the read-API. Mirrors Swift
/// `ResidentHostConfig.defaultHTTPPort`.
pub const DEFAULT_HTTP_PORT: u16 = 4200;

/// How many ports above the default the host will try when the port was not
/// explicitly requested (spec §3: default hunts upward; explicit is exact).
pub const HUNT_RANGE: u16 = 100;

/// Configuration for the resident host: the manager config plus the host's own
/// network surfaces. Mirrors Swift `ResidentHostConfig`.
#[derive(Debug, Clone)]
pub struct ResidentHostConfig {
    /// The manager (store + retention) configuration.
    pub manager: ManagerConfig,
    /// TCP port for the loopback HTTP read-API (0 = OS-assigned, handy for tests).
    pub http_port: u16,
    /// Bearer token gating the HTTP control surface. Must be >= 16 chars to be
    /// honoured (see `HttpReadApi::is_authorized`).
    pub control_token: String,
    /// Filesystem path for the gated control UDS (created at 0600).
    pub control_socket_path: String,
    /// Directory under which the admin plane creates SQLite-backed estate stores.
    pub estates_directory: String,
    /// Whether `http_port` was explicitly requested (env/flag). Explicit means
    /// exact — a busy port fails. When false (the built-in default), `start`
    /// hunts upward from `http_port` to the first bindable port (spec §3).
    pub http_port_explicit: bool,
    /// Whether to maintain the §3 `mgr.port` file. True for the production
    /// `from_environment` path; false for memberwise (test/embedded) hosts so
    /// parallel tests never touch the live machine's port file.
    pub write_port_file: bool,
}

impl ResidentHostConfig {
    /// Memberwise constructor (used by tests).
    pub fn new(
        manager: ManagerConfig,
        http_port: u16,
        control_token: impl Into<String>,
        control_socket_path: impl Into<String>,
        estates_directory: impl Into<String>,
    ) -> Self {
        ResidentHostConfig {
            manager,
            http_port,
            control_token: control_token.into(),
            control_socket_path: control_socket_path.into(),
            estates_directory: estates_directory.into(),
            // Memberwise construction (tests, embedders) is an explicit choice
            // of port: exact bind, no hunting, no §3 port file.
            http_port_explicit: true,
            write_port_file: false,
        }
    }

    /// Resolve a resident-host config from the environment, reusing
    /// `ManagerConfig::from_environment` for the store/retention parts. The
    /// control socket and estates dir default next to the store file; the control
    /// token has NO default (an empty token disables the HTTP control surface —
    /// the UDS, gated by 0600, still works). Mirrors Swift
    /// `ResidentHostConfig.fromEnvironment()`.
    pub fn from_environment() -> Self {
        let env: HashMap<String, String> = std::env::vars().collect();
        let manager = ManagerConfig::from_environment_map(&env);
        let store_dir = std::path::Path::new(&manager.store_path)
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| std::path::PathBuf::from("."));
        let http_port_explicit = env.contains_key(HTTP_PORT_ENV_KEY)
            && env
                .get(HTTP_PORT_ENV_KEY)
                .map(|s| !s.is_empty())
                .unwrap_or(false);
        let http_port = env
            .get(HTTP_PORT_ENV_KEY)
            .and_then(|s| s.parse::<u16>().ok())
            .unwrap_or(DEFAULT_HTTP_PORT);
        let control_token = env.get(CONTROL_TOKEN_ENV_KEY).cloned().unwrap_or_default();
        let control_socket_path = env.get(CONTROL_SOCKET_ENV_KEY).cloned().unwrap_or_else(|| {
            store_dir
                .join("control.sock")
                .to_string_lossy()
                .into_owned()
        });
        let estates_directory = env.get(ESTATES_DIR_ENV_KEY).cloned().unwrap_or_else(|| {
            store_dir.join("estates").to_string_lossy().into_owned()
        });
        ResidentHostConfig {
            manager,
            http_port,
            control_token,
            control_socket_path,
            estates_directory,
            http_port_explicit,
            write_port_file: true,
        }
    }
}

/// The resident multi-plane host process for moot-mgr. Mirrors Swift `ResidentHost`.
///
/// The manager + admin are shared behind an `Arc<Mutex<…>>` so the HTTP read-API
/// + control channel (which serve connections on dedicated threads) and the
/// retention tick can reach them through one serialized owner — the Rust
/// equivalent of the Swift actor isolation around the open store.
pub struct ResidentHost {
    config: ResidentHostConfig,
    manager: Arc<Mutex<MootManager>>,
    admin: Arc<Mutex<EstateAdmin>>,
    start_instant_epoch: f64,
    api: Option<Arc<crate::http_read_api::HttpReadApi>>,
    control: Option<crate::control_channel::ControlChannel>,
}

/// Best-effort: keep the resident host's memory — including decrypted estate
/// content held in RAM — out of the swap file. Non-fatal: when the memlock limit
/// can't be raised we lock only resident pages and never request `MCL_FUTURE`
/// (which could fail future allocations under a low `RLIMIT_MEMLOCK` and abort).
#[cfg(unix)]
fn lock_memory_from_swap() {
    // SAFETY: setrlimit/mlockall are plain libc syscalls with no aliasing concerns.
    unsafe {
        let unlimited = libc::rlimit {
            rlim_cur: libc::RLIM_INFINITY,
            rlim_max: libc::RLIM_INFINITY,
        };
        let raised = libc::setrlimit(libc::RLIMIT_MEMLOCK, &unlimited) == 0;
        let flags = if raised {
            libc::MCL_CURRENT | libc::MCL_FUTURE
        } else {
            libc::MCL_CURRENT
        };
        if libc::mlockall(flags) != 0 {
            eprintln!(
                "moot-mgr: mlockall failed ({}); RAM swap-protection off \
                 (estate data is still encrypted at rest)",
                std::io::Error::last_os_error()
            );
        }
    }
}

#[cfg(not(unix))]
fn lock_memory_from_swap() {
    // Windows: per-region VirtualLock only; not applied process-wide here.
}

impl ResidentHost {
    /// Create a resident host. `start_instant_epoch` is the host start time
    /// (uptime base) in epoch seconds — injected so uptime is deterministic in
    /// tests. Mirrors Swift `ResidentHost.init(config:startInstant:clock:)`.
    pub fn new(config: ResidentHostConfig, start_instant_epoch: f64) -> Self {
        let manager = Arc::new(Mutex::new(MootManager::new(config.manager.clone())));
        let admin = Arc::new(Mutex::new(EstateAdmin::new(config.estates_directory.clone())));
        ResidentHost {
            config,
            manager,
            admin,
            start_instant_epoch,
            api: None,
            control: None,
        }
    }

    /// Start the host: open the store, then bring up the read-API and the gated
    /// UDS control channel. The retention loop is driven by the binary's timer
    /// thread via `run_retention_tick`. Mirrors Swift `ResidentHost.start()`.
    ///
    /// Port selection (spec §3): an explicitly requested port binds exactly —
    /// busy fails. The built-in default hunts upward from `http_port` by
    /// retrying the bind on the next candidate (no probe race) up to
    /// `HUNT_RANGE` ports. Whatever port binds is written to the `mgr.port`
    /// file in the mootx01 data dir and removed on `stop()`.
    pub fn start(&mut self) -> Result<(), ManagerError> {
        // Keep this resident host's memory (incl. decrypted estate content held
        // in RAM) out of the swap file. Best-effort; encrypted at rest regardless.
        lock_memory_from_swap();
        // Ensure the shared whole-file database key exists in the estates
        // directory before any estate is provisioned or opened, so estates this
        // host manages are encrypted at rest. Every estate opener resolves the
        // sibling db.key, so the daemon and this host share the key for any
        // directory they both touch.
        persistence_kit::ensure_install_key(std::path::Path::new(&self.config.estates_directory))?;
        self.manager.lock().unwrap().start()?;

        let candidates: Vec<u16> = if self.config.http_port_explicit {
            vec![self.config.http_port]
        } else {
            (0..=HUNT_RANGE)
                .map(|i| self.config.http_port.saturating_add(i))
                .collect()
        };
        let mut api_result: Option<Arc<crate::http_read_api::HttpReadApi>> = None;
        let mut last_err: Option<String> = None;
        for port in candidates {
            let api = Arc::new(crate::http_read_api::HttpReadApi::new(
                Arc::clone(&self.manager),
                Arc::clone(&self.admin),
                port,
                self.config.control_token.clone(),
                self.start_instant_epoch,
            ));
            match api.clone().start() {
                Ok(()) => {
                    if port != self.config.http_port {
                        eprintln!(
                            "moot-mgr: port {} busy; hunted to {port}",
                            self.config.http_port
                        );
                    }
                    self.config.http_port = port;
                    api_result = Some(api);
                    break;
                }
                Err(e) => last_err = Some(format!("{e}")),
            }
        }
        let api = api_result.ok_or_else(|| ManagerError::Storage {
            reason: format!(
                "HTTP read-API bind failed: {}",
                last_err.unwrap_or_else(|| "no bindable port".into())
            ),
        })?;

        let control = crate::control_channel::ControlChannel::new(
            Arc::clone(&api),
            self.config.control_socket_path.clone(),
        );
        control.start().map_err(|e| ManagerError::Storage {
            reason: format!("control channel bind failed: {e}"),
        })?;

        // §3 port file: record the bound port for status/dashboard discovery
        // (production hosts only — see `write_port_file`).
        if self.config.write_port_file {
            let bound = api.bound_port();
            let port_file = mgr_port_file_path();
            if let Some(dir) = port_file.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            if let Err(e) = std::fs::write(&port_file, format!("{bound}\n")) {
                eprintln!(
                    "moot-mgr: cannot write port file {}: {e} (continuing)",
                    port_file.display()
                );
            }
        }

        self.api = Some(api);
        self.control = Some(control);
        Ok(())
    }

    /// Stop the host: tear down both surfaces, close the store. Idempotent.
    /// Mirrors Swift `ResidentHost.stop()`.
    pub fn stop(&mut self) {
        if let Some(control) = self.control.take() {
            control.stop();
        }
        if let Some(api) = self.api.take() {
            api.stop();
            // Clean-shutdown removal of the §3 port file (only when we wrote it).
            if self.config.write_port_file {
                let _ = std::fs::remove_file(mgr_port_file_path());
            }
        }
        self.manager.lock().unwrap().stop();
    }

    /// The HTTP port actually bound (resolves an OS-assigned port when 0 was
    /// given). Mirrors Swift `ResidentHost.boundHTTPPort()`.
    pub fn bound_http_port(&self) -> u16 {
        self.api
            .as_ref()
            .map(|a| a.bound_port())
            .unwrap_or(self.config.http_port)
    }

    /// The owned manager, for in-process consumers/tests. Mirrors Swift
    /// `ResidentHost.managerHandle()`.
    pub fn manager_handle(&self) -> Arc<Mutex<MootManager>> {
        Arc::clone(&self.manager)
    }

    /// The owned admin engine, for in-process consumers/tests. Production callers
    /// reach admin verbs only through the gated control surface; this handle is
    /// for the in-process read reflection and tests. Mirrors Swift
    /// `ResidentHost.adminHandle()`.
    pub fn admin_handle(&self) -> Arc<Mutex<EstateAdmin>> {
        Arc::clone(&self.admin)
    }

    /// Run one retention pass with the caller-supplied clock. The binary's
    /// retention-loop thread calls this every `retention_cadence_secs`. The loop
    /// owns the clock boundary (determinism applies to the store engines, which
    /// receive the computed cutoff — not to the host's own timer). Mirrors the
    /// body of the Swift `ResidentHost.startRetentionLoop` tick.
    pub fn run_retention_tick(&self, now_epoch: f64) -> Result<usize, ManagerError> {
        self.manager.lock().unwrap().run_retention(now_epoch)
    }

    /// The retention cadence in seconds (how often the binary's loop should tick).
    pub fn retention_cadence_secs(&self) -> i64 {
        self.config.manager.retention_cadence_secs
    }
}

/// The mootx01 data dir, honoring `MOOTX01_DATA_DIR`. Mirrors the mootx01 CLI's
/// data-dir resolution (apps/mootx01/rust core::paths): macOS
/// `~/Library/Application Support/ai.mootx01.ce`, Windows `%LOCALAPPDATA%\MOOTx01`,
/// elsewhere `${XDG_DATA_HOME:-~/.local/share}/mootx01`. Both `mgr.port` and the
/// daemon's `daemon.port` live under this directory.
pub fn mootx01_data_dir() -> std::path::PathBuf {
    use std::path::PathBuf;
    if let Ok(v) = std::env::var("MOOTX01_DATA_DIR") {
        if !v.is_empty() {
            return PathBuf::from(v);
        }
    }
    #[cfg(target_os = "macos")]
    {
        let home = std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."));
        home.join("Library/Application Support/ai.mootx01.ce")
    }
    #[cfg(target_os = "windows")]
    {
        let base = std::env::var("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("."));
        base.join("MOOTx01")
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        let base = std::env::var("XDG_DATA_HOME")
            .ok()
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                std::env::var("HOME")
                    .map(|h| PathBuf::from(h).join(".local").join("share"))
                    .unwrap_or_else(|_| PathBuf::from("."))
            });
        base.join("mootx01")
    }
}

/// §3 `mgr.port` location — `<data>/mgr.port`.
pub fn mgr_port_file_path() -> std::path::PathBuf {
    mootx01_data_dir().join("mgr.port")
}

/// §3 `daemon.port` location — `<data>/daemon.port`, where the mootx01 daemon
/// writes the port it actually bound. moot-mgr reads this to reach the daemon
/// rather than guessing 4242 (the daemon hunts off 4242 with `--http auto`).
pub fn daemon_port_file_path() -> std::path::PathBuf {
    mootx01_data_dir().join("daemon.port")
}
