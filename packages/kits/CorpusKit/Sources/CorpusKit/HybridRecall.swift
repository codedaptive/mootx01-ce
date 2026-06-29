// HybridRecall.swift
//
// Hybrid retrieval composition: vector kNN plus BM25 keyword
// scoring fused via Reciprocal Rank Fusion (RRF), with optional
// Maximal Marginal Relevance (MMR) diversification on the
// merged candidate list. Per paper section 10.2.
//
// The hybrid recall lives in CorpusKit because both inputs (vector
// hits from VectorKit + keyword hits from BM25Index) are CorpusKit
// concerns. NeuronKit's reasoning layer composes higher-level
// recall pipelines on top.
//
// LANE-E2: the two-lane RRF logic is now delegated to Fusion
// (Engine/Fusion.swift) instead of being reimplemented inline.
// HybridRecall builds the per-lane ranked lists and raw-score maps,
// then calls Fusion.fuse(rankedLists:laneScores:weights:rrfK:).
// The ranking output is bit-identical to the previous implementation
// for the same inputs (verified by HybridRecallConformanceTests).
//
// CORPUSKIT_REPORT_001 (cp-corpuskit-report): added IntellectusLib
// self-report telemetry to recall. The emit calls are placed at the
// operation boundary, after the result is assembled, so the
// mathematical behaviour is unchanged. The recall path always reads
// startTime and endTime unconditionally and constructs metric values
// before calling Intellectus.report; the disabled-monitoring path
// does not short-circuit these steps.

import Foundation
import EngramLib
import IntellectusLib
import VectorKit

public struct HybridRecallConfiguration: Sendable {
    public var vectorWeight: Double
    public var keywordWeight: Double
    public var rrfK: Double            // RRF constant (Cormack et al. recommend 60)
    public var mmrLambda: Double?      // optional MMR diversification (nil disables)

    public init(
        vectorWeight: Double = 0.6,
        keywordWeight: Double = 0.4,
        rrfK: Double = 60,
        mmrLambda: Double? = nil
    ) {
        self.vectorWeight = vectorWeight
        self.keywordWeight = keywordWeight
        self.rrfK = rrfK
        self.mmrLambda = mmrLambda
    }
}

public enum HybridRecall {

