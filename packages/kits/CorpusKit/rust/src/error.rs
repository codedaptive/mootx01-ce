//! Errors. Mirror of Swift's CorpusKitError.

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CorpusKitError {
    EncodingFailure(String),
    DecodingFailure(String),
    TokenizerUnavailable(String),
    ModelUnavailable(String),
    EmbeddingFailed(String),
    StoreUnavailable(String),
    /// The selected embedding model cannot be reconstructed from a trained
    /// basis because it does not implement `TrainableEmbeddingBasis` — the
    /// deterministic provider, the named host-inference model cases, and the
    /// stateless FDC provider have no trained basis to restore. Returned by
    /// `EmbeddingModelConfig::reconstruct` for those cases rather than
    /// panicking or returning a wrong provider.
    NotTrainable(String),
}

impl std::fmt::Display for CorpusKitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CorpusKitError::EncodingFailure(s) => write!(f, "encoding failure: {}", s),
            CorpusKitError::DecodingFailure(s) => write!(f, "decoding failure: {}", s),
            CorpusKitError::TokenizerUnavailable(s) => write!(f, "tokenizer unavailable: {}", s),
            CorpusKitError::ModelUnavailable(s) => write!(f, "model unavailable: {}", s),
            CorpusKitError::EmbeddingFailed(s) => write!(f, "embedding failed: {}", s),
            CorpusKitError::StoreUnavailable(s) => write!(f, "store unavailable: {}", s),
            CorpusKitError::NotTrainable(s) => write!(f, "not trainable: {}", s),
        }
    }
}

impl std::error::Error for CorpusKitError {}

pub type CorpusKitResult<T> = Result<T, CorpusKitError>;
