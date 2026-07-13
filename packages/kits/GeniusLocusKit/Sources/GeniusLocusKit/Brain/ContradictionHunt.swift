// ContradictionHunt.swift
//
// The contradiction hunter's core pass — dreaming's content-driven
// phase and the engine behind the on-demand `moot_hunt_contradictions`
// sweep. One implementation, three surfaces: the standing
// `ContradictionScoutSignal` (resident cadence), the DreamingDaemon
// THETA phase, and the ARIA tools (`moot_dream` sweep +
// `moot_hunt_contradictions`).
//
// Shape (mirrors `VectorSimilaritySignal`'s bounded proximity pass):
// sample up to `probeLimit` vector-indexed drawer IDs, kNN each probe
// through the estate's VectorStore, canonicalize + deduplicate pairs,
// then run the SubstrateML `ConflictCue` screen over the pair's
// hydrated content:
//
//   strong cue  (score ≥ ConflictCue.strongThreshold)  →  capture a
//     `contradicts` tunnel with lifecycle `.proposed`, originClass
//     `.derived` — reviewable via `respondToTunnel` and surfaced by
//     `moot_lens_contradiction` as "proposed (agent-derived)".
//   borderline  (borderlineThreshold ≤ score < strong)  →  returned as
//     candidate pairs for the BYOAI client to adjudicate; never
//     persisted by the hunter itself.
//
// Dedup contract: a pair with ANY existing `contradicts` tunnel — in
// any lifecycle, including `.withdrawn` (a rejected review) and
// tombstoned rows — is never proposed again. Rejection is durable.
//
// Sensitivity: `DrawerStore.addTunnel` stamps the tunnel with the MAX
// of its endpoints' sensitivities (#57, both legs), so a proposed edge
// touching a restricted drawer is gated by the tunnel sensitivity
// ceiling automatically; the hunter adds nothing to disclose.
//
// Cost: O(probeLimit · K) index lookups + one batched body hydration
// for the surviving candidate pairs — never O(N²) over content.

import Foundation
import LocusKit
import VectorKit
import SubstrateML

/// A `contradicts` tunnel the hunter proposed this pass.
public struct ProposedContradiction: Sendable, Equatable {
    public let tunnelID: String
    public let sourceDrawerID: String
    public let targetDrawerID: String
    /// `ConflictCueKind` raw value ("negation_asymmetry", ...).
    public let cueKind: String
    public let score: Float
}

/// A pair the screen found suspicious but below the auto-propose bar —
/// the agent-adjudication feed. Snippets are capped so a tool response
/// carrying many candidates stays bounded.
public struct BorderlineContradiction: Sendable, Equatable {
    public let sourceDrawerID: String
    public let targetDrawerID: String
    public let cueKind: String
    public let score: Float
    public let sourceSnippet: String
    public let targetSnippet: String
}

/// One hunt pass's outcome. `vectorStoreAvailable == false` means the
/// estate has no registered VectorStore (semantic indexing not wired) —
/// the pass is a no-op, reported honestly rather than as a silent zero.
public struct ContradictionHuntReport: Sendable {
    public let vectorStoreAvailable: Bool
    public let probesScanned: Int
    public let pairsScreened: Int
    public let proposed: [ProposedContradiction]
    public let borderline: [BorderlineContradiction]
    /// Pairs skipped because a `contradicts` tunnel already exists
    /// between them (any lifecycle — includes rejected reviews).
    public let deduplicated: Int
}

public extension GeniusLocusKit {

    /// Maximum characters carried per borderline snippet.
    static let huntSnippetLimit = 160

