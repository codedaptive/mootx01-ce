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

        // RRF fusion of BM25 and vector lists.
        let fused = rrfFuse(bm25List, vectorList, k: 60, limit: request.limit)

        // Hydrate fused hits from the estate.
        let hits = await hydrateHits(
            fused,
            estate: estate,
            bm25IDs: Set(bm25List.map(\.id)),
            vectorIDs: Set(vectorList.map(\.id))
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

        // RRF fusion of all three lists.
        let fused = rrfFuseThree(locusList, bm25List, vectorList, k: 60, limit: request.limit)

        // Hydrate fused hits from the estate. Locus rows are already in memory;
        // supplement with allDrawers() for any IDs that came only from BM25/vector.
        let locusIndex = Dictionary(uniqueKeysWithValues: locusRows.map { ($0.id, $0) })
        let bm25IDs = Set(bm25List.map(\.id))
        let vectorIDs = Set(vectorList.map(\.id))
        // Load all drawers only if there are non-locus hits to hydrate.
        let extraIDs = (bm25IDs.union(vectorIDs)).subtracting(Set(locusIndex.keys))
        let extraIndex: [String: LocusKit.Drawer]
        if !extraIDs.isEmpty {
            let allDrawers = (try? await estate.allDrawers()) ?? []
            extraIndex = Dictionary(uniqueKeysWithValues: allDrawers.map { ($0.id, $0) })
        } else {
            extraIndex = [:]
        }
        var hits: [RecallHit] = []
        for (drawerID, rrfScore) in fused {
            let drawer: LocusKit.Drawer? = locusIndex[drawerID] ?? extraIndex[drawerID]
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
    /// 6. Normalise score columns to [0, 1].
    /// 7. Compute a `RecallUnionProfile`.
    /// 8. Compute adaptive weights from sketch + profile.
    /// 9. Score each candidate: weighted sum of normalised columns
    ///    + signal-agreement bonus (0.05 × popcount(sourceMask) / 3).
    /// 10. Greedy MMR (λ=0.7): iteratively pick the candidate that maximises
    ///    λ·relevance − (1−λ)·maxSimilarityToSelected, where similarity
    ///    is sourceMask Jaccard (cheap, pre-hydration proxy).
    /// 11. Hydrate selected IDs from the estate (single `allDrawers()` call).
    /// 12. Return `GLKRecallResult` with `unionProfile` populated.
    ///
    /// MMR similarity before hydration uses sourceMask bit-overlap (Jaccard).
    /// This is the correct pre-hydration proxy: candidates sourced from the same
    /// lanes carry similar signal, so penalising them raises diversity. Post-
    /// hydration shingle similarity can replace this in a future mission.
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

        // Step 5.5 — bulk-load all drawers early so matrix scoring and final
        // hydration share one estate round-trip. Moving allDrawers() before
        // normalize (step 6) lets the matrix scorer derive per-candidate
        // field coordinates from Drawer objects rather than a second fetch.
        let allDrawers = (try? await estate.allDrawers()) ?? []
        let drawerIndex = Dictionary(uniqueKeysWithValues: allDrawers.map { ($0.id, $0) })

        // Step 5.6 — matrix scoring (before normalize).
        // Populate fieldFit, coOccurrence, and temporal buffer columns when a
        // MatrixTier is registered for this estate. queryCoords are derived from
        // the top locus candidate — the highest-ranked bitmap hit sets the
        // reference field-value signature that all other candidates are scored
        // against. Graph and preference columns remain 0.0: no cached graph
        // projections (RandomWalks, EigenvalueCentrality) or preference data
        // (Bradley-Terry from RecallTrace) are integrated per-estate yet; a
        // future mission will wire these when the graph cache and the preference
        // store are promoted into the GeniusLocusKit actor's registry.
        if let matrix = matrixTiers[handle] {
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

        // Step 6 — normalise score columns to [0, 1].
        buffer.normalizeFinals()

        // Step 7 — compute union profile.
        let profile = RecallUnionProfile.compute(
            from: buffer, primarySourceCount: primarySourceCount)

        // Step 8 — compute adaptive weights from query + profile.
        let weights = RecallWeights.adaptive(for: sketch, profile: profile)

        // Step 9 — compute weighted final score per candidate.
        // Active weights: locus, bm25, vector, fieldFit, graph, matrix (coOccurrence
        // + temporal combined under the matrix weight budget).
        // agreementBonus = 0.05 × popcount(sourceMask) / 3.
        // Divides by 3 because the maximum popcount across the three primary
        // source bits is 3; this normalises the bonus to a maximum of 0.05.
        let agreementBonus: Float = 0.05
        var scores = [Float](repeating: 0, count: buffer.count)
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
                agreementBonus * Float(buffer.sourceMask[i].nonzeroBitCount) / 3.0
        }

        // Step 10 — greedy MMR (λ = 0.7).
        // maxSim[i] tracks the highest similarity between candidate i and any
        // already-selected candidate. Updated incrementally after each selection
        // to avoid O(n²·k) full recomputation.
        var maxSim = [Float](repeating: 0, count: buffer.count)
        var selected: [Int] = []
        var unselected = Set(0..<buffer.count)
        let limit = min(request.limit, buffer.count)

        while selected.count < limit, !unselected.isEmpty {
            // Pick argmax of λ·relevance − (1−λ)·maxSimilarityToSelected.
            var bestIdx = unselected.first!
            var bestMMR = Float.leastNormalMagnitude
            for i in unselected {
                let mmrScore = 0.7 * scores[i] - 0.3 * maxSim[i]
                if mmrScore > bestMMR {
                    bestMMR = mmrScore
                    bestIdx = i
                }
            }
            selected.append(bestIdx)
            unselected.remove(bestIdx)

            // Update maxSim for remaining candidates using sourceMask Jaccard.
            // Pre-hydration similarity proxy: candidates that share source lanes
            // carry correlated signal and should be penalised.
            for i in unselected {
                let sim = glkSourceMaskJaccard(
                    buffer.sourceMask[bestIdx], buffer.sourceMask[i])
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
            let drawer = drawerIndex[id]
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
    /// Pre-hydration MMR similarity proxy: candidates sourced from the same
    /// lanes carry correlated signal. Penalising them in the MMR pass raises
    /// topical diversity. Post-hydration, shingle similarity over drawer content
    /// can replace this in a future mission.
    ///
    /// Returns 0 when both masks are zero (no shared lane evidence — treat
    /// as fully dissimilar).
    private func glkSourceMaskJaccard(_ a: UInt16, _ b: UInt16) -> Float {
        let andBits = a & b
        let orBits  = a | b
        guard orBits != 0 else { return 0 }
        return Float(andBits.nonzeroBitCount) / Float(orBits.nonzeroBitCount)
    }

    // MARK: - Hydration helper (corpusOnly lane)

    /// Hydrate fused hits for the `corpusOnly` lane.
    ///
    /// Loads all current drawers from the estate once, then joins by row ID.
    /// Using `estate.allDrawers()` is the available public estate API for bulk
    /// drawer retrieval; single-drawer-by-ID lookup is not yet on the public
    /// surface (tracked for a future LocusKit verb). For small estates
    /// (test and early-production scale) this is efficient enough.
    private func hydrateHits(
        _ fused: [(id: String, score: Float)],
        estate: LocusKit.Estate,
        bm25IDs: Set<String>,
        vectorIDs: Set<String>
    ) async -> [RecallHit] {
        // Bulk-load all drawers once; build an ID index for O(1) joins.
        let allDrawers = (try? await estate.allDrawers()) ?? []
        let drawerIndex = Dictionary(uniqueKeysWithValues: allDrawers.map { ($0.id, $0) })

        var hits: [RecallHit] = []
        for (drawerID, rrfScore) in fused {
            let drawer: LocusKit.Drawer? = drawerIndex[drawerID]
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
}
