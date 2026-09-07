import Foundation

// The span rerank stage of the unionBest recall path (Encoder Rerank Program,
// contract sheet §8). A retrieval-trained sentence encoder reranks the HEAD of
// the lexical (BM25) candidate list by the best cosine between the query vector
// and the item's stored int8 span vectors; the reranked head is fused back into
// the lexical order with reciprocal-rank fusion. The stage reads two seams that
// the estate lifecycle registers per estate (`GeniusLocusKit.registerSpanEncoder`):
// the query-side encoder and the span-vector rows. Neither is owned here — the
// encoder is CorpusKit's `SpanEncoder` (sheet §7), the rows are SynapseKit's
// `vectors_v6` span rows (sheet §3) — so the director types them as protocols
// and the lifecycle supplies the conformances.

/// The query side of a span encoder as the recall stage reads it (sheet §7
/// `SpanEncoder`, narrowed to the two members recall needs).
public protocol SpanRerankEncoding: Sendable {
    /// The active registry model id (sheet §1, e.g. `minilm-l6-v2-w60`). The
    /// span rows are read under this id, so a model swap re-keys the lookup
    /// and the duty's re-encode under the new id is what makes hits reappear.
    var modelID: String { get }

    /// Encode one query: applies the model's query prefix, pools, and
    /// L2-normalises, so a dot product against a stored span is a cosine.
    func encodeQuery(_ text: String) async throws -> [Float]
}

/// One stored span vector as the recall stage reads it: the sheet §3 span row
/// without `contentVersion` (the drain duty's staleness key, which recall does
/// not consult — a stale row still ranks; the duty replaces it).
public struct SpanRerankVector: Sendable, Equatable {
    /// Span index within the item (0-based, span order).
    public let index: UInt32
    /// The int8-quantised span vector (`dim` entries, sheet §4).
    public let int8: [Int8]
    /// The per-vector dequantisation scale (sheet §4: `max_i |v_i| / 127`).
    public let scale: Float
    /// First word of the span in the item's word list (inclusive).
    public let startWord: Int
    /// End word of the span (exclusive).
    public let endWord: Int

    public init(index: UInt32, int8: [Int8], scale: Float, startWord: Int, endWord: Int) {
        self.index = index
        self.int8 = int8
        self.scale = scale
        self.startWord = startWord
        self.endWord = endWord
    }
}

/// Serving-generation span rows per item (sheet §3
/// `VectorStore.spanVectors(itemIDs:modelID:)`). Items with no rows under the
/// model are absent from the result.
public protocol SpanVectorReading: Sendable {
    func spanVectors(itemIDs: [String], modelID: String) async throws -> [String: [SpanRerankVector]]
}

/// One head entry handed to the stage: the item and its 1-based lexical rank.
public struct SpanRerankInput: Sendable, Equatable {
    public let itemID: String
    public let bm25Rank: Int

    public init(itemID: String, bm25Rank: Int) {
        self.itemID = itemID
        self.bm25Rank = bm25Rank
    }
}

/// One span hit: the item's best span under the active model and its cosine.
/// The span bounds ride the returned `RecallHit` so the composer can render
/// the evidence snippet (sheet §9) without re-deriving the spans.
public struct SpanRerankHit: Sendable, Equatable {
    public let itemID: String
    public let bestSpanIndex: UInt32
    public let bestSpanStart: Int
    public let bestSpanEnd: Int
    public let cosine: Float
    /// The item's 1-based rank in the lexical head the stage read
    /// (`SpanRerankInput.bm25Rank`). The packager's lane-agreement margin
    /// compares this order with the span order.
    public let bm25Rank: Int

    public init(
        itemID: String, bestSpanIndex: UInt32, bestSpanStart: Int,
        bestSpanEnd: Int, cosine: Float, bm25Rank: Int
    ) {
        self.itemID = itemID
        self.bestSpanIndex = bestSpanIndex
        self.bestSpanStart = bestSpanStart
        self.bestSpanEnd = bestSpanEnd
        self.cosine = cosine
        self.bm25Rank = bm25Rank
    }
}

/// The per-estate registration the director reads: the encoder, the span rows,
/// and the head size (`encoder_head`, sheet §7).
struct SpanRerankSource: Sendable {
    let encoder: any SpanRerankEncoding
    let store: any SpanVectorReading
    let head: Int
}

/// One entry of the fused lexical list: the item, its reciprocal-rank score,
/// and its span hit when the head produced one.
struct FusedLexicalEntry: Sendable, Equatable {
    let id: String
    let score: Float
    let hit: SpanRerankHit?
}

/// The stage's constants and pure functions. Kept free of estate state so the
/// parity fixture (`span_rerank_parity.json`, sheet §11) exercises exactly the
/// code the director runs. The constants are public so the lifecycle's
/// registration call can default to them; the functions are the director's.
public enum SpanRerankStage {
    /// Depth of the internal lexical call (sheet §8): the BM25 list the head is
    /// cut from and the fusion reorders. Fixed, and deliberately NOT the
    /// request's `frontierK` (clamped to [64, 256]): the clamp bounds the pool
    /// that enters the weighted score, not the lexical order the rerank reads.
    public static let lexicalDepth = 1000

