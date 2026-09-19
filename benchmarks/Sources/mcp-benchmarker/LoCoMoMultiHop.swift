import Foundation

// LoCoMoMultiHop.swift — the two-pass conversational multi-hop retrieval
// strategy (item 12).
//
// PASS 1 — decompose → pools → intersect: the question is decomposed into
// distinctive sub-cues; each sub-cue (plus the full question as its own
// anchor pool) retrieves a ranked pool; the pools are fused with reciprocal
// rank fusion. A candidate corroborated by MULTIPLE pools rises — the
// intersection is computed by scoring, not set arithmetic, so partial
// overlap still ranks.
//
// PASS 2 — bridge hop, run only when pass 1 finds no cross-pool
// corroboration: multi-hop questions whose bridge entity is not named in
// the question (e.g. "what did X's sister study" where the sister's NAME
// only appears in the estate) produce disjoint pools. The bridge pass reads
// the top pass-1 hits, extracts distinctive tokens the question does NOT
// contain (the candidate bridge entities), re-queries with question +
// bridge tokens, and re-fuses with the new pool included.
//
// Everything here is deterministic given the estate's ranked responses: no
// clocks, no randomness, no model calls. The strategy is measurement-led —
// it runs client-side over the existing MCP verbs (moot_memory_search,
// moot_memory_get) so the recipe can be measured BEFORE any product
// surface is built for it, the same sequence the dream pass followed.

// MARK: - Sub-cue decomposition

/// Stopwords excluded from sub-cue and bridge-token extraction: question
/// scaffolding and function words that retrieve indiscriminately.
/// Deliberately the same list shape as the product's grounding-term
/// extractor — a sub-cue is a grounding term used as its own query.
let multiHopStopwords: Set<String> = [
    "the", "and", "for", "are", "was", "were", "has", "have", "had",
    "did", "does", "not", "with", "that", "this", "from", "they",
    "their", "them", "then", "than", "there", "these", "those", "you",
    "your", "what", "when", "where", "which", "who", "whom", "why",
    "how", "will", "would", "could", "should", "about", "been", "being",
    "into", "over", "under", "after", "before", "between", "during",
    "any", "all", "each", "most", "some", "such", "can", "may", "might",
    "must", "shall", "its", "his", "her", "him", "she", "our", "out",
    "but", "per", "via", "also", "just", "only", "very", "much", "more",
]

/// Decomposes a question into distinctive sub-cues: alphanumeric runs,
/// lowercased, stopwords and short fragments dropped (< 3 chars unless
/// digit-bearing), first-appearance dedupe, capped at `maxCues` so the
/// per-question call budget stays bounded. Each surviving cue becomes its
/// own retrieval pool in pass 1.
func multiHopSubCues(from question: String, maxCues: Int = 6) -> [String] {
    var seen = Set<String>()
    var cues: [String] = []
    for raw in question.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
        let token = raw.lowercased()
        let hasDigit = token.contains { $0.isNumber }
        guard token.count >= 3 || hasDigit else { continue }
        guard !multiHopStopwords.contains(token) else { continue }
        guard seen.insert(token).inserted else { continue }
        cues.append(token)
        if cues.count == maxCues { break }
    }
    return cues
}

// MARK: - Pool fusion

/// One fused candidate: its id, RRF score, and how many pools surfaced it.
struct MultiHopCandidate: Sendable, Equatable {
    let id: String
    let score: Double
    let poolCount: Int
}

/// Reciprocal-rank fusion across ranked id pools (k = 60, the spec's RRF
/// constant). score(id) = Σ over pools 1/(k + rank + 1). Sorting is by
/// score descending with first-appearance order (pool-major, then rank) as
/// the deterministic tie-break, so equal scores never reorder between runs.
/// `poolCount` is the corroboration signal pass 2 triggers on.
func fuseMultiHopPools(_ pools: [[String]], rrfK: Int = 60) -> [MultiHopCandidate] {
    var score: [String: Double] = [:]
    var poolCount: [String: Int] = [:]
    var firstSeen: [String: Int] = [:]
    var order = 0
    for pool in pools {
        var seenInPool = Set<String>()
        for (rank, id) in pool.enumerated() {
            // A pool that repeats an id contributes only its best rank —
            // duplicates within one pool are a serialization artifact, not
            // extra evidence.
            guard seenInPool.insert(id).inserted else { continue }
            score[id, default: 0] += 1.0 / Double(rrfK + rank + 1)
            poolCount[id, default: 0] += 1
            if firstSeen[id] == nil { firstSeen[id] = order; order += 1 }
        }
    }
    return score
        .map { MultiHopCandidate(id: $0.key, score: $0.value, poolCount: poolCount[$0.key] ?? 0) }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return (firstSeen[$0.id] ?? .max) < (firstSeen[$1.id] ?? .max)
        }
}

