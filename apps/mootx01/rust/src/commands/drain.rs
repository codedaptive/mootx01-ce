//! commands/drain.rs — `mootx01 drain`, the FINISHER (GENIUSLOCUSKIT_SPEC
//! § DUTY_LIFECYCLE). Run attached by an operator or a script; a stdio
//! `serve` spawns nothing. It opens the estate (which eager-mounts the
//! Corpus's lease-gated drain worker), waits until the ingest queue is empty,
//! then pays the settle loop for every row-debt duty — span encode, subject
//! backfill, fact extraction — until each lane owes nothing or a batch pays
//! nothing, one progress line per batch on stderr. When it exits, nothing it
//! started is still running. The T3 encode lease keeps it from double-draining
//! against a resident; each duty batch runs under its own claimed queue job.

use std::process::ExitCode;
use std::time::{Duration, Instant};

use aria_mcp::estate_registry::{DrainStatus, EstateRegistry, EstateOpening};
use genius_locus_kit::{EstateBackend, EstateOpenPosture};

use crate::exit;

/// Host identity for the open (matches the registry's production default). The
/// drain writes no memories, so this is cosmetic provenance only.
const OWNER: &str = "aria-mcp-default";
/// Hard cap on total wait so a wedged drain can never hang forever.
const MAX_WAIT_SECS: u64 = 3600;

pub fn run(db: Option<String>) -> ExitCode {
    // Own session: a process-group kill aimed at the script that ran this
    // finisher does not reach it mid-batch.
    #[cfg(unix)]
    // SAFETY: setsid is a plain libc syscall with no aliasing concerns.
    unsafe {
        libc::setsid();
    }

    // The estate is the catalog's: the `--db` value (a registered name or a
    // transient path), else the active estate. Routes through the funnel (Windows base-directory adoption +
    // catalog open) so the adoption always precedes the open.
    let record = match crate::core::estate_open::catalog(db.as_deref()) {
        Ok(catalog) => catalog.active().clone(),
        Err(e) => {
            eprintln!("mootx01 drain: {e}");
            return ExitCode::from(exit::FAILURE);
        }
    };
    if record.backend != EstateBackend::Sqlite {
        eprintln!("mootx01 drain: estate '{}' is not a SQLite estate — nothing to drain here", record.name);
        return ExitCode::from(exit::OK);
    }
    let estate_path = record.database_path();
    if !estate_path.exists() {
        return ExitCode::from(exit::OK); // nothing to drain
    }
    let estate = estate_path.to_string_lossy().into_owned();
    // The at-rest posture is decided before the open and fails closed, as in
    // serve: a ciphertext file whose key is missing is never reopened plaintext.
    let open_posture = match EstateOpenPosture::resolve(&record) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("mootx01 drain: estate encryption posture unavailable: {e}");
            return ExitCode::from(exit::FAILURE);
        }
    };

    // Opening eager-mounts the Corpus ingest queue + lease-gated drain worker
    // (the registry's SQLite open wires the estate through GLK
    // wire_glk_substores), so the backlog drains without any capture. The
    // record's kind decides federation; a finisher never seeds charters.
    let opening = EstateOpening { seed_charters: false, ..EstateOpening::for_record(&record) };
    let reg = match EstateRegistry::new_sqlite_with(&estate, OWNER, opening) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("mootx01 drain: {e}");
            return ExitCode::from(exit::FAILURE);
        }
    };
    // The manifest must say what is on disk after the migration chain ran.
    let now_millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0);
    if let Err(e) = genius_locus_kit_migrations::refresh_after_chain(&record, open_posture.manifest_encryption(), now_millis) {
        eprintln!("mootx01 drain: estate manifest could not be written: {e}");
    }
    let handle = reg.default.handle;

    // Poll the drain status (same surface as moot_drain_status) until the
    // ENCODE drain is idle — the queue is empty whether this process drained
    // it (held the T3 lease) or a resident did. Capped so a wedged drain
    // cannot hang forever.
    //
    // Keyed on the encode drain only via `DrainStatus::encode_settled`
    // (PERF_W1_DRAIN_RIDER Finding 3): the "distillation" entry can only
    // settle via a `moot_distill` sweep or the hourly standing signal —
    // neither of which this command runs — so polling ALL drains would spin
    // to MAX_WAIT_SECS holding the encode DrainLease and wedge the next serve
    // session's encode queue. This finisher's contract is the encode queue
    // and its lease; it exits as soon as that is settled.
    let deadline = Instant::now() + Duration::from_secs(MAX_WAIT_SECS);
    while Instant::now() < deadline {
        let idle = {
            let coord = reg.coord.lock().unwrap();
            coord
                .drain_statuses(&handle)
                .map(|d| DrainStatus::encode_settled(&d))
                .unwrap_or(true)
        };
        if idle {
            break;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    eprintln!("mootx01 drain: encode queue settled for {estate}");

    // The settle loop per row-debt duty (§ DUTY_LIFECYCLE): span encode and
    // subject backfill under the coordinator, one progress line per batch;
    // then fact extraction, whose model calls run outside the coordinator
    // mutex and whose settle cycle prints its own progress.
    let fact_settings_directory: Option<&std::path::Path> =
        if opening.federate { None } else { Some(record.directory.as_path()) };
    aria_mcp::runtime::configure_duty_limits_from_settings(&reg.coord, &handle, fact_settings_directory);
    {
        use genius_locus_kit::brain::duty_queue::DutyKind;
        let now_ms = (aria_mcp::dream_runner::wall_now_epoch_secs() * 1000.0) as i64;
        match reg.coord.lock() {
            Ok(mut coord) => {
                for kind in [DutyKind::SpanEncode, DutyKind::SubjectBackfill, DutyKind::AnomalySweep] {
                    let outcome = coord.pay_duty_until_settled_with(&handle, kind, now_ms, |report| {
                        eprintln!("mootx01 drain: {} — {} paid, {} remaining",
                            kind.wire_name(), report.units_paid, report.remaining_debt);
                    });
                    if let Err(error) = outcome {
                        eprintln!("mootx01 drain warning: {} settle error: {error:?} — continuing", kind.wire_name());
                    }
                }
            }
            Err(error) => eprintln!("mootx01 drain warning: duties skipped — coordinator lock poisoned: {error}"),
        }
    }
    if let Some(cycle) = aria_mcp::runtime::build_fact_extraction_settle_cycle(
        &reg.coord, handle.clone(), fact_settings_directory)
    {
        match cycle() {
            Ok(settled) => eprintln!("mootx01 drain: fact extraction — {settled} source(s) settled"),
            Err(error) => eprintln!("mootx01 drain warning: fact extraction settle error: {error} — continuing"),
        }
    }
    eprintln!("mootx01 drain: duties settled for {estate} — exiting");
    ExitCode::from(exit::OK)
}
