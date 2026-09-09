import CorpusKit
import FactExtractionKit
import Foundation
import LocusKit

/// Explicit gate values for the harness-first KGFact recall stage. This stage
/// is not inserted into ordinary recall until its benchmark arm earns that
/// wiring; callers opt in and must provide the entities found in the query.
public struct FactFirstRecallThresholds: Sendable, Equatable {
    public let minimumTopScore: Float
    public let minimumMargin: Float
    public let minimumEntityContainment: Float
    public let vectorWeight: Float

    public init(
        minimumTopScore: Float = 0.70,
        minimumMargin: Float = 0.20,
        minimumEntityContainment: Float = 1.0,
        vectorWeight: Float = 0.35
    ) {
        self.minimumTopScore = minimumTopScore
        self.minimumMargin = minimumMargin
        self.minimumEntityContainment = minimumEntityContainment
        self.vectorWeight = vectorWeight
    }
}

/// One result family: the assertion and the source drawer travel together and
/// never compete as peer retrieval hits.
public struct FactRecallFamily: Sendable, Equatable {
    public let fact: KGFact
    public let source: Drawer
    public let score: Float
    public let lexicalScore: Float
    public let vectorScore: Float?
    public let margin: Float
    public let entityContainment: Float

    public init(
        fact: KGFact, source: Drawer, score: Float, lexicalScore: Float,
        vectorScore: Float?, margin: Float, entityContainment: Float
    ) {
        self.fact = fact
        self.source = source
        self.score = score
        self.lexicalScore = lexicalScore
        self.vectorScore = vectorScore
        self.margin = margin
        self.entityContainment = entityContainment
    }
}

public enum FactFirstRecallDecision: Sendable, Equatable {
    case solid(FactRecallFamily)
    case fallThrough
}

public enum FactFirstRecallStage {
    /// Score the fact's rebuildable projection. Optional vector scores are
    /// supplied by the harness/index owner and keyed by KGFact id; absent
    /// scores keep this a lexical-only arm rather than fabricating vectors.
    public static func decide(
        query: String,
        queryEntities: [String],
        facts: [KGFact],
        sourceDrawers: [String: Drawer],
        vectorScores: [String: Float]? = nil,
        thresholds: FactFirstRecallThresholds = FactFirstRecallThresholds()
    ) -> FactFirstRecallDecision {
        let entities = queryEntities
            .map(defaultKeywordTokens)
            .filter { !$0.isEmpty }
        guard !entities.isEmpty else { return .fallThrough }
        let entityTokens = Set(entities.flatMap { $0 })
        let queryTokens = distinctiveTokens(query, entityTokens: entityTokens)
        guard !queryTokens.isEmpty else { return .fallThrough }

        let eligible = facts.compactMap { fact -> Eligible? in
            guard !fact.searchProjection.isEmpty,
                  fact.searchProjectionVersion == FactSearchProjection.version,
                  let source = sourceDrawers[fact.sourceDrawerID],
                  source.tombstonedAt == nil,
                  source.areFactsExtracted else { return nil }
            let tokens = defaultKeywordTokens(fact.searchProjection)
            guard !tokens.isEmpty else { return nil }
            return Eligible(fact: fact, source: source, tokens: tokens)
        }
        guard !eligible.isEmpty else { return .fallThrough }

        var termFreqs: BM25Weighting.TermFreqTable = [:]
        var documentLengths: [String: Int] = [:]
        for row in eligible {
            documentLengths[row.fact.id] = row.tokens.count
            var counts: [String: Int] = [:]
            for token in row.tokens { counts[token, default: 0] += 1 }
            for (term, frequency) in counts {
                termFreqs[term, default: [:]][row.fact.id] = frequency
            }
        }
        let (index, termMapping) = BM25Weighting.build(
            termFreqs: termFreqs, docLengths: documentLengths)
        let queryPairs = BM25Weighting.queryPairs(
            queryTerms: queryTokens.sorted(), termMapping: termMapping)
        let impacts = index.topK(
            query: queryPairs, k: eligible.count, algorithm: .blockMaxWand)
        let maximumImpact = impacts.first?.impact ?? 0
        let normalizedImpacts = Dictionary(uniqueKeysWithValues: impacts.map {
            ($0.itemID, maximumImpact > 0 ? $0.impact / maximumImpact : 0)
        })

        let vectorWeight = max(0, min(1, thresholds.vectorWeight))
        let scored = eligible.map { row -> Scored in
            let projection = Set(row.tokens)
            let coverage = Float(queryTokens.intersection(projection).count)
                / Float(queryTokens.count)
            // BM25 supplies corpus-aware ranking; multiplying by absolute
            // coverage prevents a one-term singleton corpus from looking solid.
            let lexical = coverage * (normalizedImpacts[row.fact.id] ?? 0)
            let vector = vectorScores?[row.fact.id].map { max(0, min(1, $0)) }
            let score = vector.map {
                lexical * (1 - vectorWeight) + $0 * vectorWeight
            } ?? lexical
            let identity = Set(defaultKeywordTokens(
                row.fact.subject + " " + row.fact.object))
            let contained = entities.filter { Set($0).isSubset(of: identity) }.count
            let containment = Float(contained) / Float(entities.count)
            return Scored(
                fact: row.fact, source: row.source, score: score,
                lexical: lexical, vector: vector, containment: containment)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.fact.id < $1.fact.id
        }

        guard let top = scored.first else { return .fallThrough }
        let second = scored.dropFirst().first?.score ?? 0
        let margin = top.score - second
        guard top.score >= thresholds.minimumTopScore,
              margin >= thresholds.minimumMargin,
              top.containment >= thresholds.minimumEntityContainment else {
            return .fallThrough
        }
        return .solid(FactRecallFamily(
            fact: top.fact, source: top.source, score: top.score,
            lexicalScore: top.lexical, vectorScore: top.vector,
            margin: margin, entityContainment: top.containment))
    }

