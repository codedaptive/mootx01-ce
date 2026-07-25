//! dream_runner.rs — one-shot REM dispatch for `mootx01 dream`.
//!
//! Provides `run_one_dreaming_cycle`: opens a SQLite estate, mounts the
//! dreaming queue, and iterates the shared REM dispatch table to run every
//! due cycle (ALPHA, THETA, BETA, OMEGA). Called by the `dream`
//! subcommand.
//!
//! Layering: `mootx01` → `aria-mcp::dream_runner` → `neuron-kit` / `genius-locus-kit`.
//! The dream command does not import neuron-kit or genius-locus-kit directly —
//! they route through this module so `mootx01`'s Cargo.toml stays thin
//! (single `aria-mcp` dep, same as the drain command).
//!
//! # REM dispatch table
//!
//! All four cadences (ALPHA, THETA, BETA, OMEGA) are dispatched from the shared
//! `rem_cycle_table()`. ALPHA runs when the queue is non-empty. THETA runs when the
//! 24 h cadence is due. BETA (T12) and OMEGA (T13) are cadence-gated with live run-fns.
//! The dream_runner and the resident governor both iterate the same table definition —
//! neither re-defines the cycle roster.

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use neuron_kit::{
    DreamingDaemon, EstateDreamingReader, EstateDreamingSink, RecallTraceRewardSource,
};
use neuron_kit::estate_manifest_policy_store::EstateManifestDreamingPolicyStore;
use neuron_kit::dreaming_cycle::DreamingPolicyStore;
use neuron_kit::rem_cycle_table::{RemCycleKind, rem_cycle_table};

use crate::estate_registry::EstateRegistry;

/// Result of a `run_one_dreaming_cycle` call.
#[derive(Debug)]
pub struct DreamRunResult {
    /// True if REM-ALPHA ran (queue was non-empty and the cycle executed).
    /// False if the queue was empty or could not be mounted (nothing to do).
    pub cycle_ran: bool,
    /// Number of proposals emitted by the ALPHA cycle. 0 when `cycle_ran` is false.
    pub proposals_emitted: usize,
    /// Number of candidates considered by the ALPHA cycle. 0 when `cycle_ran` is false.
    pub candidates_considered: usize,
    /// True if REM-THETA ran (cadence was due). Proposals are counted in
    /// `theta_proposals_emitted`.
    pub theta_ran: bool,
    /// Number of proposals emitted by the THETA cycle. 0 when `theta_ran` is false.
    pub theta_proposals_emitted: usize,
}

