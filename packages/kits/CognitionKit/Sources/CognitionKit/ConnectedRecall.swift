// ConnectedRecall — the `recall_connected` recipe: multi-hop retrieval by
// graph diffusion over the estate's connection structure.
//
// WHY THIS RECIPE EXISTS: similarity search (vector + keyword) measures
// local geometric distance to the QUESTION, so it finds the first hop of a
// multi-hop question and reliably misses the second — the answer turn often
// shares no words with the question (measured: the LoCoMo multi-hop
// category sits near the floor for every similarity-only strategy). The
// deterministic fix is structural: seed a random walk with restart
// (Monte Carlo personalized PageRank — SubstrateML.RandomWalks, seeded,
// bit-reproducible) at the top similarity hits, diffuse through the
// estate's CONNECTION graph to reach bridge-linked memories, and fuse the
// walk's visit ranking with the anchor ranking.
//
// THE GRAPH (Bob's ruling, 2026-08-06): tunnels are high-confidence edges —
// obvious plus human-validated. Dream-produced Association rows are
// PENDING-review candidate edges awaiting the human (via the AI, or the
// moot-mgr dashboard once built) — "a tiny little bit less confident,
// like 2–3%". recall_connected walks BOTH: a pending association is still
// structure worth traversing when a question needs a bridge.
//
//   Association-edge confidence discount (~0.975): recorded, NOT applied
//   in v1. walkWithRestart samples neighbors uniformly (unweighted
//   adjacency), and a 2–3% edge preference is below the resolution of a
//   bounded Monte Carlo visit count — expressing it would be false
//   precision. If measurement ever shows pending edges misleading the
//   walk, the discount belongs in a weighted walkWithRestart variant
//   (SubstrateML change, conformance-gated), not in ad-hoc post-scaling.
//
// COST MODEL: this recipe IS the expensive path. The cheap paths
// (moot_memory_search, recall_precise, recall_shaped) answer frequent
// easy questions; the caller — an AI selecting among the recall roster,
// or a harness strategy — escalates to recall_connected for the hard,
// infrequent bridge question. Escalation triggers stay caller-side so the
// recipe remains a pure deterministic function of its inputs.
//
// Boundary discipline: substrate reads go through GLK verbs only
// (scored recall request, recallTunnels, recallAssociations, hydrate);
// the walk math is SubstrateML's; this recipe sequences.

import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import SubstrateML
import SubstrateTypes

/// One connected-recall match. `content` is hydrated for every returned
/// match (anchor hits carry bodies from the scored recall; walk-only hits
/// are late-hydrated), so the ARIA surface can render the same
/// `id  [room]  preview` lines `moot_memory_search` emits.
public struct ConnectedMatch: Sendable, Equatable {
    public let id: String
    public let room: String
    public let content: String
    /// Which lane(s) surfaced this match: "anchor", "walk", or "both".
    /// Provenance for diagnosis — a healthy multi-hop answer typically
    /// arrives via "walk".
    public let source: String
}

public enum ConnectedRecall {

    /// Default number of anchor hits that seed the diffusion.
    public static let defaultSeeds = 3
    /// Default walk length per seed. Bounded by the same ceiling
    /// ExploratoryRecall enforces.
    public static let defaultSteps = 4_000
    /// Default restart probability (the PPR α). 0.15 is the classic
    /// PageRank teleport value: long enough excursions to cross one or two
    /// bridges, frequent enough restarts to stay anchored to the seeds.
    public static let defaultRestart: Float32 = 0.15
    /// Walk-length ceiling (mirrors ExploratoryRecall.maxWalkSteps).
    static let maxWalkSteps = 50_000