    /// Run one contradiction-hunt pass over `handle`.
    ///
    /// - Parameters:
    ///   - handle: Open estate handle.
    ///   - modelID: Embedding-model partition for the DRAWER-keyed lane;
    ///     must match the model used when those vectors were filed.
    ///     Defaults to the standing-signal registration default. When a
    ///     Corpus is registered for the estate, its chunk-keyed lane is
    ///     ALSO mined under the corpus's own modelID — that is the lane
    ///     the production encode pipeline populates.
    ///   - probeLimit: Maximum vector-indexed item IDs probed this
    ///     pass. The incremental (signal/THETA) callers keep this small;
    ///     the on-demand sweep passes a larger bound.
    ///   - filedAfter: When non-nil, only probes whose drawer was filed
    ///     after this instant are examined — the incremental watermark.
    ///     Neighbours may be any age (a new memory can contradict an old
    ///     one).
    ///   - proximityThreshold: Maximum Hamming distance (0–256) for a
    ///     neighbour to become a candidate pair. Same 64 default as
    ///     `VectorSimilaritySignal` — the cue screen is the precision
    ///     gate, proximity only bounds the candidate set.
    ///   - now: Deterministic clock supplied by the caller.
    func huntContradictions(
        in handle: EstateHandle,
        modelID: String = "minilm-v6",
        probeLimit: Int = 50,
        filedAfter: Date? = nil,
        proximityThreshold: Int = 64,
        now: Date
    ) async throws -> ContradictionHuntReport {
        let estate = try estate(for: handle)
        guard let vectorStore = registeredVectorStore(for: handle) else {
            return ContradictionHuntReport(
                vectorStoreAvailable: false, probesScanned: 0, pairsScreened: 0,
                proposed: [], borderline: [], deduplicated: 0)
        }

        // Probe sample: the NEWEST vector-indexed item IDs (filed_at
        // descending, distinct). Recency-first is what makes a bounded
        // sweep converge: new memories are the ones that need screening
        // against the existing estate, so a probe_limit window always
        // contains the latest captures — an ascending-item_id window was a
        // UUID lottery that new content-addressed chunk IDs almost never
        // entered on a large estate. Neighbours may be ANY age (findNearest
        // searches the whole lane), so new-vs-old conflicts are found from
        // the new side. Two row populations exist: DRAWER-keyed rows
        // (bespoke lanes such as the distillation lane, and test-planted
        // vectors) and CHUNK-keyed rows (the production encode pipeline —
        // EstateLifecycle registers `corpus.sharedVectorStore`, and the
        // drain writes itemID = chunk UUID under the corpus's own modelID).
        // Both lanes are mined below.
        let probeIDs = try await vectorStore.recentItemIDs(limit: probeLimit)
        guard !probeIDs.isEmpty else {
            return ContradictionHuntReport(
                vectorStoreAvailable: true, probesScanned: 0, pairsScreened: 0,
                proposed: [], borderline: [], deduplicated: 0)
        }

        // Durable dedup set: every drawer pair already joined by a
        // contradicts tunnel, any lifecycle, tombstoned included.
        var settledPairs: Set<String> = []
        for tunnel in try await estate.allTunnels() where tunnel.kind == .contradicts {
            if let s = tunnel.sourceDrawerId, let t = tunnel.targetDrawerId {
                settledPairs.insert(Self.pairKey(s, t))
            }
        }

        // kNN candidate mining, canonical-pair deduplicated.
        //
        // Lane 1 — drawer-keyed rows under the caller's `modelID`. Rows
        // whose item is not in this lane fail `getVector` and fall through.
        var candidatePairs: [(a: String, b: String)] = []
        var seenPairs: Set<String> = []
        for probeID in probeIDs {
            guard let probeEngram = try? await vectorStore.getVector(
                itemID: probeID, modelID: modelID) else { continue }
            guard let matches = try? await vectorStore.findNearest(
                probe: probeEngram, modelID: modelID, limit: 5) else { continue }
            for match in matches {
                guard match.itemID != probeID,
                      match.distance <= proximityThreshold else { continue }
                let key = Self.pairKey(probeID, match.itemID)
                guard seenPairs.insert(key).inserted else { continue }
                candidatePairs.append((min(probeID, match.itemID),
                                       max(probeID, match.itemID)))
            }
        }

        // Lane 2 — chunk-keyed corpus rows. On a production estate this is
        // the ONLY populated lane: the encode drain keys every vector row by
        // chunk UUID under the corpus provider's modelID, so lane 1 finds
        // nothing there. Mine the same probe set on the corpus lane and map
        // chunk hits back to their owning drawers (chunk → source_id via the
        // corpus's warm map). Chunk pairs from the SAME drawer collapse;
        // `seenPairs` keys on drawer IDs, so the two lanes dedupe together.
        if let corpus = corpusKits[handle] {
            let corpusModelID = await corpus.modelID
            var chunkMatches: [(a: String, b: String)] = []
            var involvedChunkIDs: Set<UUID> = []
            for probeID in probeIDs {
                guard let probeUUID = UUID(uuidString: probeID),
                      let probeEngram = try? await vectorStore.getVector(
                          itemID: probeID, modelID: corpusModelID) else { continue }
                guard let matches = try? await vectorStore.findNearest(
                    probe: probeEngram, modelID: corpusModelID, limit: 5) else { continue }
                for match in matches {
                    guard match.itemID != probeID,
                          match.distance <= proximityThreshold,
                          let matchUUID = UUID(uuidString: match.itemID) else { continue }
                    involvedChunkIDs.insert(probeUUID)
                    involvedChunkIDs.insert(matchUUID)
                    chunkMatches.append((probeID, match.itemID))
                }
            }
            if !chunkMatches.isEmpty {
                let owners = await corpus.sourceIDs(forChunkIDs: Array(involvedChunkIDs))
                for pair in chunkMatches {
                    guard let ua = UUID(uuidString: pair.a),
                          let ub = UUID(uuidString: pair.b),
                          let sourceA = owners[ua], let sourceB = owners[ub],
                          sourceA != sourceB else { continue }
                    let key = Self.pairKey(sourceA, sourceB)
                    guard seenPairs.insert(key).inserted else { continue }
                    candidatePairs.append((min(sourceA, sourceB),
                                           max(sourceA, sourceB)))
                }
            }
        }

        // Batched late hydration: load every candidate body once.
        let allIDs = Array(Set(candidatePairs.flatMap { [$0.a, $0.b] }))
        var drawersByID: [String: Drawer] = [:]
        if !allIDs.isEmpty {
            for drawer in try await estate.hydrateBodies(ids: allIDs) {
                drawersByID[drawer.id] = drawer
            }
        }

        var probesScanned = 0
        var pairsScreened = 0
        var deduplicated = 0
        var proposed: [ProposedContradiction] = []
        var borderline: [BorderlineContradiction] = []
        probesScanned = probeIDs.count

        for pair in candidatePairs {
            guard let a = drawersByID[pair.a], let b = drawersByID[pair.b],
                  a.tombstonedAt == nil, b.tombstonedAt == nil else { continue }
            // Incremental watermark: at least one side must be new enough.
            if let watermark = filedAfter,
               a.filedAt <= watermark, b.filedAt <= watermark { continue }
            if settledPairs.contains(Self.pairKey(a.id, b.id)) {
                deduplicated += 1
                continue
            }
            pairsScreened += 1

            let cue = ConflictCue.evaluate(a.content, b.content)
            guard cue.kind != .none else { continue }

            if cue.score >= ConflictCue.strongThreshold {
                // Endpoint wings/rooms come from the node tree; a pair
                // whose endpoints cannot be resolved is skipped rather
                // than filed with fabricated coordinates.
                let names = try await estate.resolveNodeNames(
                    parentNodeIds: [a.parentNodeId, b.parentNodeId])
                guard let aNames = names[a.parentNodeId],
                      let bNames = names[b.parentNodeId] else { continue }
                let frame = TunnelCaptureFrame(
                    sourceWing: aNames.wing,
                    sourceRoom: aNames.room,
                    targetWing: bNames.wing,
                    targetRoom: bNames.room,
                    label: "hunter: \(cue.kind.rawValue) score=\(cue.score)",
                    addedBy: "contradiction-hunter",
                    sourceDrawerId: a.id,
                    targetDrawerId: b.id,
                    kind: .contradicts,
                    originClass: .derived,
                    lifecycle: .proposed
                )
                let tunnel = try await estate.capture(frame)
                settledPairs.insert(Self.pairKey(a.id, b.id))
                proposed.append(ProposedContradiction(
                    tunnelID: tunnel.id,
                    sourceDrawerID: a.id,
                    targetDrawerID: b.id,
                    cueKind: cue.kind.rawValue,
                    score: cue.score))
            } else if cue.score >= ConflictCue.borderlineThreshold {
                borderline.append(BorderlineContradiction(
                    sourceDrawerID: a.id,
                    targetDrawerID: b.id,
                    cueKind: cue.kind.rawValue,
                    score: cue.score,
                    sourceSnippet: String(a.content.prefix(Self.huntSnippetLimit)),
                    targetSnippet: String(b.content.prefix(Self.huntSnippetLimit))))
            }
        }

        return ContradictionHuntReport(
            vectorStoreAvailable: true,
            probesScanned: probesScanned,
            pairsScreened: pairsScreened,
            proposed: proposed,
            borderline: borderline,
            deduplicated: deduplicated)
    }

    /// Canonical unordered pair key — lexicographically smaller ID first.
    internal static func pairKey(_ a: String, _ b: String) -> String {
        a < b ? "\(a)||\(b)" : "\(b)||\(a)"
    }
}
