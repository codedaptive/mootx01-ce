// CorpusKitError.swift

import Foundation

public enum CorpusKitError: Error, Sendable, Equatable {
    case encodingFailure(String)
    case decodingFailure(String)
    case tokenizerUnavailable(String)
    case modelUnavailable(String)
    case embeddingFailed(String)
    case storeUnavailable(String)
}
