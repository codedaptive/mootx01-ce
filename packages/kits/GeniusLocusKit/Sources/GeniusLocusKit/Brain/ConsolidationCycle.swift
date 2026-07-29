// ConsolidationCycle.swift
//
// Wave-2 true consolidation (SPEC_CONSOLIDATION_VAGUE_RECALL §3, §5).
//
// Aged, stable, highly-similar episodic items collapse into one searchable
// "vague" item; the originals remain fully preserved and reachable through
// `_consolidated_from` tunnels, and Fast Recall gets a smaller, sharper
// candidate set via the `representedByVague` tier filter (§4.2, LocusKit
// fourth insertDefaults axis).
//
// Division of labor (mirrors DistillationCycle):
//   - LocusKit `consolidateTransactionally` owns the ATOMIC ACT (§3.2
//     steps 2–4: vague capture + tunnels + constituent bits, one commit).
//   - This file owns everything the store cannot: the candidate pool
//     (D1/D2/D3 aging gate), cluster detection over the Fingerprint256
//     lane (§3.1, D4/D5), the combine-then-distill input composition
//     (§3.2 step 1, D6/D7), vague-drawer construction (D13/D14 bits,
//     fresh lineage), and the vague item's own lane entry.
//
// Covenant invariants enforced here (§3.3, §6):
//   - Constituents are NEVER superseded and never leave the index; the
//     only exclusion mechanism is the evaluator tier filter.
//   - Consolidation never runs inline with capture (D9): the sweep is
//     invoked from maintenance windows only, and every sweep is bounded
//     (candidate slice + cluster cap) so it can never starve the other
//     dream-cycle work.

import EideticLib
import Foundation
import LocusKit
import SubstrateTypes
import VectorKit
import EngramLib
import SubstrateKernel
import SubstrateML

// MARK: - Configuration

/// Tunables for one consolidation sweep. Every value traces to a ratified
/// spec knob; placeholders are the ratified placeholders (D2/D7/D9) and
/// are expected to be tuned from aged-estate distributions before GA.
public struct ConsolidationConfig: Sendable {
    /// D1/D2: capture-age gate — items younger than this never consolidate.
    public var minimumAgeSeconds: TimeInterval
    /// D1/D3: recall-quiet gate — items recalled within this window are
    /// "hot" and never consolidate. The clock derives from the existing
    /// recall-trace rows (RecallTraceItem target+recalledAt); the 30-day
    /// trace prune bounds the lookback, which is exactly the semantics the
    /// gate needs (absence of a trace row == not recently recalled).
    public var recallQuietSeconds: TimeInterval
    /// D4: Hamming ceiling for near-pair clustering. `nil` (the default)
    /// derives the ceiling per sweep from the measured pairwise distance
    /// distribution of the candidate pool sample — the spec forbids a
    /// blind a-priori radius (the DS-series lesson), so the shipped
    /// default is the DERIVATION, not a number.
    public var hammingCeiling: Int?
    /// D5: minimum cluster size. Ratified at 3.
    public var minimumClusterSize: Int
    /// D7: clusters larger than this use the distillate-merge fallback
    /// instead of combining originals (cost grows with cluster size).
    public var largeClusterFallback: Int
    /// D8: vagueLevel cap. Ratified at 2 (one level of vague-of-vague).
    public var vagueLevelCap: UInt8
    /// D9: bounded sweep — at most this many pool candidates are examined
    /// per maintenance window; the sweep resumes from the cursor next
    /// cycle and never scans unboundedly.
    public var maxCandidatesPerSweep: Int
    /// Near-pair probe width per candidate (bounded fan-out into the
    /// Hamming index; components form from the union of probes).
    public var neighborProbeLimit: Int

    public init(
        minimumAgeSeconds: TimeInterval = 90 * 86_400,   // D2 placeholder X=90d
        recallQuietSeconds: TimeInterval = 30 * 86_400,  // D2 placeholder Y=30d
        hammingCeiling: Int? = nil,                      // D4: derive per sweep
        minimumClusterSize: Int = 3,                     // D5 ratified
        largeClusterFallback: Int = 20,                  // D7 placeholder
        vagueLevelCap: UInt8 = 2,                        // D8 ratified
        maxCandidatesPerSweep: Int = 500,                // D9 bound (placeholder)
        neighborProbeLimit: Int = 8
    ) {
        self.minimumAgeSeconds = minimumAgeSeconds
        self.recallQuietSeconds = recallQuietSeconds
        self.hammingCeiling = hammingCeiling
        self.minimumClusterSize = minimumClusterSize
        self.largeClusterFallback = largeClusterFallback
        self.vagueLevelCap = vagueLevelCap
        self.maxCandidatesPerSweep = maxCandidatesPerSweep
        self.neighborProbeLimit = neighborProbeLimit
    }
}

