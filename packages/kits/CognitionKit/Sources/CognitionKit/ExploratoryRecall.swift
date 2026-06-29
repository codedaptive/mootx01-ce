// ExploratoryRecall.swift
//
// ExploratoryRecall — the `recall_exploratory` recipe (cookbook § 19.1).
//
// Runs a random walk with restart from a seed drawer over a wing's
// drawer-to-drawer tunnel graph, aggregating visit counts in RowId
// space. Returns the most-visited drawers in descending visit-frequency
// order, excluding the seed.
//
// RowId identity: `SubstrateTypes.RowId` is a typealias for `UUID`, so
// the [RowId: [RowId]] adjacency is a dictionary of UUIDs. Drawer string
// ids are UUID strings by construction (Drawer.id is a UUID string). The
// recipe parses them to UUID/RowId when building the adjacency.
//
// Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2):
//   - Estate read: one `kit.recallTunnels` call through the passed GLK
//     handle (per I-2; no direct substrate access).
//   - Graph build: convert tunnel drawer-id strings to RowIds and build
//     the [RowId: [RowId]] adjacency (deterministic; no math).
//   - Walk: one `RandomWalks.walkWithRestart` call — the engine owns
//     all walk math; the recipe shapes inputs and relabels outputs
//     (I-1, B-1).
//
// Determinism (B-6): the walk's PRNG seed is derived from the seed
// drawer id via FNV hash64 — never from a wall clock — so the same
// seed drawer and wing always produce the same ranking. `now` is not
// used (no timed recall). Walk parameters (steps, restartProbability,
// k) are passed in as recipe input.
//
// Capability gate: `.exploratoryRecall` (SPEC B-5, I-3) is verified
// before any estate touch.
//
// Cookbook references:
//   § 7.4  — random walks (the spec)
//   § 19.1 — recall_exploratory (this recipe)

import Foundation
import GeniusLocusKit
import LocusKit
import SubstrateML
import SubstrateTypes

// MARK: - Result type

/// One recalled drawer from an exploratory walk: the drawer id and its
/// visit count (the number of walk steps that landed there). Ordered by
/// visit count descending (most-visited first) in the recipe output.
public struct ExploratoryResult: Sendable, Equatable {
    /// The drawer's UUID string id (substrate vocabulary; matches `Drawer.id`).
    public let drawerID: String
    /// Number of walk steps that landed on this drawer (visit count).
    public let visitCount: Int

    public init(drawerID: String, visitCount: Int) {
        self.drawerID = drawerID
        self.visitCount = visitCount
    }
}

// MARK: - Recipe

/// Exploratory-recall recipe: walk with restart from a seed drawer over a
/// wing's tunnel graph and return the most-visited drawers.
///
/// The recipe gates on `exploratoryRecall`, reads the tunnel graph via
/// GLK, builds a RowId (`UUID`) adjacency from drawer ids, and delegates
/// the walk entirely to `SubstrateML.RandomWalks.walkWithRestart`. The
/// seed drawer is excluded from the ranked output (it is the origin, not
/// a result). A seed absent from the tunnel graph yields an empty result.
///
/// Read-only (B-6, I-6): no write verb is issued.
public struct ExploratoryRecall: Recipe {

    public struct Input: Sendable {
        /// The wing whose drawer-to-drawer tunnel graph the walk explores.
        public let wing: String
        /// The seed drawer id (UUID string) from which the walk starts.
        public let seedDrawerID: String
        /// Number of walk steps (total visit budget).
        public let steps: Int
        /// Teleport-home probability per step. Must be in [0, 1).
        /// Defaults to the cookbook § 7.4 reference value (0.15).
        public let restartProbability: Float32
        /// Top-k drawer count to return. 0 = return all visited drawers
        /// except the seed.
        public let k: Int

        public init(
            wing: String,
            seedDrawerID: String,
            steps: Int,
            restartProbability: Float32 = Float32(RandomWalks.defaultRestartProb),
            k: Int = 10
        ) {
            self.wing = wing
            self.seedDrawerID = seedDrawerID
            self.steps = steps
            self.restartProbability = restartProbability
            self.k = k
        }
    }

    public struct Output: Sendable {
        /// Most-visited drawers in descending visit-count order, excluding
        /// the seed. The seed is the start of exploration, not a result.
        public let results: [ExploratoryResult]
        /// Total unique RowIds visited by the walk (including the seed).
        public let visitedCount: Int

        public init(results: [ExploratoryResult], visitedCount: Int) {
            self.results = results
            self.visitedCount = visitedCount
        }
    }

    public init() {}

