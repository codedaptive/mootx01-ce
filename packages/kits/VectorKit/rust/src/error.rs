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

    /// A `VectorPayload` was constructed with an inconsistent or
    /// unsupported kind/dim/bytes combination. Payload describes the
    /// violation.
    InvalidPayload(String),

    /// Raw bytes in the store could not be decoded into a valid typed
    /// vector. Payload describes the failure.
    DecodingFailure(String),

    /// An `Int8` `VectorPayload` was submitted for persistence, but the
    /// int8 quantization policy (symmetric vs asymmetric, per-vector vs
    /// per-dim scale) has not been ratified. Writing an int8 payload now
    /// would lock in undefined dequantization semantics. Use `Float32`
    /// (float32 lane) or the `Binary` Engram lane instead. See
    /// VECTORKIT_SPEC §I-4a and arch spec §10.3. When a quantization
    /// policy is ratified, remove this error case and the guards that
    /// return it.
    Int8QuantizationPolicyUndefined(String),

    /// Trained distributional provider's `embed_float` returned no vector
    /// because all query tokens are out-of-vocabulary (OOV). The provider
    /// HAS a trained basis (vocab is non-empty) but none of the query's
    /// tokens appear in it.
    ///
    /// Distinct from `EmbeddingFailed` (structural opt-out — provider
    /// structurally cannot produce float vectors). Thrown by RI, PPMI, LSA,
    /// NMF providers when vocab is non-empty but zero query tokens match.
    ///
    /// The corpus layer catches this and maps it to
    /// `FloatLaneOutcome::UnavailableNoVocabHit`. Payload describes which
    /// provider threw and how many tokens were OOV.
    EmbedFloatVocabMiss(String),
}
