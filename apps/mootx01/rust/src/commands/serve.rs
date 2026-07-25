//! commands/serve.rs — §4.1: host the ARIA MCP server.
//!
//! Thin translation of spec flags onto the aria-mcp runtime's environment
//! contract, then a single call into `aria_mcp::runtime::run` — the same
//! function the `aria-mcp` dev binary calls, so both entry points run
//! identical resident-daemon logic.
//!
//! Flag → env translation:
//!   --db <name>   → ARIA_MCP_SQLITE_PATH = <data>/databases/<name>/estate.sqlite
//!                   (skipped when the caller already set ARIA_MCP_POSTGRES_URL
//!                   or ARIA_MCP_SQLITE_PATH — explicit env wins, and setting
//!                   both would trip from_env's ambiguity exit)
//!   --http auto   → hunt 4242 upward to the first free port (§3)
//!   --http <port> → exact; busy means exit 1, never hunt (§3)
//!   (neither)     → MOOTX01_HTTP_PORT env if the caller set it, else stdio
//!
//! Whatever port the daemon binds is written to `<data>/daemon.port` and
//! best-effort removed when the runtime returns (§3).

use std::net::TcpListener;
use std::path::Path;
use std::process::ExitCode;

use crate::cli::HttpMode;
use crate::core::daemon_client;
use crate::core::mcp_ownership;
use crate::core::paths;
use crate::core::release;
use crate::core::update_advisor;
use crate::exit;

/// How many ports above 4242 `auto` will probe before giving up.
const HUNT_RANGE: u16 = 100;
/// §3 default daemon port.
const DEFAULT_PORT: u16 = 4242;

/// Best-effort: keep the daemon's memory — including decrypted estate content
/// held in RAM during operations — out of the swap file. Non-fatal: if the
/// memlock limit can't be raised (insufficient privilege) we lock only the
/// currently-resident pages and never request `MCL_FUTURE`, which could fail
/// future allocations under a low `RLIMIT_MEMLOCK` and abort the process. The
/// estate file is encrypted at rest on disk regardless.
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
                "mootx01: mlockall failed ({}); RAM swap-protection off \
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

