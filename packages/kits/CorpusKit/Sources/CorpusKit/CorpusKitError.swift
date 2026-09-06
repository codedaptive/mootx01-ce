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
    /// An attached-mode Corpus was asked to do something only standalone
    /// mode permits — mutate canonical content through CorpusKit, or
    /// configure passage indexing. Attached mode stores only rebuildable
    /// derived state and indexes whole Drawers; the violation is rejected
    /// BEFORE anything is written (GLK shared-content 1.1, P1).
    case attachedModeViolation(String)
    /// A (mode, index-unit) or store configuration is structurally invalid
    /// — e.g. a non-positive passage token budget (GLK shared-content 1.1, P1).
    case invalidConfiguration(String)
    /// A queued job's (revision, digest) no longer matches the CURRENT
    /// canonical record — the job is stale and is rejected WITHOUT
    /// advancing the index checkpoint (identity and indexing contract,
    /// GLK shared-content 1.1).
    case staleRevision(String)
}
