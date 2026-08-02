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

/// What one consolidation sweep did (§3.2 acts + §5.1 fold-ins) and the
/// D10 drift evidence it observed (fold-in candidates whose nearest vague
/// item sat beyond the D4 ceiling — the rejection counter that feeds the
/// defrag trigger).
public struct ConsolidationSweepReport: Sendable {
    public let newVagueItems: Int
    public let foldIns: Int
    public let foldInRejections: Int
    /// Items whose adjective or provenance sensitivity bitmap was promoted
    /// during the repair prologue (§D.6 #4). Zero when no under-tiered vague
    /// drawers are found.
    public let repairedItems: Int
    public var totalActs: Int { newVagueItems + foldIns }
}

extension GeniusLocusKit {

    /// One bounded consolidation sweep (§3.1 + §3.2 + §5.1). Returns the
    /// count of consolidation acts (new vague items + fold-ins).
    ///
    /// Invoked from DreamingDaemon maintenance windows only (D9) — never
    /// from any capture path. Idempotent across re-runs: consolidated
    /// constituents carry `representedByVague` and drop out of the pool.
    @discardableResult
    public func consolidationSweep(
        handle: EstateHandle,
        distillFn: @escaping @Sendable (DistillationInput) -> DistillationOutput,
        now: Date,
        config: ConsolidationConfig = ConsolidationConfig(),
        limit: Int? = nil
    ) async throws -> Int {
        try await consolidationSweepReport(
            handle: handle, distillFn: distillFn, now: now,
            config: config, limit: limit
        ).totalActs
    }

