use std::collections::HashSet;

use crate::contract::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FactGroundingRejection {
    ResponseIdentityMismatch,
    SourceDigestMismatch,
    TooManyCandidates,
    EmptyField,
    FieldTooLong,
    InvalidConfidence,
    EvidenceNotFound,
    EvidenceOutsideSelectedSpans,
    AmbiguousEvidence,
    UnsupportedValues,
    Duplicate,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FactGroundingReport {
    pub accepted: Vec<GroundedFactCandidate>,
    pub rejected: Vec<FactGroundingRejection>,
}

pub struct FactGroundingValidator;

impl FactGroundingValidator {
    pub const MAXIMUM_FIELD_CHARACTERS: usize = 240;
    pub const MAXIMUM_EVIDENCE_CHARACTERS: usize = 600;
    pub const MAXIMUM_ALIAS_COUNT: usize = 12;

    pub fn validate(
        response: &FactExtractionResponse,
        request: &FactExtractionRequest,
        original_source: &str,
        expected_spec: &FactExtractorModelSpec,
    ) -> FactGroundingReport {
        if response.provider_id != expected_spec.provider_id
            || response.model_id != expected_spec.model_id
            || response.model_version != expected_spec.model_version
            || response.schema_version != expected_spec.schema_version
        {
            return FactGroundingReport {
                accepted: vec![],
                rejected: vec![FactGroundingRejection::ResponseIdentityMismatch],
            };
        }
        if response.source_digest != request.source_digest {
            return FactGroundingReport {
                accepted: vec![],
                rejected: vec![FactGroundingRejection::SourceDigestMismatch],
            };
        }
        if response.candidates.len()
            > request
                .maximum_facts
                .min(expected_spec.maximum_facts_per_source)
        {
            return FactGroundingReport {
                accepted: vec![],
                rejected: vec![FactGroundingRejection::TooManyCandidates],
            };
        }

        // Rust `char` and Swift `Unicode.Scalar` are the shared offset unit.
        // UTF-8 byte positions are carried separately on `FactSourceSpan`.
        let source_scalars: Vec<char> = original_source.chars().collect();
        let mut accepted = Vec::new();
        let mut rejected = Vec::new();
        let mut seen = HashSet::new();

        for candidate in &response.candidates {
            let subject = normalize(&candidate.subject);
            let predicate = normalize(&candidate.predicate);
            let object = normalize(&candidate.object);
            let evidence = candidate.evidence_quote.trim().to_string();
            if subject.is_empty()
                || predicate.is_empty()
                || object.is_empty()
                || evidence.is_empty()
            {
                rejected.push(FactGroundingRejection::EmptyField);
                continue;
            }
            if subject.chars().count() > Self::MAXIMUM_FIELD_CHARACTERS
                || predicate.chars().count() > Self::MAXIMUM_FIELD_CHARACTERS
                || object.chars().count() > Self::MAXIMUM_FIELD_CHARACTERS
                || evidence.chars().count() > Self::MAXIMUM_EVIDENCE_CHARACTERS
            {
                rejected.push(FactGroundingRejection::FieldTooLong);
                continue;
            }
            if !candidate.confidence.is_finite() || !(0.0..=1.0).contains(&candidate.confidence) {
                rejected.push(FactGroundingRejection::InvalidConfidence);
                continue;
            }
            let needle: Vec<char> = evidence.chars().collect();
            let occurrences = occurrences(&needle, &source_scalars);
            if occurrences.is_empty() {
                rejected.push(FactGroundingRejection::EvidenceNotFound);
                continue;
            }
            let eligible: Vec<_> = occurrences
                .into_iter()
                .filter(|(start, end)| {
                    request
                        .eligible_source_spans
                        .iter()
                        .any(|span| span.start <= *start && *end <= span.end)
                })
                .collect();
            if eligible.is_empty() {
                rejected.push(FactGroundingRejection::EvidenceOutsideSelectedSpans);
                continue;
            }
            if eligible.len() != 1 {
                rejected.push(FactGroundingRejection::AmbiguousEvidence);
                continue;
            }
            let evidence_tokens = grounding_tokens(&evidence);
            if !grounding_tokens(&subject).is_subset(&evidence_tokens)
                || !grounding_tokens(&object).is_subset(&evidence_tokens)
            {
                rejected.push(FactGroundingRejection::UnsupportedValues);
                continue;
            }

            let identity = format!(
                "{}\0{}\0{}",
                subject.to_lowercase(),
                predicate.to_lowercase(),
                object.to_lowercase()
            );
            if !seen.insert(identity) {
                rejected.push(FactGroundingRejection::Duplicate);
                continue;
            }

            let (start, end) = eligible[0];
            let start_utf8_byte = source_scalars[..start].iter().collect::<String>().len();
            let end_utf8_byte = source_scalars[..end].iter().collect::<String>().len();
            let aliases = normalized_aliases(&candidate.search_aliases);
            let projection = FactSearchProjection::build(&subject, &predicate, &object, &aliases);
            accepted.push(GroundedFactCandidate {
                subject,
                predicate,
                object,
                evidence_quote: evidence,
                evidence_span: FactSourceSpan {
                    start,
                    end,
                    start_utf8_byte,
                    end_utf8_byte,
                },
                confidence: candidate.confidence,
                assertion_kind: candidate.assertion_kind,
                search_aliases: aliases,
                search_projection: projection,
            });
        }
        FactGroundingReport { accepted, rejected }
    }
}

pub struct FactSearchProjection;

impl FactSearchProjection {
    pub const VERSION: &'static str = "kgfact-search-v1";

    pub fn build(subject: &str, predicate: &str, object: &str, aliases: &[String]) -> String {
        let mut seen = HashSet::new();
        [subject, predicate, object]
            .into_iter()
            .map(str::to_string)
            .chain(aliases.iter().cloned())
            .filter_map(|part| {
                let value = normalize(&part);
                if value.is_empty() || !seen.insert(value.to_lowercase()) {
                    None
                } else {
                    Some(value)
                }
            })
            .collect::<Vec<_>>()
            .join(" ")
    }
}

fn normalize(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn normalized_aliases(aliases: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    aliases
        .iter()
        .filter_map(|alias| {
            let value = normalize(alias);
            let key = value.to_lowercase();
            if value.is_empty()
                || value.chars().count() > FactGroundingValidator::MAXIMUM_FIELD_CHARACTERS
                || !seen.insert(key)
            {
                None
            } else {
                Some(value)
            }
        })
        .take(FactGroundingValidator::MAXIMUM_ALIAS_COUNT)
        .collect()
}

fn occurrences(needle: &[char], haystack: &[char]) -> Vec<(usize, usize)> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return vec![];
    }
    (0..=haystack.len() - needle.len())
        .filter_map(|start| {
            if haystack[start..start + needle.len()] == *needle {
                Some((start, start + needle.len()))
            } else {
                None
            }
        })
        .collect()
}

fn grounding_tokens(value: &str) -> HashSet<String> {
    value
        .split(|character: char| !character.is_alphanumeric())
        .filter(|token| !token.is_empty())
        .map(str::to_lowercase)
        .collect()
}
