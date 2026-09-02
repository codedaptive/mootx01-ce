// redistill.rs — RedistillInput/Output data types AND run_redistill recipe
// body: force re-distillation of every active item followed by a full
// derived-lane reindex (CDL-02). Rust parity with CognitionKit/Redistill.swift.
//
// Why the full reindex: the BM25 lane admits grammar-v1 trailer tokens
// scanned from the distilled text (CorpusKit trailer lexical supplement), so
// a converter change moves the lexical lane as well as the dense one. A
// per-item dense recompose would leave BM25 stale.

use genius_locus_kit::coordinator::{EstateCoordinator, VerbDispatchError};
use genius_locus_kit::handle::EstateHandle;

/// Input for the redistill recipe. Mirrors Swift `Redistill.Input`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RedistillInput {
    /// Optional cap on items redistilled this pass (`None` = every item).
    pub limit: Option<usize>,
}

/// Output of the redistill recipe. Mirrors Swift `Redistill.Output`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RedistillOutput {
    /// Count of drawer rows whose representation columns were rewritten.
    pub items_redistilled: usize,
}

/// Run the redistill recipe: `EstateCoordinator::redistill_items_sweep`
/// to completion, then `EstateCoordinator::reindex_corpus` (all derived
/// lanes). Mirrors Swift `Redistill.run(input:estate:kit:now:)`.
pub fn run_redistill(
    input: &RedistillInput,
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    now: i64,
) -> Result<RedistillOutput, VerbDispatchError> {
    let items_redistilled = coord.redistill_items_sweep(handle, now, input.limit)?;
    coord.reindex_corpus(handle, now)?;
    Ok(RedistillOutput { items_redistilled })
}
