//! Typed transcript recall recipe.  The fixed balanced composition lives in
//! `shaped_recall`; this module supplies only the strict lower-stage request
//! and exposes its evidence to the operation boundary.

use genius_locus_kit::cross_encoder_stage::{CrossEncoderReport, StrictTranscriptEvidence};
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::{EstateCoordinator, RerankDirective};
use locus_kit::filter::Filter;

use crate::error::{RecipeRunError, SubstrateError};
use crate::precise_recall::PreciseMatch;
use crate::shaped_recall::balanced_union_best_request;

pub const TRANSCRIPT_POOL: usize = 50;
pub const TRANSCRIPT_HEAD: usize = 30;
pub const TRANSCRIPT_SPANS: usize = 3;
pub const TRANSCRIPT_RRF_K: usize = 60;

#[derive(Debug, Clone, PartialEq)]
pub struct TranscriptRecallOutput {
    pub matches: Vec<PreciseMatch>,
    pub cross_encoder: CrossEncoderReport,
    pub strict: StrictTranscriptEvidence,
}

/// Execute the fixed transcript recipe.  A strict lower-stage failure remains
/// a typed outcome; callers must inspect `strict.available` and turn false
/// into the operation's explicit unavailable response rather than presenting
/// the ordinary first-stage ordering as reranked output.
pub fn run(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    query: &str,
    filter: Filter,
    now: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
) -> Result<TranscriptRecallOutput, RecipeRunError> {
    let request = balanced_union_best_request(
        query, filter, TRANSCRIPT_POOL, None,
        Some(RerankDirective::strict_transcript(Some("transcript_strict"))),
    );
    let result = coord.recall_scored(handle, request, now)
        .map_err(|e| SubstrateError::new("recall_transcript", format!("{e:?}")))?;
    let cross_encoder = result.cross_encoder.clone().ok_or_else(|| SubstrateError::new("recall_transcript", "strict rerank report missing"))?;
    let strict = cross_encoder.strict_transcript.clone().ok_or_else(|| SubstrateError::new("recall_transcript", "strict rerank evidence missing"))?;
    let matches = if strict.available { result.hits.iter().map(|hit| {
        let (room, content) = hit.drawer.as_ref().map(|drawer| {
            let room = node_names.get(&drawer.parent_node_id).cloned().unwrap_or_default().1;
            (room, drawer.content.clone())
        }).unwrap_or_default();
        PreciseMatch { id: hit.id.clone(), room, content, score: hit.score.final_score as f64 }
    }).collect() } else { Vec::new() };
    Ok(TranscriptRecallOutput { matches, cross_encoder, strict })
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

    #[test]
    fn unavailable_strict_rerank_never_exposes_generic_matches() {
        const NOW: i64 = 1_700_000_000;
        let mut coordinator = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let handle = coordinator.open(store, OwnerCredentials::new("owner"), 0, 100).unwrap();
        coordinator.capture(&handle, CaptureFrame::new(
            "User: where is the transcript? Assistant: in the archive.",
            CaptureChannel::Typed, "transcripts", LatticeAnchor::udc("004"),
            "aria-v2-test", "test-v1",
        ), NOW).unwrap();

        let output = run(
            &coordinator, &handle, "where is the transcript?",
            Filter::CurrentlyBelieve, NOW, &std::collections::HashMap::new(),
        ).expect("typed unavailable outcome");
        assert!(!output.strict.available);
        assert!(output.matches.is_empty(), "required rerank failure must hide generic order");
    }
}
