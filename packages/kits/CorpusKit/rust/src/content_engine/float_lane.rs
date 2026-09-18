// float_lane.rs: the whole-record dense float surface of `CorpusContentEngine`.
//
// The per-signal nearest
// and farthest recall the RecallDirector whole-record lane consumes, the
// discrimination signal, `recompose_dense_vector`, and the forced-error test
// seams. Swift twin: CorpusContentEngine+FloatLane.swift.

use super::*;
use intellectus_lib::{report, StatSample};
use crate::corpus::{discrimination_signal_from_outcome, FloatDiscriminationSignal, FloatLaneOutcome};
use synapsekit::engine::metric::FloatMetric;

/// Emit one CorpusKit-tagged counter (the same shape corpus.rs uses).
fn emit_engine_metric(name: &str, value: f64) {
    report!(StatSample::metric(
        name.to_string(),
        value,
        [("kit".to_string(), "CorpusKit".to_string())]
            .into_iter()
            .collect(),
        {
            use std::time::{SystemTime, UNIX_EPOCH};
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0)
        },
    ));
}

impl CorpusContentEngine {
    /// Re-embed ONLY the dense float (Lane D) vector for a single content ID.
    ///
    /// Resolves the current record from the source — picking up any newly-written
    /// `dense_composition_text` (e.g. a distillate written by the GLK drain rider)
    /// — and writes a fresh float-vector row (vector_index: 1) for each active slot.
    /// Only the float lane is updated: BM25, binary (Hamming) vectors, coverage,
    /// and the idempotence checkpoint are NOT touched.
    ///
    /// **Why not the full index path?** The idempotence gate keys on the CONTENT
    /// digest (unchanged by distillation). Calling `index_record(force: true)`
    /// would bypass the gate but also re-run BM25 indexing, disturbing IDF state.
    /// This method targets only the float lane, preserving §9 BM25 isolation
    /// (SPEC_DISTILLATION_STORAGE): BM25 scores are byte-identical before/after.
    ///
    /// Routes through the CCE (not direct to `VectorStore`) to maintain
    /// counts-admission serialization (FINDING_11X_MAINTENANCE_WALK_2026-07-28
    /// constraint 3). Returns `false` only when the ID no longer resolves.
    ///
    /// Swift parity: `CorpusContentEngine.recomposeDenseVector(id:now:)`.
    pub fn recompose_dense_vector(&self, id: &str, now_millis: i64) -> CorpusKitResult<bool> {
        Self::validate(id)?;
        match self.source.record(id)? {
            Some(record) => {
                self.recompose_dense_float(&record, now_millis)?;
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Dense-float-only vector upsert for one content record. Writes the float
    /// (vector_index: 1) row across all active slots using `effective_dense_text`.
    /// Does NOT touch BM25, binary vectors, coverage, or the checkpoint.
    /// Swift parity: `CorpusContentEngine.recomposeDenseFloat(record:now:)`.
    fn recompose_dense_float(
        &self,
        record: &CorpusContentRecord,
        now_millis: i64,
    ) -> CorpusKitResult<()> {
        // The whole-content key is the content ID itself. For passage mode,
        // passages use lexical text only — no dense-text split — so only the
        // whole-document float row is updated here, which is correct for all
        // GLK-attached configurations.
        let key = &record.id;
        let embed_text = record
            .dense_composition_text
            .as_deref()
            .unwrap_or(&record.text);

        let mut rows: Vec<VectorPayloadInput> = Vec::with_capacity(self.slots.len());
        for slot in &self.slots {
            let handle = slot.handle.lock().unwrap();
            let provider = handle.provider();
            let (_engram, floats) = provider
                .embed_pair(embed_text)
                .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{e:?}")))?;
            if floats.is_empty() {
                continue;
            }
            rows.push(VectorPayloadInput {
                item_id: key.clone(),
                vector_index: 1,
                payload: VectorPayload::from_f32(&floats),
                model_id: provider.model_id().to_string(),
                model_version: provider.model_version().to_string(),
                filed_at_unix_secs: now_millis,
            });
        }
        if !rows.is_empty() {
            self.vector_store
                .add_payloads(&rows)
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        }
        Ok(())
    }

    /// Per-signal dense float NEAREST recall — content-ID keyed.
    /// Per-signal dense float NEAREST recall.
    ///
    /// - `metric`: the float distance function. Defaults to `FloatMetric::Cosine`
    ///   so callers that do not pass a metric see byte-identical behaviour.
    pub fn float_nearest_per_signal(
        &self,
        query: &str,
        limit: usize,
        metric: FloatMetric,
    ) -> Vec<(String, FloatLaneOutcome)> {
        self.float_per_signal(query, limit, true, metric)
    }

    /// Per-signal dense float FARTHEST (anti-similarity) recall.
    ///
    /// - `metric`: the float distance function. Defaults to `FloatMetric::Cosine`.
    pub fn float_farthest_per_signal(
        &self,
        query: &str,
        limit: usize,
        metric: FloatMetric,
    ) -> Vec<(String, FloatLaneOutcome)> {
        self.float_per_signal(query, limit, false, metric)
    }

    /// Per-signal dense float nearest recall WITH per-query discrimination signal.
    ///
    /// Mirrors Swift `CorpusContentEngine.floatNearestPerSignalWithDiscrimination`.
    /// Same semantics and return shape as `float_nearest_per_signal`, but each entry
    /// carries an optional `FloatDiscriminationSignal` alongside the outcome.
    /// Discrimination is `Some` exactly when the outcome is `Hits` with ≥1 result.
    ///
    /// **Measurement only:** no behaviour change inside `CorpusContentEngine`.
    /// The coordinator (GLK) consumes the signal to discount the dense contribution
    /// when the lane self-reports degeneracy.
    ///
    /// See `FloatDiscriminationSignal` for the statistic definition.
    ///
    /// - `metric`: the float distance function; propagated to `float_nearest_per_signal`.
    pub fn float_nearest_per_signal_with_discrimination(
        &self,
        query: &str,
        limit: usize,
        metric: FloatMetric,
    ) -> Vec<(String, FloatLaneOutcome, Option<FloatDiscriminationSignal>)> {
        self.float_nearest_per_signal(query, limit, metric)
            .into_iter()
            .map(|(model_id, outcome)| {
                let disc = discrimination_signal_from_outcome(&outcome);
                (model_id, outcome, disc)
            })
            .collect()
    }

    /// Single-signal convenience: the DEFAULT slot's nearest outcome (cosine metric).
    pub fn float_nearest(&self, query: &str, limit: usize) -> FloatLaneOutcome {
        self.float_nearest_per_signal(query, limit, FloatMetric::Cosine)
            .into_iter()
            .next()
            .map(|(_, o)| o)
            .unwrap_or(FloatLaneOutcome::EmptyQuery)
    }

    fn float_per_signal(
        &self,
        query: &str,
        limit: usize,
        nearest: bool,
        metric: FloatMetric,
    ) -> Vec<(String, FloatLaneOutcome)> {
        if limit == 0 || query.is_empty() {
            return self
                .slots
                .iter()
                .map(|s| (s.model_id.clone(), FloatLaneOutcome::EmptyQuery))
                .collect();
        }
        // Consume the forced-error seam for the DEFAULT slot (nearest only).
        let mut forced_default: Option<FloatLaneOutcome> = None;
        if nearest {
            #[cfg(feature = "canonical-test-seams")]
            let forced_provider_opt_out = self
                .forced_float_provider_opt_out
                .swap(false, Ordering::AcqRel);
            #[cfg(not(feature = "canonical-test-seams"))]
            let forced_provider_opt_out = false;
            if forced_provider_opt_out {
                emit_engine_metric("corpus.float_lane.dark_provider", 1.0);
                forced_default = Some(FloatLaneOutcome::UnavailableProviderOptOut);
            } else if let Ok(mut guard) = self.forced_float_error.lock() {
                if let Some(message) = guard.take() {
                    emit_engine_metric("corpus.float_lane.store_error", 1.0);
                    forced_default = Some(FloatLaneOutcome::StoreError(message));
                }
            }
        }
        let mut results = Vec::with_capacity(self.slots.len());
        for (slot_index, slot) in self.slots.iter().enumerate() {
            let model_id = slot.model_id.clone();
            if slot_index == 0 {
                if let Some(forced) = forced_default.take() {
                    results.push((model_id, forced));
                    continue;
                }
            }
            let probe = {
                let handle = slot.handle.lock().unwrap();
                match handle.provider().embed_float(query) {
                    Ok(v) if v.is_empty() => {
                        emit_engine_metric("corpus.float_lane.dark_provider", 1.0);
                        results.push((model_id, FloatLaneOutcome::UnavailableProviderOptOut));
                        continue;
                    }
                    Ok(v) => v,
                    Err(synapsekit::SynapseKitError::EmbedFloatVocabMiss(_)) => {
                        emit_engine_metric("corpus.float_lane.dark_vocab_miss", 1.0);
                        results.push((model_id, FloatLaneOutcome::UnavailableNoVocabHit));
                        continue;
                    }
                    Err(_) => {
                        emit_engine_metric("corpus.float_lane.dark_provider", 1.0);
                        results.push((model_id, FloatLaneOutcome::UnavailableProviderOptOut));
                        continue;
                    }
                }
            };
            let matches = if nearest {
                self.vector_store
                    .find_nearest_float(&probe, &model_id, limit * 4, metric)
            } else {
                self.vector_store
                    .find_farthest_float(&probe, &model_id, limit * 4, metric)
            };
            let matches = match matches {
                Ok(m) => m,
                Err(e) => {
                    emit_engine_metric("corpus.float_lane.store_error", 1.0);
                    results.push((model_id, FloatLaneOutcome::StoreError(format!("{e:?}"))));
                    continue;
                }
            };
            if matches.is_empty() {
                emit_engine_metric("corpus.float_lane.dark_no_rows", 1.0);
                results.push((model_id, FloatLaneOutcome::UnavailableNoFloatRows));
                continue;
            }
            let mut by_content: BTreeMap<String, f32> = BTreeMap::new();
            for m in &matches {
                let id = content_id_from_item_key(&m.item_id).to_string();
                let similarity = 1.0 - (m.distance as f32) / 10_000.0;
                let entry =
                    by_content
                        .entry(id)
                        .or_insert(if nearest { f32::MIN } else { f32::MAX });
                if nearest {
                    if similarity > *entry {
                        *entry = similarity;
                    }
                } else if similarity < *entry {
                    *entry = similarity;
                }
            }
            if by_content.is_empty() {
                emit_engine_metric("corpus.float_lane.dark_no_rows", 1.0);
                results.push((model_id, FloatLaneOutcome::UnavailableNoFloatRows));
                continue;
            }
            let mut ranked: Vec<(String, f32)> = by_content.into_iter().collect();
            ranked.sort_by(|a, b| {
                let ord = if nearest {
                    b.1.partial_cmp(&a.1)
                } else {
                    a.1.partial_cmp(&b.1)
                };
                ord.unwrap_or(std::cmp::Ordering::Equal)
                    .then_with(|| a.0.cmp(&b.0))
            });
            ranked.truncate(limit);
            emit_engine_metric("corpus.float_lane.hit", ranked.len() as f64);
            results.push((model_id, FloatLaneOutcome::Hits(ranked)));
        }
        results
    }

    /// Test seam: force the next per-signal float call to report a store
    /// error for the DEFAULT slot (single-use).
    pub fn test_force_float_store_error(&self, message: impl Into<String>) {
        if let Ok(mut guard) = self.forced_float_error.lock() {
            *guard = Some(message.into());
        }
    }

    /// Test seam: force the next default float call to report provider opt-out.
    #[cfg(feature = "canonical-test-seams")]
    pub fn test_force_float_provider_opt_out(&self) {
        self.forced_float_provider_opt_out
            .store(true, Ordering::Release);
    }
}
