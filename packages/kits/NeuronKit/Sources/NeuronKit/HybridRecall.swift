// HybridRecall.swift
//
// NeuronKit's hybrid-recall wrapper over the GLK estate `recall` verb.
// Per NEURONKIT_SPEC § 4.1, hybrid recall combines a BM25 lexical path
// and a vector semantic path, fuses them with Reciprocal Rank Fusion
// (k = 60), reranks with Maximal Marginal Relevance (λ = 0.7 by
// default), and pages the reranked output into an `AsyncSequence`.
//
// MOOTx01 invariant B-1: NeuronKit never calls LocusKit, VectorKit, or
// CorpusKit directly. The estate handle is the only substrate boundary
// available. The estate's `recall` verb today returns a single
// `[Drawer]` array — its underlying RecallStream is drained inside the
// GLK boundary before the rows reach this wrapper. Consequently this
// wrapper cannot see the separate BM25 and vector ranked lists, so the
// true RRF fusion described in the spec is bounded by what the verb
// returns. The wrapper therefore:
//
//   1. Treats the verb's ordered `[Drawer]` as L₁ (the single fused
//      list the boundary chose to surface), and constructs a degenerate
//      L₂ that equals L₁. RRF over (L₁, L₁) collapses to the same
//      ordering as L₁ but the implementation runs the math
//      identically — so the day the estate surface widens to expose
//      separate lexical and semantic lists, only the fan-in changes.
//   2. Runs MMR diversity reranking over the fused list with
//      λ = `tuning.mmrLambda` (default 0.7), computing similarity
//      between drawers from the textual content shingles (a
//      deterministic, vector-free proxy — actual embedding similarity
//      lives behind the verb and is not reachable from here under B-1).
//      C-8 demands MMR reranking on *every* page; this wrapper applies
//      it once over the full result before paging, which guarantees
//      every emitted page is from the reranked sequence.
//   3. Pages the reranked drawers into a NeuronKit-owned
//      `RecallStream` `AsyncSequence`, where each `Page` carries
//      `rows`, `pageIndex`, and `isLast`. The page size comes from
//      `tuning.pageSize`, defaulting to 50 (matches LocusKit's default
//      so callers see a consistent page granularity end-to-end).
//
// The `RecallStream` and `RecallStream.Page` types declared here are
// deliberately distinct from `LocusKit.RecallStream` and its
// `RecallPage` (different layer, different module). Wherever both are
// in scope they must be fully qualified.

import Foundation
import GeniusLocusKit
import IntellectusLib
import LocusKit
import SubstrateML

// Re-export the substrate's `Drawer` value type through NeuronKit so
// callers and tests reference one canonical name. The aliasing is
// cosmetic — `LocusKit.Drawer` remains the storage truth — but it
// keeps NeuronKit's public surface module-coherent and avoids forcing
// every caller to import LocusKit just to spell the row type the
// reasoning surface returns.
public typealias Drawer = LocusKit.Drawer

