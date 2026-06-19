import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// One precise-recall match: the drawer's id, its room (for serialization
/// in the same shape `moot_memory_search` uses), the content preview, and
/// the precision score it was ranked by.
public struct PreciseMatch: Sendable, Equatable, Codable {
    /// The drawer's stable row id.
    public let id: String
    /// The drawer's room (structural coordinate), echoed for the tool
    /// surface's `[room]` rendering.
    public let room: String
    /// The drawer's content (the recipe returns it so the tool surface can
    /// serialize without a second fetch).
    public let content: String
    /// The precision score this drawer was ranked by, in `[0, 1]`.
    public let score: Double
    public init(id: String, room: String, content: String, score: Double) {
        self.id = id
        self.room = room
        self.content = content
        self.score = score
    }
}

/// PreciseRecall — the precise-recall recipe and the ablation harness's
/// executor. It closes the measured gauntlet gap (strong coarse grab, weak
/// precise reduction: found@10 high, found@1 low) by ascending GLK fetch → a
/// NAMED reduction COMPOSITION → bounded reduce to surface the EXACT answer
/// above its near-duplicate distractors.
///
/// The ascent (SPEC § 5, B-1/B-2 — pure sequencing; the recipe owns no
/// math and no substrate state):
///   a. GLK FETCH (coarse grab): a `GLKRecallRequest` in `.unionBest` mode
///      with `.raw` scoring over a GENEROUS candidate pool (`pool`, default
///      30). `.unionBest` fuses LocusKit + CorpusKit (BM25 + vector); `.raw`
///      is the HIGH-RECALL lane (gauntlet-measured found@10 ≈ 0.56 vs
///      `.matrixAware`'s pruned ≈ 0.20). Nothing is pruned here; recall is
///      preserved so the true target stays in the pool. Every hit carries its
///      DENSE signal (Step 2): the `RecallScoreVector` (integer Hamming
///      distance, per-lane bm25/vector/coOccurrence) and the structured
///      drawer's lattice anchor.
///   b. REDUCTION COMPOSITION (the precision step): each pooled hit becomes a
///      `NeuronKit.ReductionCandidate` carrying that dense signal + content,
///      and the NAMED composition (`composition`, default `text`) scores and
///      re-ranks the pool. The grid of compositions (`CompositionGrid`) is the
///      ablation surface: text-only, hamming-only, tokenExact-only,
///      hamming+tokenExact, weighted-all, … — none pre-judged; the gauntlet
///      ranks them. The default `text` reproduces the original recipe
///      (`queryPrecision`) behavior so an absent (`nil`) composition is a no-op.
///      Unknown name validation belongs at the CALLER'S boundary (e.g.
///      RecipeTools), not inside the recipe.
///   c. BOUNDED REDUCE: the composition returns the top `limit`. The reduce
///      only RE-ORDERS the coarse pool and truncates to the caller's requested
///      `limit`; it never prunes the pool below `limit`, so the true target
///      cannot be dropped out of the set the coarse grab already surfaced
///      (found@10 holds; found@1/MRR lift). The deliberate opposite of an
///      over-pruning reducer.
///
/// Read-only (B-6, I-6). Deterministic: the signal components read no clock,
/// the composition fold is a pure function of (query, candidates), and the
/// recipe takes `now` for telemetry parity with the other recipes; it never
/// calls `Date()` in the ranking path.
public enum PreciseRecall {

    /// Default coarse candidate pool size. Generous enough that the true
    /// target is in the pool (recall), bounded so the re-rank stays cheap.
    public static let defaultPool = 30

