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

    /// No result found for the given query. Used by VEC-02 storage
    /// reads; included here so the error surface is complete from the
    /// scaffold.
    case notFound
}