pub fn run(db: Option<String>, http: Option<HttpMode>) -> ExitCode {
    // Keep the daemon's memory (incl. decrypted estate content held in RAM) out
    // of the swap file. Best-effort; the estate is encrypted at rest regardless.
    lock_memory_from_swap();
    let data = paths::data_dir();

    // Estate selection. Explicit backend env vars win over --db; otherwise
    // resolve the named (or active) estate to a SQLite path.
    let postgres_set = env_nonempty("ARIA_MCP_POSTGRES_URL");
    let sqlite_set = env_nonempty("ARIA_MCP_SQLITE_PATH");
    if !postgres_set && !sqlite_set {
        let name = db.unwrap_or_else(|| paths::active_estate(&data));
        let estate = paths::estate_sqlite_path(&data, &name);
        if let Some(dir) = estate.parent() {
            if let Err(e) = std::fs::create_dir_all(dir) {
                eprintln!("mootx01: cannot create estate directory {}: {e}", dir.display());
                return ExitCode::from(exit::FAILURE);
            }
            // Ensure the shared whole-file database key exists in the estate
            // directory before the estate is opened, so the estate is encrypted
            // at rest. Any process opening a file in this directory resolves the
            // same db.key, so the daemon and moot-mgr share the key.
            if let Err(e) = aria_mcp::ensure_install_key(dir) {
                eprintln!(
                    "mootx01: cannot prepare estate encryption key in {}: {e}",
                    dir.display()
                );
                return ExitCode::from(exit::FAILURE);
            }
        }
        std::env::set_var("ARIA_MCP_SQLITE_PATH", &estate);
        eprintln!("mootx01: estate '{name}' at {}", estate.display());
    } else if db.is_some() {
        eprintln!(
            "mootx01: --db ignored (ARIA_MCP_POSTGRES_URL / ARIA_MCP_SQLITE_PATH set explicitly)"
        );
    }

    // Transport selection + port hunting (§3).
    let bound_port: Option<u16> = match http {
        Some(HttpMode::Port(p)) => {
            // Explicit means exact: fail if busy, never hunt.
            if !port_free(p) {
                eprintln!(
                    "mootx01: port {p} is in use and was requested explicitly; \
                     not hunting. Free the port or use --http auto."
                );
                return ExitCode::from(exit::FAILURE);
            }
            std::env::set_var("MOOTX01_HTTP_PORT", p.to_string());
            Some(p)
        }
        Some(HttpMode::Auto) => match hunt(DEFAULT_PORT, HUNT_RANGE) {
            Some(p) => {
                if p != DEFAULT_PORT {
                    eprintln!("mootx01: port {DEFAULT_PORT} busy; hunted to {p}");
                }
                std::env::set_var("MOOTX01_HTTP_PORT", p.to_string());
                Some(p)
            }
            None => {
                eprintln!(
                    "mootx01: no free port in {DEFAULT_PORT}–{}",
                    DEFAULT_PORT + HUNT_RANGE
                );
                return ExitCode::from(exit::FAILURE);
            }
        },
        None => {
            // Env-driven daemon mode (service units may set MOOTX01_HTTP_PORT
            // directly). Explicit env is exact per §3 — validate it parses;
            // the runtime enforces bind failure as exit 1.
            match std::env::var("MOOTX01_HTTP_PORT") {
                Ok(v) if !v.is_empty() => match v.parse::<u16>() {
                    Ok(p) => Some(p),
                    Err(_) => {
                        eprintln!(
                            "mootx01: MOOTX01_HTTP_PORT={v:?} is not a valid TCP port (0–65535)"
                        );
                        return ExitCode::from(exit::FAILURE);
                    }
                },
                _ => None, // stdio
            }
        }
    };

    // T4 — forward, don't collide. If this is an stdio serve and a LIVE resident
    // already serves THIS estate, forward stdin JSON-RPC to it over loopback HTTP
    // (the same bridge `mootx01 proxy` uses) instead of opening the estate as a
    // second direct writer. "Same estate" = the resident's recorded estate path
    // matches ours; liveness = the recorded port answering on loopback. If the
    // marker is stale (no resident answering), fall through and open directly.
    if bound_port.is_none() {
        if let Ok(estate) = std::env::var("ARIA_MCP_SQLITE_PATH") {
            let marker = data.join("mootx01.estate");
            let same_estate = std::fs::read_to_string(&marker)
                .map(|s| s.trim() == estate)
                .unwrap_or(false);
            if same_estate {
                let port = daemon_client::resolved_port();
                if daemon_client::alive(port) {
                    eprintln!(
                        "mootx01: a live resident already serves this estate \u{2014} forwarding stdio to the daemon on 127.0.0.1:{port} instead of opening a second writer (T4)"
                    );
                    return crate::commands::proxy::run(Some(format!("http://127.0.0.1:{port}")));
                }
                eprintln!(
                    "mootx01: estate marker present but no resident reachable on 127.0.0.1:{port} (stale marker) \u{2014} opening the estate directly"
                );
            }
        }
    }

    // §3: whatever port the daemon binds is written to daemon.port and
    // removed on clean shutdown. The resident daemon also writes mootx01.pid
    // (status reports it) and mootx01.estate (the served-estate marker a stdio
    // serve reads for T4 forwarding), and enforces the single-writer rule: one
    // resident AutonomicGovernor per estate. Liveness is the
    // recorded port answering on loopback — portable where kill(pid, 0) is not.
    // An stdio serve either forwards to a live resident (T4, above) or opens the
    // estate directly; it files none of these markers.
    let port_file = paths::daemon_port_file(&data);
    let pid_file = data.join("mootx01.pid");
    if let Some(p) = bound_port {
        if let Some(prev) = paths::read_port_file(&port_file) {
            // Liveness = a real mootx01 daemon ANSWERS on the recorded port,
            // not merely that the port is occupied. `!port_free(prev)` is true
            // for ANY listener (a reused socket, an unrelated service, moot-mgr's
            // dashboard) and would falsely refuse to start — the Swift port
            // correctly checks the owning PID's liveness. Probe the daemon the
            // same way the T4 stdio-forward path does (daemon_client::alive).
            if prev != p && daemon_client::alive(prev) {
                eprintln!(
                    "mootx01: estate is already served by a live resident daemon \
                     on port {prev}. One resident writer per estate \u{2014} stop it first."
                );
                return ExitCode::from(exit::FAILURE);
            }
        }
        if let Err(e) = paths::write_port_file(&port_file, p) {
            eprintln!(
                "mootx01: cannot write port file {}: {e} (continuing)",
                port_file.display()
            );
        }
        let _ = std::fs::write(&pid_file, format!("{}\n", std::process::id()));
        // T4: record the served estate path so a stdio serve can detect that THIS
        // estate already has a live resident and forward to it. SQLite estates
        // only (postgres has no local file path to match on).
        if let Ok(estate) = std::env::var("ARIA_MCP_SQLITE_PATH") {
            let _ = std::fs::write(data.join("mootx01.estate"), estate);
        }
    }

    //  on-startup dreaming trigger: if the dreaming queue
    // has pending items from a prior session, spawn a detached dreamer so
    // dreaming catches up without waiting for the next recall event.
    if let Ok(estate) = std::env::var("ARIA_MCP_SQLITE_PATH") {
        if dreaming_queue_has_pending(&estate) {
            eprintln!("mootx01: dreaming queue has pending items from prior session — spawning detached dreamer (T10 startup)");
            spawn_detached_dream();
        }
    }

    // computed once at startup (not per-call). Empty whenever no
    // plugin is detected or its version matches this binary — the common
    // case, which leaves ping/status unchanged.
    let version_skew = mcp_ownership::version_skew_advisory(
        "mootx01@mootx01",
        env!("CARGO_PKG_VERSION"),
        &super::install::home_dir(),
    )
    .unwrap_or_default();

    // Upstream-release advisory (`update_available` in ping/status):
    // resident daemons only. A resident outlives releases, so this must be
    // evaluated lazily at ping/status time — UpdateAdvisor rate-limits the
    // release-feed probe to once per 24h (and honors the
    // MOOTX01_NO_UPDATE_CHECK kill switch) and collapses failures to
    // silence. stdio one-shots stay network-free on purpose: ping is
    // documented as returning immediately, and an offline probe timeout
    // there would break that; every plugin-capable host talks to the
    // resident over HTTP anyway. The probe itself is bounded
    // (curl --max-time 4) because it runs behind the dispatcher mutex.
    // Mirrors Swift ServeCommand's `residentPort != nil` gate.
    let update_advisory: Option<aria_mcp::dispatcher::UpdateAdvisoryProvider> =
        if bound_port.is_some() {
            let advisor = std::sync::Arc::new(update_advisor::UpdateAdvisor::new(
                env!("CARGO_PKG_VERSION"),
                Box::new(|| {
                    let latest = release::latest_version_within(Some(4)).ok()?;
                    // Newer-only gating: the advisor renders whatever tag it
                    // is handed, so equal/older/unparsable must collapse to
                    // None here. Leading v restored for display parity with
                    // the Swift leg (which surfaces the raw GitHub tag).
                    match release::is_newer(&latest, env!("CARGO_PKG_VERSION")) {
                        Some(true) => Some(format!("v{latest}")),
                        _ => None,
                    }
                }),
            ));
            Some(std::sync::Arc::new(move || advisor.advisory()))
        } else {
            None
        };

    // Host the runtime. Does not return until the transport stops.
    aria_mcp::runtime::run("mootx01", &version_skew, update_advisory);

    if bound_port.is_some() {
        remove_port_file(&port_file);
        let _ = std::fs::remove_file(&pid_file);
        let _ = std::fs::remove_file(data.join("mootx01.estate"));
    } else {
        // T5 — direct-open stdio exit (the forward path returned earlier). The
        // client may SIGKILL us the moment stdin closes, killing the in-process
        // encode drain mid-flight. If encode work is still queued, hand it to a
        // detached `drain` finisher that outlives us (it takes the T3 lease and
        // drains to empty, or stands by if a resident has since taken over). Only
        // spawn when the maildir actually has pending/in-flight jobs.
        if let Ok(estate) = std::env::var("ARIA_MCP_SQLITE_PATH") {
            if encode_queue_has_pending(&estate) {
                spawn_detached_drain();
            }
            //  on-exit dreaming trigger: if the dreaming
            // queue has items (enqueued during this session or from prior sessions),
            // spawn a detached `dream` finisher so dreaming work is not lost when
            // the stdio serve exits. Independent of the encode drain — both can be
            // held simultaneously.
            if dreaming_queue_has_pending(&estate) {
                eprintln!("mootx01: dreaming queue has pending items on exit — spawning detached dreamer (T10 exit)");
                spawn_detached_dream();
            }
        }
    }
    ExitCode::from(exit::OK)
}

