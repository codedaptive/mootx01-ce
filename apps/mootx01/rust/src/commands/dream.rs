//! commands/dream.rs — `mootx01 dream`, the one-shot dreaming COORDINATOR
//! (GENIUSLOCUSKIT_SPEC § DUTY_LIFECYCLE). Launched by an operator, a script,
//! or the `drain` finisher; a stdio `serve` spawns nothing.
//!
//! Lifecycle:
//!   - `libc::setsid()` on Unix so a process-group kill aimed at a script does
//!     not reach it mid-batch.
//!   - Acquires the per-stream `"dreaming"` DrainLease (beside `queue.sqlite`,
//!     independent of the encode lease) and HEARTBEATS it for the whole run: a
//!     pass that pays a model-bound batch outlives DRAIN_LEASE_TTL_SECS, and a
//!     stale lease would let a second dreamer start on the same estate. If
//!     another dreamer holds a fresh lease it exits immediately.
//!   - Delegates to `aria_mcp::dream_runner::run_one_dreaming_cycle`: one
//!     bounded fact-extraction batch, the REM-ALPHA cycle if the queue holds
//!     jobs, one subject-backfill batch, one span-encode batch. Never loops
//!     until settled; `mootx01 drain` is the settle loop.
//!   - Stops the heartbeat, releases the lease, exits.
//!
//! THETA/BETA/OMEGA cycles (T11/T12/T13) are NOT implemented. Seam comments in
//! `dream_runner.rs` mark where they would plug in.

use std::process::ExitCode;

use aria_mcp::estate_registry::EstateOpening;
use genius_locus_kit::{EstateBackend, EstateOpenPosture};
use queuekit::DrainLease;

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

    // The estate is the catalog's: the `--db` value the spawning serve was
    // launched with (a registered name or a transient path), else the active
    // estate. Routes through the funnel (Windows base-directory adoption +
    // catalog open) so the adoption always precedes the open.
    let record = match crate::core::estate_open::catalog(db.as_deref()) {
        Ok(catalog) => catalog.active().clone(),
        Err(e) => {
            eprintln!("mootx01 dream: {e}");
            return ExitCode::from(exit::FAILURE);
        }
    };
    if record.backend != EstateBackend::Sqlite {
        eprintln!("mootx01 dream: estate '{}' is not a SQLite estate — exiting", record.name);
        return ExitCode::from(exit::OK);
    }
    let estate_path = record.database_path();
    let estate = estate_path.to_string_lossy().into_owned();

    // Nothing to dream on if the estate file does not exist.
    if !estate_path.exists() {
        eprintln!("mootx01 dream: estate file does not exist — exiting");
        return ExitCode::from(exit::OK);
    }
    // The at-rest posture is decided before the open and fails closed, as in
    // serve: a ciphertext file whose key is missing is never reopened plaintext.
    let open_posture = match EstateOpenPosture::resolve(&record) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("mootx01 dream: estate encryption posture unavailable: {e}");
            return ExitCode::from(exit::FAILURE);
        }
    };
    // The record's kind decides federation; a dreamer never seeds charters.
    let opening = EstateOpening { seed_charters: false, ..EstateOpening::for_record(&record) };

    // The dreaming lease file lives beside queue.sqlite (parent directory of the
    // estate SQLite file), keyed by "dreaming". This is fully independent of the
    // encode drain lease ("encode.drain.lease") — both can be held simultaneously
    // Drain leases are scoped by estate and stream.
    let lease_dir = record.directory.clone();

    // Per-process instance token: UUID v4 nonce so a reused PID after a crash
    // cannot impersonate the prior lease holder.
    let instance_token = uuid::Uuid::new_v4().to_string();
    let lease = DrainLease::new(&lease_dir, "dreaming", instance_token.clone());

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
    // Heartbeat for the whole run (§ DUTY_LIFECYCLE). The thread writes the
    // same owner token through a twin handle, so ownership never changes.
    let heartbeat_stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let heartbeat = {
        let stop = std::sync::Arc::clone(&heartbeat_stop);
        let twin = DrainLease::new(&lease_dir, "dreaming", instance_token);
        std::thread::spawn(move || {
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                std::thread::sleep(std::time::Duration::from_secs_f64(queuekit::DRAIN_LEASE_HEARTBEAT_SECS));
                if stop.load(std::sync::atomic::Ordering::Relaxed) {
                    break;
                }
                twin.heartbeat(aria_mcp::dream_runner::wall_now_epoch_secs());
            }
        })
    };

    // Delegate all dreaming logic to aria_mcp::dream_runner. The epoch-seconds
    // timestamp is read ONCE here (the command boundary) and threaded through
    // deterministically — no SystemTime reads inside the cycle path.
    let result = aria_mcp::dream_runner::run_one_dreaming_cycle(&estate, OWNER, opening, now_secs);
    // The manifest must say what is on disk after the migration chain ran
    // inside the open.
    let now_millis = (now_secs * 1000.0) as i64;
    if let Err(e) = genius_locus_kit_migrations::refresh_after_chain(&record, open_posture.manifest_encryption(), now_millis) {
        eprintln!("mootx01 dream: estate manifest could not be written: {e}");
    }
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
            // Non-fatal at the command level: the lease is released and the
            // next dreamer can retry.
        }
    }

    // Stop the heartbeat before the guard releases the lease.
    heartbeat_stop.store(true, std::sync::atomic::Ordering::Relaxed);
    let _ = heartbeat.join();
    ExitCode::from(exit::OK)
}

/// RAII guard that releases the DrainLease when dropped (clean exit or panic).
struct LeaseGuard<'a>(&'a DrainLease);

impl<'a> Drop for LeaseGuard<'a> {
    fn drop(&mut self) {
        self.0.release();
    }
}