    /// Head size when the estate manifest carries no `encoder_head` (sheet §7).
    public static let defaultEncoderHead = 30

    /// Reciprocal-rank constant, the same `k = 60` every other RRF fusion in
    /// the director uses (sheet §8).
    public static let rrfK = 60

    /// Rerank the lexical head by the best span cosine per item.
    ///
    /// Encodes the query once, reads the span rows for every head item under
    /// the encoder's model id, and keeps the best (highest-cosine) span per
    /// item; an item with no rows under the active model produces no hit and
    /// keeps its lexical rank in `fuse`. Returned hits are in span-rank order:
    /// cosine descending, ties by `bm25Rank` ascending (sheet §8), so the
    /// array index is the hit's span rank.
    ///
    /// - Throws: whatever the encoder or the row read throws; the director
    ///   treats a throw as "stage degraded, lexical order stands".
    static func spanRerank(
        head: [SpanRerankInput],
        query: String,
        encoder: any SpanRerankEncoding,
        store: any SpanVectorReading
    ) async throws -> [SpanRerankHit] {
        guard !head.isEmpty else { return [] }
        let queryVector = try await encoder.encodeQuery(query)
        guard !queryVector.isEmpty else { return [] }
        let rows = try await store.spanVectors(itemIDs: head.map(\.itemID), modelID: encoder.modelID)
        var hits: [SpanRerankHit] = []
        for input in head {
            guard let spans = rows[input.itemID], !spans.isEmpty else { continue }
            var best: SpanRerankHit? = nil
            for span in spans {
                // A row whose dimension disagrees with the query vector is not
                // this model's row; it cannot be scored and is skipped.
                guard span.int8.count == queryVector.count else { continue }
                let cosine = dotQuery(queryVector, q: span.int8, scale: span.scale)
                // Strictly greater keeps the lowest span index on an exact tie,
                // so both ports pick the same span.
                if best == nil || cosine > best!.cosine {
                    best = SpanRerankHit(
                        itemID: input.itemID, bestSpanIndex: span.index,
                        bestSpanStart: span.startWord, bestSpanEnd: span.endWord,
                        cosine: cosine, bm25Rank: input.bm25Rank)
                }
            }
            if let best { hits.append(best) }
        }
        hits.sort { a, b in
            if a.cosine != b.cosine { return a.cosine > b.cosine }
            return a.bm25Rank < b.bm25Rank
        }
        return hits
    }

    /// Cosine between a unit float query `u` and a stored int8 span (sheet §4):
    /// `Σ u_i × q_i × scale`, no renormalisation — the quantisation error is
    /// accepted by ruling. Float32 accumulation in index order, the same
    /// operation order as the Rust twin and the fixture generator, so the two
    /// ports produce identical cosines for identical rows.
    static func dotQuery(_ u: [Float], q: [Int8], scale: Float) -> Float {
        var acc: Float = 0
        for i in 0..<min(u.count, q.count) {
            acc += (u[i] * Float(q[i])) * scale
        }
        return acc
    }

    /// Fuse the lexical order with the span hits (sheet §8): reciprocal-rank
    /// fusion with `k = rrfK`, `score = 1/(k + bm25Rank) + w/(k + spanRank)`,
    /// where `spanRank` runs over the hits only (their array order) and an item
    /// without a hit keeps `1/(k + bm25Rank)`. Sorted by score descending, ties
    /// by `bm25Rank` ascending. `spanWeight` is `w` (1.0 by ruling; the shape
    /// key `dense:<modelID>` scales it).
    static func fuse(bm25Order: [String], hits: [SpanRerankHit], spanWeight: Float) -> [FusedLexicalEntry] {
        var hitByID: [String: (hit: SpanRerankHit, spanRank: Int)] = [:]
        for (index, hit) in hits.enumerated() where hitByID[hit.itemID] == nil {
            hitByID[hit.itemID] = (hit: hit, spanRank: index + 1)
        }
        let k = Float(rrfK)
        var fused: [(entry: FusedLexicalEntry, bm25Rank: Int)] = []
        fused.reserveCapacity(bm25Order.count)
        for (index, id) in bm25Order.enumerated() {
            let bm25Rank = index + 1
            var score = 1 / (k + Float(bm25Rank))
            var hit: SpanRerankHit? = nil
            if let entry = hitByID[id] {
                score += spanWeight / (k + Float(entry.spanRank))
                hit = entry.hit
            }
            fused.append((entry: FusedLexicalEntry(id: id, score: score, hit: hit), bm25Rank: bm25Rank))
        }
        fused.sort { a, b in
            if a.entry.score != b.entry.score { return a.entry.score > b.entry.score }
            return a.bm25Rank < b.bm25Rank
        }
        return fused.map(\.entry)
    }
}
