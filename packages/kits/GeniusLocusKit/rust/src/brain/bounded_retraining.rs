//! Production retraining boundary. BACKSTOPS AGAINST THE ABSURD, not working
//! limits (Bob, 2026-09-16): the dense basis must be learned from every
//! document, so the retrain is never capped in normal use; if the data is
//! there it is processed. Ten million documents is more than an order of
//! magnitude past a decade of heavy filing plus palace imports; a retrain
//! running past a day on a daily cadence is a broken system, not a slow one.
//! Thirty sweeps is the SVD's fixed iteration count. Reaching a backstop keeps
//! the serving basis and is an error-level event; the estate ping declares an
//! estate at the document backstop LSA-degraded. Twin of Swift
//! `GeniusLocusKit.reindexCorpus(handle:now:)`. Callers must release their
//! coordinator lock.
use corpus_kit::{CorpusContentEngine, RetrainingBudget};
use corpus_kit::error::CorpusKitError;
use std::time::{Duration, Instant};

/// The document backstop for the LSA retrain; read by the estate ping.
pub const LSA_RETRAINING_DOCUMENT_BACKSTOP: usize = 10_000_000;
/// The time backstop for one retrain attempt.
pub const LSA_RETRAINING_TIME_BACKSTOP: Duration = Duration::from_secs(24 * 60 * 60);

/// F11: returns `Ok(true)` for a full retrain and `Ok(false)` when a backstop
/// was reached and the serving basis was kept (DEGRADED) — the caller MUST
/// treat `Ok(false)` the same as an error for vocabulary-baseline purposes:
/// do NOT advance `last_reindex_vocab`/`lastReindexVocab`, so the next ALPHA
/// or THETA cycle retries instead of silently accepting a stale basis as
/// current. Before this fix `Ok(())` covered both outcomes, so a degraded
/// retrain still advanced the baseline exactly like a full one — the
/// vocabulary drift the backstop was hit under was never revisited.
pub fn reindex_with_settings(engine: &CorpusContentEngine, now: i64) -> Result<bool, CorpusKitError> {
    let deadline = Instant::now().checked_add(LSA_RETRAINING_TIME_BACKSTOP);
    let budget = RetrainingBudget::new(LSA_RETRAINING_DOCUMENT_BACKSTOP, 30, deadline);
    let report = engine.reindex_with_budget(now, &budget)?;
    if !report.skipped_model_ids.is_empty() {
        eprintln!("mootx01 reindex: LSA retraining DEGRADED, a backstop was reached and the serving basis was kept: {:?}", report.skipped_model_ids);
        return Ok(false);
    }
    Ok(true)
}
