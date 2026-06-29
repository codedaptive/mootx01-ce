//! commands/dream.rs — T10 on-demand REM-ALPHA dreaming cycle finisher.
//!
//! `mootx01 dream` is the detached dreaming finisher an stdio `serve` spawns in
//! three situations:
//!
//!   1. Post-recall fork: after a recall that co-recalled ≥ 2 drawers and
//!      enqueued a dreaming job, so dream sessions trigger promptly after
//!      activity without waiting for the next autonomic governor tick.
//!   2. On-exit: when a direct-open stdio `serve` exits and the dreaming queue
//!      has pending items (mirrors the T5 drain on-exit pattern).
//!   3. On-startup: when `serve` opens an estate and finds pending dreaming
//!      items from a prior session (jobs in `queue.sqlite` not yet processed).
//!
//! Lifecycle:
//!   - Calls `libc::setsid()` on Unix to escape the parent serve's process group,
//!     surviving a SIGKILL aimed at the spawning serve.
//!   - Acquires the per-stream `"dreaming"` DrainLease (beside `queue.sqlite`,
//!     keyed by "dreaming" — independent of the encode "encode.drain.lease").
//!     If another dreamer holds a fresh lease it exits immediately (stampede
//!     prevention — at most one dreamer per estate per stream at a time).
//!   - Delegates to `aria_mcp::dream_runner::run_one_dreaming_cycle` which:
//!       - Force-mounts the dreaming queue so the persistent queue.sqlite backlog
//!         is visible even after a process restart.
//!       - Checks the pending count; exits if 0 or not mountable.
//!       - Runs ONE REM-ALPHA cycle via `DreamingDaemon::run_cycle`.
//!   - Releases the lease and exits.
//!
//! THETA/BETA/OMEGA cycles (T11/T12/T13) are NOT implemented. Seam comments in
//! `dream_runner.rs` mark where they would plug in.

use std::path::Path;
use std::process::ExitCode;

use queuekit::DrainLease;

use crate::core::paths;
use crate::exit;

/// Host identity used when opening the estate. Cosmetic only — the dream
/// command writes proposals, not memories, so provenance is stamped by GLK.
const OWNER: &str = "aria-mcp-default";

pub fn run(db: Option<String>) -> ExitCode {
    // Detach into our own session (mirrors drain.rs). A spawned child already
    // survives the parent's pid death on Unix; setsid hardens against group signals
    // so a SIGKILL aimed at the spawning stdio serve does not also kill us.
    #[cfg(unix)]
    // SAFETY: setsid is a plain libc syscall with no aliasing concerns.
    unsafe {
        libc::setsid();
    }

    // Resolve the estate path: ARIA_MCP_SQLITE_PATH override (inherited from the
    // spawning serve) wins; else resolve the named/active estate (mirrors drain.rs).
    let data = paths::data_dir();
    let estate = match std::env::var("ARIA_MCP_SQLITE_PATH") {
        Ok(p) if !p.is_empty() => p,
        _ => {
            let name = db.unwrap_or_else(|| paths::active_estate(&data));
            paths::estate_sqlite_path(&data, &name)
                .to_string_lossy()
                .into_owned()
        }
    };

    // Nothing to dream on if the estate file does not exist.
    if !Path::new(&estate).exists() {
        eprintln!("mootx01 dream: estate file does not exist — exiting");
        return ExitCode::from(exit::OK);
    }

    // The dreaming lease file lives beside queue.sqlite (parent directory of the
    // estate SQLite file), keyed by "dreaming". This is fully independent of the
    // encode drain lease ("encode.drain.lease") — both can be held simultaneously
    // per ADR-021 Decision 7 (per-(estate, stream) leases).
    let estate_path = Path::new(&estate);
    let lease_dir = match estate_path.parent() {
        Some(d) => d.to_path_buf(),
        None => {
            eprintln!("mootx01 dream: cannot derive lease directory from estate path — exiting");
            return ExitCode::from(exit::FAILURE);
        }
    };

    // Per-process instance token: UUID v4 nonce so a reused PID after a crash
    // cannot impersonate the prior lease holder.
    let instance_token = uuid::Uuid::new_v4().to_string();
    let lease = DrainLease::new(&lease_dir, "dreaming", instance_token);

    // Acquire the dreaming lease. If another dreamer holds a fresh lease, exit
    // immediately — stampede prevention; the other dreamer will process the queue.
    let now_secs = aria_mcp::dream_runner::wall_now_epoch_secs();
    if !lease.try_acquire(now_secs) {
        eprintln!("mootx01 dream: dreaming lease held by another process — exiting (another dreamer is running)");
        return ExitCode::from(exit::OK);
    }
    // Release the lease on any exit path. `DrainLease::release` only removes the
    // file if this process still holds it (owner-check), so it is safe to call
    // unconditionally.
    let _guard = LeaseGuard(&lease);

    // Delegate all dreaming logic to aria_mcp::dream_runner. The epoch-seconds
    // timestamp is read ONCE here (the command boundary) and threaded through
    // deterministically — no SystemTime reads inside the cycle path.
    let result = aria_mcp::dream_runner::run_one_dreaming_cycle(&estate, OWNER, now_secs);
    match result {
        Ok(r) if r.cycle_ran => {
            eprintln!(
                "mootx01 dream: REM-ALPHA cycle finished — {} proposal(s), {} considered",
                r.proposals_emitted, r.candidates_considered
            );
        }
        Ok(_) => {
            // Nothing to process (empty queue or not mountable) — already logged
            // inside run_one_dreaming_cycle.
        }
        Err(e) => {
            eprintln!("mootx01 dream: cycle error: {e}");
            // Non-fatal at the command level: the lease will be released and the
            // next dreamer can retry. Don't return FAILURE — callers (serve's
            // spawn-and-forget) never check our exit code.
        }
    }

    ExitCode::from(exit::OK)
}

/// RAII guard that releases the DrainLease when dropped (clean exit or panic).
struct LeaseGuard<'a>(&'a DrainLease);

impl<'a> Drop for LeaseGuard<'a> {
    fn drop(&mut self) {
        self.0.release();
    }
}