    /// Sweep with the full report (metrics surface for the D10/D11 defrag
    /// policy and the maintenance diagnostics).
    public func consolidationSweepReport(
        handle: EstateHandle,
        distillFn: @escaping @Sendable (DistillationInput) -> DistillationOutput,
        now: Date,
        config: ConsolidationConfig = ConsolidationConfig(),
        limit: Int? = nil
    ) async throws -> ConsolidationSweepReport {
        let none = ConsolidationSweepReport(newVagueItems: 0, foldIns: 0, foldInRejections: 0, repairedItems: 0)
        let estate = try estate(for: handle)
        guard let vectorStore = vectorStores[handle] else { return none }


        // ── §D.6 #4 repair prologue: restamp under-tiered vague drawers ──────
        // Scan all active vague drawers. For each, compare the vague drawer's
        // stored sensitivity to the MAX of its constituents' sensitivity. If the
        // vague drawer is under-tiered (constituent MAX > vague), restamp the
        // adjective and provenance bitmaps and overwrite the adjective bitmap on
        // all _consolidated_from tunnels for that vague item. Uses
        // "consolidation-repair" as the changedBy actor so these writes are
        // distinct from normal mutation paths in the audit trail.
        var repairedItems = 0
        var repairCursor: String? = nil
        var repairExamined = 0
        repairing: while repairExamined < config.maxCandidatesPerSweep {
            let repPage = try await estate.activeDrawersAfter(
                id: repairCursor, limit: min(500, config.maxCandidatesPerSweep - repairExamined))
            if repPage.isEmpty { break repairing }
            repairCursor = repPage.last?.id
            repairExamined += repPage.count
            for vague in repPage where vague.isVague {
                let constituentIDs = try await estate.vagueConstituents(of: vague.id)
                guard !constituentIDs.isEmpty else { continue }
                let vagueAdjRaw = Int(vague.adjectiveSensitivity.rawValue)
                let vagueProvRaw = Int(vague.sensitivity.rawValue)
                var maxAdjRaw = vagueAdjRaw
                var maxProvRaw = vagueProvRaw
                let constituents = try await estate.getDrawers(ids: constituentIDs)
                for constituent in constituents {
                    let cAdj = Int(constituent.adjectiveSensitivity.rawValue)
                    let cProv = Int(constituent.sensitivity.rawValue)
                    if cAdj > maxAdjRaw { maxAdjRaw = cAdj }
                    if cProv > maxProvRaw { maxProvRaw = cProv }
                }
                guard maxAdjRaw != vagueAdjRaw || maxProvRaw != vagueProvRaw else { continue }
                if maxAdjRaw != vagueAdjRaw {
                    let newAdj = BitField.writeField(
                        Int64(maxAdjRaw), into: vague.adjectiveBitmap, shift: 6, width: 6)
                    try await estate.repairVagueAdjectiveBitmap(
                        drawerId: vague.id, newAdjective: newAdj, now: now)
                }
                if maxProvRaw != vagueProvRaw {
                    let newProv = BitField.writeField(
                        Int64(maxProvRaw), into: vague.provenance, shift: 30, width: 6)
                    try await estate.repairVagueProvenance(
                        drawerId: vague.id, newProvenance: newProv, now: now)
                }
                // Restamp all _consolidated_from tunnels for this vague item.
                // Tunnel adjective bitmap carries the sensitivity tier at bits
                // 6–11 (cookbook §2.3) so tunnel readers see the promoted tier.
                let stampedAdjBitmap = BitField.writeField(
                    Int64(maxAdjRaw), into: 0, shift: 6, width: 6)
                for cid in constituentIDs {
                    let tid = "_consolidated_from:\(vague.id):\(cid)"
                    try await estate.updateTunnelAdjBitmap(id: tid, adjBitmap: stampedAdjBitmap)
                }
                repairedItems += 1
            }
        }
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
        guard !pool.isEmpty else { return ConsolidationSweepReport(newVagueItems: 0, foldIns: 0, foldInRejections: 0, repairedItems: repairedItems) }

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
        guard !clusterable.isEmpty else { return ConsolidationSweepReport(newVagueItems: 0, foldIns: 0, foldInRejections: 0, repairedItems: repairedItems) }

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
            guard !distances.isEmpty else { return ConsolidationSweepReport(newVagueItems: 0, foldIns: 0, foldInRejections: 0, repairedItems: repairedItems) }
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
        // Edge typing (§3.1 vs §5.1 vs §5.4):
        //   non-vague ↔ non-vague  → union edge (new-cluster formation, §3.1)
        //   non-vague ↔ vague      → fold-in candidate (§5.1) — REGARDLESS of
        //                            whether the vague item is itself pool-aged;
        //                            an existing vague item absorbs its
        //                            newly-aged neighbors, it never seeds a
        //                            fresh cluster with them.
        //   vague     ↔ vague      → union edge (vague-of-vague, §5.4).
        // The nearest vague neighbor decides fold-in: within the ceiling it
        // folds, beyond it the rejection feeds the D10 drift counter.
        var nearestVague: [String: (vagueID: String, distance: Int)] = [:]
        var offPoolMatches: [String: [(id: String, distance: Int)]] = [:]
        var offPoolMatchIDs = Set<String>()
        let poolDrawerByID = Dictionary(uniqueKeysWithValues: clusterable.map { ($0.id, $0) })
        for drawer in clusterable {
            parent[drawer.id] = parent[drawer.id] ?? drawer.id
            guard let probe = engrams[drawer.id] else { continue }
            let matches = try await vectorStore.findNearest(
                probe: probe,
                modelID: Self.distillationLaneModelID,
                limit: config.neighborProbeLimit)
            for match in matches where match.itemID != drawer.id {
                if let mate = poolDrawerByID[match.itemID] {
                    switch (drawer.isVague, mate.isVague) {
                    case (false, false), (true, true):
                        if match.distance <= ceiling {
                            parent[mate.id] = parent[mate.id] ?? mate.id
                            union(drawer.id, mate.id)
                        }
                    case (false, true):
                        if nearestVague[drawer.id].map({ match.distance < $0.distance }) ?? true {
                            nearestVague[drawer.id] = (mate.id, match.distance)
                        }
                    case (true, false):
                        if nearestVague[mate.id].map({ match.distance < $0.distance }) ?? true {
                            nearestVague[mate.id] = (drawer.id, match.distance)
                        }
                    }
                } else {
                    // Off-pool matches include constituents' per-item
                    // fingerprints (bit-21 rows keep lane entries) — which of
                    // these are VAGUE resolves after the loop; selection of
                    // the nearest vague neighbor happens then.
                    offPoolMatchIDs.insert(match.itemID)
                    if !drawer.isVague {
                        offPoolMatches[drawer.id, default: []]
                            .append((match.itemID, match.distance))
                    }
                }
            }
        }
        // Resolve off-pool matches once; fold-in targets must be ACTIVE vague
        // items (a superseded vague v1's lingering lane entry must never
        // attract new fold-ins). Pool-resident vague items are added directly.
        let offPool = try await estate.getDrawers(ids: Array(offPoolMatchIDs))
        var activeVagueByID = Dictionary(uniqueKeysWithValues: offPool
            .filter { $0.isVague && $0.state != .superseded }
            .map { ($0.id, $0) })
        for drawer in clusterable where drawer.isVague && drawer.state != .superseded {
            activeVagueByID[drawer.id] = drawer
        }
        // Nearest VAGUE off-pool neighbor per drawer (in-pool vague neighbors
        // were selected inline above; keep whichever is nearer).
        for (drawerID, matches) in offPoolMatches {
            for match in matches where activeVagueByID[match.id] != nil {
                if nearestVague[drawerID].map({ match.distance < $0.distance }) ?? true {
                    nearestVague[drawerID] = (match.id, match.distance)
                }
            }
        }
        var components: [String: [Drawer]] = [:]
        for drawer in clusterable {
            components[find(drawer.id), default: []].append(drawer)
        }

        // ── §5.1: fold-ins first — items whose nearest vague neighbor is
        // within the ceiling join that vague item's enlarged set rather than
        // seeding a new cluster. Rejections (nearest vague beyond ceiling)
        // count toward D10 drift.
        var foldGroups: [String: [Drawer]] = [:]
        var foldInRejections = 0
        var foldedIDs = Set<String>()
        for drawer in clusterable {
            guard let candidate = nearestVague[drawer.id],
                  let vagueItem = activeVagueByID[candidate.vagueID] else { continue }
            if candidate.distance <= ceiling {
                // A vague-of-vague constituent at the cap cannot fold higher.
                let foldedLevel = drawer.isVague ? drawer.vagueLevel : 0
                guard max(vagueItem.vagueLevel, foldedLevel + 1) <= config.vagueLevelCap
                else { continue }
                foldGroups[vagueItem.id, default: []].append(drawer)
                foldedIDs.insert(drawer.id)
            } else {
                foldInRejections += 1
            }
        }
        var foldIns = 0
        for (vagueID, folded) in foldGroups {
            if let cap = limit, foldIns >= cap { break }
            guard let vagueItem = activeVagueByID[vagueID] else { continue }
            let existingIDs = try await estate.vagueConstituents(of: vagueID)
            let enlargedIDs = existingIDs + folded.map(\.id).filter { !existingIDs.contains($0) }
            guard enlargedIDs.count >= config.minimumClusterSize else { continue }
            let enlargedByID = Dictionary(
                uniqueKeysWithValues: try await estate.getDrawers(ids: enlargedIDs)
                    .map { ($0.id, $0) })
            let enlarged = enlargedIDs.compactMap { enlargedByID[$0] }
                .sorted { ($0.filedAt, $0.id) < ($1.filedAt, $1.id) }
            guard let regen = composeAndDistill(
                constituents: enlarged, config: config, distillFn: distillFn)
            else { continue }
            let level = max(
                vagueItem.vagueLevel,
                1 + (enlarged.map { $0.isVague ? $0.vagueLevel : 0 }.max() ?? 0))
            guard level <= config.vagueLevelCap else { continue }

            // Sensitivity inheritance (§D.1 monotone ceiling): the fold-in
            // drawer carries the MAX adjective and provenance sensitivity over
            // the enlarged constituent set and the prior vague item. A fold-in
            // must never lower the tier — cookbook §2.3 bits 6–11 (adjective)
            // and §2.5 bits 30–35 (provenance at capture).
            let v2MaxAdjSens: AdjectiveSensitivity = enlarged.reduce(vagueItem.adjectiveSensitivity) { best, d in
                d.adjectiveSensitivity.rawValue > best.rawValue ? d.adjectiveSensitivity : best
            }
            let v2MaxProvSens: Sensitivity = enlarged.reduce(vagueItem.sensitivity) { best, d in
                d.sensitivity.rawValue > best.rawValue ? d.sensitivity : best
            }
            let v2AdjBitmap = BitField.writeField(
                Int64(v2MaxAdjSens.rawValue), into: 0, shift: 6, width: 6)
            let v2ProvBitmap = BitField.writeField(
                Int64(v2MaxProvSens.rawValue), into: 0, shift: 30, width: 6)

            let v2 = Drawer(
                id: UUID().uuidString,
                content: regen.rendering,
                parentNodeId: vagueItem.parentNodeId,
                addedBy: "consolidation-daemon",
                filedAt: now,
                embeddingModelID: vagueItem.embeddingModelID,
                provenance: v2ProvBitmap,
                adjectiveBitmap: v2AdjBitmap,
                operationalBitmap: DrawerFeatureFlags.isVague.rawValue
                    | ((Int64(level) & 0b11) << 22),
                lineageID: vagueItem.lineageID,
                // Fold-in v2 is a fresh derived row: same subject rule as the
                // new-cluster path below — never born as debt.
                subject: Self.vagueSubject(from: regen.rendering),
                subjectPipelineVersion: Self.consolidationSubjectPipeline,
                subjectAt: now
            )
            try await estate.foldInTransactionally(
                vagueV2: v2,
                priorVagueID: vagueID,
                enlargedConstituentIDs: enlargedIDs,
                addedBy: "consolidation-daemon",
                now: now)
            if regen.fingerprint != .zero {
                try await vectorStore.addVector(
                    itemID: v2.id,
                    engram: regen.fingerprint,
                    modelID: Self.distillationLaneModelID,
                    modelVersion: "1",
                    filedAt: now)
            }
            foldIns += 1
        }

        // ── §3.2: the consolidation act, one NEW cluster at a time ─────
        var produced = 0
        let byID = Dictionary(uniqueKeysWithValues: clusterable.map { ($0.id, $0) })
        clusters: for member in components.values {
            if let cap = limit, produced + foldIns >= cap { break clusters }

            // Capture order (D6: concatenate in capture order); members that
            // already folded into an existing vague item this sweep are out.
            let constituents = member
                .filter { !foldedIDs.contains($0.id) }
                .compactMap { byID[$0.id] }
                .sorted { ($0.filedAt, $0.id) < ($1.filedAt, $1.id) }
            guard constituents.count >= config.minimumClusterSize else { continue clusters }

            // D8: the product's level is 1 + max(constituent levels); a
            // cluster whose product would exceed the cap is rejected whole
            // (its members remain untouched and re-enter the pool).
            let productLevel = 1 + (constituents.map { $0.isVague ? $0.vagueLevel : 0 }.max() ?? 0)
            guard productLevel <= config.vagueLevelCap else { continue clusters }

            // §3.2 step 1 — compose input (shared D6/D7 helper).
            guard let regen = composeAndDistill(
                constituents: constituents, config: config, distillFn: distillFn)
            else { continue clusters }
            let rendering = regen.rendering
            let fingerprint = regen.fingerprint

            // §3.2 step 2 — construct the vague drawer: fresh identity and
            // FRESH lineageID (never a constituent's — §3.3/§6.3), placed in
            // the earliest constituent's room, carrying isVague + vagueLevel
            // (bits 20 + 22–23; representedByVague is never set on a vague
            // item at capture).
            //
            // Sensitivity inheritance (§D.1): the vague drawer carries the MAX
            // adjective and provenance sensitivity over all constituents —
            // cookbook §2.3 bits 6–11 (adjective) and §2.5 bits 30–35
            // (provenance at capture). Source tier flows to derived artifact.
            let vagueBitmap: Int64 =
                DrawerFeatureFlags.isVague.rawValue
                | ((Int64(productLevel) & 0b11) << 22)
            let newMaxAdjSens: AdjectiveSensitivity = constituents.reduce(.normal) { best, d in
                d.adjectiveSensitivity.rawValue > best.rawValue ? d.adjectiveSensitivity : best
            }
            let newMaxProvSens: Sensitivity = constituents.reduce(.normal) { best, d in
                d.sensitivity.rawValue > best.rawValue ? d.sensitivity : best
            }
            let newVagueAdjBitmap = BitField.writeField(
                Int64(newMaxAdjSens.rawValue), into: 0, shift: 6, width: 6)
            let newVagueProvBitmap = BitField.writeField(
                Int64(newMaxProvSens.rawValue), into: 0, shift: 30, width: 6)
            let vague = Drawer(
                id: UUID().uuidString,
                content: rendering,
                parentNodeId: constituents[0].parentNodeId,
                addedBy: "consolidation-daemon",
                filedAt: now,
                embeddingModelID: constituents[0].embeddingModelID,
                provenance: newVagueProvBitmap,
                adjectiveBitmap: newVagueAdjBitmap,
                operationalBitmap: vagueBitmap,
                // Derived writers emit their own subject at creation (PR-02):
                // a vague item must never be born as subject debt, because
                // the debt counter would then grow with every consolidation
                // sweep. The daemon has no AI at hand, so the subject is the
                // deterministic best available — the rendering's first line,
                // character-capped to the contract (a truncation cap, not the
                // AI register's compress-don't-truncate rule; miniLLM
                // regeneration upgrades these rows later via the
                // pipeline-version lever). Distinct pipeline tag so those
                // regeneration sweeps can target exactly this producer.
                subject: Self.vagueSubject(from: rendering),
                subjectPipelineVersion: Self.consolidationSubjectPipeline,
                subjectAt: now
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
        return ConsolidationSweepReport(
            newVagueItems: produced,
            foldIns: foldIns,
            foldInRejections: foldInRejections,
            repairedItems: repairedItems)
    }

    /// Pipeline-version tag for subjects the consolidation daemon writes on
    /// vague items. Deliberately NOT `ai-v1`: these subjects are
    /// deterministic first-line caps, not AI-authored assertions, and the
    /// distinct tag lets a future miniLLM regeneration sweep target exactly
    /// this producer via `countMissingSubject(pipelineVersion:)`.
    /// Twin: Rust `CONSOLIDATION_SUBJECT_PIPELINE`.
    static let consolidationSubjectPipeline = "consolidation-v1"

    /// Deterministic subject for a vague item: the rendering's first
    /// non-empty line, character-capped to the store contract. Never
    /// returns empty for the renderings `composeAndDistill` produces
    /// (it rejects all-blank clusters). Twin: Rust `vague_subject`.
    static func vagueSubject(from rendering: String) -> String {
        let firstLine = rendering
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? rendering
        return String(firstLine.prefix(DrawerStore.subjectLengthContract))
    }

    /// D6/D7 composition + distillation shared by the consolidation act and
    /// fold-in regeneration. Returns nil only for pathological all-empty
    /// input (a cluster of blank rows).
    private func composeAndDistill(
        constituents: [Drawer],
        config: ConsolidationConfig,
        distillFn: @Sendable (DistillationInput) -> DistillationOutput
    ) -> (rendering: String, fingerprint: Fingerprint256)? {
        // Preferred path (D6): combine the original contents and distill the
        // combination. Fallback (D7): oversized clusters merge the EXISTING
        // distillates (cheap — no matrix over a huge combined text); rows not
        // yet distilled contribute their content unchanged.
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
        guard !rendering.isEmpty else { return nil }
        return (rendering, fingerprint)
    }

    /// §5.2 defrag — compositionally cascade + re-consolidate; no third
    /// mechanism exists. Expunges the drifted vague item (the Part-3
    /// deletion cascade reverts every constituent to current-searchable in
    /// the same transaction), then re-runs one bounded sweep over the
    /// reverted pool. Rare-cadence policy (D10 trigger evaluation, D11
    /// scheduling) belongs to the maintenance caller; the verb itself is
    /// unconditional.
    @discardableResult
    public func defragVagueItem(
        handle: EstateHandle,
        vagueDrawerID: String,
        distillFn: @escaping @Sendable (DistillationInput) -> DistillationOutput,
        now: Date,
        config: ConsolidationConfig = ConsolidationConfig()
    ) async throws -> ConsolidationSweepReport {
        try await expunge(handle, ExpungeFrame(
            rowID: vagueDrawerID,
            reason: "wave-2 defrag: cluster drift exceeded the D10 threshold",
            confirmation: true), now: now)
        return try await consolidationSweepReport(
            handle: handle, distillFn: distillFn, now: now, config: config)
    }
}