// MARK: - Bridge extraction

/// Extracts candidate bridge tokens from pass-1 hit contents: distinctive
/// tokens (≥ 4 chars or digit-bearing, non-stopword) that the QUESTION does
/// not contain — an entity the answer chain names but the question does
/// not is exactly what a bridge is. First-appearance order, capped so the
/// re-query stays a query and not a paste of the corpus.
func multiHopBridgeTokens(
    fromContents contents: [String],
    question: String,
    maxTokens: Int = 6
) -> [String] {
    let questionTokens = Set(multiHopSubCues(from: question, maxCues: .max))
    var seen = Set<String>()
    var bridges: [String] = []
    for content in contents {
        for raw in content.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = raw.lowercased()
            let hasDigit = token.contains { $0.isNumber }
            guard token.count >= 4 || hasDigit else { continue }
            guard !multiHopStopwords.contains(token) else { continue }
            guard !questionTokens.contains(token) else { continue }
            guard seen.insert(token).inserted else { continue }
            bridges.append(token)
            if bridges.count == maxTokens { return bridges }
        }
    }
    return bridges
}

// MARK: - The two-pass driver

/// Runs the full two-pass strategy over live MCP verbs and returns the
/// fused ranked ids plus a compact provenance payload. `search` issues one
/// ranked query (the verb-map search tool); `hydrate` fetches one drawer's
/// full text (`moot_memory_get`) for bridge extraction — both are injected
/// so the driver's logic stays pure enough to reason about and the runner
/// owns the wire calls.
func runMultiHopStrategy(
    question: String,
    search: (String) async throws -> [String],
    hydrate: (String) async throws -> String,
    resultLimit: Int = 20
) async throws -> (ids: [String], payload: String, bridged: Bool) {
    // PASS 1 — the full question anchors pool 0 (multi-hop must never score
    // below plain search on single-hop questions), then one pool per sub-cue.
    var pools: [[String]] = [try await search(question)]
    let cues = multiHopSubCues(from: question)
    for cue in cues {
        pools.append(try await search(cue))
    }
    var fused = fuseMultiHopPools(pools)

    // Corroboration check: a candidate surfaced by ≥ 2 pools means the
    // sub-cues intersect somewhere — the ruled decompose-and-intersect model
    // answered the question. No corroboration at the head means the pools
    // are disjoint: the bridge entity is not named in the question, so a
    // sequential second hop is required.
    let corroborated = fused.first.map { $0.poolCount >= 2 } ?? false
    var bridged = false
    if !corroborated, let top = fused.first {
        var contents: [String] = []
        for candidate in fused.prefix(3) {
            if let text = try? await hydrate(candidate.id), !text.isEmpty {
                contents.append(text)
            }
        }
        let bridges = multiHopBridgeTokens(fromContents: contents, question: question)
        if !bridges.isEmpty {
            // Re-query with question + bridge candidates and re-fuse with the
            // bridge pool included. One hop only: LoCoMo multi-hop is 2-hop,
            // and each further hop multiplies the call budget.
            let bridgeQuery = question + " " + bridges.joined(separator: " ")
            pools.append(try await search(bridgeQuery))
            fused = fuseMultiHopPools(pools)
            bridged = true
        }
        _ = top
    }

    let ids = fused.prefix(resultLimit).map(\.id)
    // Compact provenance payload: which mechanics ran, never the corpus.
    // Retrieval metrics score the id list; this text only feeds token
    // accounting and human diagnosis.
    let payload = """
    multihop: pools=\(pools.count) cues=\(cues.count) bridged=\(bridged)
    \(ids.joined(separator: "\n"))
    """
    return (ids: ids, payload: payload, bridged: bridged)
}
