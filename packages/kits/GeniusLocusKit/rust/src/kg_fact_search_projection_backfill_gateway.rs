//! kg_fact_search_projection_backfill_gateway.rs
//!
//! Thin gateway that injects fact-extraction-kit's FactSearchProjection into
//! locus-kit's kg_fact_search_projection_backfill. genius-locus-kit depends
//! on both locus-kit and fact-extraction-kit, so it is the correct injection
//! site — locus-kit sits below fact-extraction-kit and must not import it
//! directly. Mirrors Swift `KGFactSearchProjectionBackfillGateway.swift`.
//!
//! Run ONLY by `mootx01 upgrade` (Bob's ruling: upgrade is the sole
//! migration vehicle).

use fact_extraction_kit::grounding::FactSearchProjection;
use persistence_kit::storage::Storage;

use locus_kit::kg_fact_search_projection_backfill::{
    self, KGFactSearchProjectionBackfillReport,
};
use locus_kit::error::LocusKitError;

/// Run the search-projection backfill against `storage`, with
/// fact-extraction-kit's concrete build function and version injected.
///
/// The `FactSearchProjection::build` and `FactSearchProjection::VERSION`
/// symbols from fact-extraction-kit are injected here because locus-kit
/// sits below fact-extraction-kit and must not depend on it.
pub fn run(
    storage: &dyn Storage,
) -> Result<KGFactSearchProjectionBackfillReport, LocusKitError> {
    kg_fact_search_projection_backfill::run(
        storage,
        // fact-extraction-kit's build function is injected here because
        // locus-kit sits below fact-extraction-kit and must not depend on it.
        &|subject, predicate, object| {
            FactSearchProjection::build(subject, predicate, object, &[])
        },
        FactSearchProjection::VERSION,
    )
}
