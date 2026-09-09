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
    pub distilled_text: String,
    pub eligible_source_spans: Vec<FactSourceSpan>,
    pub maximum_facts: usize,
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
