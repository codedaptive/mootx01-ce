//! Source-grounded KGFact extraction duty.

use std::sync::Arc;

use fact_extraction_kit::contract::{
    FactAssertionKind, FactExtractor, FactExtractorKind,
    FactExtractorModelSpec, GroundedFactCandidate,
};
use fact_extraction_kit::grounding::FactSearchProjection;
use locus_kit::fact_extractor_model_store::{FactExtractorModelRow, FactExtractorModelStore};
use locus_kit::kg_fact::KGFactExtractionMetadata;
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
    pub chunks_processed: usize,
    pub scanned_sources: usize,
    pub deferred_sources: usize,
    pub inapplicable_sources: usize,
    pub rejected_sources: usize,
    pub made_progress: bool,
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
        let recipe_id = super::fact_extraction_workflow::workflow_recipe(recipe_id, extractor.spec());
        let recipe_id = recipe_id.as_str();
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

    /// Compatibility entry; production prepares under the coordinator lock and
    /// runs the returned work after releasing it.
    pub fn run_fact_extraction_batch(&self, handle: &EstateHandle, limit: usize, now: i64)
        -> Result<FactExtractionBatchResult, GeniusLocusKitError> {
        match self.prepare_fact_extraction_batch(handle, limit, now)? {
            Some(work) => work.run(),
            None => Ok(FactExtractionBatchResult::default()),
        }
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

pub(super) fn candidate_semantic_key(
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

pub(super) fn distilled_fact_id(source_id: &str, recipe_id: &str, semantic_key: &str) -> String {
    let digest = substrate_kernel::sha256::hash(
        format!("distilled-fact-v1|{source_id}|{recipe_id}|{semantic_key}").as_bytes(),
    );
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    uuid::Uuid::from_bytes(bytes).to_string()
}

pub(super) fn source_digest(source: &str) -> String {
    substrate_kernel::sha256::hash(source.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub(super) fn extraction_metadata(
    candidate: &GroundedFactCandidate,
    source_digest: &str,
    spec: &FactExtractorModelSpec,
) -> KGFactExtractionMetadata {
    KGFactExtractionMetadata {
        evidence_quote: candidate.evidence_quote.clone(),
        evidence_start: candidate.evidence_span.start as i64,
        evidence_end: candidate.evidence_span.end as i64,
        evidence_start_utf8_byte: candidate.evidence_span.start_utf8_byte as i64,
        evidence_end_utf8_byte: candidate.evidence_span.end_utf8_byte as i64,
        source_digest: source_digest.into(),
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
