import GeniusLocusKit
import LocusKit
import NeuronKit

/// The paraphrase door as a recipe: nearest drawers by whole-record LSA
/// vector for a free-text question, in the dense lane's own nearest-first
/// order. Wraps `GeniusLocusKit.similarRecall`; no fusion, no rerank.
public struct SimilarRecall: Recipe {

    public struct Input: Sendable {
        public let query: String
        public let limit: Int
        public let filter: LocusKit.Filter

        public init(query: String, limit: Int, filter: LocusKit.Filter) {
            self.query = query
            self.limit = limit
            self.filter = filter
        }
    }

    public struct Output: Sendable {
        /// Matches nearest-first; `score` is the raw cosine similarity in [−1, 1].
        public let matches: [PreciseMatch]

        public init(matches: [PreciseMatch]) {
            self.matches = matches
        }
    }

    public init() {}

    public let name = "similar_recall"
    public let version = "1.0.0"
    public let description = "Recall the drawers whose whole-record LSA vector lies nearest a free-text question: the paraphrase door."
    public let requiredCapabilities: [NeuronKitCapability] = []

    public func run(input: Input, estate: EstateHandle, kit: GeniusLocusKit) async throws -> Output {
        try verifyCapabilities(required: requiredCapabilities)
        let hits = try await kit.similarRecall(
            estate, query: input.query, limit: input.limit, filter: input.filter)
        return Output(matches: hits.map { hit in
            PreciseMatch(
                id: hit.id, room: hit.drawer?.parentNodeId ?? "",
                content: hit.drawer?.content ?? "", score: Double(hit.score.final))
        })
    }
}
