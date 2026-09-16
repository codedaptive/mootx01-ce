//! Production retraining boundary: load settings once and preserve the caller's
//! baseline on a skipped attempt. Callers must release their coordinator lock.
use corpus_kit::{CorpusContentEngine, RetrainingBudget};
use corpus_kit::error::CorpusKitError;
use moot_product_identity::{settings, storage};
use std::time::{Duration, Instant};

pub fn reindex_with_settings(engine: &CorpusContentEngine, now: i64) -> Result<(), CorpusKitError> {
    let settings = settings::load(&storage::configuration_directory());
    let deadline = Instant::now().checked_add(Duration::from_millis(settings.corpus_lsa_retraining_timeout_milliseconds));
    let budget = RetrainingBudget::new(settings.corpus_lsa_retraining_max_documents,
        settings.corpus_lsa_retraining_max_sweeps, deadline);
    let report = engine.reindex_with_budget(now, &budget)?;
    if report.skipped_model_ids.is_empty() { Ok(()) } else {
        Err(CorpusKitError::InvalidConfiguration(format!("Retraining budget exhausted: {:?}", report.skipped_model_ids)))
    }
}