/// True when the corpus ingest maildir beside `estate_path` has any job waiting
/// (`new/`) or claimed but unfinished (`cur/`). A cheap directory check so a
/// stdio serve only spawns the detached drainer when there is real work left.
fn encode_queue_has_pending(estate_path: &str) -> bool {
    let dir = match Path::new(estate_path).parent() {
        Some(d) => d,
        None => return false,
    };
    let qdir = dir.join("corpus_ingest_queue");
    ["new", "cur"].iter().any(|sub| {
        std::fs::read_dir(qdir.join(sub))
            .map(|mut entries| entries.next().is_some())
            .unwrap_or(false)
    })
}

/// True when the dreaming queue SQLite file exists beside `estate_path`,
/// indicating there may be pending dreaming jobs from a prior session or from
/// the current session's recalls. A cheap file-existence check that does NOT
/// open the database — the full pending count is probed by `dream_runner` after
/// acquiring the DrainLease. Returns false for non-existent estates (nothing to
/// dream on) and for estates that have never triggered a dreaming enqueue (no
/// per-estate queue file ever created).
fn dreaming_queue_has_pending(estate_path: &str) -> bool {
    let estate = Path::new(estate_path);
    let dir = match estate.parent() {
        Some(d) => d,
        None => return false,
    };
    // The dreaming queue lives at <estate-stem>.queue.sqlite beside the estate
    // file (recall-driven dreaming per-estate isolation). The stem prefix ensures two
    // estates in the same directory each have their own queue and cannot drain
    // each other's jobs. Its existence signals at least one dreaming-eligible
    // recall has occurred — actual pending count is verified inside dream_runner.
    let stem = estate
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    if stem.is_empty() {
        return false;
    }
    dir.join(format!("{}.queue.sqlite", stem)).exists()
}

