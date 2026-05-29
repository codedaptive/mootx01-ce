//! VectorKit error surface. Parallel to the Swift `VectorKitError`
//! enum. Cases match one-for-one across languages so cross-language
//! conformance tests can share fixtures.

/// Structured errors for VectorKit operations.
#[derive(Debug, PartialEq, Eq)]
pub enum VectorKitError {
    /// Embedding inference failed. Payload is the underlying reason
    /// (e.g. ONNX runtime error). Surfaced by
    /// `EmbeddingProvider::embed`.
    EmbeddingFailed(String),

    /// Model not loaded or not available on this platform. Payload
    /// names the model that was requested.
    ModelUnavailable(String),

    /// Vector store could not be opened or created. Payload describes
    /// the SQLite or filesystem failure.
    StoreUnavailable(String),

    /// No result found for the given query. Used by VEC-02 storage
    /// reads; included here so the error surface is complete from the
    /// scaffold.
    NotFound,
}