    /// Runs connected recall: scored anchor grab → multi-seed walk with
    /// restart over tunnels ∪ associations → RRF fusion → hydrated matches.
    /// Deterministic for fixed inputs: the walk RNG seeds derive from the
    /// seed drawer ids (FNV-64), never a clock.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        query: String,
        wing: String,
        filter: LocusKit.Filter,
        limit: Int,
        seeds: Int = defaultSeeds,
        steps: Int = defaultSteps,
        restartProbability: Float32 = defaultRestart
    ) async throws -> [ConnectedMatch] {
        let safeLimit = max(1, limit)
        let safeSeeds = max(1, seeds)
        let safeSteps = max(1, min(steps, maxWalkSteps))
        let safeRestart = max(Float32(0.0), min(restartProbability, Float32(0.999)))

        // 1. ANCHOR — the same high-recall scored grab PreciseRecall uses
        //    (.unionBest fuses BM25 + vector; .raw is the unpruned lane).
        //    Hydration .full so anchor bodies ride along for rendering.
        var frame = LocusKit.RecallFrame(filterChain: [filter])
        frame.hydrationLevel = .full
        frame.limit = max(safeLimit, 20)
        let request = GLKRecallRequest(
            frame: frame,
            mode: .unionBest,
            scoring: .raw,
            limit: max(safeLimit, 20),
            fallback: .allowDegraded,
            queryText: query,
            traceLimit: safeLimit)
        let anchor = try await kit.recall(handle, request)
        // ReductionCandidate.from(hit:) is the established hit→(id, room,
        // content) projection (PreciseRecall uses the same one); reusing it
        // keeps room resolution identical across the recall recipes.
        let anchorRows = anchor.hits.enumerated().map { index, hit in
            NeuronKit.ReductionCandidate.from(hit: hit, coarseRank: index)
        }
        let anchorIDs = anchorRows.map(\.id)

        // 2. GRAPH — tunnels (validated) ∪ associations (pending review),
        //    per the ruling above. Edges are added in BOTH directions:
        //    tunnel rows canonicalize A→B and B→A into one row, and a
        //    diffusion that can only travel the stored direction would
        //    halve its reachability for no semantic reason. Drawer-less
        //    (room-level) edges are skipped — the walk ranks drawers.
        var adjacency: [RowId: [RowId]] = [:]
        func addEdge(_ a: String?, _ b: String?) {
            guard let aStr = a, let bStr = b,
                  let aID = UUID(uuidString: aStr),
                  let bID = UUID(uuidString: bStr) else { return }
            adjacency[aID, default: []].append(bID)
            adjacency[bID, default: []].append(aID)
        }
        for tunnel in try await kit.recallTunnels(handle, wing: wing) {
            addEdge(tunnel.sourceDrawerId, tunnel.targetDrawerId)
        }
        for association in try await kit.recallAssociations(handle) {
            addEdge(association.sourceDrawerId, association.targetDrawerId)
        }

        // 3. DIFFUSION — one walk per anchor seed, visit counts summed.
        //    Seeds that are not in the graph contribute nothing (a seed
        //    with no edges cannot diffuse); if NO seed is connected the
        //    result is the anchor ranking unchanged — connected recall
        //    degrades to plain scored recall on a structureless estate,
        //    never below it.
        var visitTotals: [RowId: Int] = [:]
        for seedID in anchorIDs.prefix(safeSeeds) {
            guard let seedRow = UUID(uuidString: seedID),
                  adjacency[seedRow] != nil else { continue }
            let visits = RandomWalks.walkWithRestart(
                seed: seedRow,
                steps: safeSteps,
                restartProbability: safeRestart,
                rngSeed: FNV.hash64(seedID),
                adjacency: adjacency)
            for (row, count) in visits {
                visitTotals[row, default: 0] += count
            }
        }
        // Rank walk hits by summed visits, deterministic tie-break by id.
        let walkRanked: [String] = visitTotals
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.uuidString < $1.key.uuidString }
            .map { $0.key.uuidString }

        // 4. FUSION — RRF (k = 60, the spec constant) over the two ranked
        //    lists. Both lanes are relevance-bearing here (anchor = scored
        //    similarity, walk = structural reachability from those very
        //    anchors), so equal lane weights are the honest fusion.
        var score: [String: Double] = [:]
        for (rank, id) in anchorIDs.enumerated() { score[id, default: 0] += 1.0 / Double(60 + rank + 1) }
        for (rank, id) in walkRanked.enumerated() { score[id, default: 0] += 1.0 / Double(60 + rank + 1) }
        let fused = score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(safeLimit).map(\.key)

        // 5. HYDRATE walk-only survivors (anchor rows carry bodies already)
        //    and assemble matches in fused order with lane provenance.
        //
        //    Walk hydration carries the CALLER's filter, exactly as anchor
        //    recall (step 1) does. Both paths gate identically: a query with
        //    filter:"exportable" must never surface a non-exportable drawer
        //    just because it is reachable from an exportable anchor through a
        //    tunnel or association (Bob ruling, Wave-3 G1). insertDefaults is
        //    per-axis and conditional on absence, so the caller filter rides
        //    ALONGSIDE the spec defaults, never instead of them.
        let anchorByID = Dictionary(uniqueKeysWithValues: anchorRows.map { ($0.id, $0) })
        let walkSet = Set(walkRanked)
        let needsHydration = fused.filter { anchorByID[$0] == nil }
        // Use the GATED overload so tombstoned rows (state=withdrawn/terminal)
        // and sensitivity-restricted rows (>elevated) are excluded: the frame
        // receives insertDefaults (currentlyBelieve + trustworthy +
        // sensitivityAtMost(.elevated)) plus the caller's filter. Graph edges
        // can outlive a drawer's visibility — a stale edge must not disclose
        // a withdrawn, sensitive, or caller-filtered row.
        let hydratedDrawers: [String: Drawer]
        if needsHydration.isEmpty {
            hydratedDrawers = [:]
        } else {
            let drawers = (try? await kit.hydrate(
                handle,
                ids: Array(needsHydration),
                matchingFrame: RecallFrame(filterChain: [filter]))) ?? []
            hydratedDrawers = Dictionary(
                uniqueKeysWithValues: drawers.map { ($0.id, $0) })
        }
        return fused.map { id in
            let inAnchor = anchorByID[id] != nil
            let inWalk = walkSet.contains(id)
            let source = inAnchor && inWalk ? "both" : (inAnchor ? "anchor" : "walk")
            if let row = anchorByID[id] {
                return ConnectedMatch(id: id, room: row.room, content: row.content, source: source)
            }
            let drawer = hydratedDrawers[id]
            return ConnectedMatch(
                id: id,
                room: drawer?.parentNodeId ?? "",
                content: drawer?.content ?? "",
                source: source)
        }
    }
}
