//! svc_smoke — live Task Scheduler round-trip for the Windows service
//! backend (register → start → restart → unregister), driving the real
//! `core::service` code path including /TR quoting. Run on a Windows box:
//!
//!   cargo run --example svc_smoke
//!
//! Uses the current debug binary and a scratch data dir; the daemon task is
//! registered, started (the daemon hunts from 4242), verified via the
//! daemon.port file, then unregistered and the process stopped. Leaves the
//! machine clean. Exits nonzero on any failure.

#[cfg(target_os = "windows")]
fn main() {
    use mootx01_cli::core::service;
    use std::time::{Duration, Instant};

    let exe = std::env::current_dir()
        .unwrap()
        .join("target/debug/mootx01.exe");
    assert!(exe.exists(), "build first: cargo build (missing {})", exe.display());

    let scratch = std::env::temp_dir().join(format!("moot-svc-smoke-{}", std::process::id()));
    std::fs::create_dir_all(&scratch).unwrap();
    let scratch_str = scratch.display().to_string();

    const TASK: &str = "mootx01-svc-smoke"; // never the real task name
    // vault_on=true: smoke uses the default vault-on posture.
    // Fails CLOSED if scratch_str contains cmd.exe-unsafe characters (it won't
    // — temp_dir() paths are ASCII-clean on all supported Windows builds).
    let (exec, arg) = service::daemon_task_command(&exe.display().to_string(), Some(&scratch_str), true)
        .expect("scratch data-dir path must be cmd.exe-safe");
    println!("action: {exec} {arg}");

    // Register + start.
    match service::register_task(TASK, &exec, &arg) {
        service::RegisterOutcome::Registered(p) => println!("registered: {}", p.display()),
        other => panic!("register failed: {other:?}"),
    }

    // The daemon writes daemon.port once it binds (hunting from 4242).
    let port_file = scratch.join("daemon.port");
    let deadline = Instant::now() + Duration::from_secs(30);
    let port = loop {
        if let Ok(s) = std::fs::read_to_string(&port_file) {
            if let Ok(p) = s.trim().parse::<u16>() {
                break p;
            }
        }
        assert!(Instant::now() < deadline, "daemon.port never appeared — task did not start");
        std::thread::sleep(Duration::from_millis(500));
    };
    println!("daemon up on port {port}");

    // Restart path.
    service::restart_task(TASK).expect("restart_task");
    println!("restarted");

    // Unregister. The contract: the task is gone afterwards (a hard /End may
    // skip the daemon's own port-file cleanup; that is status's stale-file
    // job, not this smoke's).
    let existed = service::unregister_task(TASK).expect("unregister_task");
    assert!(existed, "task should have existed");
    let gone = service::unregister_task(TASK).expect("second unregister");
    assert!(!gone, "task should be gone");
    println!("unregistered clean");

    let _ = std::fs::remove_dir_all(&scratch);
    println!("svc_smoke: OK");
}

#[cfg(not(target_os = "windows"))]
fn main() {
    eprintln!("svc_smoke is Windows-only");
}
