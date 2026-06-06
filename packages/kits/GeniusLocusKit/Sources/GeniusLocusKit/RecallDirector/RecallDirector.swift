import CorpusKit
import EngramLib
import Foundation
import OSLog
import LocusKit
import VectorKit

/// The Recall Director — routes a `GLKRecallRequest` through the appropriate
/// lane and returns a fully scored `GLKRecallResult`.
///
/// Live lanes:
/// - `.locusOnly` — LocusKit bitmap-index scan.
/// - `.corpusOnly` — BM25 keyword + Hamming vector, fused via RRF.
/// - `.hybrid` — locus + BM25 + vector, fused via RRF.
/// - `.unionBest` — multi-lane union with greedy MMR deduplication.
///
/// The director computes a `RecallPlan` before lane recall runs. The plan
/// captures the effective mode and the frontier-K value
/// (`min(max(limit * 4, 64), 256)`), which bounds candidate retrieval
/// without pulling unbounded rows from the estate.
public extension GeniusLocusKit {

    /// Logger for the Recall Director. Uses the fleet-standard subsystem
    /// and category per CLAUDE.md.
    private static var recallLog: Logger {
        Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
    }

    // MARK: - Primary entry point

    /// Route a `GLKRecallRequest` through the Recall Director.
    ///
    /// The director:
    /// 1. Resolves the estate for `handle` (throws `estateNotOpen` if stale).
    /// 2. Computes a `RecallPlan` — effective mode and frontier-K.
    /// 3. Dispatches to the lane named in `request.mode`.
    /// 4. Returns a `GLKRecallResult` carrying the plan, hits, and provenance.
    ///
    /// All four modes are live: `.locusOnly`, `.corpusOnly`, `.hybrid`, and
    /// `.unionBest` (greedy MMR deduplication across all lanes).
    ///
    /// - Parameters:
    ///   - handle: The estate to recall from. Must be open in this kit.
    ///   - request: The fully-specified recall request.
    /// - Returns: A `GLKRecallResult` with hits ordered as the active lane produced them.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func recall(_ handle: EstateHandle, _ request: GLKRecallRequest) async throws -> GLKRecallResult {
        // Resolve the estate up front. A stale handle surfaces here as
        // estateNotOpen before any plan work.
        let estate = try estate(for: handle)

        // Compute the execution plan. frontierK bounds candidate retrieval:
        // min(max(limit * 4, 64), 256) ensures we pull enough candidates
        // for scoring without retrieving unbounded rows.
        let frontierK = min(max(request.limit * 4, 64), 256)
        let plan = RecallPlan(
            effectiveMode: request.mode,
            frontierK: frontierK,
            weights: .uniform
        )

        Self.recallLog.debug(
            "RecallDirector: mode=\(request.mode.rawValue, privacy: .public) limit=\(request.limit, privacy: .public) frontierK=\(frontierK, privacy: .public)"
        )