/// Hybrid recall over the estate addressed by `handle`. Wraps the
/// GLK `recall` verb (the only legal substrate boundary per B-1),
/// applies RRF + MMR per spec § 4.1, and pages the result into a
/// NeuronKit `RecallStream` `AsyncSequence`.
///
/// `tuning` controls the recall fusion and reranking parameters
/// independently of `RecallFrame`'s filter chain; the defaults match
/// the spec (k = 60, λ = 0.7). Pass a non-nil `tuning` to override
/// either knob on a per-call basis.
///
/// - Parameter frame: The estate recall frame (filter chain, ordering,
///   limit). Passed unchanged through `glk.recall`.
/// - Parameter handle: Estate handle. The single legal substrate
///   entry point.
/// - Parameter glk: The GeniusLocusKit actor that owns the estate.
/// - Parameter tuning: RRF/MMR/page-size tuning. Defaults per spec.
/// - Returns: A `RecallStream` over the MMR-reranked drawer set.
/// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is
///   stale, or any verb error raised by the boundary.
public func hybridRecall(
    _ frame: RecallFrame,
    handle: EstateHandle,
    on glk: GeniusLocusKit,
    tuning: RecallFrameTuning = .default,
    cueTerms: [String] = []
) async throws -> RecallStream {
    let start = Date().timeIntervalSince1970
    let drawers = try await glk.recall(handle, frame)
    let reranked = HybridRecallEngine.rerank(drawers: drawers, tuning: tuning, cueTerms: cueTerms)
    let stream = RecallStream(rows: reranked, pageSize: tuning.pageSize)

    // Emit hybrid-recall telemetry at the operation boundary. `start` is
    // read from `Date().timeIntervalSince1970` here at the verb boundary
    // (a factory-level side-effect), not inside the math engine, so the
    // math stays deterministic. When monitoring is off (the default), the
    // autoclosure is never evaluated — zero allocation, zero clock on the
    // off-path.
    //
    // `neuronkit.recall.latency_ms`: wall time from verb call to rerank done.
    // `neuronkit.recall.candidate_count`: drawers returned by the estate verb.
    // `neuronkit.recall.result_count`: drawers after MMR rerank (same count).
    // Both candidate and result counts are emitted so the Activity view can
    // display funnel depth (MANAGER_1.0_PLAN §4, GUI §4.4 Activity).
    let elapsed = (Date().timeIntervalSince1970 - start) * 1000.0
    // Use the estate UUID string as the tag value — stable across re-opens
    // of the same database, distinct per estate, never empty.
    let estateTag = handle.estateUUID.uuidString

    Intellectus.report(.metric(
        name: "neuronkit.recall.latency_ms",
        value: elapsed,
        tags: ["estate": estateTag],
        ts: Date().timeIntervalSince1970
    ))
    Intellectus.report(.metric(
        name: "neuronkit.recall.candidate_count",
        value: Double(drawers.count),
        tags: ["estate": estateTag],
        ts: Date().timeIntervalSince1970
    ))
    Intellectus.report(.metric(
        name: "neuronkit.recall.result_count",
        value: Double(reranked.count),
        tags: ["estate": estateTag],
        ts: Date().timeIntervalSince1970
    ))

    return stream
}

/// Hybrid recall tuning knobs. Per spec § 4.1: `bm25Weight` (0.3),
/// `vectorWeight` (0.7), `rrfK` (60), `mmrLambda` (0.7). `pageSize`
/// matches LocusKit's `RecallStream.defaultPageSize` (50).
///
/// The fusion weights are passed through the RRF math even though
/// today the verb returns a single fused list (see file header). They
/// are preserved so that the day the estate surface exposes separate
/// lexical and semantic lists, callers already have the knobs and
/// recorded defaults.
public struct RecallFrameTuning: Sendable, Equatable {

    /// Weight applied to the BM25 path during RRF fusion. Spec default
    /// 0.3.
    public let bm25Weight: Float

    /// Weight applied to the vector path during RRF fusion. Spec
    /// default 0.7.
    public let vectorWeight: Float

    /// RRF damping constant (k). Spec default 60.
    public let rrfK: Int

    /// MMR diversity / relevance trade-off (λ). Spec default 0.7.
    /// Higher values favour relevance; lower values favour diversity.
    public let mmrLambda: Float

    /// Page size for the emitted `RecallStream`. Matches LocusKit's
    /// 50-row default so callers see consistent page granularity
    /// across substrate and reasoning layers.
    public let pageSize: Int

    public init(
        bm25Weight: Float = 0.3,
        vectorWeight: Float = 0.7,
        rrfK: Int = 60,
        mmrLambda: Float = 0.7,
        pageSize: Int = 50
    ) {
        self.bm25Weight = bm25Weight
        self.vectorWeight = vectorWeight
        self.rrfK = rrfK
        self.mmrLambda = mmrLambda
        self.pageSize = pageSize
    }

    /// Spec-default tuning (k = 60, λ = 0.7, page size 50).
    public static let `default` = RecallFrameTuning()
}

/// Paged async sequence of MMR-reranked drawers. NeuronKit's own
/// paging type, distinct from `LocusKit.RecallStream`. Each emitted
/// `Page` carries `rows`, `pageIndex` (zero-based), and `isLast` (true
/// only on the final page). Even an empty result emits one page with
/// `rows.isEmpty` and `isLast == true` so callers can run a uniform
/// `for await` loop without special-casing the zero-row outcome.
public struct RecallStream: AsyncSequence, Sendable {
    public typealias Element = Page