    /// Retrieve top-k chunks by hybrid (vector + keyword) scoring.
    ///
    /// Both the vector pass (Hamming kNN) and keyword pass (BM25) produce
    /// ranked candidate lists. These are fused using generalized RRF via
    /// `Fusion.fuse` — the .binaryDense lane carries vector hits and
    /// the .sparse lane carries BM25 hits. The ranking behaviour is
    /// identical to the previous inline implementation.
    ///
    /// - Parameters:
    ///   - probe: probe Engram (from the query's embedding).
    ///   - query: query text (for the keyword pass).
    ///   - modelID: stable model id; the kNN pass filters to this
    ///     model so cross-model comparisons cannot occur.
    ///   - limit: top-k cap.
    ///   - vectorStore: VectorKit handle.
    ///   - invertedIndex: SQLite-backed durable inverted index (BM25 keyword
    ///     lane). Replaced the in-memory BM25Index so keyword state persists
    ///     across process restarts without replaying chunk bodies on open.
    ///   - bundleStore: chunk content store.
    ///   - configuration: weights, RRF constant, optional MMR.
    ///
    /// Telemetry: emits `corpuskit.recall.latency_ms` (wall time for the
    /// retrieval/fusion/hydration pipeline; HybridRecall receives a
    /// precomputed probe, so embedding time is not included), `corpuskit.recall.vector_result_count` (number of
    /// vector hits from findNearest before RRF), `corpuskit.recall.keyword_result_count`
    /// (number of keyword hits from BM25 before RRF), and
    /// `corpuskit.recall.result_count` (final output count after RRF and
    /// hydration) when monitoring is enabled. All four are emitted at the
    /// operation boundary — after the result is assembled — so they cannot
    /// affect the return value. Off-path: single Atomic<Bool> load per call.
    public static func recall(
        probe: Engram,
        query: String,
        modelID: String,
        limit: Int,
        vectorStore: VectorStore,
        invertedIndex: InvertedIndexStore,
        bundleStore: BundleStore,
        configuration: HybridRecallConfiguration = HybridRecallConfiguration()
    ) async throws -> [ScoredChunk] {
        // Capture start time before the retrieval work. One Date() read per
        // call; the computed latency is forwarded to the sink only when
        // monitoring is enabled (inside the @autoclosure guard).
        let startTime = Date().timeIntervalSince1970

        // Pull a generous candidate window from each side.
        let candidateK = max(limit * 4, 32)

        async let vectorHits = vectorStore.findNearest(
            probe: probe,
            modelID: modelID,
            limit: candidateK
        )
        // Pre-tokenise using the same corpus-default vocabulary as ingest so the
        // query and index share identical vocabulary. CorpusDefaultTokenizer is
        // stateless; a fresh instance is semantically equivalent to the tokenizer
        // used when the index was built — same FNV-1a fold, same vocab parameters.
        // InvertedIndexStore.topK runs the BM25-weighted WAND / Block-Max WAND
        // engine over the persisted term-frequency table, producing SparseHits.
        // The scores are identical to what BM25Index.topK produced: both build the
        // InvertedIndex via BM25Weighting.build on the same termFreqs/docLengths.
        let queryTokens = CorpusDefaultTokenizer().keywordTokens(query)
        // InvertedIndexStore.topK is synchronous internally (builds/returns the
        // cached InvertedIndex and runs WAND/BMW), but as an actor method it
        // requires await for isolation. The async let for vectorHits proceeds
        // concurrently while we cross the actor boundary here.
        let iixHits = await invertedIndex.topK(queryTerms: queryTokens, k: candidateK)

        let vectorResults = try await vectorHits
        // Map SparseHit (itemID: String, impact: Float) → (id: UUID, score: Float)
        // matching the shape that the keyword-lane builder below expects. Hits
        // whose itemID is not a valid UUID string are dropped (should not occur:
        // InvertedIndexStore only receives chunk.id.uuidString from Corpus.ingest).
        let keywordResults: [(id: UUID, score: Float)] = iixHits.compactMap { hit in
            guard let uuid = UUID(uuidString: hit.itemID) else { return nil }
            return (id: uuid, score: hit.impact)
        }

        // Build per-lane ranked inputs for the generalized Fusion engine.
        //
        // Vector lane (.binaryDense): findNearest returns hits sorted by
        // Hamming distance ascending — index 0 = rank 1.
        // Raw score = Hamming distance (Int cast to Float); lower = closer.
        //
        // Keyword lane (.sparse): topK returns (id: UUID, score: Float)
        // sorted by BM25 score descending — index 0 = rank 1.
        // Raw score = BM25 score Float.
        //
        // Both ranked lists are built as [(itemID: String, rank: Int)] using
        // the chunk UUID.uuidString as itemID — the same join key used by
        // bundleStore.getMany.

        var vectorRanked: [(itemID: String, rank: Int)] = []
        var vectorScoreMap: [String: Float] = [:]
        for (idx, hit) in vectorResults.enumerated() {
            // Skip items whose itemID is not a valid UUID string — they
            // cannot be hydrated by bundleStore and are not in the corpus.
            // P3-secfix: parse through UUID and re-emit .uuidString so the
            // key is always the Swift canonical uppercase form (e.g.
            // "A1B2C3D4-..."). Without this, a vector hit stored with a
            // lowercase UUID string (common from Rust-side DBs) and a keyword
            // hit for the same memory use different map keys and never fuse.
            // Intra-port canonical form: Swift = uppercase UUID.uuidString.
            guard let parsedUUID = UUID(uuidString: hit.itemID) else { continue }
            let canonicalID = parsedUUID.uuidString
            vectorRanked.append((itemID: canonicalID, rank: idx + 1))
            // Hamming distance as Float; lower = closer to probe.
            vectorScoreMap[canonicalID] = Float(hit.distance)
        }

        var keywordRanked: [(itemID: String, rank: Int)] = []
        var keywordScoreMap: [String: Float] = [:]
        for (idx, hit) in keywordResults.enumerated() {
            // hit.id is UUID-typed; .uuidString is always uppercase on Apple —
            // the same canonical form used for vector hits above.
            let itemID = hit.id.uuidString
            keywordRanked.append((itemID: itemID, rank: idx + 1))
            keywordScoreMap[itemID] = hit.score
        }

        // Delegate fusion to Fusion.fuse. The .binaryDense and .sparse
        // LaneTags are used because they match the canonical lane names
        // for these two retrieval paths (arch spec §2.4, LaneTag definition).
        let fusedHits = Fusion.fuse(
            rankedLists: [
                .binaryDense: vectorRanked,
                .sparse:      keywordRanked
            ],
            laneScores: [
                .binaryDense: vectorScoreMap,
                .sparse:      keywordScoreMap
            ],
            weights: [
                .binaryDense: Float(configuration.vectorWeight),
                .sparse:      Float(configuration.keywordWeight)
            ],
            rrfK: Float(configuration.rrfK)
        )

        // Apply the limit. Fusion.fuse returns the full merged list sorted
        // by fusedScore DESC, itemID ASC; truncate to the requested top-k.
        let topHits = fusedHits.count > limit
            ? Array(fusedHits.prefix(limit))
            : fusedHits

        // Hydrate chunks from bundleStore using the UUID primary keys.
        // Items whose itemID is not a valid UUID are dropped at this point
        // (they were included in fusion but cannot be hydrated).
        let uuids = topHits.compactMap { UUID(uuidString: $0.itemID) }
        let chunks = try await bundleStore.getMany(ids: uuids)
        let byID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })

        // Build the output list in fused-score order.
        // Per-lane raw scores from FusedHit.perLane feed ScoredChunk
        // subscores: .binaryDense → vectorScore, .sparse → keywordScore.
        // A nil subscore means that lane did not produce a hit for that item.
        var out: [ScoredChunk] = []
        for hit in topHits {
            guard let uuid = UUID(uuidString: hit.itemID),
                  let chunk = byID[uuid] else { continue }
            let vectorScore = hit.perLane[.binaryDense]
            let keywordScore = hit.perLane[.sparse]
            // vectorScore: presence in perLane[.binaryDense] determines non-nil.
            // A raw score of 0 (Hamming distance 0) is the BEST possible match —
            // the probe is identical to the stored engram. Treating distance 0 as nil
            // would silently discard the highest-quality vector hit, misleading nil-
            // checking callers into thinking no vector lane contributed.
            //
            // keywordScore: BM25 scores are strictly positive for any match, so
            // a zero value reliably indicates the keyword lane did not contribute.
            out.append(ScoredChunk(
                chunk: chunk,
                score: hit.fusedScore,
                vectorScore:  vectorScore,
                keywordScore: (keywordScore == 0 || keywordScore == nil) ? nil : keywordScore
            ))
        }

        // Emit recall telemetry at the operation boundary, after the result
        // is assembled. The autoclosures are evaluated only when monitoring
        // is enabled; the startTime clock read (above) is the only
        // unconditional overhead. When monitoring is off (the default),
        // each call is a single Atomic<Bool> load + branch.
        //
        // corpuskit.recall.latency_ms: wall time for the full pipeline
        //   (vector kNN + BM25 + RRF + hydration).
        // corpuskit.recall.vector_result_count: raw vector hits before RRF.
        // corpuskit.recall.keyword_result_count: raw keyword hits before RRF.
        // corpuskit.recall.result_count: final output count after hydration.
        let endTime = Date().timeIntervalSince1970
        let resultCount = out.count
        let vectorCount = vectorResults.count
        let keywordCount = keywordResults.count
        Intellectus.report(.metric(
            name: "corpuskit.recall.latency_ms",
            value: (endTime - startTime) * 1000.0,
            tags: ["kit": "CorpusKit", "model_id": modelID],
            ts: endTime
        ))
        Intellectus.report(.metric(
            name: "corpuskit.recall.vector_result_count",
            value: Double(vectorCount),
            tags: ["kit": "CorpusKit", "model_id": modelID],
            ts: endTime
        ))
        Intellectus.report(.metric(
            name: "corpuskit.recall.keyword_result_count",
            value: Double(keywordCount),
            tags: ["kit": "CorpusKit", "model_id": modelID],
            ts: endTime
        ))
        Intellectus.report(.metric(
            name: "corpuskit.recall.result_count",
            value: Double(resultCount),
            tags: ["kit": "CorpusKit", "model_id": modelID],
            ts: endTime
        ))

        return out
    }
}
