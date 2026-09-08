//! commands/drain.rs — T5 detached encode-drain finisher.
//!
//! When an stdio `serve` that opened an estate DIRECTLY (no resident to forward
//! to) exits — the client closed stdin, or a one-shot `query` terminated it —
//! any encode work still queued would die with the process. `serve` spawns this
//! command, detached, to finish the job: it opens the estate (which eager-mounts
//! the Corpus's lease-gated drain worker), waits until the ingest queue is empty,
//! then exits. The T3 lease keeps it from double-draining against a resident or
//! another finisher. Rarely run by hand.

use std::process::ExitCode;
use std::time::{Duration, Instant};

use aria_mcp::estate_registry::{DrainStatus, EstateRegistry, SqliteOpening};
use genius_locus_kit::{EstateBackend, EstateCatalog, EstateOpenPosture};

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

    // The estate is the catalog's: the `--db` value the spawning serve was
    // launched with (a registered name or a transient path), else the active
    // estate. Nothing here computes a path.
    let catalog = match db.as_deref() {
        Some(value) => EstateCatalog::open_selecting(value),
        None => EstateCatalog::open(),
    };
    let record = match catalog {
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
    let opening = SqliteOpening { seed_charters: false, ..SqliteOpening::for_record(&record) };
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
    eprintln!("mootx01 drain: encode queue settled for {estate} — exiting");
    ExitCode::from(exit::OK)
}