/// Spawn `mootx01 dream` detached to run one REM-ALPHA cycle after a
/// direct-open stdio serve exits or starts up with a pending dreaming queue
///. The child `setsid`s itself (unix) / is created
/// detached (windows); we inherit env (so ARIA_MCP_SQLITE_PATH targets the same
/// estate) and do not wait on it.
fn spawn_detached_dream() {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("mootx01: cannot locate own binary to spawn detached dreamer: {e}");
            return;
        }
    };
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("dream")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        cmd.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }
    if let Err(e) = cmd.spawn() {
        eprintln!("mootx01: failed to spawn detached dreamer: {e}");
    }
}

/// Spawn `mootx01 drain` detached to finish the encode queue after a direct-open
/// stdio serve exits (T5). The child `setsid`s itself (unix) / is created
/// detached (windows); we inherit env (so ARIA_MCP_SQLITE_PATH targets the same
/// estate) and do not wait on it.
fn spawn_detached_drain() {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("mootx01: cannot locate own binary to spawn detached drainer: {e}");
            return;
        }
    };
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("drain")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        cmd.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }
    if let Err(e) = cmd.spawn() {
        eprintln!("mootx01: failed to spawn detached drainer: {e}");
    }
}

fn env_nonempty(key: &str) -> bool {
    std::env::var(key).map(|v| !v.is_empty()).unwrap_or(false)
}

/// Probe-bind on loopback; free means we could bind. Racy by nature (the
/// port can be taken between probe and the runtime's real bind), in which
/// case the runtime's bind failure path exits 1 — acceptable for v1.
fn port_free(port: u16) -> bool {
    TcpListener::bind(("127.0.0.1", port)).is_ok()
}

/// First free port in [start, start+range], or None.
fn hunt(start: u16, range: u16) -> Option<u16> {
    (start..=start.saturating_add(range)).find(|&p| port_free(p))
}

fn remove_port_file(path: &Path) {
    let _ = std::fs::remove_file(path);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hunt_skips_a_busy_port() {
        // Occupy a port, then hunt starting at it: hunt must return a
        // different (higher) free port.
        let holder = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let busy = holder.local_addr().unwrap().port();
        let found = hunt(busy, 10).expect("a free port within 10 of any port");
        assert_ne!(found, busy);
        assert!(found > busy);
    }

    #[test]
    fn port_free_reflects_occupancy() {
        let holder = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let busy = holder.local_addr().unwrap().port();
        assert!(!port_free(busy), "an occupied port must report not-free");
        drop(holder);
        // The OS may not release the listener's port synchronously on drop
        // (notably on Windows), so poll briefly for it to become rebindable
        // rather than asserting it instantly.
        let mut freed = false;
        for _ in 0..100 {
            if port_free(busy) {
                freed = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert!(freed, "a released port must become free");
    }
}
