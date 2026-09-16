//! commands/serve.rs — §4.1: host the ARIA MCP server.
//!
//! Resolves the estate through the estate catalog, decides its at-rest posture,
//! then makes a single call into `aria_mcp::runtime::run` — the same function
//! the `aria-mcp` dev binary calls, so both entry points run identical
//! resident-daemon logic. Twin of the Swift `ServeCommand`.
//!
//! Estate selection (nothing here computes a path):
//!   --db <name>        → the registered estate of that name
//!   --db <dir>/<name>  → a transient estate at <dir>/<name>/ (plaintext, no
//!                        identity, no charters, forgotten at exit)
//!   (neither)          → the catalog's active estate
//!   --in-memory        → the in-memory backend; the estate lives and dies
//!                        with this process (accuracy-measurement posture)
//!
//! Transport:
//!   --http auto   → hunt 4242 upward to the first free port (§3)
//!   --http <port> → exact; busy means exit 1, never hunt (§3)
//!   (neither)     → MOOTX01_HTTP_PORT env if the caller set it, else stdio
//!   --frozen      → MOOTX01_FROZEN=1 (the runtime's Dispatcher reads it and
//!                   refuses mutating tools, drops recall traces and reward
//!                   marks); this command spawns no detached dreamer or
//!                   drainer, never forwards to a live resident, and refuses
//!                   the combination with HTTP (the resident's autonomic
//!                   governor is a background worker)
//!
//! Whatever port the daemon binds is written to `<configuration>/daemon.port`
//! and best-effort removed when the runtime returns (§3). The resident's PID
//! marker is `estate.pid` inside the estate it serves: "this estate is being
//! served" is a fact about the estate.

use std::net::TcpListener;
use std::path::Path;
use std::process::ExitCode;

use aria_mcp::estate_posture::EstatePosture;
use aria_mcp::estate_registry::EstateOpening;
use aria_mcp::server::RuntimeEstate;
use genius_locus_kit::{
    EstateBackend, EstateCatalog, EstateOpenPosture, EstateOpenPostureKind, EstateRecord, EstateRecordKind,
};

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