/// Open the addressed SQLite estate and iterate the shared REM dispatch table,
/// running every due cycle: ALPHA (queue non-empty), THETA (24h cadence),
/// BETA (7d cadence), OMEGA (14d cadence). recall-driven dreaming
///
/// # Lease
///
/// The DrainLease is the CALLER'S responsibility — the `dream` command acquires
/// it before calling this function and releases it after. This function does not
/// touch the lease file.
///
/// # Determinism
///
/// `now_epoch_secs` is injected by the caller (wall-clock at the start of the
/// command). No `SystemTime::now()` inside the cycle path — the conformance
/// contract (CLAUDE.md: every computation is deterministic; pass `now` from the
/// boundary, never call SystemTime inside engines).
///
/// # Errors
///
/// Returns `Err(String)` when the estate cannot be opened. A cycle error
/// (proposal write failure, etc.) is non-fatal and is reflected in the result:
/// `cycle_ran` is true but `proposals_emitted` reflects the actual count after
/// any write failures.
pub fn run_one_dreaming_cycle(
    estate_path: &str,
    owner: &str,
    now_epoch_secs: f64,
) -> Result<DreamRunResult, String> {
    // Nothing to do if the estate file does not exist.
    if !Path::new(estate_path).exists() {
        return Ok(DreamRunResult {
            cycle_ran: false,
            proposals_emitted: 0,
            candidates_considered: 0,
            theta_ran: false,
            theta_proposals_emitted: 0,
        });
    }

    // Open the estate. `EstateRegistry::new_sqlite` wires corpus + VectorStore
    // + encode queue (semantic recall layer). The dreaming queue is a separate
    // lazy-mount (below) — it is NOT wired by `new_sqlite`.
    let reg = EstateRegistry::new_sqlite(estate_path, owner)
        .map_err(|e| format!("dream: estate open failed: {e}"))?;
    let handle = reg.default.handle.clone();
    // The DrawerStore is the manifest-backed KV surface for policy persistence.
    let store = std::sync::Arc::clone(&reg.default.store);

    // Lock the coordinator and run the dreaming logic.
    // The lock is held for the duration of the cycle because `EstateDreamingReader`
    // holds a `&EstateCoordinator` reference — the borrow cannot outlive the lock.
    let coord = reg
        .coord
        .lock()
        .map_err(|e| format!("dream: coordinator lock poisoned: {e}"))?;

    // Force-mount the dreaming queue so `dreaming_queue_pending_count_for_gate`
    // returns a real count from the persistent queue.sqlite rather than None.
    // The queue is normally lazy-mounted on the first external-origin recall event,
    // which has not fired in this session.
    coord.mount_dreaming_queue(&handle);

    // On-mount crash recovery (Mission #54): reclaim any stale "dreaming" cur
    // jobs left by a prior dream process that died mid-cycle. The DrainLease
    // was acquired by the CALLER (`mootx01 dream` command) before calling this
    // function — a successful try_acquire is the structural guarantee that the
    // prior holder is dead, so every cur row is an orphan. Resetting them to
    // "new" here means the REM-ALPHA cycle below will re-process them.
    coord.reclaim_stale_dreaming_jobs(&handle);

    // §12.2 REM-ALPHA gate: probe the dreaming queue depth.
    // None  → queue could not be mounted — ALPHA skipped; THETA/BETA/OMEGA may still run.
    // Some(0) → queue empty — ALPHA skipped; THETA/BETA/OMEGA may still run.
    // Some(n>0) → queue has items; proceed with ALPHA.
    let alpha_pending = coord.dreaming_queue_pending_count_for_gate(&handle);
    match alpha_pending {
        None => {
            eprintln!(
                "mootx01 dream: dreaming queue not mountable for estate {estate_path} — REM-ALPHA skipped"
            );
        }
        Some(0) => {
            eprintln!(
                "mootx01 dream: dreaming queue is empty for estate {estate_path} — REM-ALPHA skipped"
            );
        }
        Some(n) => {
            eprintln!("mootx01 dream: {n} dreaming job(s) pending — REM-ALPHA will run");
        }
    }
    let alpha_queue_ready = alpha_pending.map_or(false, |n| n > 0);

    // Build reader and sink for ALPHA over the locked coordinator.
    // `since_str` and `now_str` bound the recall-trace reward window; ISO8601
    // format matches the substrate's TEXT date convention.
    let now_i64 = now_epoch_secs as i64;
    // Default 30 s window = the spec default tick_interval_ms of 30_000 ms.
    let since_epoch_secs = now_epoch_secs - 30.0;
    let since_str = epoch_secs_to_iso8601(since_epoch_secs);
    let now_str = epoch_secs_to_iso8601(now_epoch_secs);

    // Build the ALPHA reader only if the queue is ready (avoids a pointless
    // reader construction + recall-trace scan when the queue is empty).
    let alpha_reader_result = if alpha_queue_ready {
        Some(
            EstateDreamingReader::new(&coord, &handle, &since_str, &now_str, now_epoch_secs)
                .map_err(|e| format!("dream: dreaming reader construction failed: {e:?}"))?,
        )
    } else {
        None
    };
    let mut sink = EstateDreamingSink::new(&coord, handle.clone(), now_i64);

    // Construct the manifest-backed policy store and load persisted state.
    // `EstateManifestDreamingPolicyStore::new` takes the DrawerStore Arc —
    // the same KV surface `Estate::meta`/`set_meta` delegates to.
    let mut policy_store = EstateManifestDreamingPolicyStore::new(std::sync::Arc::clone(&store));

    // Load policy; fall back to spec defaults when absent or undecodable.
    let loaded_policy = policy_store.load_policy().unwrap_or_default();
    let mut dreaming = DreamingDaemon::new(loaded_policy);

    // Restore persisted cycle state: idempotency memory,
    // co-recall counts, proposed-key set, EWC++ consolidation, cycle counter.
    // Non-fatal: if the estate has no persisted state, the daemon starts fresh.
    if let Some(state) = policy_store.load_daemon_state() {
        dreaming.restore_state(state);
    }
    if let Some(bandit) = policy_store.load_bandit() {
        dreaming.set_bandit(bandit);
    }

    // ── REM dispatch table ─────────────────────────────
    // Iterate the shared table. Each entry's due-check is performed here; the
    // daemon runs only the cycles that are currently due. ALPHA is gated on the
    // queue pending count (already checked above); THETA/BETA/OMEGA are cadence-gated.
    //
    // For ALPHA: `run_cycle` is the unconditional single-cycle path (the pending-
    // count check above is the gate; we would not have reached here otherwise).
    // For THETA: build a fresh reader with the 24 h window (distinct from the 30 s
    // ALPHA window used above). The reader/sink are independent objects — no shared
    // mutable state between the two cycle runs.

    let mut alpha_ran = false;
    let mut alpha_proposals = 0;
    let mut alpha_candidates = 0;
    let mut theta_ran = false;
    let mut theta_proposals = 0;

    for entry in &rem_cycle_table() {
        match entry.kind {
            RemCycleKind::Alpha => {
                // ALPHA: run only if the queue was ready (pending count checked above).
                if let Some(ref reader) = alpha_reader_result {
                    let report = dreaming.run_cycle(now_epoch_secs, reader, &RecallTraceRewardSource, &mut sink);
                    if !sink.write_errors.is_empty() {
                        eprintln!("mootx01 dream: REM-ALPHA sink errors: {:?}", sink.write_errors);
                    }
                    eprintln!(
                        "mootx01 dream: {} complete — {} proposal(s), {} candidate(s)",
                        entry.name,
                        report.proposals_emitted.len(),
                        report.candidates_considered,
                    );
                    alpha_ran = true;
                    alpha_proposals = report.proposals_emitted.len();
                    alpha_candidates = report.candidates_considered;
                }
            }
            RemCycleKind::Theta => {
                if !dreaming.theta_due(now_epoch_secs) {
                    eprintln!("mootx01 dream: {} not due — skipping", entry.name);
                    continue;
                }
                // Build a fresh reader with the 24 h window for THETA.
                let theta_since_secs = now_epoch_secs - DreamingDaemon::THETA_CADENCE_SECS;
                let theta_since_str = epoch_secs_to_iso8601(theta_since_secs);
                // `now_str` is already the ISO8601 form of `now_epoch_secs` — reuse it.
                match EstateDreamingReader::new(&coord, &handle, &theta_since_str, &now_str, now_epoch_secs) {
                    Err(e) => {
                        eprintln!("mootx01 dream: REM-THETA reader error: {e:?}");
                    }
                    Ok(theta_reader) => {
                        let mut theta_sink = EstateDreamingSink::new(&coord, handle.clone(), now_i64);
                        if let Some(report) = dreaming.run_theta_cycle(now_epoch_secs, &theta_reader, &mut theta_sink) {
                            if !theta_sink.write_errors.is_empty() {
                                eprintln!("mootx01 dream: REM-THETA sink errors: {:?}", theta_sink.write_errors);
                            }
                            eprintln!(
                                "mootx01 dream: {} complete — {} proposal(s)",
                                entry.name,
                                report.proposals_emitted.len(),
                            );
                            theta_proposals = report.proposals_emitted.len();
                        } else {
                            eprintln!("mootx01 dream: {} ran — no used drawers in 24h window", entry.name);
                        }
                        theta_ran = true;
                    }
                }
            }
            RemCycleKind::Beta => {
                if dreaming.beta_due(now_epoch_secs) {
                    dreaming.run_beta_cycle(now_epoch_secs);
                    eprintln!("mootx01 dream: {} (T12) — advanced cadence timestamp", entry.name);
                }
            }
            RemCycleKind::Omega => {
                if !dreaming.omega_due(now_epoch_secs) {
                    eprintln!("mootx01 dream: {} not due — skipping", entry.name);
                    continue;
                }
                // OMEGA's reinforcement window is the biweekly cadence of recall_trace
                // (a dreamed tunnel is reinforced if its endpoints were co-recalled
                // within this window); the reader also surfaces the dreamed tunnels.
                let omega_since_secs = now_epoch_secs - DreamingDaemon::OMEGA_CADENCE_SECS;
                let omega_since_str = epoch_secs_to_iso8601(omega_since_secs);
                match EstateDreamingReader::new(&coord, &handle, &omega_since_str, &now_str, now_epoch_secs) {
                    Err(e) => {
                        eprintln!("mootx01 dream: REM-OMEGA reader error: {e:?}");
                    }
                    Ok(omega_reader) => {
                        let mut omega_sink = EstateDreamingSink::new(&coord, handle.clone(), now_i64);
                        let _ = dreaming.run_omega_cycle(now_epoch_secs, &omega_reader, &mut omega_sink);
                        if !omega_sink.write_errors.is_empty() {
                            eprintln!("mootx01 dream: REM-OMEGA sink errors: {:?}", omega_sink.write_errors);
                        }
                        eprintln!("mootx01 dream: {} complete — retired unreinforced dreamed tunnels", entry.name);
                    }
                }
            }
        }
    }

    // Persist the updated daemon state — last-run timestamps for
    // THETA/BETA/OMEGA and any cycle-state mutations from ALPHA, THETA, BETA
    // (consolidated/co_recall_counts pruned), or OMEGA (cycle state advanced).
    policy_store.save_daemon_state(dreaming.daemon_state());

    Ok(DreamRunResult {
        cycle_ran: alpha_ran,
        proposals_emitted: alpha_proposals,
        candidates_considered: alpha_candidates,
        theta_ran,
        theta_proposals_emitted: theta_proposals,
    })
}