    public let name = "recall_exploratory"
    public let version = "1.0.0"
    public let description =
        "Walk with restart from a seed drawer over a wing's tunnel graph and return the most-visited drawers ranked by visit frequency."

    /// Requires `exploratoryRecall` — gates on `RandomWalks.walkWithRestart`
    /// in SubstrateML (spec B-5, I-3).
    public let requiredCapabilities: [NeuronKitCapability] = [.exploratoryRecall]

    // Maximum walk steps accepted from caller input. Walks beyond this bound
    // exhaust CPU proportionally (O(steps)) and offer diminishing visit-count
    // differentiation past ~50k steps on any realistic estate graph. Clamped,
    // not rejected, so callers requesting absurdly large walks degrade
    // gracefully rather than panic. CK-4 planned hardening.
    private static let maxWalkSteps: Int = 50_000

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        // B-5: verify capability before any estate touch.
        try verifyCapabilities(required: requiredCapabilities)

        // CK-4: Sanitise walk parameters before passing them to
        // RandomWalks.walkWithRestart. Unvalidated inputs can cause:
        //   • steps ≤ 0   → zero-length walk (visit map empty, silently useless)
        //     steps >> N  → O(steps) CPU proportional to caller input (DoS)
        //   • restartProbability ≥ 1.0 → walk always teleports, never progresses
        //     restartProbability < 0.0  → undefined PRNG behaviour in the engine
        //   • k < 0 → prefix(k) panics in some contexts
        //
        // Clamp rather than throw: degrades gracefully, avoids adding a new
        // RecipeError case (and its cross-port parity cost). The clamp bounds
        // are documented constants; callers cannot exceed them.
        let safeSteps = max(1, min(input.steps, Self.maxWalkSteps))
        let safeRestart = max(Float32(0.0), min(input.restartProbability, Float32(0.999)))
        let safeK = max(0, input.k)

        // 1. Read the tunnel graph via GLK (I-2: no direct substrate).
        let tunnels = try await kit.recallTunnels(estate, wing: input.wing)

        // 2. Resolve the seed drawer id to a RowId (UUID).
        // RowId = UUID in Swift (SubstrateTypes typealias). If the seed
        // id is not a valid UUID string, no walk is possible.
        guard let seedRowId = UUID(uuidString: input.seedDrawerID) else {
            return Output(results: [], visitedCount: 0)
        }

        // 3. Build the [RowId: [RowId]] adjacency from the tunnel graph.
        // Edges: drawer-to-drawer tunnels only (both source and target
        // drawer ids must be present and parse as valid UUID strings).
        // The walk uses uniform neighbor sampling (walkWithRestart uses
        // an array of neighbor RowIds, not weighted edges).
        var adjacency: [RowId: [RowId]] = [:]
        for tunnel in tunnels {
            guard
                let srcStr = tunnel.sourceDrawerId,
                let tgtStr = tunnel.targetDrawerId,
                let srcUUID = UUID(uuidString: srcStr),
                let tgtUUID = UUID(uuidString: tgtStr)
            else { continue }
            adjacency[srcUUID, default: []].append(tgtUUID)
        }

        // 4. Seed absent from the graph: no walk, no associations.
        guard adjacency[seedRowId] != nil else {
            return Output(results: [], visitedCount: 0)
        }

        // 5. Derive the RNG seed deterministically from the seed drawer id
        // (no wall clock; B-6). FNV hash64 over the UUID string bytes.
        let rngSeed = FNV.hash64(input.seedDrawerID)

        // 6. Run the walk (engine owns all math; B-1, I-1).
        // Use safeSteps / safeRestart — clamped to valid bounds above (CK-4).
        let visits = RandomWalks.walkWithRestart(
            seed: seedRowId,
            steps: safeSteps,
            restartProbability: safeRestart,
            rngSeed: rngSeed,
            adjacency: adjacency)

        // 7. Rank by visit count descending, excluding the seed.
        // The seed is the origin of the exploration — the caller already
        // knows it; surfacing it would dilute the exploratory results.
        let visitedCount = visits.count
        var ranked: [ExploratoryResult] = visits.compactMap { (rowId, count) in
            guard rowId != seedRowId else { return nil }
            return ExploratoryResult(drawerID: rowId.uuidString, visitCount: count)
        }
        // Primary sort: visit count descending (most-visited first).
        // Secondary sort: drawerID ascending (stable, deterministic tie-break).
        ranked.sort {
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            return $0.drawerID < $1.drawerID
        }
        // Use safeK — clamped to ≥ 0 above (CK-4).
        if safeK > 0 {
            ranked = Array(ranked.prefix(safeK))
        }

        return Output(results: ranked, visitedCount: visitedCount)
    }
}
