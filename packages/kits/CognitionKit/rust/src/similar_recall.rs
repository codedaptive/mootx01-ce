//! Typed similar-recall recipe: the paraphrase door over the whole-record LSA
//! lane. Wraps `EstateCoordinator::similar_recall`; no fusion, no rerank.
//! Twin of Swift `SimilarRecall`.

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::Filter;

use crate::error::{RecipeRunError, SubstrateError};
use crate::precise_recall::PreciseMatch;

/// Output of the similar-recall recipe.
#[derive(Debug, Clone, PartialEq)]
pub struct SimilarRecallOutput {
    /// Matches nearest-first; `score` is the raw cosine similarity in `[-1, 1]`.
    pub matches: Vec<PreciseMatch>,
}

/// Execute the similar-recall recipe: the corpus engine's default float slot
/// (the whole-record LSA lane) is probed for the `limit` nearest drawers, which
/// are hydrated through `filter` and returned in lane order. `node_names`
/// resolves each drawer's room name for the match projection.
pub fn run(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    query: &str,
    limit: usize,
    filter: Filter,
    now: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
) -> Result<SimilarRecallOutput, RecipeRunError> {
    let hits = coord
        .similar_recall(handle, query, limit, filter, now)
        .map_err(|e| SubstrateError::new("similar_recall", format!("{e:?}")))?;
    let matches = hits
        .iter()
        .map(|hit| {
            let (room, content) = hit
                .drawer
                .as_ref()
                .map(|drawer| {
                    let room = node_names
                        .get(&drawer.parent_node_id)
                        .cloned()
                        .unwrap_or_default()
                        .1;
                    (room, drawer.content.clone())
                })
                .unwrap_or_default();
            PreciseMatch {
                id: hit.id.clone(),
                room,
                content,
                score: hit.score.final_score as f64,
            }
        })
        .collect();
    Ok(SimilarRecallOutput { matches })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::frames::CaptureFrame;

    /// Asserts the empty path: with no corpus engine registered for the estate
    /// the dense lane has no candidates and the recipe returns no matches. The
    /// whole-record LSA lane is not trained inside a unit test, so the
    /// ranked-first path is proven by the conformance suite, not here.
    #[test]
    fn no_registered_corpus_returns_no_matches() {
        const NOW: i64 = 1_700_000_000;
        let mut coordinator = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let handle = coordinator.open(store, OwnerCredentials::new("owner"), 0, 100).unwrap();
        coordinator.capture(&handle, CaptureFrame::new(
            "the api timeout is 30 seconds",
            CaptureChannel::Typed, "notes", LatticeAnchor::udc("004"),
            "aria-v2-test", "test-v1",
        ), NOW).unwrap();
        coordinator.capture(&handle, CaptureFrame::new(
            "grocery list apples and oranges",
            CaptureChannel::Typed, "notes", LatticeAnchor::udc("004"),
            "aria-v2-test", "test-v1",
        ), NOW).unwrap();

        let output = run(
            &coordinator, &handle, "how long before the api gives up?", 5,
            Filter::CurrentlyBelieve, NOW, &std::collections::HashMap::new(),
        ).expect("empty path is a typed outcome");
        assert!(output.matches.is_empty(), "no engine means no paraphrase candidates");
    }
}