        switch request.mode {
        case .locusOnly:
            return try await recallLocusOnly(estate: estate, request: request, plan: plan)

        case .corpusOnly:
            return try await recallCorpusOnly(
                estate: estate, request: request, plan: plan, handle: handle)

        case .hybrid:
            return try await recallHybrid(
                estate: estate, request: request, plan: plan, handle: handle)

        case .unionBest:
            return try await recallUnionBest(
                estate: estate, request: request, plan: plan, handle: handle)

        case .nodeTreeNative:
            // The nodeTreeNative mode injects host-tree topology edges into the
            // StructureGraph via recallTunnels (the structural lens path), not via
            // the scored drawer-recall path. For drawer retrieval, this mode
            // delegates to the locusOnly bitmap lane so all estate drawers are
            // reachable through the normal bitmap filter. The tree-edge union
            // happens separately when the structural lenses call recallTunnels:
            // GLK freezes the provider's treeEdges(scope:nil) result exactly once
            // at that call (G1) and appends synthetic containment tunnels to the
            // estate's stored tunnels before returning the union.
            return try await recallLocusOnly(estate: estate, request: request, plan: plan)
        }
    }

    // MARK: - locusOnly lane

    /// Execute a recall through the LocusKit bitmap-index lane.
    ///
    /// Drains `estate.recall(request.frame)` fully, applies the limit, and
    /// wraps each drawer as a `RecallHit` with `score: .locus(1.0)` and
    /// `sources: [.locusBitmap]`. The score of 1.0 signals full confidence
    /// from the bitmap evaluator; ordering is determined by `RecallFrame.ordering`,
    /// not by scoring math, because no multi-lane combiner is active.
    ///
    /// Error propagation: `estate.recall(_:)` returns a `RecallStream` and
    /// does not throw; page iteration is non-throwing. Estate-level storage
    /// errors that surface through page iteration would propagate through
    /// Swift concurrency's typed throws. Because `RecallStream` is non-throwing,
    /// no `remap` call is needed here.
    private func recallLocusOnly(
        estate: LocusKit.Estate,
        request: GLKRecallRequest,
        plan: RecallPlan
    ) async throws -> GLKRecallResult {
        // Drain the recall stream produced by the LocusKit bitmap evaluator.
        // The stream's page size is controlled by the estate; we take the
        // first `request.limit` rows after materializing.
        let stream = await estate.recall(request.frame)
        var rows: [LocusKit.Drawer] = []
        for await page in stream {
            rows.append(contentsOf: page.rows)
            // Stop draining once we have enough candidates for the limit.
            // The stream may have more pages, but we bound retrieval here.
            if rows.count >= request.limit {
                break
            }
        }

        // Apply the hard limit after draining.
        let limited = Array(rows.prefix(request.limit))

        // Scoring semantics for the locusOnly lane:
        //   - .raw  — hits returned in RecallFrame.ordering order; this IS raw
        //             behaviour because no multi-lane combiner is active.
        //   - .rrf  — single-lane RRF degrades to .raw ordering; nothing to
        //             fuse. A future mission may weight intra-lane ranks with
        //             explicit RRF math if more than one locus cursor runs in
        //             parallel.
        //   - .matrixAware — not yet active for locusOnly; falls back to raw
        //             ordering. A future mission will add the matrix scoring
        //             pass here once the per-lane matrix signal is defined.
        // No scoring branch is needed now: all three cases produce the same
        // ordering-based output for a single lane.

        // Wrap each drawer as a RecallHit. The locusOnly lane:
        //   - sources: [.locusBitmap] — the bitmap evaluator produced this hit
        //   - score: .locus(1.0) — full locus-lane confidence; multi-lane
        //     scoring is not active, so this is a sentinel rather than a
        //     computed value
        //   - explanation: ["locusBitmap"] — one token per active lane
        let hits = limited.map { drawer in
            RecallHit(
                id: drawer.id,
                drawer: drawer,
                sources: [.locusBitmap],
                score: .locus(1.0),
                explanation: ["locusBitmap"]
            )
        }

        Self.recallLog.debug(
            "RecallDirector locusOnly: \(hits.count, privacy: .public) hits returned"
        )

        return GLKRecallResult(
            request: request,
            plan: plan,
            unionProfile: nil,
            hits: hits
        )
    }

    // MARK: - corpusOnly lane

    /// Execute a recall through the BM25 keyword and Hamming vector lanes only.
    ///
    /// Flow:
    /// 1. Compile a `RecallQuerySketch` — embeds query text into `queryEngram`.
    /// 2. BM25 top-`frontierK` via `Corpus.bm25TopKBySource` (source-keyed).
    /// 3. Hamming top-`frontierK` via `VectorStore.findNearest`.
    /// 4. RRF-fuse both ranked lists (`k=60`, UUID tie-break ascending).
    /// 5. Hydrate top-`request.limit` hits from the estate.
    ///
    /// When no corpus is registered:
    /// - `.failClosed` → throws `recallLaneUnavailable(.corpus)`.
    /// - `.allowDegraded` → degrades to `locusOnly` with updated plan mode.
    private func recallCorpusOnly(
        estate: LocusKit.Estate,
        request: GLKRecallRequest,
        plan: RecallPlan,
        handle: EstateHandle
    ) async throws -> GLKRecallResult {
        guard let corpus = corpusKits[handle] else {
            if request.fallback == .allowDegraded {
                let degradedPlan = RecallPlan(
                    effectiveMode: .locusOnly,
                    frontierK: plan.frontierK,
                    weights: plan.weights
                )
                Self.recallLog.debug("RecallDirector corpusOnly: no corpus registered — degrading to locusOnly")
                return try await recallLocusOnly(estate: estate, request: request, plan: degradedPlan)
            }
            throw GeniusLocusKitError.recallLaneUnavailable(.corpus)
        }

        let sketch = await compileSketch(from: request, corpus: corpus)

        // BM25 lane: top-frontierK source-level hits from the keyword index.
        let bm25List: [(id: String, score: Float)]
        if let text = sketch.queryText, !text.isEmpty {
            let hits = await corpus.bm25TopKBySource(query: text, limit: plan.frontierK)
            bm25List = hits.map { (id: $0.sourceID, score: $0.score) }
        } else {
            bm25List = []
        }

        // Vector lane: top-frontierK Hamming nearest-neighbour hits.
        let vectorList: [(id: String, score: Float)]
        if let engram = sketch.queryEngram, let store = vectorStores[handle] {
            let modelID = await corpus.modelID
            let matches = (try? await store.findNearest(
                probe: engram,
                modelID: modelID,
                limit: plan.frontierK
            )) ?? []
            // Convert Hamming distance to a score: score = 1 - distance/256.
            // Distance 0 (identical) → score 1.0; distance 256 → score 0.0.
            vectorList = matches.map { m in
                (id: m.drawerID, score: Float(256 - m.distance) / 256.0)
            }
        } else {
            vectorList = []
        }

        // Build the candidate list according to the requested scoring strategy.
        //
        // .rrf  — RRF-fuse BM25 and vector lists; this is the default behaviour
        //         and the most accurate multi-lane combiner for two-lane inputs.
        // .raw  — skip RRF; merge the two lists in score-descending order and
        //         deduplicate by ID. BM25 scores take precedence because keyword
        //         matching is the primary signal when RRF is not requested;
        //         vector-only results are appended for IDs not in the BM25 list.
        //         This honours the caller's request to skip inter-lane rank math.
        // .matrixAware — not yet active for the corpusOnly lane; the matrix
        //         scoring pass (fieldFit, coOccurrence, temporal) is defined for
        //         the unionBest lane only. Falls back to .rrf behaviour here.
        //         A future mission will add the matrix pass to the corpusOnly lane.
        let fused: [(id: String, score: Float)]
        switch request.scoring {
        case .raw:
            // .raw skips RRF; hits returned in BM25 score order
            // (or vector score order if BM25 empty).
            var seen: Set<String> = []
            var merged: [(id: String, score: Float)] = []
            for item in bm25List.sorted(by: { $0.score > $1.score }) {
                if seen.insert(item.id).inserted {
                    merged.append(item)
                }
            }
            for item in vectorList.sorted(by: { $0.score > $1.score }) {
                if seen.insert(item.id).inserted {
                    merged.append(item)
                }
            }
            fused = Array(merged.prefix(request.limit))
        case .rrf, .matrixAware:
            // .rrf — existing RRF fusion; two-lane reciprocal rank combination.
            // .matrixAware scoring is not yet active for the corpusOnly lane;
            // falls back to .rrf behaviour. A future mission will add the matrix
            // pass here.
            fused = rrfFuse(bm25List, vectorList, k: 60, limit: request.limit)
        }

        // Hydrate fused hits from the estate, excluding tombstoned drawers and
        // applying the requested hydration level to the loaded drawers.
        let hits = await hydrateHits(
            fused,
            estate: estate,
            bm25IDs: Set(bm25List.map(\.id)),
            vectorIDs: Set(vectorList.map(\.id)),
            level: request.frame.hydrationLevel
        )

        Self.recallLog.debug(
            "RecallDirector corpusOnly: bm25=\(bm25List.count, privacy: .public) vector=\(vectorList.count, privacy: .public) fused=\(hits.count, privacy: .public)"
        )

        return GLKRecallResult(request: request, plan: plan, unionProfile: nil, hits: hits)
    }

    // MARK: - hybrid lane

    /// Execute a recall fusing LocusKit, BM25, and vector lanes via RRF.
    ///
    /// Flow:
    /// 1. Compile a `RecallQuerySketch`.
    /// 2. Locus lane: top-`frontierK` from LocusKit bitmap evaluator.
    /// 3. BM25 lane: top-`frontierK` from `Corpus.bm25TopKBySource`.
    /// 4. Vector lane: top-`frontierK` from `VectorStore.findNearest`.
    /// 5. RRF-fuse all three lists (`k=60`, UUID tie-break ascending).
    /// 6. Hydrate top-`request.limit` hits from the estate.
    private func recallHybrid(
        estate: LocusKit.Estate,
        request: GLKRecallRequest,
        plan: RecallPlan,
        handle: EstateHandle
    ) async throws -> GLKRecallResult {
        // Locus lane — same drain as locusOnly.
        let stream = await estate.recall(request.frame)
        var locusRows: [LocusKit.Drawer] = []
        for await page in stream {
            locusRows.append(contentsOf: page.rows)
            if locusRows.count >= plan.frontierK { break }
        }
        let locusList: [(id: String, score: Float)] = Array(locusRows.prefix(plan.frontierK))
            .enumerated()
            .map { (idx, d) in (id: d.id, score: Float(plan.frontierK - idx) / Float(plan.frontierK)) }

        // Corpus and vector lanes — only if corpus is registered.
        var bm25List: [(id: String, score: Float)] = []
        var vectorList: [(id: String, score: Float)] = []
        if let corpus = corpusKits[handle], let text = request.queryText, !text.isEmpty {
            let sketch = await compileSketch(from: request, corpus: corpus)
            let bm25Hits = await corpus.bm25TopKBySource(query: text, limit: plan.frontierK)
            bm25List = bm25Hits.map { (id: $0.sourceID, score: $0.score) }

            if let engram = sketch.queryEngram, let store = vectorStores[handle] {
                let modelID = await corpus.modelID
                let matches = (try? await store.findNearest(
                    probe: engram,
                    modelID: modelID,
                    limit: plan.frontierK
                )) ?? []
                vectorList = matches.map { m in
                    (id: m.drawerID, score: Float(256 - m.distance) / 256.0)
                }
            }
        }

        // Build the candidate list according to the requested scoring strategy.
        //
        // .rrf  — three-way RRF fusion of locus, BM25, and vector; default
        //         and most accurate combiner for the hybrid lane.
        // .raw  — skip rrfFuseThree; merge all three lists in order
        //         (locus → BM25 → vector), dedup by ID, apply limit.
        //         No rank math; the ordering reflects lane priority, not
        //         inter-lane rank fusion.
        // .matrixAware — not yet active for the hybrid lane; falls back to
        //         .rrf behaviour. A future mission will add the matrix pass.
        let fused: [(id: String, score: Float)]
        switch request.scoring {
        case .raw:
            // .raw skips rrfFuseThree; merge locus → BM25 → vector in order.
            var seen: Set<String> = []
            var merged: [(id: String, score: Float)] = []
            for item in locusList {
                if seen.insert(item.id).inserted { merged.append(item) }
            }
            for item in bm25List.sorted(by: { $0.score > $1.score }) {
                if seen.insert(item.id).inserted { merged.append(item) }
            }
            for item in vectorList.sorted(by: { $0.score > $1.score }) {
                if seen.insert(item.id).inserted { merged.append(item) }
            }
            fused = Array(merged.prefix(request.limit))
        case .rrf, .matrixAware:
            // .rrf — existing three-way RRF fusion.
            // .matrixAware not yet active for the hybrid lane; falls back to
            // .rrf behaviour. A future mission will add the matrix pass here.
            fused = rrfFuseThree(locusList, bm25List, vectorList, k: 60, limit: request.limit)
        }

        // Hydrate fused hits from the estate. Locus rows are already in memory;
        // supplement with a live-drawers fetch for any IDs that came only from
        // BM25 or vector. Tombstoned rows are excluded from the extra index so
        // that expunged content cannot surface via the BM25 or vector lanes.
        let locusIndex = Dictionary(uniqueKeysWithValues: locusRows.map { ($0.id, $0) })
        let bm25IDs = Set(bm25List.map(\.id))
        let vectorIDs = Set(vectorList.map(\.id))
        // Load non-tombstoned drawers only if there are non-locus hits to hydrate.
        // The .state != .tombstoned guard uses the adjectiveBitmap state field
        // (bits 0-5), which is reliable across both InMemory and SQLite backends.
        let extraIDs = (bm25IDs.union(vectorIDs)).subtracting(Set(locusIndex.keys))
        let extraIndex: [String: LocusKit.Drawer]
        if !extraIDs.isEmpty {
            let liveDrawers = (try? await estate.allDrawers())?.filter { $0.state != .tombstoned } ?? []
            extraIndex = Dictionary(uniqueKeysWithValues: liveDrawers.map { ($0.id, $0) })
        } else {
            extraIndex = [:]
        }
        var hits: [RecallHit] = []
        for (drawerID, rrfScore) in fused {
            let rawDrawer: LocusKit.Drawer? = locusIndex[drawerID] ?? extraIndex[drawerID]
            // Apply the caller-requested hydration level so BM25/vector-path drawers
            // honour the same bitmapOnly stripping that RecallStream applies on the
            // locus page-emission path.
            let drawer = rawDrawer.map { applyHydration($0, level: request.frame.hydrationLevel) }
            var sources: Set<RecallEvidencePath> = []
            if locusIndex[drawerID] != nil { sources.insert(.locusBitmap) }
            if bm25IDs.contains(drawerID) { sources.insert(.corpusBM25) }
            if vectorIDs.contains(drawerID) { sources.insert(.vectorHamming) }
            if sources.isEmpty { sources.insert(.locusBitmap) }

            let bm25Score: Float = bm25IDs.contains(drawerID) ? rrfScore : 0
            let vectorScore: Float = vectorIDs.contains(drawerID) ? rrfScore : 0
            let locusScore: Float = locusIndex[drawerID] != nil ? rrfScore : 0
            let scoreVec = RecallScoreVector(
                locus: locusScore, bm25: bm25Score, vector: vectorScore,
                fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                redundancyPenalty: 0, final: rrfScore
            )
            hits.append(RecallHit(id: drawerID, drawer: drawer, sources: sources,
                                  score: scoreVec, explanation: sources.map(\.rawValue).sorted()))
        }

        Self.recallLog.debug(
            "RecallDirector hybrid: locus=\(locusList.count, privacy: .public) bm25=\(bm25List.count, privacy: .public) vector=\(vectorList.count, privacy: .public) fused=\(hits.count, privacy: .public)"
        )

        return GLKRecallResult(request: request, plan: plan, unionProfile: nil, hits: hits)
    }

    // MARK: - Query sketch compiler

    /// Compile a `RecallQuerySketch` from the request and a registered corpus.
    ///
    /// Embeds `request.queryText` into `queryEngram` via the corpus's provider.
    /// If embedding fails, `queryEngram` is nil and the vector lane returns
    /// an empty candidate set.
    private func compileSketch(
        from request: GLKRecallRequest,
        corpus: Corpus
    ) async -> RecallQuerySketch {
        let text = request.queryText
        var engram: Engram? = nil
        if let t = text, !t.isEmpty {
            engram = try? await corpus.embed(t)
        }
        // Inline keyword tokenisation mirrors CorpusDefaultTokenizer.keywordTokens:
        // ASCII-lowercase, split on non-alpha-numeric, minimum word length 2.
        let tokens: [String]
        if let t = text, !t.isEmpty {
            tokens = t.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }
        } else {
            tokens = []
        }
        return RecallQuerySketch(
            frame: request.frame,
            bitmapPredicates: request.frame.filterChain,
            queryText: text,
            queryTokens: tokens,
            queryEngram: engram,
            latticeAnchor: nil
        )
    }

    // MARK: - RRF fusion helpers

    /// Reciprocal Rank Fusion for two ranked lists.
    ///
    /// Formula: `rrfScore(id) = Σ_L 1 / (k + rank_of_id_in_L)` where ranks are
    /// 1-based. Tie-break: drawerID string ascending (deterministic).
    ///
    /// - Parameters:
    ///   - a: First ranked list (id, score), already sorted descending.
    ///   - b: Second ranked list (id, score), already sorted descending.
    ///   - k: RRF smoothing constant. 60 is the Robertson et al. recommendation.
    ///   - limit: Maximum results to return.
    private func rrfFuse(
        _ a: [(id: String, score: Float)],
        _ b: [(id: String, score: Float)],
        k: Int,
        limit: Int
    ) -> [(id: String, score: Float)] {
        var rrf: [String: Double] = [:]
        for (rank, item) in a.enumerated() {
            rrf[item.id, default: 0] += 1.0 / Double(k + rank + 1)
        }
        for (rank, item) in b.enumerated() {
            rrf[item.id, default: 0] += 1.0 / Double(k + rank + 1)
        }
        var ranked = rrf.map { (id: $0.key, score: Float($0.value)) }
        ranked.sort { x, y in
            if x.score != y.score { return x.score > y.score }
            return x.id < y.id
        }
        return Array(ranked.prefix(limit))
    }

    /// RRF fusion for three ranked lists (locus + BM25 + vector).
    private func rrfFuseThree(
        _ a: [(id: String, score: Float)],
        _ b: [(id: String, score: Float)],
        _ c: [(id: String, score: Float)],
        k: Int,
        limit: Int
    ) -> [(id: String, score: Float)] {
        var rrf: [String: Double] = [:]
        for (rank, item) in a.enumerated() {
            rrf[item.id, default: 0] += 1.0 / Double(k + rank + 1)
        }
        for (rank, item) in b.enumerated() {
            rrf[item.id, default: 0] += 1.0 / Double(k + rank + 1)
        }
        for (rank, item) in c.enumerated() {
            rrf[item.id, default: 0] += 1.0 / Double(k + rank + 1)
        }
        var ranked = rrf.map { (id: $0.key, score: Float($0.value)) }
        ranked.sort { x, y in
            if x.score != y.score { return x.score > y.score }
            return x.id < y.id
        }
        return Array(ranked.prefix(limit))
    }

    // MARK: - unionBest lane

    /// Execute the multi-lane union recall with greedy MMR deduplication.
    ///
    /// Flow:
    /// 1. Compile a `RecallQuerySketch`.
    /// 2. Run the locus lane → frontierK hits.
    /// 3. Run the BM25 lane → frontierK hits (if corpus registered).
    /// 4. Run the vector lane → frontierK hits (if vectorStore and engram available).
    /// 5. Merge all hits into a `RecallCandidateBuffer` (capacity = frontierK * 3 + 10).
    /// 5.5. Bulk-load non-tombstoned drawers from the estate into a `drawerIndex`.
    /// 5.6. Matrix scoring (fieldFit, coOccurrence, temporal columns).
    /// 5.7. Graph and preference scoring from pre-built cold-path caches.
    /// 6. Normalise score columns to [0, 1].
    /// 7. Compute a `RecallUnionProfile`.
    /// 8. Compute adaptive weights from sketch + profile.
    /// 9. Score each candidate: weighted sum of normalised columns
    ///    + signal-agreement bonus (0.05 × popcount(sourceMask) / 3).
    /// 10. Greedy MMR (λ adaptive from `weights.diversity`, range 0.5–0.9): iteratively
    ///    pick the candidate that maximises λ·relevance − (1−λ)·maxSimilarityToSelected,
    ///    where similarity uses post-hydration content shingle overlap (3-gram Jaccard)
    ///    when drawer content is non-empty, and sourceMask bit-overlap Jaccard when
    ///    content is stripped (bitmapOnly hydration) or absent.
    /// 11. Build `RecallHit` array from `drawerIndex` in MMR-selected order,
    ///    applying `hydrationLevel` stripping via `applyHydration(_:level:)`.
    /// 12. Return `GLKRecallResult` with `unionProfile` populated.
    private func recallUnionBest(
        estate: LocusKit.Estate,
        request: GLKRecallRequest,
        plan: RecallPlan,
        handle: EstateHandle
    ) async throws -> GLKRecallResult {
        // Step 1 — compile sketch (may be empty if no corpus is registered).
        let sketch: RecallQuerySketch
        if let corpus = corpusKits[handle] {
            sketch = await compileSketch(from: request, corpus: corpus)
        } else {
            // No corpus — sketch has no tokens or engram; locus lane still runs.
            sketch = RecallQuerySketch(
                frame: request.frame,
                bitmapPredicates: request.frame.filterChain,
                queryText: request.queryText,
                queryTokens: [],
                queryEngram: nil,
                latticeAnchor: nil
            )
        }

        // Step 2 — locus lane.
        let stream = await estate.recall(request.frame)
        var locusRows: [LocusKit.Drawer] = []
        for await page in stream {
            locusRows.append(contentsOf: page.rows)
            if locusRows.count >= plan.frontierK { break }
        }
        let locusSlice = Array(locusRows.prefix(plan.frontierK))

        // Step 3 — BM25 lane (only when corpus is registered and query text present).
        var bm25Hits: [RecallHit] = []
        if let corpus = corpusKits[handle], let text = sketch.queryText, !text.isEmpty {
            let bm25Results = await corpus.bm25TopKBySource(query: text, limit: plan.frontierK)
            bm25Hits = bm25Results.map { r in
                let sv = RecallScoreVector(
                    locus: 0, bm25: r.score, vector: 0,
                    fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                    redundancyPenalty: 0, final: r.score
                )
                return RecallHit(id: r.sourceID, drawer: nil, sources: [.corpusBM25],
                                 score: sv, explanation: ["corpusBM25"])
            }
        }

        // Step 4 — vector lane (only when vectorStore and engram are available).
        var vectorHits: [RecallHit] = []
        if let engram = sketch.queryEngram, let store = vectorStores[handle],
           let corpus = corpusKits[handle] {
            let modelID = await corpus.modelID
            let matches = (try? await store.findNearest(
                probe: engram, modelID: modelID, limit: plan.frontierK)) ?? []
            vectorHits = matches.map { m in
                // Convert Hamming distance to similarity: 1 − distance/256.
                // Distance 0 (identical bits) → 1.0; distance 256 → 0.0.
                let sim = Float(256 - m.distance) / 256.0
                let sv = RecallScoreVector(
                    locus: 0, bm25: 0, vector: sim,
                    fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                    redundancyPenalty: 0, final: sim
                )
                return RecallHit(id: m.drawerID, drawer: nil, sources: [.vectorHamming],
                                 score: sv, explanation: ["vectorHamming"])
            }
        }

        // Count how many lanes actually contributed hits (for signalAgreement normaliser).
        var primarySourceCount = 1 // locus always contributes
        if !bm25Hits.isEmpty   { primarySourceCount += 1 }
        if !vectorHits.isEmpty { primarySourceCount += 1 }

        // Step 5 — merge all hits into the candidate buffer.
        let bufferCapacity = plan.frontierK * 3 + 10
        var buffer = RecallCandidateBuffer(capacity: bufferCapacity)

        for (idx, drawer) in locusSlice.enumerated() {
            // Rank-normalised score for locus: higher rank → higher score.
            let locusScore = Float(locusSlice.count - idx) / Float(max(locusSlice.count, 1))
            let sv = RecallScoreVector(
                locus: locusScore, bm25: 0, vector: 0,
                fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                redundancyPenalty: 0, final: locusScore
            )
            let hit = RecallHit(id: drawer.id, drawer: drawer, sources: [.locusBitmap],
                                score: sv, explanation: ["locusBitmap"])
            buffer.merge(hit: hit, sourceBit: RecallCandidateBuffer.bitLocusBitmap)
        }
        for hit in bm25Hits {
            buffer.merge(hit: hit, sourceBit: RecallCandidateBuffer.bitCorpusBM25)
        }
        for hit in vectorHits {
            buffer.merge(hit: hit, sourceBit: RecallCandidateBuffer.bitVectorHamming)
        }

        // Step 5.5 — bulk-load all live (non-tombstoned) drawers early so matrix
        // scoring and final hydration share one estate round-trip. Moving this
        // before normalize (step 6) lets the matrix scorer derive per-candidate
        // field coordinates from Drawer objects rather than a second fetch.
        // Tombstoned rows are excluded via the adjectiveBitmap state field (bits
        // 0-5); this is reliable across both InMemory and SQLite backends and
        // prevents expunged drawers from surfacing via the BM25 or vector lanes.
        let liveDrawers = (try? await estate.allDrawers())?.filter { $0.state != .tombstoned } ?? []
        let drawerIndex = Dictionary(uniqueKeysWithValues: liveDrawers.map { ($0.id, $0) })

        // Step 5.6 — matrix scoring (before normalize).
        // Runs only when scoring is .matrixAware (the full pipeline) and a
        // MatrixTier is registered. Skipped for .raw and .rrf — see step 9.
        // Populates fieldFit, coOccurrence, and temporal buffer columns.
        // queryCoords are derived from the top locus candidate — the
        // highest-ranked bitmap hit sets the reference field-value signature
        // that all other candidates are scored against.
        if request.scoring == .matrixAware, let matrix = matrixTiers[handle] {
            let scorer = RecallMatrixScorer()
            let queryCoords: [MatrixValueCoord] = locusSlice.first.map {
                matrixCoordsFor(drawer: $0)
            } ?? []
            let ff = scorer.fieldFit(queryCoords: queryCoords, matrix: matrix)
            for i in 0..<buffer.count {
                let candidateCoords = drawerIndex[buffer.ids[i]].map {
                    matrixCoordsFor(drawer: $0)
                } ?? []
                buffer.fieldFit[i] = ff
                buffer.coOccurrence[i] = scorer.coOccurrence(
                    queryCoords: queryCoords,
                    candidateCoords: candidateCoords,
                    matrix: matrix
                )
                buffer.temporal[i] = scorer.temporal(
                    queryCoords: queryCoords,
                    candidateCoords: candidateCoords,
                    activeLags: MatrixTier.lagBuckets,
                    matrix: matrix
                )
            }
        }

        // Step 5.7 — graph and preference scoring.
        // Candidate-frontier lookups only: per-drawer scores are read from
        // pre-built caches registered by the dreaming/training cycle. No
        // synchronous estate-wide analytics are performed here (spec §15).
        // Columns remain 0.0 when no cache is registered for the estate.
        // normalizeFinals preserves all-zero columns as 0.0 (absent signal),
        // distinguishing them from non-zero uniform columns (measured-uniform,
        // normalized to 0.5). Absent columns therefore contribute nothing to
        // scoring on a fresh estate — the correct behaviour for no priors.
        if let graphCache = graphCaches[handle] {
            for i in 0..<buffer.count {
                buffer.graph[i] = graphCache.graphScore(for: buffer.ids[i])
            }
        }
        if let prefStore = preferenceStores[handle] {
            for i in 0..<buffer.count {
                buffer.preference[i] = prefStore.preferenceScore(for: buffer.ids[i])
            }
        }

        // Step 6 — normalise score columns to [0, 1].
        buffer.normalizeFinals()

        // Step 7 — compute union profile.
        let profile = RecallUnionProfile.compute(
            from: buffer, primarySourceCount: primarySourceCount)

        // Step 8 — compute adaptive weights from query + profile.
        // Used only for .matrixAware (the full weighted pipeline). For .raw
        // and .rrf the weights are unused; scores are read directly from the
        // normalised buffer.final column (the lane-normalised rank score from
        // step 6, which already encodes relative relevance without matrix
        // signal contributions).
        let weights = RecallWeights.adaptive(for: sketch, profile: profile)

        // Step 9 — compute final score per candidate.
        //
        // .matrixAware — the full existing weighted pipeline IS the matrixAware
        //   path. Active weights: locus, bm25, vector, fieldFit, graph, preference,
        //   matrix (coOccurrence + temporal combined). agreementBonus = 0.05 ×
        //   popcount(sourceMask) / 3 (normalised to max 0.05 over 3 source bits).
        //   RecallWeights has no dedicated preference field; preference is scored
        //   at equal weight to graph (weights.graph) so both cold-path signals
        //   share the same budget slice.
        //
        // .raw — skip the weighted scoring pass; use the raw .final score from
        //   the buffer (the lane-normalised rank score set in step 6) for MMR.
        //   No matrix signals, no adaptive weights, no agreement bonus.
        //
        // .rrf — .rrf in unionBest uses equal-weight lane scoring without matrix
        //   signals. A future mission will add explicit equal-weight RRF fusion
        //   across lane scores here; for now this falls back to the .raw path
        //   (buffer.final scores) to avoid silent matrix-signal bleed.
        let agreementBonus: Float = 0.05
        var scores = [Float](repeating: 0, count: buffer.count)
        switch request.scoring {
        case .matrixAware:
            for i in 0..<buffer.count {
                // Matrix lane: coOccurrence and temporal combined at equal weight
                // under the matrix weight budget, so the two matrix signals share
                // the same budget slice without over-weighting matrix overall.
                let matrixSignal = (buffer.coOccurrence[i] + buffer.temporal[i]) * 0.5
                scores[i] =
                    weights.locus    * buffer.locus[i] +
                    weights.bm25     * buffer.bm25[i] +
                    weights.vector   * buffer.vector[i] +
                    weights.fieldFit * buffer.fieldFit[i] +
                    weights.matrix   * matrixSignal +
                    weights.graph    * buffer.graph[i] +
                    weights.graph    * buffer.preference[i] +
                    agreementBonus * Float(buffer.sourceMask[i].nonzeroBitCount) / 3.0
            }
        case .raw, .rrf:
            // .raw: use the normalised lane-rank score directly — no matrix signals,
            // no adaptive weights, no agreement bonus.
            // .rrf: falls back to .raw (buffer.final) until a future mission adds
            // explicit equal-weight RRF fusion across lane scores in unionBest.
            for i in 0..<buffer.count {
                scores[i] = buffer.final[i]
            }
        }

        // Step 10 — greedy MMR with adaptive λ.
        // λ is derived from weights.diversity: higher diversity weight (triggered
        // by high-redundancy corpus) reduces λ, pushing MMR toward diversity.
        // Formula: λ = clamp(0.7 − (diversity − 0.1) × 0.5, 0.5, 0.9).
        // At diversity=0.1 (base): λ=0.7. At diversity=0.25 (high redundancy):
        // λ=0.625. maxSim[i] tracks the highest similarity between candidate i
        // and any already-selected candidate. Updated incrementally after each
        // selection to avoid O(n²·k) full recomputation.
        let lambda: Float = min(0.9, max(0.5, 0.7 - (weights.diversity - 0.1) * 0.5))
        var maxSim = [Float](repeating: 0, count: buffer.count)
        var selected: [Int] = []
        var unselected = Set(0..<buffer.count)
        let limit = min(request.limit, buffer.count)

        while selected.count < limit, !unselected.isEmpty {
            // Pick argmax of λ·relevance − (1−λ)·maxSimilarityToSelected.
            var bestIdx = unselected.first!
            var bestMMR = Float.leastNormalMagnitude
            for i in unselected {
                let mmrScore = lambda * scores[i] - (1 - lambda) * maxSim[i]
                if mmrScore > bestMMR {
                    bestMMR = mmrScore
                    bestIdx = i
                }
            }
            selected.append(bestIdx)
            unselected.remove(bestIdx)

            // Update maxSim for remaining candidates using post-hydration
            // shingle similarity when drawer content is available. Falls
            // back to sourceMask Jaccard for bitmapOnly hydration (content
            // stripped to "") or candidates absent from drawerIndex.
            let contentBest = drawerIndex[buffer.ids[bestIdx]]?.content ?? ""
            for i in unselected {
                let sim: Float
                let contentI = drawerIndex[buffer.ids[i]]?.content ?? ""
                if !contentBest.isEmpty, !contentI.isEmpty {
                    sim = glkShingleSimilarity(contentBest, contentI)
                } else {
                    sim = glkSourceMaskJaccard(
                        buffer.sourceMask[bestIdx], buffer.sourceMask[i])
                }
                if sim > maxSim[i] { maxSim[i] = sim }
            }
        }

        // Step 11 — build RecallHit array in MMR-selected order.
        // The explainer runs here — only for selected hits, never for frontier
        // candidates — then wires the explanation array onto each RecallHit.
        let explainer = RecallExplainer()
        var hits: [RecallHit] = []
        hits.reserveCapacity(selected.count)
        for idx in selected {
            let id = buffer.ids[idx]
            // Apply the caller-requested hydration level to the drawer from
            // drawerIndex (which holds unstripped drawers loaded from the estate).
            // This mirrors the stripping RecallStream applies on the locus
            // page-emission path so the director path is consistent.
            let drawer = drawerIndex[id].map {
                applyHydration($0, level: request.frame.hydrationLevel)
            }
            var sources: Set<RecallEvidencePath> = []
            let mask = buffer.sourceMask[idx]
            if mask & RecallCandidateBuffer.bitLocusBitmap  != 0 { sources.insert(.locusBitmap) }
            if mask & RecallCandidateBuffer.bitLocusGraph   != 0 { sources.insert(.locusGraph) }
            if mask & RecallCandidateBuffer.bitCorpusBM25   != 0 { sources.insert(.corpusBM25) }
            if mask & RecallCandidateBuffer.bitVectorHamming != 0 { sources.insert(.vectorHamming) }
            if sources.isEmpty { sources.insert(.locusBitmap) }

            let sv = RecallScoreVector(
                locus: buffer.locus[idx], bm25: buffer.bm25[idx],
                vector: buffer.vector[idx], fieldFit: buffer.fieldFit[idx],
                coOccurrence: buffer.coOccurrence[idx], temporal: buffer.temporal[idx],
                graph: buffer.graph[idx], preference: buffer.preference[idx],
                redundancyPenalty: 0, final: scores[idx]
            )
            // Derive a temporary hit to pass to the explainer (explanation
            // initialised empty; the real explanation is set below).
            let bareHit = RecallHit(id: id, drawer: drawer, sources: sources,
                                    score: sv, explanation: [])
            let explanationLines = explainer.explain(hit: bareHit, sketch: sketch,
                                                     plan: plan, scoring: request.scoring)
            hits.append(RecallHit(id: id, drawer: drawer, sources: sources,
                                  score: sv, explanation: explanationLines))
        }

        Self.recallLog.debug(
            "RecallDirector unionBest: locus=\(locusSlice.count, privacy: .public) bm25=\(bm25Hits.count, privacy: .public) vector=\(vectorHits.count, privacy: .public) selected=\(hits.count, privacy: .public)"
        )

        return GLKRecallResult(request: request, plan: plan, unionProfile: profile, hits: hits)
    }

    // MARK: - Matrix coord helper

    /// Derive MatrixValueCoords from a Drawer's three bitmap fields.
    ///
    /// Uses the same fieldPath/value pairs the AuditBridge writes to the
    /// UnifiedAuditLog when a drawer is captured: "adjective", "operational",
    /// and "provenance". Zero bitmaps are excluded because MatrixTier.applyCapture
    /// skips zero-bitmap coords — a zero-bitmap field never appears as a key in
    /// the O or T matrices, so including it as a query or candidate coord would
    /// always produce a cache miss and contribute 0.0 to the score.
    private func matrixCoordsFor(drawer: LocusKit.Drawer) -> [MatrixValueCoord] {
        var coords: [MatrixValueCoord] = []
        if drawer.adjectiveBitmap != 0 {
            coords.append(MatrixValueCoord(
                fieldPath: "adjective",
                value: .bitmap(UInt64(bitPattern: drawer.adjectiveBitmap))
            ))
        }
        if drawer.operationalBitmap != 0 {
            coords.append(MatrixValueCoord(
                fieldPath: "operational",
                value: .bitmap(UInt64(bitPattern: drawer.operationalBitmap))
            ))
        }
        if drawer.provenance != 0 {
            coords.append(MatrixValueCoord(
                fieldPath: "provenance",
                value: .bitmap(UInt64(bitPattern: drawer.provenance))
            ))
        }
        return coords
    }

    // MARK: - MMR similarity helpers

    /// Jaccard similarity between two source-lane bitsets.
    ///
    /// MMR similarity proxy for bitmapOnly hydration or drawers without
    /// content: candidates sourced from the same lanes carry correlated
    /// signal. Penalising them in the MMR pass raises topical diversity.
    /// When content is available, `glkShingleSimilarity` is preferred.
    ///
    /// Returns 0 when both masks are zero (no shared lane evidence — treat
    /// as fully dissimilar).
    private func glkSourceMaskJaccard(_ a: UInt16, _ b: UInt16) -> Float {
        let andBits = a & b
        let orBits  = a | b
        guard orBits != 0 else { return 0 }
        return Float(andBits.nonzeroBitCount) / Float(orBits.nonzeroBitCount)
    }

    /// Shingle-overlap (Jaccard) similarity between two content strings.
    ///
    /// Builds 3-character lowercase shingle sets from each string and
    /// returns |A ∩ B| / |A ∪ B|. Returns 0.0 when either set is empty
    /// (no shingle overlap — treat as fully dissimilar). The 3-gram window
    /// matches NeuronKit.HybridRecallEngine.shingleSimilarity exactly;
    /// GeniusLocusKit reimplements locally because it does not depend on
    /// NeuronKit (layering constraint).
    private func glkShingleSimilarity(_ a: String, _ b: String) -> Float {
        let sa = glkShingles(a)
        let sb = glkShingles(b)
        guard !sa.isEmpty, !sb.isEmpty else { return 0 }
        let intersection = sa.intersection(sb).count
        let union = sa.union(sb).count
        guard union > 0 else { return 0 }
        return Float(intersection) / Float(union)
    }

    /// 3-character lowercase shingle set for shingle similarity computation.
    ///
    /// Folds the string to lowercase UTF-8 scalars and windows over
    /// every consecutive triple. Short strings (fewer than 3 scalars)
    /// produce an empty set, causing `glkShingleSimilarity` to return 0.
    private func glkShingles(_ s: String) -> Set<String> {
        let chars = Array(s.lowercased())
        guard chars.count >= 3 else { return [] }
        var result = Set<String>(minimumCapacity: chars.count - 2)
        for i in 0...(chars.count - 3) {
            result.insert(String(chars[i..<i+3]))
        }
        return result
    }

    // MARK: - Hydration helper (corpusOnly lane)

    /// Hydrate fused hits for the `corpusOnly` lane.
    ///
    /// Loads all live (non-tombstoned) drawers from the estate once, then joins
    /// by row ID. Tombstoned rows are excluded via the adjectiveBitmap state
    /// field so that expunged content cannot surface in BM25 or vector results.
    /// The `level` parameter applies the same hydration stripping that RecallStream
    /// enforces on the locus page-emission path. For small estates
    /// (test and early-production scale) a full scan is efficient enough.
    private func hydrateHits(
        _ fused: [(id: String, score: Float)],
        estate: LocusKit.Estate,
        bm25IDs: Set<String>,
        vectorIDs: Set<String>,
        level: LocusKit.HydrationLevel
    ) async -> [RecallHit] {
        // Bulk-load non-tombstoned drawers once; build an ID index for O(1) joins.
        // The .state != .tombstoned guard uses adjectiveBitmap bits 0-5, which is
        // reliable across both InMemory and SQLite backends.
        let liveDrawers = (try? await estate.allDrawers())?.filter { $0.state != .tombstoned } ?? []
        let drawerIndex = Dictionary(uniqueKeysWithValues: liveDrawers.map { ($0.id, $0) })

        var hits: [RecallHit] = []
        for (drawerID, rrfScore) in fused {
            // Apply hydration stripping so the BM25/vector path honours the same
            // bitmapOnly contract that RecallStream enforces on the locus path.
            let drawer = drawerIndex[drawerID].map { applyHydration($0, level: level) }
            var sources: Set<RecallEvidencePath> = []
            if bm25IDs.contains(drawerID) { sources.insert(.corpusBM25) }
            if vectorIDs.contains(drawerID) { sources.insert(.vectorHamming) }
            if sources.isEmpty { sources.insert(.corpusBM25) }

            let bm25Score: Float = bm25IDs.contains(drawerID) ? rrfScore : 0
            let vectorScore: Float = vectorIDs.contains(drawerID) ? rrfScore : 0
            let scoreVec = RecallScoreVector(
                locus: 0, bm25: bm25Score, vector: vectorScore,
                fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                redundancyPenalty: 0, final: rrfScore
            )
            hits.append(RecallHit(id: drawerID, drawer: drawer, sources: sources,
                                  score: scoreVec, explanation: sources.map(\.rawValue).sorted()))
        }
        return hits
    }

    // MARK: - Hydration helper

    /// Apply `hydrationLevel` stripping to a drawer, mirroring the behaviour
    /// `RecallStream` enforces on the locus page-emission path (see
    /// `RecallStream.AsyncIterator.hydrate`).
    ///
    /// `.bitmapOnly` rebuilds the `Drawer` with `content = ""` while preserving
    /// every other field (notably the bitmap columns — adjective, operational,
    /// provenance — which are the entire point of this tier).
    /// `.structured` and `.full` return the drawer unchanged.
    private func applyHydration(
        _ d: LocusKit.Drawer,
        level: LocusKit.HydrationLevel
    ) -> LocusKit.Drawer {
        switch level {
        case .bitmapOnly:
            return LocusKit.Drawer(
                id: d.id,
                content: "",
                wing: d.wing,
                room: d.room,
                sourceFile: d.sourceFile,
                chunkIndex: d.chunkIndex,
                addedBy: d.addedBy,
                filedAt: d.filedAt,
                // Preserve eventTime (ING-01): bitmapOnly hydration
                // must not collapse the event clock onto filedAt.
                eventTime: d.eventTime,
                embeddingModelID: d.embeddingModelID,
                tombstonedAt: d.tombstonedAt,
                removedByBatch: d.removedByBatch,
                provenance: d.provenance,
                adjectiveBitmap: d.adjectiveBitmap,
                operationalBitmap: d.operationalBitmap,
                lineageID: d.lineageID,
                udcCode: d.udcCode,
                udcFacets: d.udcFacets,
                wikidataQID: d.wikidataQID,
                wikidataQidsSecondary: d.wikidataQidsSecondary
            )
        case .structured, .full:
            return d
        }
    }
}
