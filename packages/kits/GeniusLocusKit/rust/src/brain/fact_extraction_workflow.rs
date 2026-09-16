//! GLK owns extraction policy and progress. QueueKit stores opaque CAS-fenced
//! checkpoints; LocusKit owns the guarded atomic fact publication.
use super::fact_extraction_duty::{
    candidate_semantic_key, distilled_fact_id, extraction_metadata, source_digest,
    FactExtractionBatchResult,
};
use crate::{
    coordinator::{EstateCoordinator, GeniusLocusKitError},
    handle::EstateHandle,
};
use fact_extraction_kit::{
    next_fact_source_chunk, FactExtractionError as Error, FactExtractionOutcome as Outcome,
    FactExtractionRequest, FactExtractor, FactExtractorModelSpec, FactGroundingValidator,
    GroundedFactCandidate,
};
use locus_kit::drawer_operational::ContentKind;
use locus_kit::{drawer::Drawer, estate::Estate, kg_fact::KGFact};
use persistence_kit::storage::BackendConfiguration;
use queuekit::{JobId, QueueCheckpointStore, StreamId, HLC};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Instant;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Progress {
    version: usize,
    source_id: String,
    source_digest: String,
    recipe_id: String,
    content_kind: i64,
    outcome: Outcome,
    next_start: usize,
    #[serde(rename = "nextStartUTF8Byte")]
    next_start_utf8_byte: usize,
    maximum_characters: usize,
    ready_to_publish: bool,
    candidates: Vec<GroundedFactCandidate>,
    rejected_candidates: usize,
    attempts: usize,
    malformed_attempts: usize,
    next_attempt_at: f64,
    lease_until: f64,
    lease_token: String,
    reason: String,
}
impl Progress {
    fn new(drawer: &Drawer, digest: String, recipe: &str, maximum: usize) -> Self {
        Self {
            version: 1,
            source_id: drawer.id.clone(),
            source_digest: digest,
            recipe_id: recipe.into(),
            content_kind: drawer.content_kind().raw_value(),
            outcome: Outcome::Pending,
            next_start: 0,
            next_start_utf8_byte: 0,
            maximum_characters: maximum,
            ready_to_publish: false,
            candidates: vec![],
            rejected_candidates: 0,
            attempts: 0,
            malformed_attempts: 0,
            next_attempt_at: 0.0,
            lease_until: 0.0,
            lease_token: String::new(),
            reason: String::new(),
        }
    }
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Sweep {
    after_source_id: Option<String>,
}

#[derive(Debug)]
pub struct FactExtractionWorkStatus {
    pub runnable: usize,
    pub in_flight: usize,
    pub partial: usize,
    pub retrying: usize,
    pub blocked: usize,
    pub rejected: usize,
    pub not_applicable: usize,
    pub completed_empty: usize,
    // False when no extractor is registered for the estate; the detail
    // prepends the explanation so an operator reading moot_drain_status with
    // pending rows sees "no extractor registered" ahead of the counts.
    pub extractor_registered: bool,
}
impl Default for FactExtractionWorkStatus {
    fn default() -> Self {
        Self {
            runnable: 0,
            in_flight: 0,
            partial: 0,
            retrying: 0,
            blocked: 0,
            rejected: 0,
            not_applicable: 0,
            completed_empty: 0,
            extractor_registered: true,
        }
    }
}
impl FactExtractionWorkStatus {
    pub fn detail(&self) -> String {
        let counts = format!(
            "ready: {}, running: {}, partial: {}, retrying: {}, blocked: {}, rejected: {}, not applicable: {}, empty: {}",
            self.runnable, self.in_flight, self.partial, self.retrying, self.blocked,
            self.rejected, self.not_applicable, self.completed_empty
        );
        if !self.extractor_registered {
            return format!("no extractor registered; {counts}");
        }
        counts
    }
}
fn stream() -> StreamId {
    StreamId("fact-extraction-checkpoints".into())
}
fn work_id(source: &str) -> JobId {
    JobId(source_digest(&format!("fact-work-v1|{source}"))[..32].into())
}
fn stamp(now: i64) -> HLC {
    HLC {
        physical_time: now,
        logical_count: 0,
        node_id: 0,
    }
}
fn failure(error: impl std::fmt::Debug) -> GeniusLocusKitError {
    GeniusLocusKitError::UnderlyingEstateFailure {
        reason: format!("{error:?}"),
    }
}
pub(super) fn workflow_recipe(base: &str, spec: &FactExtractorModelSpec) -> String {
    let marker = "|fact-workflow-v2|";
    let root = base.split(marker).next().unwrap_or(base);
    let identity = [
        &spec.provider_id,
        &spec.model_id,
        &spec.model_version,
        &spec.schema_version,
        &spec.maximum_input_characters.to_string(),
        &spec.maximum_facts_per_source.to_string(),
        "original-overlap-v2",
        "array-prompt-v2",
        "grounding-v1",
        "eligibility-v1",
    ]
    .join("|");
    format!("{root}{marker}{}", source_digest(&identity))
}

impl EstateCoordinator {
    fn fact_checkpoints(
        &self,
        handle: &EstateHandle,
    ) -> Result<QueueCheckpointStore, GeniusLocusKitError> {
        self.ensure_dreaming_queue(handle);
        let map = self.dreaming_queues.borrow();
        let (queue, _) = map
            .get(handle)
            .ok_or_else(|| failure("extraction queue not mounted"))?;
        let checkpoints = QueueCheckpointStore::new(queue).map_err(failure)?;
        if let Some(storage) = self.storages.get(handle) {
            if !matches!(
                storage.configuration().backend,
                BackendConfiguration::InMemory
            ) && !checkpoints.is_persistent()
            {
                return Err(failure(
                    "fact extraction requires a durable queue for a persistent estate",
                ));
            }
        }
        Ok(checkpoints)
    }

