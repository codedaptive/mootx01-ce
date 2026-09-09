//! Harness-first KGFact recall gate. Facts and sources are one result family.

use std::collections::{HashMap, HashSet};

use corpus_kit::engine::{Algorithm, BM25Parameters, BM25Weighting, TermFreqTable};
use corpus_kit::tokenizer::default_keyword_tokens;
use fact_extraction_kit::grounding::FactSearchProjection;
use locus_kit::drawer::Drawer;
use locus_kit::kg_fact::KGFact;

use crate::coordinator::{EstateCoordinator, GeniusLocusKitError};
use crate::handle::EstateHandle;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FactFirstRecallThresholds {
    pub minimum_top_score: f32,
    pub minimum_margin: f32,
    pub minimum_entity_containment: f32,
    pub vector_weight: f32,
}

impl Default for FactFirstRecallThresholds {
    fn default() -> Self {
        Self {
            minimum_top_score: 0.70,
            minimum_margin: 0.20,
            minimum_entity_containment: 1.0,
            vector_weight: 0.35,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct FactRecallFamily {
    pub fact: KGFact,
    pub source: Drawer,
    pub score: f32,
    pub lexical_score: f32,
    pub vector_score: Option<f32>,
    pub margin: f32,
    pub entity_containment: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub enum FactFirstRecallDecision {
    Solid(FactRecallFamily),
    FallThrough,
}

struct Scored<'a> {
    fact: &'a KGFact,
    source: &'a Drawer,
    score: f32,
    lexical: f32,
    vector: Option<f32>,
    containment: f32,
}

struct Eligible<'a> {
    fact: &'a KGFact,
    source: &'a Drawer,
    tokens: Vec<String>,
}

pub struct FactFirstRecallStage;

impl FactFirstRecallStage {
    pub fn decide(
        query: &str,
        query_entities: &[String],
        facts: &[KGFact],
        source_drawers: &HashMap<String, Drawer>,
        vector_scores: Option<&HashMap<String, f32>>,
        thresholds: FactFirstRecallThresholds,
    ) -> FactFirstRecallDecision {
        let entities: Vec<Vec<String>> = query_entities
            .iter()
            .map(|value| default_keyword_tokens(value))
            .filter(|value| !value.is_empty())
            .collect();
        if entities.is_empty() {
            return FactFirstRecallDecision::FallThrough;
        }
        let entity_tokens: HashSet<String> = entities.iter().flatten().cloned().collect();
        let query_tokens = distinctive_tokens(query, &entity_tokens);
        if query_tokens.is_empty() {
            return FactFirstRecallDecision::FallThrough;
        }
        let eligible: Vec<Eligible<'_>> = facts
            .iter()
            .filter_map(|fact| {
                if fact.search_projection.is_empty()
                    || fact.search_projection_version != FactSearchProjection::VERSION
                {
                    return None;
                }
                let source = source_drawers.get(&fact.source_drawer_id)?;
                if source.tombstoned_at.is_some() || !source.are_facts_extracted() {
                    return None;
                }
                let tokens = default_keyword_tokens(&fact.search_projection);
                if tokens.is_empty() {
                    return None;
                }
                Some(Eligible {
                    fact,
                    source,
                    tokens,
                })
            })
            .collect();
        if eligible.is_empty() {
            return FactFirstRecallDecision::FallThrough;
        }

        let mut term_freqs = TermFreqTable::new();
        let mut document_lengths = HashMap::new();
        for row in &eligible {
            document_lengths.insert(row.fact.id.clone(), row.tokens.len());
            let mut counts = HashMap::new();
            for token in &row.tokens {
                *counts.entry(token.clone()).or_insert(0usize) += 1;
            }
            for (term, frequency) in counts {
                term_freqs
                    .entry(term)
                    .or_default()
                    .insert(row.fact.id.clone(), frequency);
            }
        }
        let (index, term_mapping) =
            BM25Weighting::build(&term_freqs, &document_lengths, BM25Parameters::default());
        let mut query_terms: Vec<String> = query_tokens.iter().cloned().collect();
        query_terms.sort_unstable();
        let query_pairs = BM25Weighting::query_pairs(&query_terms, &term_mapping);
        let impacts = index.top_k(&query_pairs, eligible.len(), Algorithm::BlockMaxWand);
        let maximum_impact = impacts.first().map(|hit| hit.impact).unwrap_or(0.0);
        let normalized_impacts: HashMap<String, f32> = impacts
            .into_iter()
            .map(|hit| {
                let normalized = if maximum_impact > 0.0 {
                    hit.impact / maximum_impact
                } else {
                    0.0
                };
                (hit.item_id, normalized)
            })
            .collect();

        let vector_weight = thresholds.vector_weight.max(0.0).min(1.0);
        let mut scored: Vec<Scored<'_>> = eligible
            .iter()
            .map(|row| {
                let projection: HashSet<String> = row.tokens.iter().cloned().collect();
                let coverage = query_tokens.intersection(&projection).count() as f32
                    / query_tokens.len() as f32;
                // BM25 supplies corpus-aware ranking; multiplying by absolute
                // coverage prevents a one-term singleton corpus from looking solid.
                let lexical =
                    coverage * normalized_impacts.get(&row.fact.id).copied().unwrap_or(0.0);
                let vector = vector_scores
                    .and_then(|scores| scores.get(&row.fact.id))
                    .map(|score| score.max(0.0).min(1.0));
                let score = match vector {
                    Some(vector) => lexical * (1.0 - vector_weight) + vector * vector_weight,
                    None => lexical,
                };
                let identity: HashSet<String> =
                    default_keyword_tokens(&format!("{} {}", row.fact.subject, row.fact.object))
                        .into_iter()
                        .collect();
                let contained = entities
                    .iter()
                    .filter(|entity| entity.iter().all(|token| identity.contains(token)))
                    .count();
                Scored {
                    fact: row.fact,
                    source: row.source,
                    score,
                    lexical,
                    vector,
                    containment: contained as f32 / entities.len() as f32,
                }
            })
            .collect();
        scored.sort_by(|left, right| {
            right
                .score
                .total_cmp(&left.score)
                .then_with(|| left.fact.id.cmp(&right.fact.id))
        });
        let Some(top) = scored.first() else {
            return FactFirstRecallDecision::FallThrough;
        };
        let second = scored.get(1).map(|row| row.score).unwrap_or(0.0);
        let margin = top.score - second;
        if top.score < thresholds.minimum_top_score
            || margin < thresholds.minimum_margin
            || top.containment < thresholds.minimum_entity_containment
        {
            return FactFirstRecallDecision::FallThrough;
        }
        FactFirstRecallDecision::Solid(FactRecallFamily {
            fact: top.fact.clone(),
            source: top.source.clone(),
            score: top.score,
            lexical_score: top.lexical,
            vector_score: top.vector,
            margin,
            entity_containment: top.containment,
        })
    }
}

impl EstateCoordinator {
    /// Explicit fact-only recall entry point. The ordinary RecallDirector is
    /// unchanged until benchmark qualification chooses a product call site.
    pub fn recall_fact_first(
        &self,
        handle: &EstateHandle,
        query: &str,
        query_entities: &[String],
        vector_scores: Option<&HashMap<String, f32>>,
        thresholds: FactFirstRecallThresholds,
    ) -> Result<FactFirstRecallDecision, GeniusLocusKitError> {
        let estate = self.estate_for_verb(handle).map_err(|error| {
            GeniusLocusKitError::UnderlyingEstateFailure {
                reason: format!("{error:?}"),
            }
        })?;
        let facts = estate.all_kg_facts().map_err(glk_error)?;
        let ids: Vec<&str> = facts
            .iter()
            .map(|fact| fact.source_drawer_id.as_str())
            .collect();
        let drawers = estate.get_drawers(&ids).map_err(glk_error)?;
        let source_drawers = drawers
            .into_iter()
            .map(|drawer| (drawer.id.clone(), drawer))
            .collect();
        Ok(FactFirstRecallStage::decide(
            query,
            query_entities,
            &facts,
            &source_drawers,
            vector_scores,
            thresholds,
        ))
    }
}

fn distinctive_tokens(query: &str, entity_tokens: &HashSet<String>) -> HashSet<String> {
    default_keyword_tokens(query)
        .into_iter()
        .filter_map(|token| {
            if is_stop_word(&token) {
                None
            } else if token.ends_with('s') {
                let singular = token[..token.len() - 1].to_string();
                if entity_tokens.contains(&singular) {
                    Some(singular)
                } else {
                    Some(token)
                }
            } else {
                Some(token)
            }
        })
        .collect()
}

fn is_stop_word(token: &str) -> bool {
    matches!(
        token,
        "a" | "an"
            | "and"
            | "are"
            | "do"
            | "does"
            | "for"
            | "how"
            | "i"
            | "in"
            | "is"
            | "it"
            | "me"
            | "my"
            | "of"
            | "on"
            | "the"
            | "to"
            | "was"
            | "what"
            | "when"
            | "where"
            | "who"
            | "why"
    )
}

fn glk_error(error: locus_kit::error::LocusKitError) -> GeniusLocusKitError {
    GeniusLocusKitError::UnderlyingEstateFailure {
        reason: error.to_string(),
    }
}
