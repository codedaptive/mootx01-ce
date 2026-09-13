//! Distilled, source-grounded KGFact extraction duty.

use std::collections::HashSet;
use std::sync::Arc;

use context_distill_lib::converter::ContextDistillConverter;
use context_distill_lib::distiller::ContextDistiller;
use context_distill_lib::input::DistillationInput;
use fact_extraction_kit::contract::{
    FactAssertionKind, FactExtractionRequest, FactExtractor, FactExtractorKind,
    FactExtractorModelSpec, FactSourceSpan, GroundedFactCandidate,
};
use fact_extraction_kit::grounding::{FactGroundingValidator, FactSearchProjection};
use locus_kit::fact_extractor_model_store::{FactExtractorModelRow, FactExtractorModelStore};
use locus_kit::kg_fact::{KGFact, KGFactExtractionMetadata, KGFactOrigin};
use locus_kit::kg_fact_operational::{KGAssertionKind, KGConfidenceBand, KGExtractorClass};
use substrate_kernel::bit_field;

use crate::coordinator::{EstateCoordinator, GeniusLocusKitError};
use crate::handle::EstateHandle;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FactExtractionBatchResult {
    pub completed_sources: usize,
    pub facts_filed: usize,
    pub candidates_rejected: usize,
    pub skipped_sources: usize,
    pub failed_sources: usize,
}

impl EstateCoordinator {
    /// Single activation point. Attaching an unchanged active recipe creates no
    /// debt; switching recipes atomically clears bit 28 estate-wide.
    pub fn activate_fact_extractor(
        &mut self,
        extractor: Arc<dyn FactExtractor>,
        recipe_id: &str,
        handle: &EstateHandle,
    ) -> Result<usize, GeniusLocusKitError> {
        if recipe_id.is_empty() {
            return Err(GeniusLocusKitError::UnderlyingEstateFailure {
                reason: "fact extractor recipe_id must not be empty".into(),
            });
        }
        let storage =
            self.storages
                .get(handle)
                .cloned()
                .ok_or(GeniusLocusKitError::EstateNotOpen {
                    estate_uuid: handle.estate_uuid,
                })?;
        let registry = FactExtractorModelStore::new(storage);
        let desired = model_row(recipe_id, extractor.spec());
        if registry
            .active()
            .map_err(glk_error)?
            .as_ref()
            .is_some_and(|active| same_recipe(active, &desired))
        {
            self.fact_extractors.insert(handle.clone(), extractor);
            self.fact_extractor_recipe_ids
                .insert(handle.clone(), recipe_id.into());
            return Ok(0);
        }
        registry.upsert(&desired).map_err(glk_error)?;
        let cleared = registry.activate(recipe_id).map_err(glk_error)?;
        self.fact_extractors.insert(handle.clone(), extractor);
        self.fact_extractor_recipe_ids
            .insert(handle.clone(), recipe_id.into());
        Ok(cleared)
    }

    pub fn unregister_fact_extractor(&mut self, handle: &EstateHandle) {
        self.fact_extractors.remove(handle);
        self.fact_extractor_recipe_ids.remove(handle);
    }

    pub fn registered_fact_extractor(
        &self,
        handle: &EstateHandle,
    ) -> Option<Arc<dyn FactExtractor>> {
        self.fact_extractors.get(handle).cloned()
    }

    /// Run one bounded duty batch. Per-source model or storage failures leave
    /// bit 28 clear and are reported rather than failing the product path.
    pub fn run_fact_extraction_batch(
        &self,
        handle: &EstateHandle,
        limit: usize,
        now: i64,
    ) -> Result<FactExtractionBatchResult, GeniusLocusKitError> {
        if limit == 0 {
            return Ok(FactExtractionBatchResult::default());
        }
        let Some(extractor) = self.fact_extractors.get(handle) else {
            return Ok(FactExtractionBatchResult::default());
        };
        let Some(recipe_id) = self.fact_extractor_recipe_ids.get(handle) else {
            return Ok(FactExtractionBatchResult::default());
        };
        let estate = self.estate_for_verb(handle).map_err(|error| {
            GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("{error:?}"),
            }
        })?;
        let pending = estate
            .fact_extraction_debt_batch(limit, None)
            .map_err(glk_error)?;
        let mut result = FactExtractionBatchResult::default();

