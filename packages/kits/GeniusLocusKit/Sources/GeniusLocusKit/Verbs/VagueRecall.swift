// VagueRecall.swift
//
// Wave-2 §4.4: the two-hop vague-recall verb — "ponder what the estate
// vaguely recalls." Mirrors the existing search→recall_precise escalation
// pattern: callers escalate here when current-tier hits are thin.
//
//   Hop 1 — the vague tier's OWN lane: the query is fingerprinted with the
//   same construction stored vague items use (queryFingerprint over the
//   default extractor — "p1" pins one extractor, so probe and stored
//   fingerprints are structurally comparable) and probed against the
//   distillation-features-v1 Hamming lane; only `isVague` rows count as
//   hits. Vague content never blends into the base episodic index's
//   ranking lanes (§3.3/§6.1) — this lane-probe IS its search surface.
//
//   Hop 2 — bounded constituent hydration: each vague hit hydrates its
//   constituents through `_consolidated_from` tunnels — at most K per hit
//   and M total (D12) — into a second-pass answer set. Hydration is direct
//   by-ID fetch (tier filters do not apply to explicit hydration; the
//   evaluator's exclusion is a DEFAULT-search effect only). For a
//   vague-of-vague hit, hop 2 returns its direct constituents (which are
//   vague items); it does not auto-recurse past the D12 bounds.

import Foundation
import LocusKit
import SubstrateML

/// Result of the two-hop vague recall (§4.4).
public struct VagueRecallResult: Sendable {
    /// Hop-1 hits: vague items in lane-proximity order (distance ASC).
    public let vagueHits: [Drawer]
    /// Hop-2 answer set: hydrated constituents, hit-order grouped, bounded
    /// by K per hit and M total (D12).
    public let constituents: [Drawer]
}

extension GeniusLocusKit {

    /// Two-hop vague recall (§4.4). The verb itself is unconditional —
    /// trigger policy (WHEN to escalate here: thin hits, low
    /// discrimination) is a recipe/caller concern, out of verb scope.
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - query: free-text query; fingerprinted for the hop-1 lane probe.
    ///   - hitLimit: max vague items returned by hop 1.
    ///   - constituentsPerHit: D12 K — max constituents hydrated per hit.
    ///   - totalConstituents: D12 M — max constituents hydrated overall.
    public func vagueRecall(
        _ handle: EstateHandle,
        query: String,
        hitLimit: Int = 8,
        constituentsPerHit: Int = 8,   // D12 K placeholder (ratified)
        totalConstituents: Int = 32    // D12 M placeholder (ratified)
    ) async throws -> VagueRecallResult {
        let estate = try estate(for: handle)
        guard let vectorStore = vectorStores[handle] else {
            return VagueRecallResult(vagueHits: [], constituents: [])
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, hitLimit > 0 else {
            return VagueRecallResult(vagueHits: [], constituents: [])
        }

        // Hop 1: probe the lane. Over-fetch beyond hitLimit because the lane
        // holds BOTH per-item distillation fingerprints and vague items'
        // fingerprints — non-vague rows are filtered out after hydration of
        // the match IDs (cheap: IDs only, then one batch drawer fetch).
        let probe = DistillationPipeline.queryFingerprint(
            query: trimmed,
            extractFeatures: DistillationPipeline.defaultExtractor)
        guard probe != .zero else {
            return VagueRecallResult(vagueHits: [], constituents: [])
        }
        let matches = try await vectorStore.findNearest(
            probe: probe,
            modelID: Self.distillationLaneModelID,
            limit: max(hitLimit * 4, hitLimit))
        let matchedIDs = matches.map(\.itemID)
        guard !matchedIDs.isEmpty else {
            return VagueRecallResult(vagueHits: [], constituents: [])
        }
        let byID = Dictionary(
            uniqueKeysWithValues: try await estate.getDrawers(ids: matchedIDs)
                .map { ($0.id, $0) })
        // Preserve lane order (distance ASC per the oracle contract).
        let vagueHits = matchedIDs
            .compactMap { byID[$0] }
            .filter(\.isVague)
            .prefix(hitLimit)

        // Hop 2: bounded hydration through _consolidated_from tunnels.
        var constituentIDs: [String] = []
        var seen = Set<String>()
        hydration: for hit in vagueHits {
            let ids = try await estate.vagueConstituents(of: hit.id)
            for id in ids.prefix(constituentsPerHit) {
                guard constituentIDs.count < totalConstituents else { break hydration }
                if seen.insert(id).inserted { constituentIDs.append(id) }
            }
        }
        let constituentByID = Dictionary(
            uniqueKeysWithValues: try await estate.getDrawers(ids: constituentIDs)
                .map { ($0.id, $0) })
        let constituents = constituentIDs.compactMap { constituentByID[$0] }

        return VagueRecallResult(
            vagueHits: Array(vagueHits),
            constituents: constituents)
    }
}