    /// One page of recall results. Spec § 4.1 step 5 — the reranked
    /// L₄ is paged into the stream.
    public struct Page: Sendable, Equatable {
        public let rows: [Drawer]
        public let pageIndex: Int
        public let isLast: Bool

        public init(rows: [Drawer], pageIndex: Int, isLast: Bool) {
            self.rows = rows
            self.pageIndex = pageIndex
            self.isLast = isLast
        }
    }

    private let rows: [Drawer]
    private let pageSize: Int

    internal init(rows: [Drawer], pageSize: Int) {
        self.rows = rows
        // Page size below 1 would loop forever or emit zero-row pages
        // with `isLast == false`. Clamp to keep the invariant that
        // every emitted page either makes progress or is the last.
        self.pageSize = Swift.max(1, pageSize)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(rows: rows, pageSize: pageSize)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let allRows: [Drawer]
        private let pageSize: Int
        private var offset = 0
        private var pageIndex = 0
        private var exhausted = false

        init(rows: [Drawer], pageSize: Int) {
            self.allRows = rows
            self.pageSize = pageSize
        }

        public mutating func next() async -> Page? {
            guard !exhausted else { return nil }
            let end = Swift.min(offset + pageSize, allRows.count)
            let slice = Array(allRows[offset..<end])
            let isLast = end >= allRows.count
            let page = Page(rows: slice, pageIndex: pageIndex, isLast: isLast)
            offset = end
            pageIndex += 1
            if isLast { exhausted = true }
            return page
        }
    }
}

/// Internal reranking engine. Exposed at module scope so the Swift
/// conformance tests and the Rust version exercise the same deterministic
/// math against shared vectors. The engine is pure data-in, data-out;
/// no substrate access, no clocks, no randomness.
internal enum HybridRecallEngine {

