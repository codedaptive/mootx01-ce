//! commands/drain.rs — T5 detached encode-drain finisher.
//!
//! When an stdio `serve` that opened an estate DIRECTLY (no resident to forward
//! to) exits — the client closed stdin, or a one-shot `query` terminated it —
//! any encode work still queued would die with the process. `serve` spawns this
//! command, detached, to finish the job: it opens the estate (which eager-mounts
//! the Corpus's lease-gated drain worker), waits until the ingest queue is empty,
//! then exits. The T3 lease keeps it from double-draining against a resident or
//! another finisher. Rarely run by hand.

use std::path::Path;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use aria_mcp::estate_registry::EstateRegistry;

use crate::core::paths;
use crate::exit;

/// Host identity for the open (matches the registry's production default). The
/// drain writes no memories, so this is cosmetic provenance only.
const OWNER: &str = "aria-mcp-default";
/// Hard cap on total wait so a wedged drain can never hang forever.
const MAX_WAIT_SECS: u64 = 3600;

pub fn run(db: Option<String>) -> ExitCode {
    // Detach into our own session so a process-group kill aimed at the parent
    // serve does not also reach this finisher. A spawned child already survives
    // the parent's pid death on Unix; setsid hardens against group signals.
    #[cfg(unix)]
    // SAFETY: setsid is a plain libc syscall with no aliasing concerns.
    unsafe {
        libc::setsid();
    }

    let data = paths::data_dir();
    // Estate path: an explicit ARIA_MCP_SQLITE_PATH override (inherited from the
    // spawning serve) wins; else resolve the named/active estate.
    let estate = match std::env::var("ARIA_MCP_SQLITE_PATH") {
        Ok(p) if !p.is_empty() => p,
        _ => {
            let name = db.unwrap_or_else(|| paths::active_estate(&data));
            paths::estate_sqlite_path(&data, &name)
                .to_string_lossy()
                .into_owned()
        }
    };
    if !Path::new(&estate).exists() {
        return ExitCode::from(exit::OK); // nothing to drain
    }

    // Opening eager-mounts the Corpus ingest queue + lease-gated drain worker
    // (estate_registry::wire_sqlite_semantic_recall), so the backlog drains
    // without any capture.
    let reg = match EstateRegistry::new_sqlite(&estate, OWNER) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("mootx01 drain: {e}");
            return ExitCode::from(exit::FAILURE);
        }
    };
    let handle = reg.default.handle;

    // Poll the drain status (same surface as moot_drain_status) until every drain
    // is idle — the queue is empty whether this process drained it (held the T3
    // lease) or a resident did. Capped so a wedged drain cannot hang forever.
    let deadline = Instant::now() + Duration::from_secs(MAX_WAIT_SECS);
    while Instant::now() < deadline {
        let idle = {
            let coord = reg.coord.lock().unwrap();
            coord
                .drain_statuses(&handle)
                .map(|d| d.iter().all(|x| !x.is_draining()))
                .unwrap_or(true)
        };
        if idle {
            break;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    eprintln!("mootx01 drain: encode queue settled for {estate} — exiting");
    ExitCode::from(exit::OK)
}