    pub fn prepare_fact_extraction_batch(
        &self,
        handle: &EstateHandle,
        limit: usize,
        now: i64,
    ) -> Result<Option<FactExtractionBatchWork>, GeniusLocusKitError> {
        let Some(extractor) = self.fact_extractors.get(handle).cloned() else {
            return Ok(None);
        };
        let Some(recipe_id) = self.fact_extractor_recipe_ids.get(handle).cloned() else {
            return Ok(None);
        };
        if limit == 0 {
            return Ok(None);
        }
        let estate = self.estate_for_verb(handle).map_err(failure)?.clone();
        let checkpoints = self.fact_checkpoints(handle)?;
        let Some(lease) = checkpoints
            .acquire_drain_lease(&super::duty_queue::DutyKind::FactExtraction.stream_id())
            .map_err(failure)?
        else {
            return Ok(None);
        };
        if checkpoints.is_persistent() {
            if let Some((queue, _)) = self.dreaming_queues.borrow().get(handle) {
                queue
                    .reclaim_in_flight_for_stream(
                        &super::duty_queue::DutyKind::FactExtraction.stream_id(),
                    )
                    .map_err(failure)?;
            }
        }
        let cursor_id = work_id("sweep");
        let cursor_stream = StreamId("fact-extraction-sweep".into());
        let previous = checkpoints
            .read(&cursor_id, &cursor_stream)
            .map_err(failure)?;
        let cursor = previous
            .as_ref()
            .map(|data| serde_json::from_slice::<Sweep>(data))
            .transpose()
            .map_err(failure)?;
        let after = cursor
            .as_ref()
            .and_then(|cursor| cursor.after_source_id.as_deref());
        let mut drawers = estate
            .fact_extraction_debt_batch(limit, after)
            .map_err(failure)?;
        let wrapped = drawers.is_empty() && after.is_some();
        if wrapped {
            drawers = estate
                .fact_extraction_debt_batch(limit, None)
                .map_err(failure)?;
        }
        let cursor = Sweep {
            after_source_id: drawers.last().map(|drawer| drawer.id.clone()),
        };
        checkpoints
            .compare_and_swap(
                &cursor_id,
                &cursor_stream,
                previous.as_deref(),
                &serde_json::to_vec(&cursor).map_err(failure)?,
                stamp(now),
            )
            .map_err(failure)?;
        let traversed_forward = !wrapped && !drawers.is_empty();
        Ok(Some(FactExtractionBatchWork {
            drawers,
            extractor,
            recipe_id,
            checkpoints,
            estate,
            now,
            traversed_forward,
            _lease: lease,
        }))
    }

