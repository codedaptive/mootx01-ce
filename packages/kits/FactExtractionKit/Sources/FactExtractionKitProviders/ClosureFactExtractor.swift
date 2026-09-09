import FactExtractionKit
import Foundation

/// Testable provider adapter used by hosts whose inference runtime is supplied
/// out of process. The production resident-worker client conforms through the
/// same closure-shaped seam without leaking process types into the contract.
public struct ClosureFactExtractor: FactExtractor {
    public let spec: FactExtractorModelSpec
    private let inference: @Sendable (FactExtractionRequest) async throws -> FactExtractionResponse

    public init(
        spec: FactExtractorModelSpec,
        inference: @escaping @Sendable (FactExtractionRequest) async throws -> FactExtractionResponse
    ) {
        self.spec = spec
        self.inference = inference
    }

    public func extract(_ request: FactExtractionRequest) async throws -> FactExtractionResponse {
        guard request.maximumFacts > 0,
              request.maximumFacts <= spec.maximumFactsPerSource,
              request.distilledText.unicodeScalars.count <= spec.maximumInputCharacters else {
            throw FactExtractionError.invalidRequest("request exceeds the active extractor recipe")
        }
        return try await inference(request)
    }
}