        for drawer in pending {
            let source = drawer.content.clone();
            if source.is_empty() || drawer.tombstoned_at.is_some() {
                result.skipped_sources += 1;
                continue;
            }
            let outcome = (|| -> Result<(usize, usize), String> {
                let distilled = ContextDistiller::new().distill(
                    &DistillationInput::new(&source, ""),
                    ContextDistillConverter::IntentSpanV23Attributed,
                );
                let spans = source_spans(&distilled.selected_source_spans);
                let distilled_text: String = distilled
                    .mining_body
                    .chars()
                    .take(extractor.spec().maximum_input_characters)
                    .collect();
                let request = FactExtractionRequest {
                    source_id: drawer.id.clone(),
                    source_digest: distilled.source_sha256,
                    distilled_text,
                    eligible_source_spans: spans,
                    maximum_facts: extractor.spec().maximum_facts_per_source,
                };
                let response = extractor
                    .extract(&request)
                    .map_err(|error| error.to_string())?;
                let grounding = FactGroundingValidator::validate(
                    &response,
                    &request,
                    &source,
                    extractor.spec(),
                );
                if !response.candidates.is_empty() && grounding.accepted.is_empty() {
                    return Err("all non-empty model candidates failed grounding".into());
                }
                let live = estate
                    .get_drawers(&[drawer.id.as_str()])
                    .map_err(|error| error.to_string())?;
                if live
                    .first()
                    .map_or(true, |current| current.content != source)
                {
                    return Ok((0, grounding.rejected.len()));
                }

                let history: Vec<KGFact> = estate
                    .all_kg_facts_including_retired()
                    .map_err(|error| error.to_string())?
                    .into_iter()
                    .filter(|fact| fact.source_drawer_id == drawer.id)
                    .collect();
                let active: Vec<KGFact> = estate
                    .all_kg_facts()
                    .map_err(|error| error.to_string())?
                    .into_iter()
                    .filter(|fact| fact.source_drawer_id == drawer.id)
                    .collect();
                let mut desired_ids = HashSet::new();
                let mut newly_filed = Vec::new();
                let mut filed = 0;

                for candidate in &grounding.accepted {
                    let key =
                        candidate_semantic_key(candidate, &request.source_digest, extractor.spec());
                    if let Some(existing) =
                        active.iter().find(|fact| fact_semantic_key(fact) == key)
                    {
                        desired_ids.insert(existing.id.clone());
                        continue;
                    }
                    let base_id = distilled_fact_id(&drawer.id, recipe_id, &key);
                    let id = if history.iter().any(|fact| fact.id == base_id) {
                        let reactivation_ordinal = history
                            .iter()
                            .filter(|fact| fact_semantic_key(fact) == key)
                            .count();
                        distilled_fact_id(
                            &drawer.id,
                            recipe_id,
                            &format!("{key}|reactivated|{reactivation_ordinal}"),
                        )
                    } else {
                        base_id
                    };
                    let metadata = extraction_metadata(candidate, &request, extractor.spec());
                    self.add_kg_fact_with_id_origin_and_extraction(
                        handle,
                        &id,
                        &candidate.subject,
                        &candidate.predicate,
                        &candidate.object,
                        &drawer.id,
                        &KGFactOrigin {
                            added_by: "distilled-fact-duty".into(),
                            ..KGFactOrigin::default()
                        },
                        &metadata,
                        now,
                    )
                    .map_err(|error| format!("{error:?}"))?;
                    desired_ids.insert(id.clone());
                    newly_filed.push(id);
                    filed += 1;
                }

                for old in &active {
                    if !old.extraction_schema_version.is_empty() && !desired_ids.contains(&old.id) {
                        self.withdraw_kg_fact(handle, &old.id, "fact-extraction-duty", None, now)
                            .map_err(|error| format!("{error:?}"))?;
                    }
                }
                let settled = estate
                    .set_facts_extracted_if_content_matches(&drawer.id, &source)
                    .map_err(|error| error.to_string())?;
                if settled != 1 {
                    for id in newly_filed {
                        let _ = self.withdraw_kg_fact(handle, &id, "fact-extraction-duty", None, now);
                    }
                    return Ok((0, grounding.rejected.len()));
                }
                Ok((filed, grounding.rejected.len()))
            })();
            match outcome {
                Ok((filed, rejected)) => {
                    result.candidates_rejected += rejected;
                    if filed == 0 {
                        // Distinguish a successful zero/replay from a liveness
                        // skip by checking the settlement bit.
                        match estate.get_drawers(&[drawer.id.as_str()]) {
                            Ok(rows) if rows.first().is_some_and(|d| d.are_facts_extracted()) => {
                                result.completed_sources += 1;
                            }
                            _ => result.skipped_sources += 1,
                        }
                    } else {
                        result.completed_sources += 1;
                        result.facts_filed += filed;
                    }
                }
                Err(_) => result.failed_sources += 1,
            }
        }
        Ok(result)
    }
}

fn model_row(recipe_id: &str, spec: &FactExtractorModelSpec) -> FactExtractorModelRow {
    FactExtractorModelRow {
        recipe_id: recipe_id.into(),
        provider_id: spec.provider_id.clone(),
        model_id: spec.model_id.clone(),
        model_version: spec.model_version.clone(),
        schema_version: spec.schema_version.clone(),
        extractor_kind: match spec.extractor_kind {
            FactExtractorKind::FoundationModel => "foundationModel",
            FactExtractorKind::SpecializedModel => "specializedModel",
        }
        .into(),
        maximum_input_characters: spec.maximum_input_characters as i64,
        maximum_facts_per_source: spec.maximum_facts_per_source as i64,
        is_active: false,
    }
}