// MARK: - Sweep

extension GeniusLocusKit {

    /// One bounded consolidation sweep (§3.1 + §3.2). Returns the number of
    /// vague items captured this sweep.
    ///
    /// Invoked from DreamingDaemon maintenance windows only (D9) — never
    /// from any capture path. Idempotent across re-runs: consolidated
    /// constituents carry `representedByVague` and drop out of the pool.
    public func consolidationSweep(
        handle: EstateHandle,
        distillFn: @escaping @Sendable (DistillationInput) -> DistillationOutput,
        now: Date,
        config: ConsolidationConfig = ConsolidationConfig(),
        limit: Int? = nil
    ) async throws -> Int {
        let estate = try estate(for: handle)
        guard let vectorStore = vectorStores[handle] else { return 0 }

        // ── §3.1 step 1: candidate pool ────────────────────────────────
        // Aged (D1/D2), recall-quiet (D3), not already represented, and not
        // a vague item at the D8 cap. Bounded page walk (D9).
        let ageCutoff = now.addingTimeInterval(-config.minimumAgeSeconds)
        let recallCutoff = now.addingTimeInterval(-config.recallQuietSeconds)
        let recentlyRecalled: Set<String> = Set(
            try await estate.recentRecallTraces(since: recallCutoff, now: now)
                .map(\.target))

        var pool: [Drawer] = []
        var cursor: String? = nil
        var examined = 0
        paging: while examined < config.maxCandidatesPerSweep {
            let page = try await estate.activeDrawersAfter(
                id: cursor, limit: min(500, config.maxCandidatesPerSweep - examined))
            if page.isEmpty { break paging }
            cursor = page.last?.id
            examined += page.count
            for drawer in page {
                guard drawer.filedAt <= ageCutoff else { continue }
                guard !drawer.representedByVague else { continue }
                if drawer.isVague && drawer.vagueLevel >= config.vagueLevelCap { continue }
                guard !recentlyRecalled.contains(drawer.id) else { continue }
                pool.append(drawer)
            }
        }
        guard pool.count >= config.minimumClusterSize else { return 0 }

        // Fingerprints for the pool from the distillation-features-v1 lane.
        // Items without a lane entry (never distilled / zero-feature short
        // items) cannot cluster this cycle — they re-enter the pool after
        // the next distillation sweep gives them a fingerprint.
        var engrams: [String: Engram] = [:]
        for drawer in pool {
            let stored = try await vectorStore.vectors(forItemID: drawer.id)
            if let fp = stored.first(where: { $0.modelID == Self.distillationLaneModelID }) {
                engrams[drawer.id] = fp.engram
            }
        }
        let clusterable = pool.filter { engrams[$0.id] != nil }
        guard clusterable.count >= config.minimumClusterSize else { return 0 }

        // ── D4: resolve the Hamming ceiling ────────────────────────────
        // Configured value wins; otherwise derive from the measured pairwise
        // distribution of a bounded sample (≤64 members → ≤2016 pairs): the
        // ceiling is the 10th-percentile pairwise distance, i.e. "closer
        // than 90% of random aged pairs on THIS estate". Derivation, not a
        // blind constant — per the ratified D4 alternative-rejection.
        let ceiling: Int
        if let configured = config.hammingCeiling {
            ceiling = configured
        } else {
            let sample = clusterable.prefix(64).compactMap { engrams[$0.id] }
            var distances: [Int] = []
            for i in sample.indices {
                for j in sample.indices where j > i {
                    distances.append(EngramLib.distance(sample[i], sample[j]))
                }
            }
            guard !distances.isEmpty else { return 0 }
            distances.sort()
            ceiling = distances[max(0, distances.count / 10 - 1)]
        }

        // ── §3.1 steps 2–3: near-pair sweep → connected components ─────
        // Bounded probes into the Hamming index; union-find over edges with
        // distance ≤ ceiling where BOTH endpoints are in the pool.
        let poolIDs = Set(clusterable.map(\.id))
        var parent: [String: String] = [:]
        func find(_ x: String) -> String {
            var root = x
            while let p = parent[root], p != root { root = p }
            parent[x] = root
            return root
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for drawer in clusterable {
            parent[drawer.id] = parent[drawer.id] ?? drawer.id
            guard let probe = engrams[drawer.id] else { continue }
            let matches = try await vectorStore.findNearest(
                probe: probe,
                modelID: Self.distillationLaneModelID,
                limit: config.neighborProbeLimit)
            for match in matches
            where match.itemID != drawer.id
                && match.distance <= ceiling
                && poolIDs.contains(match.itemID) {
                parent[match.itemID] = parent[match.itemID] ?? match.itemID
                union(drawer.id, match.itemID)
            }
        }
        var components: [String: [Drawer]] = [:]
        for drawer in clusterable {
            components[find(drawer.id), default: []].append(drawer)
        }

        // ── §3.2: the consolidation act, one cluster at a time ─────────
        var produced = 0
        let byID = Dictionary(uniqueKeysWithValues: clusterable.map { ($0.id, $0) })
        clusters: for member in components.values
        where member.count >= config.minimumClusterSize {
            if let cap = limit, produced >= cap { break clusters }

            // Capture order (D6: concatenate in capture order).
            let constituents = member
                .compactMap { byID[$0.id] }
                .sorted { ($0.filedAt, $0.id) < ($1.filedAt, $1.id) }

            // D8: the product's level is 1 + max(constituent levels); a
            // cluster whose product would exceed the cap is rejected whole
            // (its members remain untouched and re-enter the pool).
            let productLevel = 1 + (constituents.map { $0.isVague ? $0.vagueLevel : 0 }.max() ?? 0)
            guard productLevel <= config.vagueLevelCap else { continue clusters }

            // §3.2 step 1 — compose input. Preferred path (D6): combine the
            // original contents and distill the combination. Fallback (D7):
            // for oversized clusters merge the constituents' EXISTING
            // distillates (cheap — no matrix over a huge combined text);
            // rows not yet distilled contribute their content unchanged.
            let combined: String
            if constituents.count > config.largeClusterFallback {
                combined = constituents
                    .map { $0.distilled ?? $0.content }
                    .joined(separator: "\n")
            } else {
                combined = constituents.map(\.content).joined(separator: "\n\n")
            }
            let sentences = EideticLib.sentences(combined).map(String.init)
            let rendering: String
            let fingerprint: Fingerprint256
            if sentences.count >= 3 {
                let output = distillFn(DistillationInput(
                    memoryContents: sentences,
                    memoryTimestamps: nil,
                    clusterID: constituents[0].id,
                    sourceIDs: constituents.map(\.id)))
                rendering = output.distilledText.isEmpty
                    ? Self.compactionRendering(of: combined)
                    : output.distilledText
                fingerprint = output.featureFingerprint
            } else {
                rendering = Self.compactionRendering(of: combined)
                fingerprint = DistillationPipeline.queryFingerprint(
                    query: combined,
                    extractFeatures: DistillationPipeline.defaultExtractor)
            }
            guard !rendering.isEmpty else { continue clusters }

            // §3.2 step 2 — construct the vague drawer: fresh identity and
            // FRESH lineageID (never a constituent's — §3.3/§6.3), placed in
            // the earliest constituent's room, carrying isVague + vagueLevel
            // (bits 20 + 22–23; representedByVague is never set on a vague
            // item at capture).
            let vagueBitmap: Int64 =
                DrawerFeatureFlags.isVague.rawValue
                | ((Int64(productLevel) & 0b11) << 22)
            let vague = Drawer(
                id: UUID().uuidString,
                content: rendering,
                parentNodeId: constituents[0].parentNodeId,
                addedBy: "consolidation-daemon",
                filedAt: now,
                embeddingModelID: constituents[0].embeddingModelID,
                operationalBitmap: vagueBitmap
            )

            // §3.2 steps 2–4 in ONE transaction (LocusKit owns atomicity).
            try await estate.consolidateTransactionally(
                vagueDrawer: vague,
                constituentIDs: constituents.map(\.id),
                addedBy: "consolidation-daemon",
                now: now)

            // The vague item's own lane entry (its "own fingerprints" per
            // §3.2) — outside the transaction like distillItem's lane write:
            // columns/tunnels and the lane are independently valid, and the
            // lane upserts on (itemID, modelID) so a crash between the two
            // is healed by the next sweep.
            if fingerprint != .zero {
                try await vectorStore.addVector(
                    itemID: vague.id,
                    engram: fingerprint,
                    modelID: Self.distillationLaneModelID,
                    modelVersion: "1",
                    filedAt: now)
            }
            produced += 1
        }
        return produced
    }
}