    pub fn fact_extraction_work_status(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<FactExtractionWorkStatus, GeniusLocusKitError> {
        let estate = self.estate_for_verb(handle).map_err(failure)?;
        let mut status = FactExtractionWorkStatus {
            runnable: estate.count_fact_extraction_debt().map_err(failure)?,
            ..Default::default()
        };
        let Some(recipe_id) = self.fact_extractor_recipe_ids.get(handle) else {
            status.blocked = status.runnable;
            status.runnable = 0;
            status.extractor_registered = false;
            return Ok(status);
        };
        let map = self.dreaming_queues.borrow();
        let Some((queue, _)) = map.get(handle) else {
            return Ok(status);
        };
        let checkpoints = QueueCheckpointStore::new(queue).map_err(failure)?;
        drop(map);
        for payload in checkpoints.payloads(&stream()).map_err(failure)? {
            let state: Progress = serde_json::from_slice(&payload).map_err(failure)?;
            if state.outcome == Outcome::Completed {
                continue;
            }
            if &state.recipe_id != recipe_id {
                continue;
            }
            let sources = estate.get_drawers(&[&state.source_id]).map_err(failure)?;
            let Some(source) = sources.first() else {
                continue;
            };
            if source.tombstoned_at.is_some()
                || source.adjective_bitmap & 63
                    >= substrate_types::RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW as i64
                || source_digest(&source.content) != state.source_digest
                || source.content_kind().raw_value() != state.content_kind
            {
                continue;
            }
            if state.outcome == Outcome::CompletedEmpty
                || (state.ready_to_publish
                    && state.candidates.is_empty()
                    && source.are_facts_extracted())
            {
                status.completed_empty += 1;
            }
            if source.are_facts_extracted() {
                continue;
            }
            let epoch = now as f64 / 1000.0;
            let excluded = if state.lease_until > epoch {
                status.in_flight += 1;
                true
            } else if state.outcome == Outcome::NotApplicable {
                status.not_applicable += 1;
                true
            } else if state.outcome == Outcome::Rejected {
                status.rejected += 1;
                true
            } else if state.next_attempt_at > epoch {
                if state.outcome == Outcome::BlockedProvider {
                    status.blocked += 1;
                } else {
                    status.retrying += 1;
                }
                true
            } else {
                false
            };
            if excluded {
                status.runnable = status.runnable.saturating_sub(1);
            }
            if state.next_start > 0 && !state.outcome.is_terminal() {
                status.partial += 1;
            }
        }
        Ok(status)
    }
}

/// Owns immutable input snapshots and independent kit handles. Run outside the
/// resident coordinator mutex; storage transaction/queue CAS remain authoritative.
pub struct FactExtractionBatchWork {
    drawers: Vec<Drawer>,
    extractor: Arc<dyn FactExtractor>,
    recipe_id: String,
    checkpoints: QueueCheckpointStore,
    estate: Estate,
    now: i64,
    traversed_forward: bool,
    _lease: queuekit::QueueCheckpointLease,
}
impl FactExtractionBatchWork {
    pub fn run(self) -> Result<FactExtractionBatchResult, GeniusLocusKitError> {
        let mut report = FactExtractionBatchResult {
            scanned_sources: self.drawers.len(),
            ..Default::default()
        };
        let started = Instant::now();
        for drawer in &self.drawers {
            let now = self.now + started.elapsed().as_millis() as i64;
            let epoch = now as f64 / 1000.0;
            let id = work_id(&drawer.id);
            let previous = self.checkpoints.read(&id, &stream()).map_err(failure)?;
            let digest = source_digest(&drawer.content);
            let mut state = match &previous {
                Some(data) => serde_json::from_slice::<Progress>(data).map_err(failure)?,
                None => Progress::new(
                    drawer,
                    digest.clone(),
                    &self.recipe_id,
                    self.extractor.spec().maximum_input_characters,
                ),
            };
            if state.version != 1 {
                return Err(failure("unsupported fact checkpoint version"));
            }
            if state.source_digest != digest
                || state.recipe_id != self.recipe_id
                || state.content_kind != drawer.content_kind().raw_value()
                || matches!(state.outcome, Outcome::Completed | Outcome::CompletedEmpty)
            {
                state = Progress::new(
                    drawer,
                    digest.clone(),
                    &self.recipe_id,
                    self.extractor.spec().maximum_input_characters,
                );
            }
            if state.outcome.is_terminal()
                || state.next_attempt_at > epoch
                || state.lease_until > epoch
            {
                report.deferred_sources += 1;
                continue;
            }
            state.lease_token = uuid::Uuid::new_v4().to_string();
            state.lease_until = epoch + 120.0;
            let claim = serde_json::to_vec(&state).map_err(failure)?;
            if !self
                .checkpoints
                .compare_and_swap(&id, &stream(), previous.as_deref(), &claim, stamp(now))
                .map_err(failure)?
            {
                report.skipped_sources += 1;
                continue;
            }
            let attempt = (|| -> Result<(), Error> {
                if matches!(
                    drawer.content_kind(),
                    ContentKind::FingerprintOnly | ContentKind::Dataset
                ) || drawer.content.trim().is_empty()
                {
                    state.outcome = Outcome::NotApplicable;
                    state.reason = "eligibility-v1: structural handle or no textual content".into();
                    report.inapplicable_sources += 1;
                } else if !state.ready_to_publish {
                    let chunk = next_fact_source_chunk(
                        &drawer.content,
                        state.next_start,
                        state.next_start_utf8_byte,
                        state.maximum_characters,
                    )
                    .ok_or_else(|| Error::InvalidRequest("invalid source continuation".into()))?;
                    let request = FactExtractionRequest {
                        source_id: drawer.id.clone(),
                        source_digest: digest.clone(),
                        source_text: chunk.text.clone(),
                        eligible_source_spans: vec![chunk.span.clone()],
                        maximum_facts: self.extractor.spec().maximum_facts_per_source,
                    };
                    let response = self.extractor.extract(&request)?;
                    if response.candidates.len() >= request.maximum_facts {
                        return Err(Error::NeedsSubdivision(
                            "response reached its fact budget".into(),
                        ));
                    }
                    let grounding = FactGroundingValidator::validate_chunk(
                        &response,
                        &request,
                        &chunk,
                        self.extractor.spec(),
                    );
                    report.candidates_rejected += grounding.rejected.len();
                    state.rejected_candidates += grounding.rejected.len();
                    if !grounding.rejected.is_empty() && grounding.accepted.is_empty() {
                        return Err(Error::MalformedResponse(
                            "all candidates rejected by source grounding".into(),
                        ));
                    }
                    for candidate in grounding.accepted {
                        let key =
                            candidate_semantic_key(&candidate, &digest, self.extractor.spec());
                        if !state.candidates.iter().any(|old| {
                            candidate_semantic_key(old, &digest, self.extractor.spec()) == key
                        }) {
                            state.candidates.push(candidate);
                        }
                    }
                    state.ready_to_publish = chunk.span.end_utf8_byte == drawer.content.len();
                    let overlap = if state.ready_to_publish {
                        0
                    } else {
                        FactGroundingValidator::MAXIMUM_EVIDENCE_CHARACTERS
                            .min(state.maximum_characters / 4)
                    };
                    let overlap_bytes: usize = chunk
                        .text
                        .chars()
                        .rev()
                        .take(overlap)
                        .map(char::len_utf8)
                        .sum();
                    state.next_start = chunk.span.end - overlap;
                    state.next_start_utf8_byte = chunk.span.end_utf8_byte - overlap_bytes;
                    state.attempts = 0;
                    state.malformed_attempts = 0;
                    state.next_attempt_at = 0.0;
                    state.outcome = Outcome::Partial;
                    state.reason.clear();
                    report.chunks_processed += 1;
                }
                Ok(())
            })();
            if let Err(error) = attempt {
                report.failed_sources += 1;
                state.attempts += 1;
                state.reason = error.to_string().chars().take(512).collect();
                match error {
                    Error::NeedsSubdivision(_) if state.maximum_characters > 128 => {
                        state.maximum_characters = (state.maximum_characters / 2).max(128);
                        state.outcome = Outcome::NeedsSubdivision;
                        state.next_attempt_at = 0.0;
                    }
                    Error::NeedsSubdivision(_) | Error::InvalidRequest(_) => {
                        state.outcome = Outcome::Rejected;
                        report.rejected_sources += 1;
                    }
                    Error::MalformedResponse(_) => {
                        state.malformed_attempts += 1;
                        if state.malformed_attempts < 2 {
                            state.maximum_characters = state
                                .maximum_characters
                                .min((state.maximum_characters / 2).max(128));
                            state.outcome = Outcome::RetryScheduled;
                            state.next_attempt_at = epoch + 30.0;
                        } else {
                            state.outcome = Outcome::Rejected;
                            report.rejected_sources += 1;
                        }
                    }
                    Error::Unavailable(_) => {
                        state.outcome = Outcome::BlockedProvider;
                        state.next_attempt_at = epoch + 300.0;
                    }
                    _ => {
                        state.outcome = Outcome::RetryScheduled;
                        state.next_attempt_at = epoch
                            + (30.0 * 2_f64.powi((state.attempts - 1).min(7) as i32)).min(3600.0);
                    }
                }
            }
            state.lease_until = 0.0;
            state.lease_token.clear();
            let staged = serde_json::to_vec(&state).map_err(failure)?;
            if !self
                .checkpoints
                .compare_and_swap(&id, &stream(), Some(&claim), &staged, stamp(now))
                .map_err(failure)?
            {
                report.skipped_sources += 1;
                continue;
            }
            report.made_progress = true;
            if state.ready_to_publish && state.outcome == Outcome::Partial {
                let facts: Vec<_> = state
                    .candidates
                    .iter()
                    .map(|candidate| {
                        let key = candidate_semantic_key(candidate, &digest, self.extractor.spec());
                        let metadata =
                            extraction_metadata(candidate, &digest, self.extractor.spec());
                        KGFact {
                            added_by: "distilled-fact-duty".into(),
                            evidence_quote: metadata.evidence_quote,
                            evidence_start: metadata.evidence_start,
                            evidence_end: metadata.evidence_end,
                            evidence_start_utf8_byte: metadata.evidence_start_utf8_byte,
                            evidence_end_utf8_byte: metadata.evidence_end_utf8_byte,
                            source_digest: metadata.source_digest,
                            extractor_provider_id: metadata.extractor_provider_id,
                            extractor_model_id: metadata.extractor_model_id,
                            extractor_model_version: metadata.extractor_model_version,
                            extraction_schema_version: metadata.extraction_schema_version,
                            search_projection: metadata.search_projection,
                            search_projection_version: metadata.search_projection_version,
                            operational_bitmap: metadata.operational_bitmap,
                            ..KGFact::new(
                                distilled_fact_id(&drawer.id, &self.recipe_id, &key),
                                candidate.subject.clone(),
                                candidate.predicate.clone(),
                                candidate.object.clone(),
                                drawer.id.clone(),
                                now,
                            )
                        }
                    })
                    .collect();
                if let Some(count) = self
                    .estate
                    .publish_extracted_facts(
                        &drawer.id,
                        &drawer.content,
                        &self.recipe_id,
                        &facts,
                        now,
                    )
                    .map_err(failure)?
                {
                    report.facts_filed += count;
                    report.completed_sources += 1;
                    state.outcome = if facts.is_empty() {
                        Outcome::CompletedEmpty
                    } else {
                        Outcome::Completed
                    };
                    state.candidates.clear();
                    self.checkpoints
                        .compare_and_swap(
                            &id,
                            &stream(),
                            Some(&staged),
                            &serde_json::to_vec(&state).map_err(failure)?,
                            stamp(now),
                        )
                        .map_err(failure)?;
                } else {
                    report.skipped_sources += 1;
                }
            }
        }
        report.made_progress |= report.chunks_processed > 0
            || report.completed_sources > 0
            || report.inapplicable_sources > 0
            || self.traversed_forward;
        Ok(report)
    }
}