fn same_recipe(lhs: &FactExtractorModelRow, rhs: &FactExtractorModelRow) -> bool {
    lhs.is_active
        && lhs.recipe_id == rhs.recipe_id
        && lhs.provider_id == rhs.provider_id
        && lhs.model_id == rhs.model_id
        && lhs.model_version == rhs.model_version
        && lhs.schema_version == rhs.schema_version
        && lhs.extractor_kind == rhs.extractor_kind
        && lhs.maximum_input_characters == rhs.maximum_input_characters
        && lhs.maximum_facts_per_source == rhs.maximum_facts_per_source
}

fn source_spans(value: &serde_json::Value) -> Vec<FactSourceSpan> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|row| {
            Some(FactSourceSpan {
                start: row.get("start")?.as_u64()? as usize,
                end: row.get("end")?.as_u64()? as usize,
                start_utf8_byte: row.get("start_utf8_byte")?.as_u64()? as usize,
                end_utf8_byte: row.get("end_utf8_byte")?.as_u64()? as usize,
            })
        })
        .filter(|span| span.start <= span.end && span.start_utf8_byte <= span.end_utf8_byte)
        .collect()
}

fn candidate_semantic_key(
    candidate: &GroundedFactCandidate,
    digest: &str,
    spec: &FactExtractorModelSpec,
) -> String {
    let evidence_start = candidate.evidence_span.start.to_string();
    let evidence_end = candidate.evidence_span.end.to_string();
    [
        digest,
        &spec.provider_id,
        &spec.model_id,
        &spec.model_version,
        &spec.schema_version,
        &candidate.subject,
        &candidate.predicate,
        &candidate.object,
        &candidate.evidence_quote,
        &evidence_start,
        &evidence_end,
    ]
    .join("\0")
}

fn fact_semantic_key(fact: &KGFact) -> String {
    let evidence_start = fact.evidence_start.to_string();
    let evidence_end = fact.evidence_end.to_string();
    [
        fact.source_digest.as_str(),
        fact.extractor_provider_id.as_str(),
        fact.extractor_model_id.as_str(),
        fact.extractor_model_version.as_str(),
        fact.extraction_schema_version.as_str(),
        fact.subject.as_str(),
        fact.predicate.as_str(),
        fact.object.as_str(),
        fact.evidence_quote.as_str(),
        &evidence_start,
        &evidence_end,
    ]
    .join("\0")
}

fn distilled_fact_id(source_id: &str, recipe_id: &str, semantic_key: &str) -> String {
    substrate_kernel::sha256::hash(
        format!("distilled-fact-v1|{source_id}|{recipe_id}|{semantic_key}").as_bytes(),
    )
    .iter()
    .map(|byte| format!("{byte:02x}"))
    .collect()
}

fn extraction_metadata(
    candidate: &GroundedFactCandidate,
    request: &FactExtractionRequest,
    spec: &FactExtractorModelSpec,
) -> KGFactExtractionMetadata {
    KGFactExtractionMetadata {
        evidence_quote: candidate.evidence_quote.clone(),
        evidence_start: candidate.evidence_span.start as i64,
        evidence_end: candidate.evidence_span.end as i64,
        evidence_start_utf8_byte: candidate.evidence_span.start_utf8_byte as i64,
        evidence_end_utf8_byte: candidate.evidence_span.end_utf8_byte as i64,
        source_digest: request.source_digest.clone(),
        extractor_provider_id: spec.provider_id.clone(),
        extractor_model_id: spec.model_id.clone(),
        extractor_model_version: spec.model_version.clone(),
        extraction_schema_version: spec.schema_version.clone(),
        search_projection: candidate.search_projection.clone(),
        search_projection_version: FactSearchProjection::VERSION.into(),
        operational_bitmap: fact_operational_bitmap(
            spec.extractor_kind,
            candidate.assertion_kind,
            candidate.confidence,
        ),
    }
}

fn fact_operational_bitmap(
    kind: FactExtractorKind,
    assertion: FactAssertionKind,
    confidence: f64,
) -> i64 {
    let extractor = match kind {
        FactExtractorKind::FoundationModel => KGExtractorClass::FoundationModel,
        FactExtractorKind::SpecializedModel => KGExtractorClass::SpecializedModel,
    };
    let assertion = match assertion {
        FactAssertionKind::Asserted => KGAssertionKind::Asserted,
        FactAssertionKind::Inferred => KGAssertionKind::Inferred,
        FactAssertionKind::Hypothesized => KGAssertionKind::Hypothesized,
    };
    let band = if confidence >= 0.95 {
        KGConfidenceBand::Certain
    } else if confidence >= 0.80 {
        KGConfidenceBand::High
    } else if confidence >= 0.60 {
        KGConfidenceBand::Medium
    } else {
        KGConfidenceBand::Low
    };
    let mut bitmap = 0;
    bitmap = bit_field::write_field(extractor.raw_value(), bitmap, 0, 4);
    bitmap = bit_field::write_field(assertion.raw_value(), bitmap, 4, 3);
    bit_field::write_field(band.raw_value(), bitmap, 10, 3)
}

fn glk_error(error: locus_kit::error::LocusKitError) -> GeniusLocusKitError {
    GeniusLocusKitError::UnderlyingEstateFailure {
        reason: error.to_string(),
    }
}
