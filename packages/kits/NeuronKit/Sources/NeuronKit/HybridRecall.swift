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
import LocusKit

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
    tuning: RecallFrameTuning = .default
) async throws -> RecallStream {
    let drawers = try await glk.recall(handle, frame)
    let reranked = HybridRecallEngine.rerank(drawers: drawers, tuning: tuning)
    return RecallStream(rows: reranked, pageSize: tuning.pageSize)
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
    /// (λ = `tuning.mmrLambda`) to `drawers` and return the reranked
    /// list. Pure function — deterministic across Swift and Rust versions.
    static func rerank(drawers: [Drawer], tuning: RecallFrameTuning) -> [Drawer] {
        guard !drawers.isEmpty else { return [] }

        // RRF over the single fused list returned by the verb. Today
        // L₁ == L₂ == drawers; the RRF score still runs to keep the
        // math identical to the day the estate surface widens. RRF
        // score is monotonic-decreasing with rank, so the rank order
        // does not change relative to the input, but the score is
        // recorded for the MMR relevance term below.
        var rrfScore: [Int: Float] = [:]
        rrfScore.reserveCapacity(drawers.count)
        for (idx, _) in drawers.enumerated() {
            let lexical = 1.0 / Float(tuning.rrfK + idx + 1)
            let semantic = 1.0 / Float(tuning.rrfK + idx + 1)
            // Weighted sum matches the spec's two-path formulation.
            // With equal lists the weighting collapses to a constant
            // factor and does not reorder; with future independent
            // lists the weighting will reorder, which is the point.
            rrfScore[idx] = tuning.bm25Weight * lexical + tuning.vectorWeight * semantic
        }

        // MMR rerank. Selects the next drawer that maximises
        // λ × Sim(d, Q) − (1−λ) × max_j Sim(d, dⱼ_selected).
        // Sim(d, Q) is the normalised RRF score (already encodes "how
        // relevant the verb considered this drawer to the query frame").
        // Sim(d, dⱼ) is the deterministic shingle-overlap similarity
        // between two drawers' verbatim content — vector-free because
        // the wrapper has no embedding access under B-1, but stable
        // and conformance-testable across versions.
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

    /// Deterministic Jaccard similarity over 3-character lowercase
    /// shingles. Pure text math — no locale-sensitive transforms, no
    /// stemming, no tokeniser. The Rust version computes the same value
    /// for every shared test vector.
    static func shingleSimilarity(_ a: String, _ b: String) -> Float {
        let sa = shingles(a)
        let sb = shingles(b)
        if sa.isEmpty && sb.isEmpty { return 0 }
        let inter = sa.intersection(sb).count
        let union = sa.union(sb).count
        guard union > 0 else { return 0 }
        return Float(inter) / Float(union)
    }

    /// 3-character lowercase shingle set. ASCII-folded via
    /// `lowercased()` — locale-free in Swift's default behaviour and
    /// matches Rust's `to_lowercase()` for the ASCII-only conformance
    /// vectors used in tests.
    static func shingles(_ s: String) -> Set<String> {
        let lower = s.lowercased()
        let chars = Array(lower)
        guard chars.count >= 3 else {
            return chars.isEmpty ? [] : [String(chars)]
        }
        var out = Set<String>()
        out.reserveCapacity(chars.count - 2)
        for i in 0...(chars.count - 3) {
            out.insert(String(chars[i..<(i + 3)]))
        }
        return out
    }
}

extension NeuronKit {
    /// Deterministic Jaccard similarity over 3-character lowercase
    /// shingles — the engine's `shingleSimilarity`, surfaced publicly.
    /// Pure text math; bit-identical across versions on shared vectors.
    /// (The Rust version's `shingle_similarity` has always been `pub`;
    /// the contradiction recipe is the named Swift consumer.)
    public static func shingleSimilarity(_ a: String, _ b: String) -> Float {
        HybridRecallEngine.shingleSimilarity(a, b)
    }
}
