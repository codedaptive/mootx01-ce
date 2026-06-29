import Foundation

/// Structured errors for VectorKit operations. Per MOOTx01 standard,
/// errors are concrete enum cases — never optionals plus logging.
public enum VectorKitError: Error, Sendable, Equatable {
    /// Embedding inference failed. Associated value is the underlying
    /// reason (e.g. CoreML error description). Surfaced by
    /// `EmbeddingProvider.embed(_:)`.
    case embeddingFailed(String)

    /// Model not loaded or not available on this platform. Associated
    /// value names the model that was requested.
    case modelUnavailable(String)

    /// Vector store could not be opened or created. Associated value
    /// describes the SQLite or filesystem failure.
    case storeUnavailable(String)

    /// No result found for the given query. Reserved for future storage
    /// read paths; current APIs return optionals rather than throwing this.
    case notFound

    /// A VectorPayload is structurally invalid — wrong kind, wrong byte
    /// count, or inconsistent dim/bytes. Associated value describes the
    /// inconsistency. Thrown by VectorPayload.asEngram() and
    /// VectorPayload.asFloats().
    case invalidPayload(String)

    /// A VectorRecordKey, row, or schema element is malformed in a way
    /// that prevents decode. Associated value describes the malformation.
    case decodingFailure(String)

    /// An `.int8` VectorPayload was submitted for persistence, but the
    /// int8 quantization policy (symmetric vs asymmetric, per-vector vs
    /// per-dim scale) has not been ratified. Writing an int8 payload now
    /// would lock in undefined dequantization semantics. Use `.float`
    /// (float32 lane) or `.binaryDense` (.binary lane / Engram) instead.
    /// See VECTORKIT_SPEC §I-4a and arch spec §10.3. When a quantization
    /// policy is ratified, remove this error case and the guards that
    /// throw it.
    case int8QuantizationPolicyUndefined(String)

    /// A trained distributional provider's `embedFloat` returned no vector
    /// because all query tokens are out-of-vocabulary (OOV) — the provider
    /// HAS a trained basis but the query's vocabulary does not intersect it.
    ///
    /// This is distinct from `embeddingFailed` (structural opt-out: the
    /// provider has no float lane at all). Thrown by distributional providers
    /// (RandomIndexing, PPMI, LSA, NMF) when their vocab is non-empty but
    /// no query token hits. `Corpus.floatNearest` catches this and maps it
    /// to `FloatLaneOutcome.unavailableNoVocabHit` so callers observe the
    /// correct dark-lane reason.
    ///
    /// - Parameter description: Human-readable detail (e.g. "vocab size N,
    ///   but 0 of M query tokens matched").
    case embedFloatVocabMiss(String)
}