pub fn run(db: Option<String>, http: Option<HttpMode>, frozen_flag: bool, in_memory: bool) -> ExitCode {
    // Keep the daemon's memory (incl. decrypted estate content held in RAM) out
    // of the swap file. Best-effort; the estate is encrypted at rest regardless.
    lock_memory_from_swap();
    // Install-wide files (the resident port file, bundled models) live in the
    // configuration directory; estate files live with the estate.
    let data = EstateCatalog::configuration_directory();

    // The catalog is the one place that knows which estates exist and where.
    // `--db` selects a registered estate by name or attaches a transient one by
    // path; absent, the active estate serves. Routes through the funnel so the
    // Windows base-directory adoption always precedes the catalog open.
    let record: EstateRecord = match crate::core::estate_open::catalog(db.as_deref()) {
        Ok(catalog) => catalog.active().clone(),
        Err(e) => {
            let message = format!("mootx01 serve fatal: {e}");
            crate::core::platform_log::report_estate_fatal("estate catalog unavailable", db.as_deref());
            eprintln!("{message}");
            return ExitCode::from(exit::FAILURE);
        }
    };
    let registered = record.kind == EstateRecordKind::Registered;

    // Frozen posture: `--frozen` wins, else MOOTX01_FROZEN=1. The flag is
    // translated into the environment variable so the runtime's Dispatcher,
    // constructed inside `aria_mcp::runtime::run`, derives the same posture.
    let posture = EstatePosture::resolve(
        frozen_flag,
        std::env::var(EstatePosture::ENVIRONMENT_KEY).ok().as_deref(),
    );
    let frozen = posture.is_frozen();
    if frozen {
        std::env::set_var(EstatePosture::ENVIRONMENT_KEY, "1");
    }

    // The estate the runtime opens. The record's kind decides identity,
    // federation, charter seeding and the at-rest posture; a transient estate
    // is plaintext with its identity in memory and holds exactly what was
    // imported into it. The posture is decided BEFORE the open and fails
    // closed: a ciphertext file whose key is missing is never reopened
    // plaintext and never given a fresh key (`mootx01 upgrade` migrates).
    let runtime_estate = if in_memory {
        // C1 (benchmark reset, RAM accuracy shape): the estate exists only for
        // this process. Intended for the benchmark harness; a durable estate
        // never selects it, and no environment value turns it on.
        //
        // R8 (2026-09-08): `--in-memory` serves a TRANSIENT estate whatever
        // the record above says. The record is still resolved first, so a bad
        // `--db` is refused before the backend is chosen, but nothing that
        // outlives the process is minted: no federation identity, and no
        // charter drawers in the candidate pool a RAM benchmark arm measures.
        // Same rule in Swift `ServeCommand` and in both ports of `aria-mcp`.
        eprintln!(
            "mootx01 serve: IN-MEMORY backend (--in-memory) — \
             estate exists only for this process; accuracy-measurement posture \
             (transient: no federation, no charters)."
        );
        RuntimeEstate::InMemory { opening: EstateOpening::TRANSIENT }
    } else {
        match &record.backend {
            EstateBackend::Postgresql { connection_string } => {
                eprintln!("mootx01 serve: estate '{}' on PostgreSQL", record.name);
                RuntimeEstate::Postgresql {
                    connection_string: connection_string.clone(),
                    opening: EstateOpening::for_record(&record),
                }
            }
            EstateBackend::Sqlite => {
                let open_posture = match EstateOpenPosture::resolve(&record) {
                    Ok(p) => p,
                    Err(e) => {
                        let message = format!("mootx01 serve fatal: estate encryption posture unavailable: {e}");
                        crate::core::platform_log::report_estate_fatal(
                            "estate encryption posture unavailable", Some(&record.name));
                        eprintln!("{message}");
                        return ExitCode::from(exit::FAILURE);
                    }
                };
                if !registered {
                    eprintln!("mootx01 serve: transient estate — identity in memory, no federation, no charters");
                } else if open_posture.kind == EstateOpenPostureKind::NewPlaintextDeclared {
                    // A declared-plaintext open is never silent: name the posture
                    // AND its source, so a downgrade caused by an altered manifest
                    // is visible in the serve log.
                    eprintln!(
                        "mootx01 serve: creating estate UNENCRYPTED — its manifest {} declares plaintext. Run `mootx01 upgrade` to encrypt.",
                        record.manifest_path().display()
                    );
                }
                eprintln!(
                    "mootx01 serve: estate '{}' [{}] at {}",
                    record.name,
                    if registered { "registered" } else { "transient" },
                    record.directory.display()
                );
                RuntimeEstate::Sqlite {
                    opening: EstateOpening::for_record(&record),
                    encryption: open_posture.manifest_encryption(),
                    record: record.clone(),
                }
            }
        }
    };
    let on_disk = !in_memory && record.backend == EstateBackend::Sqlite;

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
    // second direct writer. "Same estate" = a PID marker in THIS estate's
    // directory; liveness = the recorded port answering on loopback. If the
    // marker is stale (no resident answering), fall through and open directly.
    let pid_file = record.pid_path();
    if bound_port.is_none() && on_disk && resident_pid_recorded(&pid_file) {
        let port = daemon_client::resolved_port();
        if daemon_client::alive(port) {
            // A frozen serve never forwards: the resident is a live,
            // mutating server and forwarding would hand the client
            // exactly what the flag promised it would not get.
            if frozen {
                let message = format!(
                    "mootx01 serve fatal: a live resident already serves this estate on 127.0.0.1:{port}; a frozen serve cannot forward to a live daemon. Stop the resident or freeze a clone."
                );
                crate::core::platform_log::report_estate_fatal(
                    "live resident prevents frozen serve", Some(&record.name));
                eprintln!("{message}");
                return ExitCode::FAILURE;
            }
            eprintln!(
                "mootx01: a live resident already serves this estate \u{2014} forwarding stdio to the daemon on 127.0.0.1:{port} instead of opening a second writer (T4)"
            );
            return crate::commands::proxy::run(Some(format!("http://127.0.0.1:{port}")));
        }
        eprintln!(
            "mootx01: a resident PID is recorded for this estate but none is reachable on 127.0.0.1:{port} (stale marker) \u{2014} opening the estate directly"
        );
    }

    // Frozen + HTTP is refused rather than served half-frozen: the resident
    // daemon's autonomic governor is a background worker by definition.
    if frozen {
        if bound_port.is_some() {
            let message = format!(
                "mootx01 serve fatal: --frozen / MOOTX01_FROZEN=1 cannot be combined with --http / MOOTX01_HTTP_PORT \u{2014} the resident daemon runs background workers. Serve a frozen estate over stdio."
            );
            crate::core::platform_log::report_estate_fatal(
                "HTTP transport unavailable in frozen posture", Some(&record.name));
            eprintln!("{message}");
            return ExitCode::FAILURE;
        }
        eprintln!("mootx01 serve: {}", EstatePosture::FROZEN_LOG_LINE);
    }

    // §3: whatever port the daemon binds is written to daemon.port and removed
    // on clean shutdown. The resident daemon also writes `estate.pid` into the
    // estate it serves (status reports it; a stdio serve reads it for T4
    // forwarding) and enforces the single-writer rule: one resident
    // AutonomicGovernor per estate. Liveness is the recorded port answering on
    // loopback — portable where kill(pid, 0) is not. An stdio serve either
    // forwards to a live resident (T4, above) or opens the estate directly; it
    // files none of these markers. An in-memory estate is nobody's estate on
    // disk, so no marker is written for it.
    let port_file = paths::daemon_port_file(&data);
    if let Some(p) = bound_port {
        if let Some(prev) = paths::read_port_file(&port_file) {
            // Liveness = a real mootx01 daemon ANSWERS on the recorded port,
            // not merely that the port is occupied (`!port_free(prev)` is true
            // for ANY listener and would falsely refuse to start).
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
        if on_disk {
            let _ = std::fs::create_dir_all(&record.directory);
            let _ = std::fs::write(&pid_file, format!("{}\n", std::process::id()));
        }
    }

    // On-startup dreaming trigger: if the dreaming queue has pending items from
    // a prior session, spawn a detached dreamer so dreaming catches up without
    // waiting for the next recall event. The child is told the estate with
    // `--db <selector>`, the value that selects this record again.
    let selector = record.selector_argument();
    if on_disk && record.queue_path().exists() && background_worker_permitted(posture, "startup dreamer") {
        eprintln!("mootx01: dreaming queue has pending items from prior session — spawning detached dreamer (T10 startup)");
        spawn_detached_dream(&selector);
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
    aria_mcp::runtime::run("mootx01", &version_skew, update_advisory, runtime_estate);

    if bound_port.is_some() {
        remove_port_file(&port_file);
        if on_disk {
            let _ = std::fs::remove_file(&pid_file);
        }
    } else if on_disk {
        // T5 — direct-open stdio exit (the forward path returned earlier). The
        // client may SIGKILL us the moment stdin closes, killing the in-process
        // encode drain mid-flight. If encode work is still queued, hand it to a
        // detached `drain` finisher that outlives us (it takes the T3 lease and
        // drains to empty, or stands by if a resident has since taken over). Only
        // spawn when the maildir actually has pending/in-flight jobs.
        if encode_queue_has_pending(&record.directory) && background_worker_permitted(posture, "encode drainer") {
            spawn_detached_drain(&selector);
        }
        // On-exit dreaming trigger: if the dreaming queue has items (enqueued
        // during this session or from prior sessions), spawn a detached `dream`
        // finisher so dreaming work is not lost when the stdio serve exits.
        // Independent of the encode drain — both can be held simultaneously.
        if record.queue_path().exists() && background_worker_permitted(posture, "exit dreamer") {
            eprintln!("mootx01: dreaming queue has pending items on exit — spawning detached dreamer (T10 exit)");
            spawn_detached_dream(&selector);
        }
    }
    ExitCode::from(exit::OK)
}

/// Whether the estate's `estate.pid` marker names a process other than us. A
/// marker that exists but cannot be read counts as recorded: the port probe
/// that follows decides whether anyone is actually serving.
pub(crate) fn resident_pid_recorded(pid_file: &Path) -> bool {
    match std::fs::read_to_string(pid_file) {
        Ok(text) => text.trim().parse::<u32>().map(|pid| pid != std::process::id()).unwrap_or(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
        Err(_) => true,
    }
}

/// True when the corpus ingest maildir inside `estate_dir` has any job waiting
/// (`new/`) or claimed but unfinished (`cur/`). A cheap directory check so a
/// stdio serve only spawns the detached drainer when there is real work left.
fn encode_queue_has_pending(estate_dir: &Path) -> bool {
    let qdir = estate_dir.join("corpus_ingest_queue");
    ["new", "cur"].iter().any(|sub| {
        std::fs::read_dir(qdir.join(sub))
            .map(|mut entries| entries.next().is_some())
            .unwrap_or(false)
    })
}

/// Whether this serve may launch a detached background worker (dreamer or
/// drainer). Every spawn site consults this before spawning; a frozen serve
/// answers false and says so once per site, so pending work is visible in
/// the log but never picked up by a process that outlives the snapshot.
/// Mirrors Swift `ServeCommand.backgroundWorkerPermitted`.
fn background_worker_permitted(posture: EstatePosture, worker: &str) -> bool {
    if !posture.is_frozen() {
        return true;
    }
    eprintln!("mootx01 serve: frozen — {worker} not spawned; pending work is left untouched");
    false
}

/// Spawn `mootx01 dream --db <selector>` detached to run one REM-ALPHA cycle
/// after a direct-open stdio serve exits or starts up with a pending dreaming
/// queue. The child `setsid`s itself (unix) / is created detached (windows);
/// the estate is passed as the catalog selector that chose it here, and we do
/// not wait on it.
fn spawn_detached_dream(selector: &str) {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("mootx01: cannot locate own binary to spawn detached dreamer: {e}");
            return;
        }
    };
    let mut cmd = std::process::Command::new(exe);
    cmd.args(["dream", "--db", selector])
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

/// Spawn `mootx01 drain --db <selector>` detached to finish the encode queue
/// after a direct-open stdio serve exits (T5). The child `setsid`s itself
/// (unix) / is created detached (windows); the estate is passed as the catalog
/// selector that chose it here, and we do not wait on it.
fn spawn_detached_drain(selector: &str) {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("mootx01: cannot locate own binary to spawn detached drainer: {e}");
            return;
        }
    };
    let mut cmd = std::process::Command::new(exe);
    cmd.args(["drain", "--db", selector])
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
    fn frozen_never_permits_a_background_worker() {
        assert!(background_worker_permitted(EstatePosture::Live, "startup dreamer"));
        assert!(!background_worker_permitted(EstatePosture::Frozen, "startup dreamer"));
        assert!(!background_worker_permitted(EstatePosture::Frozen, "encode drainer"));
    }

    /// Source-shape guard: every detached-worker spawn in this file sits
    /// under `background_worker_permitted`. A new spawn site added without
    /// the guard fails here, not in a benchmark.
    #[test]
    fn every_detached_worker_spawn_is_guarded() {
        let source = include_str!("serve.rs");
        let lines: Vec<&str> = source.lines().collect();
        let mut sites = 0;
        for (i, line) in lines.iter().enumerate() {
            // Skip comments and this test's own string literals.
            let is_call = (line.contains("spawn_detached_dream(&") || line.contains("spawn_detached_drain(&"))
                && !line.trim_start().starts_with("//")
                && !line.contains("contains(");
            if !is_call {
                continue;
            }
            sites += 1;
            let window = lines[i.saturating_sub(6)..i].join("\n");
            assert!(window.contains("background_worker_permitted(posture"), "spawn at serve.rs:{} is not under the frozen gate", i + 1);
        }
        // Startup dreamer, exit drainer, exit dreamer.
        assert_eq!(sites, 3, "expected 3 spawn sites");
    }

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

    /// Source-shape guard (V2-F): EstateOpenPosture::resolve is called only
    /// inside the on-disk backend arm, never inside the in-memory arm.
    ///
    /// Anchors on `RuntimeEstate::InMemory {` (the variant constructed by the
    /// in-memory arm) and `match &record.backend {` (the match that opens the
    /// on-disk paths). A nested else inside the in-memory arm could shadow the
    /// bare `} else {` token, so these structural anchors are unambiguous.
    #[test]
    fn resolve_is_inside_non_in_memory_branch() {
        let source = include_str!("serve.rs");
        let prod = &source[..source
            .find("#[cfg(test)]\nmod tests")
            .expect("tests module marker not found in serve.rs")];
        let in_memory_start = prod.find("if in_memory {").expect("if in_memory { not found");
        let in_memory_variant = prod
            .find("RuntimeEstate::InMemory {")
            .expect("RuntimeEstate::InMemory { not found");
        let backend_match = prod
            .find("match &record.backend {")
            .expect("match &record.backend { not found");
        let resolve_pos = prod
            .find("EstateOpenPosture::resolve(")
            .expect("EstateOpenPosture::resolve( not found");
        assert!(
            in_memory_start < in_memory_variant,
            "if in_memory {{ ({in_memory_start}) must precede RuntimeEstate::InMemory {{ ({in_memory_variant})"
        );
        assert!(
            in_memory_variant < backend_match,
            "RuntimeEstate::InMemory {{ ({in_memory_variant}) must precede match &record.backend {{ ({backend_match})"
        );
        assert!(
            backend_match < resolve_pos,
            "match &record.backend {{ ({backend_match}) must precede EstateOpenPosture::resolve( ({resolve_pos})"
        );
        assert!(
            !prod[in_memory_start..in_memory_variant].contains("EstateOpenPosture::resolve("),
            "EstateOpenPosture::resolve must not appear inside the in-memory arm"
        );
        assert_eq!(
            prod.matches("EstateOpenPosture::resolve(").count(),
            1,
            "exactly one call to EstateOpenPosture::resolve in production serve.rs"
        );
    }

    /// Source-shape guard (V2-F follow-up): the Rust serve never refreshes the
    /// estate manifest on any path, so an in-memory serve writes nothing into
    /// the estate directory. The Swift port reaches the same result by guarding
    /// its refresh with `if let encryption`. The production region of serve.rs
    /// must not reference the refresh module or the Swift type name.
    #[test]
    fn serve_never_refreshes_the_manifest() {
        let source = include_str!("serve.rs");
        let prod = &source[..source
            .find("#[cfg(test)]\nmod tests")
            .expect("tests module marker not found in serve.rs")];
        assert!(
            !prod.contains("manifest_refresh"),
            "serve.rs production code must not reference manifest_refresh; \
             the Swift port's in-memory guard matches this"
        );
        assert!(
            !prod.contains("EstateManifestRefresh"),
            "serve.rs production code must not reference EstateManifestRefresh; \
             the Swift port's in-memory guard matches this"
        );
    }
}