    private struct Scored {
        let fact: KGFact
        let source: Drawer
        let score: Float
        let lexical: Float
        let vector: Float?
        let containment: Float
    }

    private struct Eligible {
        let fact: KGFact
        let source: Drawer
        let tokens: [String]
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "do", "does", "for", "how", "i", "in",
        "is", "it", "me", "my", "of", "on", "the", "to", "was", "what",
        "when", "where", "who", "why",
    ]

    private static func distinctiveTokens(
        _ query: String, entityTokens: Set<String>
    ) -> Set<String> {
        Set(defaultKeywordTokens(query).compactMap { token in
            if stopWords.contains(token) { return nil }
            if token.hasSuffix("s"), entityTokens.contains(String(token.dropLast())) {
                return String(token.dropLast())
            }
            return token
        })
    }
}

public extension GeniusLocusKit {
    /// Harness-first fact-only recall entry point. Ordinary RecallDirector
    /// behavior remains byte-identical until a measured product call site opts
    /// into this pre-stage.
    func recallFactFirst(
        _ handle: EstateHandle,
        query: String,
        queryEntities: [String],
        vectorScores: [String: Float]? = nil,
        thresholds: FactFirstRecallThresholds = FactFirstRecallThresholds()
    ) async throws -> FactFirstRecallDecision {
        try requireMounted(handle, verb: "recall")
        let estate = try estate(for: handle)
        let facts = try await estate.allKGFacts()
        let sourceIDs = Array(Set(facts.map(\.sourceDrawerID)))
        let drawers = try await estate.getDrawers(ids: sourceIDs)
        return FactFirstRecallStage.decide(
            query: query, queryEntities: queryEntities, facts: facts,
            sourceDrawers: Dictionary(uniqueKeysWithValues: drawers.map { ($0.id, $0) }),
            vectorScores: vectorScores, thresholds: thresholds)
    }
}