    /// Coarse-grab `pool` candidates for `query`, re-rank them by the named
    /// reduction `composition`, and return the top `limit`.
    ///
    /// - Parameters:
    ///   - kit: the GeniusLocusKit actor the recall verb dispatches through.
    ///   - handle: the estate to recall against.
    ///   - query: the search query text (drives BM25 + vector).
    ///   - filter: the recall filter chain entry (e.g. `.unconfirmed`).
    ///   - limit: how many ranked matches to return.
    ///   - pool: coarse candidate pool size; clamped to be at least `limit`
    ///     so the bounded reduce never shrinks the returned set below what a
    ///     plain coarse grab of `limit` would have surfaced. Defaults to
    ///     `defaultPool`.
    ///   - composition: the named reduction composition from
    ///     `NeuronKit.CompositionGrid` (e.g. "hamming+tokenExact",
    ///     "weighted-all"). Defaults to `text` — the original `queryPrecision`
    ///     behavior — so an unspecified (`nil`) name reproduces today's
    ///     recipe. Callers that need strict validation (e.g. MCP tool surfaces)
    ///     MUST check `CompositionGrid.names` before calling and reject unknown
    ///     names at the boundary; the recipe itself does not throw on an
    ///     unrecognised name. This is the ablation selector: each grid
    ///     composition is one measurable column.
    /// - Returns: up to `limit` matches, descending by composition precision.
    /// - Throws: any upstream GLK recall error, unchanged.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        query: String,
        filter: LocusKit.Filter,
        limit: Int,
        pool: Int = defaultPool,
        composition: String? = nil
    ) async throws -> [PreciseMatch] {
        // The pool must be at least `limit`: the bounded reduce returns the
        // top `limit` of the pool, so a pool smaller than `limit` could only
        // shrink the result below a plain coarse grab — the regression we are
        // here to avoid.
        let poolSize = max(pool, limit)

        // a. GLK FETCH — coarse, high-recall grab, BODY-FREE. .unionBest fuses
        //    the BM25 + vector lanes; scoring is .raw — the HIGH-RECALL lane.
        //    The gauntlet measured the lanes directly: .raw / .rrf reach
        //    found@10 ≈ 0.56, while .matrixAware's matrix-tier pruning
        //    collapses to ≈ 0.20 (the over-pruned floor). The precise pool
        //    must inherit the strong lane's recall, not the pruned one — the
        //    precision re-rank below supplies the discrimination .matrixAware
        //    was (badly) attempting. We do not prune the pool here.
        //
        //    DENSE-FIRST (steps 3+4): the pool is fetched at `.bitmapOnly` —
        //    body-free — so the wide candidate pool carries its DENSE signal
        //    (integer Hamming distance, per-lane bm25/vector/coOccurrence) and
        //    its lattice anchor (udcCode/udcFacets, preserved at `.bitmapOnly`)
        //    but NO body. Bodies are read LATE, for the survivors only, by the
        //    narrow-then-hydrate reduce below.
        //
        //    TRACE BUDGET: `limit` (the request.limit) is the coarse pool scan
        //    width so every candidate passes through the RecallDirector's locus
        //    drain. `traceLimit` is the CALLER'S final limit — what the caller
        //    actually receives after the precision re-rank. The RecallDirector
        //    uses `traceLimit` (not `limit`) for the reward-cycle trace write,
        //    so the trace table records only the ~20 rows the caller received,
        //    not the ~500-row pool. Without this, a single precise query would
        //    write ~500 trace rows (~25× the useful signal).
        let frame = LocusKit.RecallFrame(
            filterChain: [filter],
            hydrationLevel: .bitmapOnly,
            limit: poolSize,
            // byRelevanceDesc was removed from Ordering (LocusKit is a bitmap
            // filter engine with no scoring signal — relevance is provided by
            // the RecallDirector's scoring mode below, not LocusKit ordering).
            // byCaptureTimeDesc provides a stable initial page order; the
            // unionBest scoring + queryText delivers relevance ranking above.
            ordering: .byCaptureTimeDesc)
        let request = GLKRecallRequest(
            frame: frame,
            mode: .unionBest,
            scoring: .raw,
            limit: poolSize,
            fallback: .allowDegraded,
            queryText: query,
            traceLimit: limit)
        let result = try await kit.recall(handle, request)

        // b. REDUCTION COMPOSITION — project each body-free pooled hit (with its
        //    DENSE signal carried from GLK: integer Hamming distance, per-lane
        //    bm25/vector/coOccurrence, the lattice anchor) into a
        //    NeuronKit.ReductionCandidate. The candidate's coarse-pool index is
        //    its tie-break rank, so equal-precision near-duplicates keep the
        //    hybrid lane's order and the reduce is bit-reproducible. Content is
        //    empty here — the body-free pool — and is filled by the late
        //    hydration closure for the survivors only.
        let comp = NeuronKit.CompositionGrid.named(composition)
        // The query arrives as plain text from the tool surface with no lattice
        // anchor; the `lattice` signal is therefore neutral for these queries
        // (it discriminates only when both sides carry a UDC code).
        let reductionQuery = NeuronKit.ReductionQuery(text: query)
        let candidates = result.hits.enumerated().map { index, hit in
            NeuronKit.ReductionCandidate.from(hit: hit, coarseRank: index)
        }

        // c. NARROW-THEN-HYDRATE BOUNDED REDUCE — the dense signals narrow the
        //    wide body-free pool first; only the bounded survivors are hydrated
        //    (via the GLK-owned late-hydration capability `kit.hydrate`) and the
        //    content signals run on them. The reduce re-orders and truncates to
        //    `limit`; it never prunes below the coarse grab, so the true target
        //    the coarse grab surfaced cannot be dropped (found@10 holds). For a
        //    content-only composition (the default `text`) there is no dense term
        //    to narrow on, so every candidate is hydrated and the result is
        //    bit-identical to the eager reduce — the default recipe is unchanged.
        // The hydration closure must NOT swallow a hydrate failure into an
        // empty body map: that would let the bounded survivors through with
        // empty content, and the recipe would return PreciseMatch rows whose
        // `content: ""` is indistinguishable from a genuinely empty body. A
        // precise recall that cannot hydrate its survivors is a FAILED recall,
        // not an empty one — the error propagates out of `run` (which already
        // throws) so the caller sees the fault rather than fabricated-empty
        // matches. (The Rust port is already fail-closed here: it fetches the
        // pool bodies in the single recall_scored(...)? call and the closure
        // only reads the pre-fetched body map.)
        let ranked = try await NeuronKit.reduceLate(
            composition: comp, query: reductionQuery,
            candidates: candidates, limit: limit,
            hydrate: { ids in try await kit.hydrate(handle, ids: ids) })

        return ranked.map { candidate in
            // precisionScore is the weighted-sum composition score stamped onto
            // the candidate during the reduce fold (ReductionComposition.reduce).
            // It reflects the composition's re-rank signal, not the coarse fusion
            // score, so discrimination classification downstream operates on the
            // quality signal that actually drove the ordering.
            PreciseMatch(
                id: candidate.id, room: candidate.room,
                content: candidate.content, score: candidate.precisionScore)
        }
    }
}
