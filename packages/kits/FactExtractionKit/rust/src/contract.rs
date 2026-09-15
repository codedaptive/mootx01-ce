use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FactExtractorKind {
    FoundationModel,
    SpecializedModel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FactAssertionKind {
    Asserted,
    Inferred,
    Hypothesized,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FactExtractorModelSpec {
    pub provider_id: String,
    pub model_id: String,
    pub model_version: String,
    pub schema_version: String,
    pub extractor_kind: FactExtractorKind,
    pub maximum_input_characters: usize,
    pub maximum_facts_per_source: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FactSourceSpan {
    pub start: usize,
    pub end: usize,
    pub start_utf8_byte: usize,
    pub end_utf8_byte: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FactExtractionRequest {
    pub source_id: String,
    pub source_digest: String,
    pub source_text: String,
    pub eligible_source_spans: Vec<FactSourceSpan>,
    pub maximum_facts: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FactSourceChunk {
    pub text: String,
    pub span: FactSourceSpan,
}

/// Source-exact chunks with enough overlap to preserve the maximum grounded
/// evidence quote across a model-context boundary.
pub fn fact_source_chunks(
    original_source: &str,
    maximum_characters: usize,
    overlap_characters: usize,
) -> Vec<FactSourceChunk> {
    if original_source.is_empty() || maximum_characters == 0 {
        return Vec::new();
    }
    let characters: Vec<char> = original_source.chars().collect();
    let overlap = overlap_characters.min(maximum_characters.saturating_sub(1));
    let mut byte_offsets = Vec::with_capacity(characters.len() + 1);
    byte_offsets.push(0);
    for character in &characters {
        byte_offsets.push(byte_offsets.last().copied().unwrap_or(0) + character.len_utf8());
    }

    let mut chunks = Vec::new();
    let mut start = 0;
    while start < characters.len() {
        let end = (start + maximum_characters).min(characters.len());
        chunks.push(FactSourceChunk {
            text: characters[start..end].iter().collect(),
            span: FactSourceSpan {
                start,
                end,
                start_utf8_byte: byte_offsets[start],
                end_utf8_byte: byte_offsets[end],
            },
        });
        if end == characters.len() {
            break;
        }
        start = end - overlap;
    }
    chunks
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FactCandidate {
    pub subject: String,
    pub predicate: String,
    pub object: String,
    pub evidence_quote: String,
    pub confidence: f64,
    pub assertion_kind: FactAssertionKind,
    pub search_aliases: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FactExtractionResponse {
    pub source_digest: String,
    pub provider_id: String,
    pub model_id: String,
    pub model_version: String,
    pub schema_version: String,
    pub candidates: Vec<FactCandidate>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroundedFactCandidate {
    pub subject: String,
    pub predicate: String,
    pub object: String,
    pub evidence_quote: String,
    pub evidence_span: FactSourceSpan,
    pub confidence: f64,
    pub assertion_kind: FactAssertionKind,
    pub search_aliases: Vec<String>,
    pub search_projection: String,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum FactExtractionError {
    #[error("extractor unavailable: {0}")]
    Unavailable(String),
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("inference failed: {0}")]
    InferenceFailed(String),
    #[error("malformed response: {0}")]
    MalformedResponse(String),
}

pub trait FactExtractor: Send + Sync {
    fn spec(&self) -> &FactExtractorModelSpec;
    fn extract(
        &self,
        request: &FactExtractionRequest,
    ) -> Result<FactExtractionResponse, FactExtractionError>;
}