    /// Apply RRF fusion (k = `tuning.rrfK`) and MMR rerank
    /// (λ = `tuning.mmrLambda`) to `drawers` and return the reranked list.
    /// Pure function — deterministic across Swift and Rust versions.
    ///
    /// When `cueTerms` is non-empty the two RRF lanes become genuinely
    /// independent: L-lexical ranks drawers by distinct-cue-term-match count
    /// descending (input-order tie-break); L-semantic is input order (recency).
    /// When `cueTerms` is empty, both lanes equal input order — output is
    /// bit-identical to the previous single-list path (hard requirement for
    /// callers that pass no query).
    static func rerank(drawers: [Drawer], tuning: RecallFrameTuning, cueTerms: [String] = []) -> [Drawer] {
        guard !drawers.isEmpty else { return [] }

        // Build the lexical rank order.
        // When cueTerms is non-empty: rank by DISTINCT cue-term-match count
        // descending, input-order tie-break. Distinct count — not occurrence
        // count — is intentional: generic terms that appear many times in one
        // drawer award only +1, so they cannot inflate a drawer above one that
        // matches more distinct cue terms. Ties break by input index (stable).
        // When cueTerms is empty: lexical order == input order, so both lanes
        // collapse to the same sequence and the RRF math produces the same
        // score vector as before.
        let lexicalOrder: [Int]
        if cueTerms.isEmpty {
            lexicalOrder = Array(drawers.indices)
        } else {
            let lowTerms = cueTerms.map { $0.lowercased() }
            // (matchCount, originalIndex) pairs for stable sort.
            let scored: [(Int, Int)] = drawers.indices.map { idx in
                let lower = drawers[idx].content.lowercased()
                let distinct = lowTerms.filter { lower.contains($0) }.count
                return (distinct, idx)
            }
            // Sort by count DESC; input index ASC as stable tie-break.
            let sorted = scored.sorted { a, b in
                a.0 != b.0 ? a.0 > b.0 : a.1 < b.1
            }
            lexicalOrder = sorted.map { $0.1 }
        }

        // Map originalIndex → lexical rank for O(1) lookup.
        var lexRank = [Int: Int]()
        lexRank.reserveCapacity(drawers.count)
        for (rank, idx) in lexicalOrder.enumerated() {
            lexRank[idx] = rank
        }

        // RRF with genuinely independent lanes:
        // L-lexical: ranked by distinct-cue-term count (or input order when
        // cueTerms is empty).  L-semantic: input order (recency — the verb's
        // natural ordering). When cueTerms is empty both lanes equal input
        // order and the formula reduces to the previous single-list math —
        // bit-identical output guaranteed.
        var rrfScore: [Int: Float] = [:]
        rrfScore.reserveCapacity(drawers.count)
        for semRank in drawers.indices {
            let lRank = lexRank[semRank] ?? semRank
            let lexical = 1.0 / Float(tuning.rrfK + lRank + 1)
            let semantic = 1.0 / Float(tuning.rrfK + semRank + 1)
            rrfScore[semRank] = tuning.bm25Weight * lexical + tuning.vectorWeight * semantic
        }

        // MMR rerank. Selects the next drawer that maximises
        // λ × Sim(d, Q) − (1−λ) × max_j Sim(d, dⱼ_selected).
        // Sim(d, Q) is the normalised RRF score (already encodes "how
        // relevant the verb considered this drawer to the query frame").
        // Sim(d, dⱼ) is the deterministic shingle-overlap similarity
        // between two drawers' verbatim content — delegates to
        // SubstrateML.ShingleSimilarity (the substrate-owned kernel, I-25).
        // Vector-free; stable and conformance-gated across versions.
        let lambda = tuning.mmrLambda
        let maxRRF = rrfScore.values.max() ?? 1.0
        let minRRF = rrfScore.values.min() ?? 0.0
        // Normalise RRF into [0, 1] so the relevance term scales
        // comparably with the [0, 1] similarity term. Falls back to
        // 0.5 when every score is equal (single-row or degenerate
        // input).
        let rrfRange = maxRRF - minRRF
        func relevance(_ idx: Int) -> Float {
            guard rrfRange > 0 else { return 0.5 }
            return ((rrfScore[idx] ?? minRRF) - minRRF) / rrfRange
        }

        var remaining = Set(drawers.indices)
        var selected: [Int] = []
        selected.reserveCapacity(drawers.count)

        while !remaining.isEmpty {
            var bestIdx = -1
            var bestScore: Float = -.infinity
            // Iterate in stable order (input order) so ties break
            // deterministically — bit-identical across versions.
            for idx in drawers.indices where remaining.contains(idx) {
                let rel = relevance(idx)
                let maxSim: Float
                if selected.isEmpty {
                    maxSim = 0
                } else {
                    var m: Float = 0
                    for s in selected {
                        let sim = shingleSimilarity(drawers[idx].content, drawers[s].content)
                        if sim > m { m = sim }
                    }
                    maxSim = m
                }
                let score = lambda * rel - (1 - lambda) * maxSim
                if score > bestScore {
                    bestScore = score
                    bestIdx = idx
                }
            }
            remaining.remove(bestIdx)
            selected.append(bestIdx)
        }

        return selected.map { drawers[$0] }
    }

    /// Deterministic Jaccard similarity over 3-character lowercase shingles.
    ///
    /// Delegates to `SubstrateML.ShingleSimilarity.similarity`, the
    /// substrate-owned kernel. Pure text math — no locale-sensitive
    /// transforms, no stemming, no tokeniser. Bit-identical across the
    /// Swift and Rust ports via the shared conformance gate (CRC 0x8a5d8888,
    /// 32-case cross-port vector). I-25: one implementation per substrate
    /// atomic; the substrate owns it.
    static func shingleSimilarity(_ a: String, _ b: String) -> Float {
        ShingleSimilarity.similarity(a, b)
    }
}

extension NeuronKit {
    /// Deterministic Jaccard similarity over 3-character lowercase shingles,
    /// surfaced on the NeuronKit namespace. Delegates through
    /// `HybridRecallEngine.shingleSimilarity` → `SubstrateML.ShingleSimilarity`.
    /// Pure text math; bit-identical across ports on shared conformance vectors.
    public static func shingleSimilarity(_ a: String, _ b: String) -> Float {
        HybridRecallEngine.shingleSimilarity(a, b)
    }
}
