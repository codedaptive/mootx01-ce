import GeniusLocusKit
import LocusKit
import NeuronKit

/// The fixed transcript recall composition. It keeps the ordinary balanced
/// unionBest/matrixAware first stage, but requires the pinned strict reranker
/// before exposing any matches.
public struct TranscriptRecall: Recipe {
    public static let policyVersion = StrictTranscriptRerankOutcome.policyVersion

    public struct Input: Sendable {
        public let query: String
        public let filter: LocusKit.Filter

        public init(query: String, filter: LocusKit.Filter) {
            self.query = query
            self.filter = filter
        }
    }

    public struct Output: Sendable {
        public let matches: [PreciseMatch]
        public let outcome: StrictTranscriptRerankOutcome

        public init(matches: [PreciseMatch], outcome: StrictTranscriptRerankOutcome) {
            self.matches = matches
            self.outcome = outcome
        }
    }

    public init() {}

    public let name = "transcript_recall"
    public let version = "1.0.0"
    public let description = "Recall transcript candidates with the fixed balanced composition and required strict reranking."
    public let requiredCapabilities: [NeuronKitCapability] = []

    public enum Error: Swift.Error, Sendable {
        case missingStrictOutcome
    }

    public func run(input: Input, estate: EstateHandle, kit: GeniusLocusKit) async throws -> Output {
        try verifyCapabilities(required: requiredCapabilities)
        let request = ShapedRecall.balancedTranscriptRequest(
            query: input.query, filter: input.filter)
        let result = try await kit.recall(estate, request)
        guard let outcome = result.strictTranscriptRerank else {
            throw Error.missingStrictOutcome
        }
        guard outcome.status == .applied else {
            // A strict caller never receives the ordinary fused order as a
            // successful transcript result when the required stage is absent.
            return Output(matches: [], outcome: outcome)
        }
        return Output(
            matches: result.hits.map { hit in
                PreciseMatch(
                    id: hit.id, room: hit.drawer?.parentNodeId ?? "",
                    content: hit.drawer?.content ?? "", score: Double(hit.score.final))
            },
            outcome: outcome)
    }
}