/// Wall-clock helper for the dream command boundary: returns the current epoch
/// seconds from `SystemTime`. This is the ONLY wall-clock read in the dream
/// path — called once at the command boundary, then the value is threaded
/// through all cycle calls deterministically.
pub fn wall_now_epoch_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Format epoch seconds as an ISO8601 UTC string (TEXT date format for the
/// substrate's recall-trace query window). Mirrors `Date.iso8601String()` in
/// the Swift port.
pub fn epoch_secs_to_iso8601(epoch_secs: f64) -> String {
    // Compute year/month/day/hour/minute/second from epoch seconds.
    // Simple Gregorian calendar arithmetic (no external dep).
    let secs_u64 = epoch_secs as u64;
    let s = secs_u64 % 60;
    let m = (secs_u64 / 60) % 60;
    let h = (secs_u64 / 3600) % 24;
    let days = secs_u64 / 86400;

    // Compute year and remaining day-of-year from days since 1970-01-01.
    let mut y: u64 = 1970;
    let mut d = days;
    loop {
        let dy = if is_leap(y) { 366 } else { 365 };
        if d < dy {
            break;
        }
        d -= dy;
        y += 1;
    }
    // Month within year.
    let months = if is_leap(y) {
        [31u64, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31u64, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut mo = 1usize;
    for (i, &ml) in months.iter().enumerate() {
        if d < ml {
            mo = i + 1;
            break;
        }
        d -= ml;
    }
    let dom = d + 1;
    format!("{y:04}-{mo:02}-{dom:02}T{h:02}:{m:02}:{s:02}.000Z")
}

fn is_leap(y: u64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
}
