import CorpusKit
import EngramLib
import Foundation
import OSLog
import LocusKit
import SubstrateML
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
        // for scoring without retrieving unbounded rows. A RecallShape may
        // override this pool depth (6b-modifiers); the override is clamped to the
        // SAME [64, 256] envelope so a shape cannot request an unbounded scan, and
        // a nil shape (or nil override) leaves the computed default unchanged.
        let computedFrontierK = min(max(request.limit * 4, 64), 256)
        let frontierK = request.recallShape?.effectiveFrontierK(engineDefault: computedFrontierK)
            ?? computedFrontierK
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
            //
            // nodeTreeNative routes to locusOnly; no corpus/vector stages are
            // attempted, so degradedStages is always empty for this mode.
            return try await recallLocusOnly(estate: estate, request: request, plan: plan)
        }
    }

    // MARK: - Late body hydration capability

    /// LATE BODY HYDRATION — read the full content blob for a specific id set on
    /// the estate behind `handle`. Returns `id → content` for every id with a
    /// live row; ids with no row are absent from the map.
    ///
    /// This is the GLK-owned hydration capability the higher lanes (NeuronKit
    /// reductions via CognitionKit recipes) call back into after a body-free
    /// recall: they fetch a wide candidate pool body-free (`.bitmapOnly` /
    /// `.structured`), narrow it on the dense signal, and hydrate ONLY the
    /// survivors through this method. Keeping it here means NeuronKit and
    /// CognitionKit never reach the LocusKit store directly — they request
    /// hydration through GLK, the composition layer that owns the estate handle.
    ///
    /// - Parameters:
    ///   - handle: the estate to hydrate from. Must be open in this kit.
    ///   - ids: the survivor/top-k ids whose bodies to read.
    /// - Returns: `id → content` for the ids that resolve to a live row.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func hydrate(_ handle: EstateHandle, ids: [String]) async throws -> [String: String] {
        let estate = try estate(for: handle)
        let bodies = try await estate.hydrateBodies(ids: ids)
        return Dictionary(uniqueKeysWithValues: bodies.map { ($0.id, $0.content) })
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
        //
        // B-10a: trace rows are written ONLY for external-origin requests.
        // Internal reads (dreaming, standing signals, recipes, migration, etc.)
        // must leave traceLimit = nil so the reward pipeline learns from
        // experience with users, not from the system's own reflective reads.
        //
        // For external requests: traceLimit = request.traceLimit ?? request.limit
        // so the reward cycle records exactly the rows surfaced to the caller.
        // When a caller (e.g. the PreciseRecall recipe) passes a coarse pool as
        // `limit` but a smaller final-result count as `traceLimit`, the trace
        // write is capped to the final result count — writing pool-sized trace
        // rows for a limit-20 precise query would inflate the trace table with
        // rows the caller never received.
        var tracedFrame = request.frame
        if case .external = request.origin {
            // External-origin: set traceLimit so the estate writes reward-cycle
            // trace rows. The frame is immutable, so we build a local copy.
            tracedFrame.traceLimit = request.traceLimit ?? request.limit
        }
        // Internal-origin: tracedFrame.traceLimit stays nil — no trace writes.
        let stream = await estate.recall(tracedFrame)
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
        //   - .rrf  — single-lane RRF is rank-preserving over the one locus
        //             cursor, so the ordering equals .raw; this is the real
        //             single-lane behaviour, not a fallback.
        //   - .matrixAware — the locusOnly lane has no matrix scoring pass (the
        //             matrix signals are defined for the unionBest weighted
        //             pipeline). matrixAware therefore FALLS BACK to raw bitmap
        //             ordering, and that fallback is surfaced as the
        //             `locusOnly.matrixAware` degraded stage below so the caller
        //             knows the requested scoring was not the one applied.
        // The hit ordering is identical for all three; only matrixAware records
        // a degraded stage (its request could not be honoured).
        //
        // Seed from the LocusKit recall stream (P0-5 sites 1-5): a failed
        // internal read (liveRows / room-fingerprints / room-drawer / bitmap-
        // eval) names a `locus.*` stage on the stream so a FAILED locus recall
        // is distinguishable from a GENUINE-EMPTY estate. Genuine-empty seeds none.
        var degradedStages: [String] = stream.degradedStages
        if request.scoring == .matrixAware {
            // estateUUID is actor-isolated on LocusKit.Estate; recallLocusOnly
            // has no EstateHandle parameter (it is reachable via the corpusOnly
            // allowDegraded path with a synthesised plan), so read it here.
            let estateID = await estate.estateUUID.uuidString
            Self.recallLog.debug(
                "RecallDirector locusOnly: matrixAware requested but no matrix pass in this lane — degraded to raw ordering")
            glkEmit(
                name: GLKMetricName.locusOnlyMatrixAwareFallback,
                value: 1.0,
                tags: ["estate_id": estateID],
                now: Date()
            )
            degradedStages.append("locusOnly.matrixAware")
        }

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

        // locusOnly does not attempt the dense float lane or any corpus/vector
        // stage. Its degradations are: a scoring-fallback (matrixAware requested
        // but unavailable in this lane, set above) and any LocusKit recall
        // internal-read failure surfaced via the stream (P0-5 sites 1-5, seeded
        // into degradedStages at the drain above).
        return GLKRecallResult(
            request: request,
            plan: plan,
            unionProfile: nil,
            hits: hits,
            denseLaneStatus: nil,
            degradedStages: degradedStages
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

        // Accumulates the names of stages that encountered a recoverable error.
        // Populated below; carried through to GLKRecallResult.degradedStages.
        var degradedStages: [String] = []

        let sketch = await compileSketch(
            from: request, corpus: corpus, handle: handle, degradedStages: &degradedStages)

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
        // Raw integer Hamming distance per drawer id (0…256), preserved alongside
        // the normalized score so the returned hit can expose it. The normalized
        // score still drives RRF ranking; this map is additive enrichment.
        var hammingByID: [String: Int] = [:]
        if let engram = sketch.queryEngram, let store = vectorStores[handle] {
            let modelID = await corpus.modelID
            // Consume the test seam (single-use: the seam error is taken once
            // and the property is cleared so subsequent calls behave normally).
            let forcedVectorError = _testForceVectorHammingError
            _testForceVectorHammingError = nil
            let matchResult: Result<[VectorMatch], Error>
            if let forcedError = forcedVectorError {
                matchResult = .failure(forcedError)
            } else {
                do {
                    matchResult = .success(try await store.findNearest(
                        probe: engram, modelID: modelID, limit: plan.frontierK))
                } catch {
                    matchResult = .failure(error)
                }
            }
            switch matchResult {
            case .success(let matches):
                // Convert Hamming distance to a score: score = 1 - distance/256.
                // Distance 0 (identical) → score 1.0; distance 256 → score 0.0.
                for m in matches { hammingByID[m.itemID] = m.distance }
                vectorList = matches.map { m in
                    (id: m.itemID, score: Float(256 - m.distance) / 256.0)
                }
            case .failure(let error):
                // Hamming vector lane DEGRADED — the query survives on BM25 only.
                // Log + telemetry so estate dashboards surface the failure.
                Self.recallLog.error(
                    "RecallDirector corpusOnly: vectorHamming.findNearest degraded: \(error, privacy: .public)")
                glkEmit(
                    name: GLKMetricName.vectorHammingDegraded,
                    value: 1.0,
                    tags: ["estate_id": handle.estateUUID.uuidString, "lane": "corpusOnly"],
                    now: Date()
                )
                degradedStages.append("vectorHamming.findNearest")
                vectorList = []
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
        // .matrixAware — the corpusOnly lane has no matrix scoring pass (the
        //         matrix signals fieldFit/coOccurrence/temporal are defined for
        //         the unionBest weighted pipeline). matrixAware FALLS BACK to
        //         .rrf fusion here, and that fallback is surfaced as the
        //         `corpusOnly.matrixAware` degraded stage so the caller knows
        //         the requested scoring was not the one applied.
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
            // .rrf — real two-lane reciprocal-rank fusion of BM25 + vector.
            // .matrixAware reuses this fusion (no matrix pass in this lane) and
            // records the scoring fallback below.
            if request.scoring == .matrixAware {
                Self.recallLog.debug(
                    "RecallDirector corpusOnly: matrixAware requested but no matrix pass in this lane — degraded to rrf")
                glkEmit(
                    name: GLKMetricName.corpusOnlyMatrixAwareFallback,
                    value: 1.0,
                    tags: ["estate_id": handle.estateUUID.uuidString],
                    now: Date()
                )
                degradedStages.append("corpusOnly.matrixAware")
            }
            // Signed-weight fusion (6b-modifiers). Lane order [bm25, hamming] is
            // fixed; the weight array is empty when no shape is set, so rrfFuseN
            // takes its all-1.0 fast path — unweighted two-lane RRF.
            let weights = laneWeights(
                for: request.recallShape, laneKeys: ["bm25", "hamming"])
            fused = rrfFuseN([bm25List, vectorList], weights: weights, k: 60, limit: request.limit)
        }

        // Hydrate fused hits from the estate, applying the recall frame's filter
        // chain so corpus-lane candidates the frame excludes (e.g. withdrawn under
        // the default `.currentlyBelieve`) are dropped, and the requested hydration
        // level to the loaded drawers.
        let hits = await hydrateHits(
            fused,
            estate: estate,
            frame: request.frame,
            bm25IDs: Set(bm25List.map(\.id)),
            vectorIDs: Set(vectorList.map(\.id)),
            hammingByID: hammingByID,
            level: request.frame.hydrationLevel,
            handle: handle,
            degradedStages: &degradedStages
        )

        Self.recallLog.debug(
            "RecallDirector corpusOnly: bm25=\(bm25List.count, privacy: .public) vector=\(vectorList.count, privacy: .public) fused=\(hits.count, privacy: .public) degraded=\(degradedStages, privacy: .public)"
        )

        // corpusOnly does not include the dense float lane (BM25 + Hamming only).
        return GLKRecallResult(request: request, plan: plan, unionProfile: nil, hits: hits,
                               denseLaneStatus: nil, degradedStages: degradedStages)
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
        // Accumulates recoverable stage failures for GLKRecallResult.degradedStages.
        var degradedStages: [String] = []

        // Locus lane — same drain as locusOnly.
        // B-10a: trace rows only for external-origin requests. For external,
        // traceLimit = request.traceLimit ?? request.limit so the reward cycle
        // records the rows the caller finally receives, not the internal scan
        // candidate count. PreciseRecall passes traceLimit = finalLimit so a
        // pool-500 precise query does not write 500 trace rows for a 20-row result.
        var tracedFrame = request.frame
        if case .external = request.origin {
            tracedFrame.traceLimit = request.traceLimit ?? request.limit
        }
        let stream = await estate.recall(tracedFrame)
        var locusRows: [LocusKit.Drawer] = []
        for await page in stream {
            locusRows.append(contentsOf: page.rows)
            if locusRows.count >= plan.frontierK { break }
        }
        // Surface LocusKit recall internal-read failures (P0-5 sites 1-5): a
        // failed locus read names a `locus.*` stage so the hybrid result can
        // tell a FAILED locus lane from a GENUINE-EMPTY one. Genuine-empty: none.
        degradedStages.append(contentsOf: stream.degradedStages)
        let locusList: [(id: String, score: Float)] = Array(locusRows.prefix(plan.frontierK))
            .enumerated()
            .map { (idx, d) in (id: d.id, score: Float(plan.frontierK - idx) / Float(plan.frontierK)) }

        // Corpus and vector lanes — only if corpus is registered.
        var bm25List: [(id: String, score: Float)] = []
        var vectorList: [(id: String, score: Float)] = []
        // Raw integer Hamming distance per drawer id (0…256) from the vector lane,
        // preserved for the returned hit. Ranking still uses the normalized score.
        var hammingByID: [String: Int] = [:]
        if let corpus = corpusKits[handle], let text = request.queryText, !text.isEmpty {
            let sketch = await compileSketch(
                from: request, corpus: corpus, handle: handle, degradedStages: &degradedStages)
            let bm25Hits = await corpus.bm25TopKBySource(query: text, limit: plan.frontierK)
            bm25List = bm25Hits.map { (id: $0.sourceID, score: $0.score) }

            if let engram = sketch.queryEngram, let store = vectorStores[handle] {
                let modelID = await corpus.modelID
                // Consume the test seam (single-use).
                let forcedVectorError = _testForceVectorHammingError
                _testForceVectorHammingError = nil
                let matchResult: Result<[VectorMatch], Error>
                if let forcedError = forcedVectorError {
                    matchResult = .failure(forcedError)
                } else {
                    do {
                        matchResult = .success(try await store.findNearest(
                            probe: engram, modelID: modelID, limit: plan.frontierK))
                    } catch {
                        matchResult = .failure(error)
                    }
                }
                switch matchResult {
                case .success(let matches):
                    for m in matches { hammingByID[m.itemID] = m.distance }
                    vectorList = matches.map { m in
                        (id: m.itemID, score: Float(256 - m.distance) / 256.0)
                    }
                case .failure(let error):
                    // Hamming vector lane DEGRADED — query survives on locus + BM25.
                    Self.recallLog.error(
                        "RecallDirector hybrid: vectorHamming.findNearest degraded: \(error, privacy: .public)")
                    glkEmit(
                        name: GLKMetricName.vectorHammingDegraded,
                        value: 1.0,
                        tags: ["estate_id": handle.estateUUID.uuidString, "lane": "hybrid"],
                        now: Date()
                    )
                    degradedStages.append("vectorHamming.findNearest")
                    vectorList = []
                }
            }
        }

        // Build the candidate list according to the requested scoring strategy.
        //
        // .rrf  — three-way RRF fusion of locus, BM25, and vector; default
        //         and most accurate combiner for the hybrid lane.
        // .raw  — skip RRF fusion; merge all three lists in order
        //         (locus → BM25 → vector), dedup by ID, apply limit.
        //         No rank math; the ordering reflects lane priority, not
        //         inter-lane rank fusion.
        // .matrixAware — the hybrid lane has no matrix scoring pass (the matrix
        //         signals are defined for the unionBest weighted pipeline).
        //         matrixAware FALLS BACK to three-way RRF fusion, and that
        //         fallback is surfaced as the `hybrid.matrixAware` degraded
        //         stage so the caller knows the requested scoring was not the
        //         one applied.
        let fused: [(id: String, score: Float)]
        switch request.scoring {
        case .raw:
            // .raw skips RRF fusion; merge locus → BM25 → vector in order.
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
            // .rrf — real three-way RRF fusion of locus + BM25 + vector.
            // .matrixAware reuses this fusion (no matrix pass in this lane) and
            // records the scoring fallback below.
            if request.scoring == .matrixAware {
                Self.recallLog.debug(
                    "RecallDirector hybrid: matrixAware requested but no matrix pass in this lane — degraded to rrf")
                glkEmit(
                    name: GLKMetricName.hybridMatrixAwareFallback,
                    value: 1.0,
                    tags: ["estate_id": handle.estateUUID.uuidString],
                    now: Date()
                )
                degradedStages.append("hybrid.matrixAware")
            }
            // Signed-weight fusion (6b-modifiers). Lane order [locus, bm25, hamming]
            // is fixed; the weight array is empty when no shape is set, so rrfFuseN
            // takes its all-1.0 fast path — unweighted three-lane RRF.
            let weights = laneWeights(
                for: request.recallShape, laneKeys: ["locus", "bm25", "hamming"])
            fused = rrfFuseN(
                [locusList, bm25List, vectorList], weights: weights, k: 60, limit: request.limit)
        }

        // Hydrate fused hits from the estate. Locus rows are already in memory
        // (they came from the frame-filtered `estate.recall`, so they are
        // frame-admissible by construction); supplement with a FRAME-AWARE
        // by-id load for any IDs that came only from BM25 or vector, so a
        // candidate the frame excludes (withdrawn under `.currentlyBelieve`,
        // tombstoned always) is absent from extraIndex and DROPPED — not surfaced
        // as a nil-drawer phantom — while the same candidate surfaces under a
        // `.usedToBelieve` frame.
        let locusIndex = Dictionary(uniqueKeysWithValues: locusRows.map { ($0.id, $0) })
        let bm25IDs = Set(bm25List.map(\.id))
        let vectorIDs = Set(vectorList.map(\.id))
        let extraIDs = (bm25IDs.union(vectorIDs)).subtracting(Set(locusIndex.keys))
        let extraIndex: [String: LocusKit.Drawer]
        // `extraLoadedIDs` records which extra ids physically loaded, so the drop
        // is gated on load success: an extra id that loaded but failed the frame
        // filter is dropped; one that did not load (transient/partial) is degraded.
        var extraLoadedIDs: Set<String> = []
        // Consume the test seam (single-use) unconditionally so the seam is
        // available even when extraIDs happens to be empty on a given query.
        // This allows tests to verify the failure path regardless of whether
        // all BM25/vector candidates were already in the locus index.
        let forcedHybridError = _testForceHybridGetDrawersError
        _testForceHybridGetDrawersError = nil
        if let forcedError = forcedHybridError {
            // Test seam active — DEGRADE regardless of extraIDs content.
            // The seam fires even when extraIDs is empty because the test is
            // verifying the degradation path, not a real query outcome.
            Self.recallLog.error(
                "RecallDirector hybrid: hybrid.getDrawers degraded (forced): \(forcedError, privacy: .public)")
            glkEmit(
                name: GLKMetricName.hybridGetDrawersDegraded,
                value: 1.0,
                tags: ["estate_id": handle.estateUUID.uuidString],
                now: Date()
            )
            degradedStages.append("hybrid.getDrawers")
            extraIndex = [:]
        } else if !extraIDs.isEmpty {
            // Production path: frame-aware hydrate of frontier IDs from BM25/vector
            // not already in the locus index. O(candidates) by-id batch load.
            //
            // Failure DEGRADES (query survives on locus-indexed results only):
            // BM25/vector hits not in the locus index will be absent from the result.
            do {
                let filtered = try await estate.getDrawers(
                    ids: Array(extraIDs), matchingFrame: request.frame,
                    hydrationLevel: request.frame.hydrationLevel)
                extraIndex = Dictionary(uniqueKeysWithValues: filtered.admissible.map { ($0.id, $0) })
                extraLoadedIDs = filtered.loadedIDs
            } catch {
                // Frontier load DEGRADED — BM25/vector-only candidates absent from result.
                Self.recallLog.error(
                    "RecallDirector hybrid: hybrid.getDrawers degraded: \(error, privacy: .public)")
                glkEmit(
                    name: GLKMetricName.hybridGetDrawersDegraded,
                    value: 1.0,
                    tags: ["estate_id": handle.estateUUID.uuidString],
                    now: Date()
                )
                degradedStages.append("hybrid.getDrawers")
                extraIndex = [:]
            }
        } else {
            extraIndex = [:]
        }
        var hits: [RecallHit] = []
        for (drawerID, rrfScore) in fused {
            // FRAME-FAITHFUL DROP, gated on load success: a non-locus candidate
            // that loaded but is absent from the frame-filtered extraIndex failed
            // the frame filter — drop it. Locus candidates are frame-admissible by
            // construction; a candidate that did not load (degraded) is kept.
            if locusIndex[drawerID] == nil
                && extraLoadedIDs.contains(drawerID) && extraIndex[drawerID] == nil { continue }
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
            // Raw Hamming distance for vector-lane hits (sentinel otherwise),
            // preserved from the vector lane. The fused `rrfScore` remains the
            // ranking signal unchanged; the dense distance is additive enrichment.
            let hamming = hammingByID[drawerID] ?? RecallScoreVector.noHammingDistance
            let scoreVec = RecallScoreVector(
                locus: locusScore, bm25: bm25Score, vector: vectorScore,
                fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                redundancyPenalty: 0, final: rrfScore, hammingDistance: hamming
            )
            hits.append(RecallHit(id: drawerID, drawer: drawer, sources: sources,
                                  score: scoreVec, explanation: sources.map(\.rawValue).sorted()))
        }

        Self.recallLog.debug(
            "RecallDirector hybrid: locus=\(locusList.count, privacy: .public) bm25=\(bm25List.count, privacy: .public) vector=\(vectorList.count, privacy: .public) fused=\(hits.count, privacy: .public) degraded=\(degradedStages, privacy: .public)"
        )

        // hybrid does not include the dense float lane (locus + BM25 + Hamming only).
        return GLKRecallResult(request: request, plan: plan, unionProfile: nil, hits: hits,
                               denseLaneStatus: nil, degradedStages: degradedStages)
    }

    // MARK: - Query sketch compiler

    /// Compile a `RecallQuerySketch` from the request and a registered corpus.
    ///
    /// Embeds `request.queryText` into `queryEngram` via the corpus's provider.
    /// If embedding fails, `queryEngram` is nil and the vector lane returns an
    /// empty candidate set; the failure is recorded in `degradedStages` so the
    /// caller can surface the degradation in `GLKRecallResult.degradedStages`.
    ///
    /// The `_testForceEmbedError` seam (single-use) allows tests to inject an
    /// embed failure without a real corpus error.
    private func compileSketch(
        from request: GLKRecallRequest,
        corpus: Corpus,
        handle: EstateHandle,
        degradedStages: inout [String]
    ) async -> RecallQuerySketch {
        let text = request.queryText
        var engram: Engram? = nil
        if let t = text, !t.isEmpty {
            // Consume the test seam (single-use).
            let forcedEmbedError = _testForceEmbedError
            _testForceEmbedError = nil
            if let forcedError = forcedEmbedError {
                // Embedding DEGRADED via test seam — vector lane will be dark.
                Self.recallLog.error(
                    "RecallDirector compileSketch: corpus.embed degraded (forced): \(forcedError, privacy: .public)")
                glkEmit(
                    name: GLKMetricName.corpusEmbedDegraded,
                    value: 1.0,
                    tags: ["estate_id": handle.estateUUID.uuidString, "lane": "embed"],
                    now: Date()
                )
                degradedStages.append("corpus.embed")
            } else {
                do {
                    engram = try await corpus.embed(t)
                } catch {
                    // Embedding DEGRADED — vector lane will be dark for this query.
                    // The query continues on BM25/locus signals.
                    Self.recallLog.error(
                        "RecallDirector compileSketch: corpus.embed degraded: \(error, privacy: .public)")
                    glkEmit(
                        name: GLKMetricName.corpusEmbedDegraded,
                        value: 1.0,
                        tags: ["estate_id": handle.estateUUID.uuidString, "lane": "embed"],
                        now: Date()
                    )
                    degradedStages.append("corpus.embed")
                }
            }
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

    /// Reciprocal Rank Fusion over N ranked lists — the single fusion primitive.
    ///
    /// Formula: `rrfScore(id) = Σ_L 1 / (k + rank_of_id_in_L)` where rank is the
    /// 0-based position of `id` in list `L` (so the `+ 1` in the denominator makes
    /// the first position 1-based). A list that does not contain `id` contributes
    /// nothing for that id. Each input list is an INDEPENDENT VOTER: an id present
    /// in more lists accrues more reciprocal-rank mass, so a candidate surfaced by
    /// multiple signals ranks at or above one surfaced by a single signal (the
    /// consensus property). Tie-break: drawerID string ascending (deterministic,
    /// matching `VectorStore.findNearest`).
    ///
    /// This is the single N-way RRF primitive the corpusOnly (2-list) and hybrid
    /// (3-list) lanes call directly, so the RRF math has exactly one implementation.
    /// At N=1 (one input list) the result is that list's ids re-sorted by their
    /// reciprocal-rank score — order-preserving for a list already in rank order,
    /// which keeps the single-signal/single-lane path identical to before.
    ///
    /// ## Signed per-list weights (6b-modifiers)
    ///
    /// Each input list `L` carries a signed weight `w_L` so a `RecallShape` can
    /// steer fusion: `fused(id) = Σ_L w_L · 1/(k + rank_L(id) + 1)`.
    ///
    ///   - `w == 1.0` — neutral. The list votes at full strength. When EVERY list
    ///     weight is `1.0` the per-id sum equals the unweighted formula EXACTLY, so
    ///     a nil/absent shape is byte-identical to the pre-6b-modifiers fusion (the
    ///     back-compat contract; proven by test).
    ///   - `w == 0`   — EXCLUDE. The list contributes nothing to the per-id sum;
    ///     its votes are dropped as if it had not run. An id surfaced ONLY by an
    ///     excluded list accrues zero mass and so does not survive (no other list
    ///     ranks it) — exclusion drops a lane's votes.
    ///   - `w < 0`    — SUPPRESS. The list's reciprocal-rank mass is SUBTRACTED, so
    ///     a candidate this list ranks HIGH (large `1/(k+rank+1)`) is DEMOTED by a
    ///     correspondingly large negative term. A candidate also surfaced by a
    ///     positive-weight list nets the two; one surfaced ONLY by a suppressing
    ///     list ends with negative mass and sinks below every positively-fused id.
    ///
    /// `weights.count` must equal `lists.count`; a list whose weight is omitted
    /// (when `weights` is the default empty array) is treated as `1.0`. The score
    /// accumulator stays `Double` for the same numerical path as before; the only
    /// change at all-1.0 is multiplying each term by exactly `1.0`.
    ///
    /// - Parameters:
    ///   - lists: The ranked lists to fuse, each `(id, score)` already sorted
    ///            descending. Empty lists are skipped. The per-list `score` is
    ///            NOT read — RRF is rank-based — only the position matters.
    ///   - weights: Signed per-list weights, aligned by index to `lists`. Empty
    ///            (the default) means every list weighs `1.0` — the unweighted
    ///            formula. A non-empty array MUST match `lists.count`.
    ///   - k: RRF smoothing constant. 60 is the Robertson et al. recommendation.
    ///   - limit: Maximum results to return.
    private func rrfFuseN(
        _ lists: [[(id: String, score: Float)]],
        weights: [Float] = [],
        k: Int,
        limit: Int
    ) -> [(id: String, score: Float)] {
        var rrf: [String: Double] = [:]
        for (listIndex, list) in lists.enumerated() {
            // A missing weight (default empty array) is the neutral 1.0 — so the
            // all-1.0 path multiplies every term by exactly 1.0 and reduces to the
            // unweighted sum (back-compat). A signed weight scales the list's whole
            // contribution: 0 drops it, <0 subtracts its rank mass (demotion).
            let w = listIndex < weights.count ? Double(weights[listIndex]) : 1.0
            if w == 0 { continue }  // exclusion: this list votes for nothing
            for (rank, item) in list.enumerated() {
                rrf[item.id, default: 0] += w * (1.0 / Double(k + rank + 1))
            }
        }
        var ranked = rrf.map { (id: $0.key, score: Float($0.value)) }
        ranked.sort { x, y in
            if x.score != y.score { return x.score > y.score }
            return x.id < y.id
        }
        return Array(ranked.prefix(limit))
    }

    /// Resolve the per-list signed weight array for a fixed-lane fusion, in the
    /// SAME order the `lists` are passed to `rrfFuseN`.
    ///
    /// `laneKeys` names each list's stable lane identifier (see `RecallShape`).
    /// When `shape` is nil every weight is `1.0` (the empty array, which `rrfFuseN`
    /// reads as all-neutral) — so the nil-shape path is byte-identical to today.
    /// When a shape is present, each lane's weight is looked up by its key, with a
    /// missing key defaulting to `1.0`.
    ///
    /// - Parameters:
    ///   - shape: the optional `RecallShape` carrying signed per-lane weights.
    ///   - laneKeys: the stable lane id for each fusion list, in list order.
    /// - Returns: a weight per lane (empty when `shape` is nil, so `rrfFuseN`
    ///   takes its all-1.0 fast path).
    private func laneWeights(for shape: RecallShape?, laneKeys: [String]) -> [Float] {
        guard let shape else { return [] }
        return laneKeys.map { shape.weight(for: $0) }
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
        // Accumulates recoverable stage failures for GLKRecallResult.degradedStages.
        var degradedStages: [String] = []

        // Step 1 — compile sketch (may be empty if no corpus is registered).
        let sketch: RecallQuerySketch
        if let corpus = corpusKits[handle] {
            sketch = await compileSketch(
                from: request, corpus: corpus, handle: handle, degradedStages: &degradedStages)
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
        // B-10a: trace rows only for external-origin requests. For external,
        // traceLimit = request.traceLimit ?? request.limit so the reward cycle
        // records the rows the caller finally receives, not the coarse pool
        // width. PreciseRecall passes traceLimit = finalLimit so a pool-500
        // precise query does not write 500 trace rows for a 20-row result.
        var tracedFrame = request.frame
        if case .external = request.origin {
            tracedFrame.traceLimit = request.traceLimit ?? request.limit
        }
        let stream = await estate.recall(tracedFrame)
        var locusRows: [LocusKit.Drawer] = []
        for await page in stream {
            locusRows.append(contentsOf: page.rows)
            if locusRows.count >= plan.frontierK { break }
        }
        // Surface LocusKit recall internal-read failures (P0-5 sites 1-5): a
        // failed locus read names a `locus.*` stage so the unionBest result can
        // tell a FAILED locus lane from a GENUINE-EMPTY one. Genuine-empty: none.
        degradedStages.append(contentsOf: stream.degradedStages)
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
            // Consume the test seam (single-use).
            let forcedVectorError = _testForceVectorHammingError
            _testForceVectorHammingError = nil
            let matchResult: Result<[VectorMatch], Error>
            if let forcedError = forcedVectorError {
                matchResult = .failure(forcedError)
            } else {
                do {
                    matchResult = .success(
                        try await store.findNearest(
                            probe: engram, modelID: modelID, limit: plan.frontierK))
                } catch {
                    matchResult = .failure(error)
                }
            }
            switch matchResult {
            case .success(let matches):
                vectorHits = matches.map { m in
                    // Convert Hamming distance to similarity: 1 − distance/256.
                    // Distance 0 (identical bits) → 1.0; distance 256 → 0.0.
                    // The normalized `sim` still drives ranking; the raw integer
                    // `m.distance` (0…256) is preserved verbatim on the score vector
                    // so dense-reduction recipes can rank on it without the rounding
                    // loss of `sim`. This is purely additive — `sim` is unchanged.
                    let sim = Float(256 - m.distance) / 256.0
                    let sv = RecallScoreVector(
                        locus: 0, bm25: 0, vector: sim,
                        fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                        redundancyPenalty: 0, final: sim, hammingDistance: m.distance
                    )
                    return RecallHit(id: m.itemID, drawer: nil, sources: [.vectorHamming],
                                     score: sv, explanation: ["vectorHamming"])
                }
            case .failure(let error):
                // Hamming vector lane DEGRADED — query survives on locus + BM25 + dense.
                Self.recallLog.error(
                    "RecallDirector unionBest: vectorHamming.findNearest degraded: \(error, privacy: .public)")
                glkEmit(
                    name: GLKMetricName.vectorHammingDegraded,
                    value: 1.0,
                    tags: ["estate_id": handle.estateUUID.uuidString, "lane": "unionBest"],
                    now: Date()
                )
                degradedStages.append("vectorHamming.findNearest")
                vectorHits = []
            }
        }

        // Step 4.5 — DENSE FLOAT lane (Lane D), PER-SIGNAL. The TRUE float-embedding
        // lane: cosine over the retained pooled vector, NOT the lossy 256-bit
        // SimHash-Hamming projection. Fires independently of the Hamming lane —
        // both can contribute. Runs only when a corpus with at least one held
        // provider is registered and the query text is non-empty. The corpus owns
        // the embed + float-index search; GLK never reaches the store directly.
        // B-10a: this lane writes NO trace rows — it adds candidates to the
        // in-memory buffer only, exactly like the Hamming lane.
        //
        // FloatLaneOutcome makes every dark-lane state observable PER SIGNAL. GLK
        // reads each held signal's outcome and emits a glk.recall.dense_lane_dark
        // counter (tagged with that signal's modelID) when a signal is dark, so
        // estate dashboards surface which signals did not run. A storeError is
        // already logged + counted inside CorpusKit (OSLog + corpus.float_lane.
        // store_error counter) for the affected signal.
        // PER-SIGNAL FAN-OUT (6b-core): the dense lane queries EVERY held provider
        // slot via `floatNearestPerSignal`, not just the default signal. Each
        // returned (modelID, outcome) is its OWN ranked dense candidate list — a
        // per-signal dense lane. A signal that is dark (providerOptOut / noFloatRows
        // / storeError / emptyQuery) emits its denseLaneDark marker tagged with its
        // modelID and contributes no candidates, while the other signals still vote.
        //
        // CONSENSUS: each per-signal `.hits` list is an independent RRF voter (same
        // reciprocal-rank formula as `rrfFuseN`, accumulated inline below so the
        // per-id best-term can also be tracked). A drawer surfaced by MULTIPLE dense
        // signals accrues more reciprocal-rank mass than one surfaced by a single
        // signal. That consensus mass is folded into the dense candidate's `final`
        // as a boost on top of the (max-across-signals) normalized cosine. The boost
        // is the RRF mass from the EXTRA voters beyond the single best-ranked one, so
        // a single-signal candidate gets zero boost — making the N=1 path byte-
        // identical to the pre-6b single-`floatNearest` behaviour (one signal → one
        // list → no extra voters → `final == dense`, exactly as before).
        //
        // `denseLaneStatus` (the aggregate result marker) reports the DEFAULT
        // signal's dark reason, matching pre-6b semantics: at N=1 the default signal
        // is the only signal, so the marker is unchanged; at N>1 the per-signal
        // counters carry each signal's modelID for fine-grained observability.
        // `denseSignalsByID` is hoisted to method scope so step 11 can append the
        // per-signal dense provenance (`vectorDense:<modelID>`) to each selected
        // hit's explanation — the buffer/MMR pass does not carry explanation text,
        // so the modelIDs that voted are threaded through this map instead.
        var denseSignalsByID: [String: [String]] = [:]
        var denseHits: [RecallHit] = []
        var denseLaneExplainerTag: String? = nil
        if let corpus = corpusKits[handle], let text = sketch.queryText, !text.isEmpty {
            let perSignal = await corpus.floatNearestPerSignal(query: text, limit: plan.frontierK)

            // Per-signal ranked id lists feed the N-way RRF voter set. `denseCosineByID`
            // keeps the MAX normalized cosine across signals for the buffer `dense`
            // column (N=1 → the single cosine, unchanged). `denseSignalsByID` records
            // which modelIDs voted, for per-hit provenance. `denseOrder` is the
            // deterministic first-seen id order.
            var perSignalLists: [[(id: String, score: Float)]] = []
            var denseCosineByID: [String: Float] = [:]
            var denseOrder: [String] = []

            for (idx, entry) in perSignal.enumerated() {
                let modelID = entry.modelID
                switch entry.outcome {
                case .hits(let matches):
                    var rankedList: [(id: String, score: Float)] = []
                    rankedList.reserveCapacity(matches.count)
                    for m in matches {
                        // Normalize cosine similarity (∈ [−1, 1]) to [0, 1] as
                        // (sim + 1) / 2 so the dense column matches every other
                        // [0, 1] column's convention (1.0 = identical direction).
                        let dense = max(0, min(1, (m.similarity + 1) / 2))
                        rankedList.append((id: m.itemID, score: dense))
                        if denseCosineByID[m.itemID] == nil { denseOrder.append(m.itemID) }
                        denseCosineByID[m.itemID] = max(denseCosineByID[m.itemID] ?? 0, dense)
                        denseSignalsByID[m.itemID, default: []].append(modelID)
                    }
                    perSignalLists.append(rankedList)

                case .unavailableProviderOptOut:
                    // This signal has no float lane — dark, tagged with its modelID.
                    // The default signal (idx 0) sets the aggregate denseLaneStatus
                    // to preserve pre-6b single-signal semantics.
                    if idx == 0 { denseLaneExplainerTag = "dark:providerOptOut" }
                    glkEmit(
                        name: GLKMetricName.denseLaneDark,
                        value: 1.0,
                        tags: ["estate_id": handle.estateUUID.uuidString,
                               "reason": "providerOptOut", "model_id": modelID],
                        now: Date()
                    )

                case .unavailableNoFloatRows:
                    // This signal has no stored float rows — dark, tagged by modelID.
                    if idx == 0 { denseLaneExplainerTag = "dark:noFloatRows" }
                    glkEmit(
                        name: GLKMetricName.denseLaneDark,
                        value: 1.0,
                        tags: ["estate_id": handle.estateUUID.uuidString,
                               "reason": "noFloatRows", "model_id": modelID],
                        now: Date()
                    )

                case .emptyQuery:
                    // Guard above (text.isEmpty) prevents this in practice; handle
                    // defensively so the enum switch is exhaustive without a `default`.
                    if idx == 0 { denseLaneExplainerTag = "dark:emptyQuery" }

                case .storeError:
                    // Unexpected store failure for this signal. CorpusKit already
                    // logged via OSLog and emitted corpus.float_lane.store_error.
                    if idx == 0 { denseLaneExplainerTag = "dark:storeError" }
                    glkEmit(
                        name: GLKMetricName.denseLaneDark,
                        value: 1.0,
                        tags: ["estate_id": handle.estateUUID.uuidString,
                               "reason": "storeError", "model_id": modelID],
                        now: Date()
                    )
                }
            }

            // N-way consensus over the per-signal dense lists. For each id, accumulate
            // the total reciprocal-rank mass across signals and the single largest
            // per-signal term (the drawer's best rank in any one signal). The boost
            // is `total − best`: the RRF mass from EVERY voter beyond the single
            // best-ranked one. At N=1 (one list) total == best for every id → boost
            // 0 → final == dense (identity with the pre-6b single-`floatNearest`
            // path). At N>1 a drawer ranked highly by multiple signals accrues extra
            // rank-aware mass — the consensus property. k=60 matches every other RRF
            // fusion in this file.
            let consensusK = 60
            var denseTotalRRF: [String: Float] = [:]
            var denseBestTerm: [String: Float] = [:]
            for list in perSignalLists {
                for (rank, item) in list.enumerated() {
                    let term = Float(1.0 / Double(consensusK + rank + 1))
                    denseTotalRRF[item.id, default: 0] += term
                    if term > (denseBestTerm[item.id] ?? 0) { denseBestTerm[item.id] = term }
                }
            }

            // Build one dense hit per distinct id (deterministic first-seen order).
            // `dense` column = max normalized cosine across signals (N=1 → the single
            // cosine, unchanged). `final` = that cosine PLUS the consensus boost.
            denseHits.reserveCapacity(denseOrder.count)
            for id in denseOrder {
                let dense = denseCosineByID[id] ?? 0
                let total = denseTotalRRF[id] ?? 0
                let best = denseBestTerm[id] ?? 0
                let boost = max(0, total - best)
                let finalScore = dense + boost
                // The dense hit's own explanation is the lane token; the per-signal
                // modelID provenance is threaded via `denseSignalsByID` and appended
                // to the SELECTED hit's explanation at step 11 (the buffer/MMR merge
                // does not carry explanation text, so it cannot be set here).
                let sv = RecallScoreVector(
                    locus: 0, bm25: 0, vector: 0,
                    fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                    redundancyPenalty: 0, final: finalScore, dense: dense)
                denseHits.append(RecallHit(id: id, drawer: nil, sources: [.vectorDense],
                                           score: sv, explanation: ["vectorDense"]))
            }
        }

        // Count how many lanes actually contributed hits (for signalAgreement normaliser).
        var primarySourceCount = 1 // locus always contributes
        if !bm25Hits.isEmpty   { primarySourceCount += 1 }
        if !vectorHits.isEmpty { primarySourceCount += 1 }
        if !denseHits.isEmpty  { primarySourceCount += 1 }

        // Step 5 — merge all hits into the candidate buffer.
        // Capacity covers all FOUR lanes (locus, BM25, Hamming, dense) at
        // frontierK each, plus slack, so no lane's candidates are dropped.
        let bufferCapacity = plan.frontierK * 4 + 10
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
        for hit in denseHits {
            buffer.merge(hit: hit, sourceBit: RecallCandidateBuffer.bitVectorDense)
        }

        // Step 5.5 — DENSE-FIRST POOL LOAD (body-free), FRAME-FILTERED. Bulk-load
        // the merged candidate pool by id at `.structured` (content blob projected
        // away — the wide pool is structured/bitmap/lattice columns only) AND apply
        // the recall frame's filter chain, via the LocusKit public frame-aware load.
        // `drawerIndex` is therefore exactly the frame-admissible subset of the pool
        // — identical semantics to the Rust path, whose `drawer_index` is derived
        // from `estate.recall(frame)` for the DEFAULT frame and any override. A
        // BM25/vector candidate whose drawer the frame excludes (e.g. `.withdrawn`
        // under the default `.currentlyBelieve`) is therefore ABSENT from
        // drawerIndex and is DROPPED at step 11 — but the SAME drawer surfaces when
        // the frame overrides to `.usedToBelieve`, because the filter is the frame's,
        // not a hardcode. Every dense scoring stage below reads structured columns,
        // so none needs a body; bodies are read LATE (steps 10–11) via hydrateBodies.
        //
        // `poolLoadedIDs` records every id whose row physically loaded, regardless
        // of the frame filter. The step-11 drop is GATED on it: an id that loaded
        // but is absent from drawerIndex failed the frame filter (drop it); an id
        // that did NOT load (transient/partial read) is DEGRADED gracefully — kept,
        // never dropped. This is the ~10% burst-loss guard: a valid ACTIVE drawer
        // merely not-yet-joined due to a partial load must not be dropped.
        //
        // Failure DEGRADES (query survives on locus/BM25/vector signals only):
        // when the load throws, drawerIndex AND poolLoadedIDs are empty, so the
        // drop is disabled (nothing loaded → nothing to drop) and all matrix/graph/
        // preference scoring columns are zero. Recorded in degradedStages.
        let forcedPoolError = _testForcePoolGetDrawersError
        _testForcePoolGetDrawersError = nil
        let drawerIndex: [String: LocusKit.Drawer]
        let poolLoadedIDs: Set<String>
        let poolGetDrawersResult: Result<LocusKit.FrameFilteredDrawers, Error>
        if let forcedError = forcedPoolError {
            poolGetDrawersResult = .failure(forcedError)
        } else {
            do {
                poolGetDrawersResult = .success(
                    try await estate.getDrawers(
                        ids: buffer.ids,
                        matchingFrame: request.frame,
                        hydrationLevel: .structured))
            } catch {
                poolGetDrawersResult = .failure(error)
            }
        }
        switch poolGetDrawersResult {
        case .success(let filtered):
            drawerIndex = Dictionary(uniqueKeysWithValues: filtered.admissible.map { ($0.id, $0) })
            poolLoadedIDs = filtered.loadedIDs
        case .failure(let error):
            // Pool load DEGRADED — matrix/graph/preference scoring will be zero.
            // The query continues on lane-rank signals only (locus + BM25 + vector).
            Self.recallLog.error(
                "RecallDirector unionBest: pool.getDrawers degraded: \(error, privacy: .public)")
            glkEmit(
                name: GLKMetricName.poolGetDrawersDegraded,
                value: 1.0,
                tags: ["estate_id": handle.estateUUID.uuidString],
                now: Date()
            )
            degradedStages.append("pool.getDrawers")
            drawerIndex = [:]
            poolLoadedIDs = []
        }

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
        //   path. Active weights: locus, bm25, vector (Hamming AND dense, sharing
        //   the vector budget), fieldFit, graph, preference, matrix (coOccurrence
        //   + temporal combined). agreementBonus = 0.05 × popcount(sourceMask) / 4
        //   (normalised to max 0.05 over 4 lane source bits: locus, bm25,
        //   vectorHamming, vectorDense).
        //   RecallWeights has no dedicated preference field; preference is scored
        //   at equal weight to graph (weights.graph) so both cold-path signals
        //   share the same budget slice.
        //
        // .raw — skip the weighted scoring pass; use the raw .final score from
        //   the buffer (the lane-normalised rank score set in step 6) for MMR.
        //   No matrix signals, no adaptive weights, no agreement bonus.
        //
        // .rrf — unionBest implements the weighted matrix-aware pipeline and a
        //   raw pass, but NOT a distinct equal-weight RRF fusion across lane
        //   scores. .rrf therefore FALLS BACK to the .raw path (buffer.final
        //   lane-normalised scores) to avoid silent matrix-signal bleed, and
        //   that fallback is surfaced as the `unionBest.rrf` degraded stage
        //   (recorded below) so the caller knows the requested scoring was not
        //   the one applied. matrixAware (the full weighted pipeline) and raw
        //   are both genuinely implemented and record no degraded stage.
        if request.scoring == .rrf {
            Self.recallLog.debug(
                "RecallDirector unionBest: rrf requested but no distinct RRF fusion in this lane — degraded to raw (buffer.final)")
            glkEmit(
                name: GLKMetricName.unionBestRRFFallback,
                value: 1.0,
                tags: ["estate_id": handle.estateUUID.uuidString],
                now: Date()
            )
            degradedStages.append("unionBest.rrf")
        }
        let agreementBonus: Float = 0.05
        var scores = [Float](repeating: 0, count: buffer.count)
        switch request.scoring {
        case .matrixAware:
            for i in 0..<buffer.count {
                // Matrix lane: coOccurrence and temporal combined at equal weight
                // under the matrix weight budget, so the two matrix signals share
                // the same budget slice without over-weighting matrix overall.
                let matrixSignal = (buffer.coOccurrence[i] + buffer.temporal[i]) * 0.5
                // The dense float lane shares the `vector` weight budget with
                // the Hamming lane (both are vector-similarity signals), so
                // adding dense does not inflate the vector lane's overall share.
                scores[i] =
                    weights.locus    * buffer.locus[i] +
                    weights.bm25     * buffer.bm25[i] +
                    weights.vector   * buffer.vector[i] +
                    weights.vector   * buffer.dense[i] +
                    weights.fieldFit * buffer.fieldFit[i] +
                    weights.matrix   * matrixSignal +
                    weights.graph    * buffer.graph[i] +
                    weights.graph    * buffer.preference[i] +
                    agreementBonus * Float(buffer.sourceMask[i].nonzeroBitCount) / 4.0
            }
        case .raw, .rrf:
            // .raw: use the normalised lane-rank score directly — no matrix signals,
            // no adaptive weights, no agreement bonus.
            // .rrf: shares the .raw path (buffer.final) because unionBest has no
            // distinct equal-weight RRF fusion across lane scores; the fallback
            // is surfaced as the `unionBest.rrf` degraded stage recorded above.
            for i in 0..<buffer.count {
                scores[i] = buffer.final[i]
            }
        }

        // Step 9.5 — DENSE-FIRST MMR-content decision. The MMR pass (step 10)
        // uses content-shingle similarity when bodies are present and the dense
        // sourceMask Jaccard otherwise. The pool was loaded body-free, so a body
        // is materialized for MMR ONLY when the caller asked for full content —
        // the one level whose MMR was content-shingle before this change (a
        // `.full` recall is content-equivalent to today). A `.structured` /
        // `.bitmapOnly` caller did not ask for bodies, so its MMR runs on the
        // dense Jaccard proxy and no pool body is read; the precise content
        // reduction for those callers happens later in the higher (NeuronKit)
        // lanes over the hydrated survivors. `mmrContentByID` is empty for those
        // levels, which the MMR loop reads as "content unavailable → Jaccard."
        //
        // Failure DEGRADES (MMR runs on sourceMask Jaccard proxy): when
        // hydrateBodies fails, mmrContentByID is empty and the MMR selection
        // order may differ from the fully-hydrated path. The stage is recorded.
        var mmrContentByID: [String: String] = [:]
        if case .full = request.frame.hydrationLevel {
            let forcedMMRError = _testForceMMRHydrationError
            _testForceMMRHydrationError = nil
            let mmrResult: Result<[(id: String, content: String)], Error>
            if let forcedError = forcedMMRError {
                mmrResult = .failure(forcedError)
            } else {
                do {
                    let bodies = try await estate.hydrateBodies(ids: buffer.ids)
                    mmrResult = .success(bodies.map { ($0.id, $0.content) })
                } catch {
                    mmrResult = .failure(error)
                }
            }
            switch mmrResult {
            case .success(let pairs):
                mmrContentByID = Dictionary(uniqueKeysWithValues: pairs)
            case .failure(let error):
                // MMR content hydration DEGRADED — MMR uses sourceMask Jaccard proxy.
                Self.recallLog.error(
                    "RecallDirector unionBest: pool.hydrateBodies.mmr degraded: \(error, privacy: .public)")
                glkEmit(
                    name: GLKMetricName.poolHydrateBodiesMMRDegraded,
                    value: 1.0,
                    tags: ["estate_id": handle.estateUUID.uuidString],
                    now: Date()
                )
                degradedStages.append("pool.hydrateBodies.mmr")
                mmrContentByID = [:]
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
            //
            // DETERMINISM: `unselected` is a Set<Int>, whose iteration order is
            // randomized per process by Swift's hash seed. A plain `>` argmax
            // therefore broke ties (equal MMR score) by whichever index the Set
            // happened to yield first — so the same query returned different
            // orderings across processes (the recall-jitter that made every
            // leaderboard comparison ±noise). The argmax must be a TOTAL order:
            // higher MMR score wins, and on an exact tie the lower drawer id
            // wins. That makes the selection independent of Set iteration order —
            // the same stable (score, then id) tie-break VectorStore.findNearest
            // already uses. `bestIdx == -1` seeds the first comparison.
            var bestIdx = -1
            var bestMMR = -Float.greatestFiniteMagnitude
            for i in unselected {
                let mmrScore = lambda * scores[i] - (1 - lambda) * maxSim[i]
                if bestIdx == -1
                    || mmrScore > bestMMR
                    || (mmrScore == bestMMR && buffer.ids[i] < buffer.ids[bestIdx]) {
                    bestMMR = mmrScore
                    bestIdx = i
                }
            }
            selected.append(bestIdx)
            unselected.remove(bestIdx)

            // Update maxSim for remaining candidates using late-hydrated
            // shingle similarity when a body is available (a `.full` caller —
            // `mmrContentByID` populated in step 9.5). Falls back to sourceMask
            // Jaccard for the body-free tiers (`.structured`/`.bitmapOnly`,
            // empty content map) or candidates absent from the pool.
            let contentBest = mmrContentByID[buffer.ids[bestIdx]] ?? ""
            for i in unselected {
                let sim: Float
                let contentI = mmrContentByID[buffer.ids[i]] ?? ""
                if !contentBest.isEmpty, !contentI.isEmpty {
                    sim = glkShingleSimilarity(contentBest, contentI)
                } else {
                    sim = glkSourceMaskJaccard(
                        buffer.sourceMask[bestIdx], buffer.sourceMask[i])
                }
                if sim > maxSim[i] { maxSim[i] = sim }
            }
        }

        // Step 10.5 — LATE BODY HYDRATION for the returned top-k. The pool was
        // loaded body-free; the returned set's bodies are read now, for exactly
        // the selected ids. TRANSITIONAL SAFETY (Kong K3): the returned top-k is
        // never less hydrated than today — a `.full` or `.structured` caller
        // gets bodies on the returned set (preserving the structured content
        // contract), a `.bitmapOnly` caller gets none (applyHydration strips it
        // anyway, so no body is read for that level). `.full` already hydrated
        // the buffer in step 9.5; reuse it rather than re-read.
        //
        // Failure DEGRADES for `.structured` recall: returned hits carry empty
        // `content` fields. The query is not discarded — the scored IDs are still
        // correct. The stage is recorded in degradedStages.
        let selectedIDs = selected.map { buffer.ids[$0] }
        var returnedContentByID: [String: String]
        switch request.frame.hydrationLevel {
        case .full:
            returnedContentByID = mmrContentByID
        case .structured:
            let forcedReturnError = _testForceReturnHydrationError
            _testForceReturnHydrationError = nil
            let returnResult: Result<[(id: String, content: String)], Error>
            if let forcedError = forcedReturnError {
                returnResult = .failure(forcedError)
            } else {
                do {
                    let bodies = try await estate.hydrateBodies(ids: selectedIDs)
                    returnResult = .success(bodies.map { ($0.id, $0.content) })
                } catch {
                    returnResult = .failure(error)
                }
            }
            switch returnResult {
            case .success(let pairs):
                returnedContentByID = Dictionary(uniqueKeysWithValues: pairs)
            case .failure(let error):
                // Return hydration DEGRADED — structured hits carry empty content.
                Self.recallLog.error(
                    "RecallDirector unionBest: pool.hydrateBodies.return degraded: \(error, privacy: .public)")
                glkEmit(
                    name: GLKMetricName.poolHydrateBodiesReturnDegraded,
                    value: 1.0,
                    tags: ["estate_id": handle.estateUUID.uuidString],
                    now: Date()
                )
                degradedStages.append("pool.hydrateBodies.return")
                returnedContentByID = [:]
            }
        case .bitmapOnly:
            returnedContentByID = [:]   // content is stripped by applyHydration
        }

        // Step 11 — build RecallHit array in MMR-selected order.
        // The explainer runs here — only for selected hits, never for frontier
        // candidates — then wires the explanation array onto each RecallHit.
        let explainer = RecallExplainer()
        var hits: [RecallHit] = []
        hits.reserveCapacity(selected.count)
        for idx in selected {
            let id = buffer.ids[idx]
            // FRAME-FAITHFUL DROP (parity with Rust `.filter(drawer_index.contains_key)`):
            // drop an id that physically loaded but is ABSENT from the frame-filtered
            // drawerIndex — it failed the frame's state/structured/content filter
            // (e.g. a withdrawn drawer under the default `.currentlyBelieve`), so it
            // must NOT surface as a nil-drawer phantom. GATED on load success: an id
            // that did not load (transient/partial read; absent from poolLoadedIDs)
            // is DEGRADED gracefully — kept with a nil drawer — never dropped, so a
            // valid ACTIVE drawer not-yet-joined is preserved (the ~10% burst guard).
            if poolLoadedIDs.contains(id) && drawerIndex[id] == nil { continue }
            // Re-materialize the late-hydrated body onto the structured pool
            // drawer, then apply the caller-requested hydration level. The pool
            // drawer carries `content == ""` (body-free load); the returned set
            // had its body read in step 10.5 for the content-bearing tiers.
            // `.bitmapOnly` strips content regardless. This mirrors the stripping
            // RecallStream applies on the locus page-emission path.
            let drawer = drawerIndex[id].map { pool -> LocusKit.Drawer in
                let hydrated = withContent(pool, returnedContentByID[id] ?? "")
                return applyHydration(hydrated, level: request.frame.hydrationLevel)
            }
            var sources: Set<RecallEvidencePath> = []
            let mask = buffer.sourceMask[idx]
            if mask & RecallCandidateBuffer.bitLocusBitmap  != 0 { sources.insert(.locusBitmap) }
            if mask & RecallCandidateBuffer.bitLocusGraph   != 0 { sources.insert(.locusGraph) }
            if mask & RecallCandidateBuffer.bitCorpusBM25   != 0 { sources.insert(.corpusBM25) }
            if mask & RecallCandidateBuffer.bitVectorHamming != 0 { sources.insert(.vectorHamming) }
            if mask & RecallCandidateBuffer.bitVectorDense  != 0 { sources.insert(.vectorDense) }
            if sources.isEmpty { sources.insert(.locusBitmap) }

            // Carry the per-lane buffer columns onto the returned score vector,
            // including the raw Hamming distance preserved through the union
            // merge (sentinel for non-vector-lane hits) and the normalized dense
            // cosine column. `final` is the fused ranking score exactly as
            // before; the extra columns are additive.
            let sv = RecallScoreVector(
                locus: buffer.locus[idx], bm25: buffer.bm25[idx],
                vector: buffer.vector[idx], fieldFit: buffer.fieldFit[idx],
                coOccurrence: buffer.coOccurrence[idx], temporal: buffer.temporal[idx],
                graph: buffer.graph[idx], preference: buffer.preference[idx],
                redundancyPenalty: 0, final: scores[idx],
                hammingDistance: buffer.hammingDistance[idx],
                dense: buffer.dense[idx]
            )
            // Derive a temporary hit to pass to the explainer (explanation
            // initialised empty; the real explanation is set below).
            let bareHit = RecallHit(id: id, drawer: drawer, sources: sources,
                                    score: sv, explanation: [])
            var explanationLines = explainer.explain(hit: bareHit, sketch: sketch,
                                                     plan: plan, scoring: request.scoring)
            // PER-SIGNAL DENSE PROVENANCE (6b-core): when this hit was surfaced by
            // the dense lane, append the modelIDs of the signals that voted, in
            // slot order. The line is honest — it names exactly the signals whose
            // float index ranked this drawer; a signal that did not vote for this
            // id is absent. Additive: the existing source/score/mode/why lines are
            // unchanged, so the N=1 explainer output gains only this one line.
            if let voters = denseSignalsByID[id], !voters.isEmpty {
                explanationLines.append(
                    "denseSignals: " + voters.map { "vectorDense:\($0)" }.joined(separator: ", "))
            }
            hits.append(RecallHit(id: id, drawer: drawer, sources: sources,
                                  score: sv, explanation: explanationLines))
        }

        Self.recallLog.debug(
            "RecallDirector unionBest: locus=\(locusSlice.count, privacy: .public) bm25=\(bm25Hits.count, privacy: .public) vector=\(vectorHits.count, privacy: .public) selected=\(hits.count, privacy: .public) denseLane=\(denseLaneExplainerTag ?? "active", privacy: .public) degraded=\(degradedStages, privacy: .public)"
        )

        return GLKRecallResult(request: request, plan: plan, unionProfile: profile, hits: hits,
                               denseLaneStatus: denseLaneExplainerTag, degradedStages: degradedStages)
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
    /// Delegates to `SubstrateML.ShingleSimilarity.similarity` — the
    /// substrate-owned character-shingle Jaccard kernel (I-25). SubstrateML sits
    /// below both GLK and NeuronKit in the kit graph, and both kits already
    /// declare a SubstrateML dependency, so the kernel has a single owner with no
    /// manifest change and no GLK→NeuronKit cross-kit layering dependency — GLK
    /// reaches the shared kernel downward through the substrate, not sideways.
    ///
    /// The substrate kernel preserves the canonical NeuronKit edge-case contract:
    /// 3-gram windows; 1–2 char strings collapse to a single whole-string shingle;
    /// both-empty → 0.0; |∩|/|∪| otherwise.
    private func glkShingleSimilarity(_ a: String, _ b: String) -> Float {
        ShingleSimilarity.similarity(a, b)
    }

    // MARK: - Hydration helper (corpusOnly lane)

    /// Hydrate fused hits for the `corpusOnly` lane.
    ///
    /// Loads only the fused candidate drawers by id in one batch via the LocusKit
    /// frame-aware load, which applies the recall `frame`'s filter chain so
    /// `drawerIndex` is exactly the frame-admissible subset — a candidate the
    /// frame excludes (withdrawn under the default `.currentlyBelieve`, tombstoned
    /// always) is ABSENT and is DROPPED rather than surfaced as a nil-drawer
    /// phantom; the same candidate surfaces under a `.usedToBelieve` frame because
    /// the filter is the frame's, not a hardcode. The `level` parameter applies
    /// the same hydration stripping RecallStream enforces on the locus page path.
    /// The by-id load is O(candidates), not O(estate).
    ///
    /// The drop is GATED on load success via `loadedIDs`: an id that loaded but is
    /// absent from drawerIndex failed the frame filter (drop it); an id that did
    /// NOT load (transient/partial read) is DEGRADED gracefully — kept with a nil
    /// drawer — never dropped. On total load failure both sets are empty so the
    /// drop is disabled and every fused id is emitted (nil drawer), recorded in
    /// `degradedStages` via the inout accumulator.
    private func hydrateHits(
        _ fused: [(id: String, score: Float)],
        estate: LocusKit.Estate,
        frame: RecallFrame,
        bm25IDs: Set<String>,
        vectorIDs: Set<String>,
        hammingByID: [String: Int],
        level: LocusKit.HydrationLevel,
        handle: EstateHandle,
        degradedStages: inout [String]
    ) async -> [RecallHit] {
        // Bulk-load the fused candidate drawers by id once, frame-filtered, and
        // build an ID index for O(1) joins. An O(candidates) by-id batch load over
        // the fused frontier replaces an O(estate) full scan.
        let forcedCorpusOnlyError = _testForceCorpusOnlyGetDrawersError
        _testForceCorpusOnlyGetDrawersError = nil
        let getDrawersResult: Result<LocusKit.FrameFilteredDrawers, Error>
        if let forcedError = forcedCorpusOnlyError {
            getDrawersResult = .failure(forcedError)
        } else {
            do {
                getDrawersResult = .success(
                    try await estate.getDrawers(
                        ids: fused.map(\.id), matchingFrame: frame, hydrationLevel: level))
            } catch {
                getDrawersResult = .failure(error)
            }
        }
        let drawerIndex: [String: LocusKit.Drawer]
        let loadedIDs: Set<String>
        switch getDrawersResult {
        case .success(let filtered):
            drawerIndex = Dictionary(uniqueKeysWithValues: filtered.admissible.map { ($0.id, $0) })
            loadedIDs = filtered.loadedIDs
        case .failure(let error):
            // corpusOnly frontier load DEGRADED — BM25/vector results unavailable.
            Self.recallLog.error(
                "RecallDirector corpusOnly: corpusOnly.getDrawers degraded: \(error, privacy: .public)")
            glkEmit(
                name: GLKMetricName.corpusOnlyGetDrawersDegraded,
                value: 1.0,
                tags: ["estate_id": handle.estateUUID.uuidString],
                now: Date()
            )
            degradedStages.append("corpusOnly.getDrawers")
            drawerIndex = [:]
            loadedIDs = []
        }

        var hits: [RecallHit] = []
        for (drawerID, rrfScore) in fused {
            // FRAME-FAITHFUL DROP, gated on load success: a candidate that loaded
            // but is absent from the frame-filtered drawerIndex failed the frame
            // filter — drop it. A candidate that did not load (degraded) is kept
            // with a nil drawer so the query degrades gracefully.
            if loadedIDs.contains(drawerID) && drawerIndex[drawerID] == nil { continue }
            // drawerIndex already carries the caller-requested hydration level (the
            // load honoured `level`), except `.bitmapOnly` stripping which the
            // frame-aware load does not apply — re-apply it here for that contract.
            let drawer = drawerIndex[drawerID].map { applyHydration($0, level: level) }
            var sources: Set<RecallEvidencePath> = []
            if bm25IDs.contains(drawerID) { sources.insert(.corpusBM25) }
            if vectorIDs.contains(drawerID) { sources.insert(.vectorHamming) }
            if sources.isEmpty { sources.insert(.corpusBM25) }

            let bm25Score: Float = bm25IDs.contains(drawerID) ? rrfScore : 0
            let vectorScore: Float = vectorIDs.contains(drawerID) ? rrfScore : 0
            // Raw Hamming distance for vector-lane hits (sentinel otherwise),
            // preserved from the vector lane. `final`/`bm25`/`vector` keep the
            // fused RRF score exactly as before — only the dense signal is added.
            let hamming = hammingByID[drawerID] ?? RecallScoreVector.noHammingDistance
            let scoreVec = RecallScoreVector(
                locus: 0, bm25: bm25Score, vector: vectorScore,
                fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                redundancyPenalty: 0, final: rrfScore, hammingDistance: hamming
            )
            hits.append(RecallHit(id: drawerID, drawer: drawer, sources: sources,
                                  score: scoreVec, explanation: sources.map(\.rawValue).sorted()))
        }
        return hits
    }

    // MARK: - Late-hydration helper

    /// Return a copy of `d` with its `content` replaced by `body` — the
    /// dense-first late-hydration step. The pool is loaded body-free
    /// (`content == ""`); this re-materializes the body onto the returned
    /// drawer for exactly the survivor/top-k ids. Every other field is
    /// preserved verbatim. When `body` is empty this is an identity rebuild
    /// (the drawer was already body-free), so callers may invoke it
    /// unconditionally.
    private func withContent(_ d: LocusKit.Drawer, _ body: String) -> LocusKit.Drawer {
        LocusKit.Drawer(
            id: d.id,
            content: body,
            wing: d.wing,
            room: d.room,
            sourceFile: d.sourceFile,
            chunkIndex: d.chunkIndex,
            addedBy: d.addedBy,
            filedAt: d.filedAt,
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
