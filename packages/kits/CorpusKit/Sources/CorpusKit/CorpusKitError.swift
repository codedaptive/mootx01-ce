// CorpusKitError.swift

import Foundation

public enum CorpusKitError: Error, Sendable, Equatable {
    case encodingFailure(String)
    case decodingFailure(String)
    case tokenizerUnavailable(String)
    case modelUnavailable(String)
    case embeddingFailed(String)
    case storeUnavailable(String)
    /// The selected embedding model cannot be reconstructed from a trained
    /// basis because it is not a `TrainableEmbeddingBasis` conformer — the
    /// deterministic provider, the named CoreML model cases, and the
    /// stateless FDC provider have no trained basis to restore. Thrown by
    /// `EmbeddingModel.reconstruct(from:)` for those cases rather than
    /// crashing or silently returning a wrong provider.
    case notTrainable(String)
}
