//! The paraphrase door: nearest drawers by whole-record LSA vector. The corpus
//! engine's DEFAULT float slot is the whole-record dense lane, so this verb
//! probes `float_nearest` directly, keeps the lane's nearest-first order,
//! hydrates the drawers through the estate's frame filter and surfaces them as
//! `RecallHit`s whose `final_score` is the raw cosine similarity. No fusion,
//! no rerank. Twin of Swift `GeniusLocusKit.similarRecall`.

use std::collections::BTreeMap;

use corpus_kit::FloatLaneOutcome;
use locus_kit::adjectives::State;
use locus_kit::drawer::Drawer;
use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};

use crate::coordinator::{EstateCoordinator, VerbDispatchError};
use crate::handle::EstateHandle;
use crate::recall::{RecallEvidencePath, RecallHit, RecallScoreVector};
use crate::verbs::lexicon::VerbError;

impl EstateCoordinator {
    /// Nearest drawers by whole-record LSA vector for a free-text question: the
    /// paraphrase door. Lane order preserved; drawers are hydrated and filtered
    /// by `filter`.
    ///
    /// `limit` values below 1 probe for a single hit. `_now` is carried for
    /// verb-surface parity with the other recall verbs; the dense probe reads
    /// no clock. Returns `final_score` = cosine similarity in `[-1, 1]` and
    /// `dense` = its `[0, 1]` normalisation. Empty when no corpus engine is
    /// registered, when the dense lane is dark for this query, or when nothing
    /// passes `filter`.
    pub fn similar_recall(
        &self,
        handle: &EstateHandle,
        query: &str,
        limit: usize,
        filter: Filter,
        _now: i64,
    ) -> Result<Vec<RecallHit>, VerbDispatchError> {
        let estate = self.estate_for_verb(handle)?;
        let Some(engine) = self.corpus_for(handle) else {
            return Ok(Vec::new());
        };
        let want = limit.max(1);
        // Every dark outcome (provider opt-out, no float rows, vocabulary miss,
        // empty query, store error) is a lane with nothing to say, not an error.
        let pairs = match engine.float_nearest(query, want) {
            FloatLaneOutcome::Hits(pairs) => pairs,
            _ => return Ok(Vec::new()),
        };
        let ids: Vec<String> = pairs.iter().map(|(id, _)| id.clone()).collect();
        // Hydrate through the frame filter: the evaluator applies `filter`, the
        // tombstone exclusion and the default sensitivity ceiling in one pass.
        // `Full` so the returned drawers carry their content for the caller.
        let mut frame = RecallFrame::new(vec![filter]);
        frame.hydration_level = HydrationLevel::Full;
        let filtered = estate
            .get_drawers_matching_frame(&ids, &frame)
            .map_err(|e| VerbDispatchError::Verb(VerbError::UnderlyingEstateFailure {
                verb: "similar_recall".to_string(),
                reason: format!("{e:?}"),
            }))?;
        let by_id: BTreeMap<String, Drawer> = filtered
            .admissible
            .into_iter()
            .map(|d| (d.id.clone(), d))
            .collect();
        let mut hits: Vec<RecallHit> = Vec::with_capacity(pairs.len());
        for (id, similarity) in pairs {
            let Some(drawer) = by_id.get(&id) else { continue };
            // A superseded row's lane entry lingers until the maintenance sweep;
            // it must never surface. ≤ Elevated without a grant: the same
            // ceiling vague_recall applies.
            if drawer.state() == State::Superseded
                || !drawer.adjective_sensitivity().is_bulk_exportable()
            {
                continue;
            }
            let mut score = RecallScoreVector::ZERO;
            score.final_score = similarity;
            // Same [0, 1] convention as the fused dense column: (sim + 1) / 2.
            score.dense = ((similarity + 1.0) / 2.0).clamp(0.0, 1.0);
            hits.push(RecallHit {
                id: id.clone(),
                drawer: Some(drawer.clone()),
                sources: vec![RecallEvidencePath::VectorDense],
                score,
                explanation: vec!["vectorDense".to_string()],
                span_hit: None,
            });
            if hits.len() >= want {
                break;
            }
        }
        Ok(hits)
    }
}
