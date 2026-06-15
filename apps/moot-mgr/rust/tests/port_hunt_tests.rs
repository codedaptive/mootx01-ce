// port_hunt_tests.rs — spec §3 port selection for the moot-mgr resident host.
//
// Default (non-explicit) port hunts upward by retrying the bind on the next
// candidate; an explicitly requested port is exact — busy fails. The §3
// mgr.port file is maintained only by production (`write_port_file`) hosts,
// recorded with the BOUND port and removed on clean stop.

use std::net::TcpListener;

use moot_mgr::manager_config::ManagerConfig;
use moot_mgr::resident_host::{ResidentHost, ResidentHostConfig};

const NOW: f64 = 1_700_000_000.0;

fn scratch(tag: &str) -> String {
    let d = std::env::temp_dir().join(format!("moot-mgr-hunt-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d.to_string_lossy().into_owned()
}

fn cfg(dir: &str, port: u16, tag: &str) -> ResidentHostConfig {
    ResidentHostConfig::new(
        ManagerConfig::new(format!("{dir}/stats.sqlite"), 7 * 24 * 60 * 60, 3600),
        port,
        "0123456789abcdef0123456789abcdef",
        format!("{dir}/{tag}.sock"),
        format!("{dir}/estates"),
    )
}

#[test]
fn default_port_hunts_past_a_busy_port() {
    let dir = scratch("hunt");
    // Occupy a port, then ask the host for that port NON-explicitly.
    let holder = TcpListener::bind("127.0.0.1:0").unwrap();
    let busy = holder.local_addr().unwrap().port();

    let mut config = cfg(&dir, busy, "hunt");
    config.http_port_explicit = false;
    let mut host = ResidentHost::new(config, NOW);
    host.start().expect("non-explicit host must hunt past the busy port");
    let bound = host.bound_http_port();
    assert_ne!(bound, busy, "must not claim the occupied port");
    assert!(bound > busy, "hunting goes upward");
    host.stop();
    drop(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn explicit_port_does_not_hunt() {
    let dir = scratch("explicit");
    let holder = TcpListener::bind("127.0.0.1:0").unwrap();
    let busy = holder.local_addr().unwrap().port();

    // Memberwise construction is explicit by contract.
    let config = cfg(&dir, busy, "explicit");
    assert!(config.http_port_explicit);
    let mut host = ResidentHost::new(config, NOW);
    let err = host.start().expect_err("explicit busy port must fail, never hunt");
    let msg = format!("{err:?}");
    assert!(msg.contains("bind failed"), "unexpected error: {msg}");
    drop(holder);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn port_file_written_with_bound_port_and_removed_on_stop() {
    let dir = scratch("portfile");
    // Route the §3 port file into the scratch dir; this is the only test in
    // this binary touching MOOTX01_DATA_DIR.
    std::env::set_var("MOOTX01_DATA_DIR", &dir);

    let mut config = cfg(&dir, 0, "portfile"); // OS-assigned
    config.write_port_file = true;
    let mut host = ResidentHost::new(config, NOW);
    host.start().expect("host must start");
    let bound = host.bound_http_port();

    let port_file = std::path::Path::new(&dir).join("mgr.port");
    let recorded: u16 = std::fs::read_to_string(&port_file)
        .expect("mgr.port must exist while running")
        .trim()
        .parse()
        .expect("mgr.port must hold a port number");
    assert_eq!(recorded, bound, "port file records the BOUND port");

    host.stop();
    assert!(!port_file.exists(), "mgr.port removed on clean stop");
    std::env::remove_var("MOOTX01_DATA_DIR");
    let _ = std::fs::remove_dir_all(&dir);
}
