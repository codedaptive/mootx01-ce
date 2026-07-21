// ContradictionHunt.swift
//
// The contradiction hunter's core pass — dreaming's content-driven
// phase and the engine behind the on-demand `moot_hunt_contradictions`
// sweep. One implementation, three surfaces: the standing
// `ContradictionScoutSignal` (resident cadence), the DreamingDaemon
// THETA phase, and the ARIA tools (`moot_dream` sweep +
// `moot_hunt_contradictions`).
//
// Shape: sample up to `probeLimit` of the newest vector-indexed item
// IDs, generate candidate pairs for each probe, canonicalize +
// deduplicate them, then run the SubstrateML `ConflictCue` screen over
// the pair's hydrated content. Candidate generation runs in two lanes:
//
//   Lane 1 (drawer-keyed) — binary Hamming kNN over the caller's
//     `modelID`, for bespoke/test-planted drawer vectors.
//   Lane 2 (corpus) — the lane a production estate populates. Candidates
//     come from the corpus's persistent BM25 inverted index
//     (`bm25TopKBySource`), NOT vectors: a contradiction is two
//     statements about the same thing that disagree, "about the same
//     thing" is what BM25 answers cheaply, and it is the same shared-term
//     similarity `ConflictCue` screens on. Vector candidate generation
//     was tried and abandoned here — the binary SimHash space is
//     degenerate at estate scale (a 109k-chunk estate buried a true twin
//     at rank #399) and a whole-partition float scan is ~3 s/probe.
//
// The screen over each surviving candidate:
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
// Sensitivity: the hunt applies the same default ceiling as recall
// (`.sensitivityAtMost(.elevated)`) before content screening or
// snippet generation. Proposed tunnels are then additionally stamped
// by `DrawerStore.addTunnel` with the MAX endpoint sensitivity (#57).
//
// Cost: O(probeLimit) BM25 queries (sub-linear WAND/BMW over posting
// lists, each capped to a bounded query length) + one batched body
// hydration for the surviving candidate pairs — never O(N²) over content.

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

    /// BM25 candidate count per probe on the corpus lane.
    ///
    /// Candidate generation is LEXICAL, not vector: a contradiction is two
    /// statements ABOUT THE SAME THING that disagree, and "about the same
    /// thing" is what the persistent BM25 inverted index already answers
    /// cheaply (sub-linear WAND/BMW over posting lists — no full-table vector
    /// scan). This is also the similarity ConflictCue itself keys on (shingle
    /// overlap with negation/value divergence), so BM25 and the screen agree
    /// on what a candidate is: the "30 seconds" / "90 seconds" twins share
    /// every token but the number, so BM25 co-locates them at the very top.
    ///
    /// The prior vector lanes were unusable here — the binary SimHash space is
    /// degenerate on real estates (109k estate: 748 chunks within Hamming ≤ 2,
    /// true twin buried at rank #399), and a whole-partition float scan is
    /// ~3 s per probe (the on-demand default of 500 probes was ~25 min). BM25
    /// returns SOURCE (drawer) IDs directly, so no chunk→drawer remap either.
    ///
    /// A small K suffices because BM25 ranks the shared-term twin near the top;
    /// the ConflictCue screen downstream is the precision gate, so this only
    /// bounds the candidate set.
    static let huntBM25CandidateK = 20

    /// Character cap on the BM25 query built from a probe drawer's content.
    ///
    /// `bm25TopKBySource` tokenises the whole query string, and WAND cost grows
    /// with the term count, so querying a large drawer's ENTIRE body makes the
    /// per-probe cost scale with drawer size (measured: per-probe time drifted
    /// up as a sweep reached older, larger drawers). Candidate generation only
    /// needs the probe's TOPIC, and the leading content carries it — a
    /// contradiction is a local disagreement, and the full bodies are compared
    /// by ConflictCue downstream regardless. Capping the query to a leading
    /// slice bounds per-probe cost independent of drawer size; short memories
    /// (the common case) are unaffected because they fall under the cap.
    static let huntBM25QueryCharLimit = 240

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

        // Lane 2 — the corpus lane, the ONLY lane a production estate
        // populates: the encode drain writes chunk-keyed rows under the corpus
        // provider's modelID, so lane 1's drawer-keyed `getVector` finds
        // nothing there. Candidate generation here is LEXICAL, via the corpus's
        // persistent BM25 inverted index — NOT vectors. A contradiction is two
        // statements about the same thing that disagree; "about the same thing"
        // is exactly what BM25 answers cheaply (sub-linear WAND/BMW over
        // posting lists), and it is the same shared-term similarity ConflictCue
        // screens on, so generator and screen agree on what a candidate is. The
        // vector lanes were unusable at estate scale — the binary SimHash space
        // is degenerate (109k estate: 748 chunks within Hamming ≤ 2, true twin
        // at rank #399) and a whole-partition float scan is ~3 s/probe. BM25
        // returns SOURCE (drawer) IDs directly, so no chunk→drawer remap.
        // `seenPairs` keys on drawer IDs, so both lanes dedupe together.
        if let corpus = corpusKits[handle] {
            // Shared-content 1.1: vector item IDs ARE Drawer IDs — the probe
            // IDs are the probe drawers directly, no chunk→drawer remap.
            let probeDrawerIDs = Array(Set(probeIDs))
            // Hydrate probe drawers for their content — the BM25 query text.
            var probeDrawers: [Drawer] = []
            if !probeDrawerIDs.isEmpty {
                probeDrawers = try await estate.hydrateBodies(ids: probeDrawerIDs)
            }
            for probeDrawer in probeDrawers where !probeDrawer.content.isEmpty {
                let query = String(probeDrawer.content.prefix(Self.huntBM25QueryCharLimit))
                guard let hits = try? await corpus.bm25TopKBySource(
                    query: query, limit: Self.huntBM25CandidateK)
                else { continue }
                for hit in hits where hit.sourceID != probeDrawer.id {
                    let key = Self.pairKey(probeDrawer.id, hit.sourceID)
                    guard seenPairs.insert(key).inserted else { continue }
                    candidatePairs.append((min(probeDrawer.id, hit.sourceID),
                                           max(probeDrawer.id, hit.sourceID)))
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
            // Match BitmapEvaluator's default recall posture: callers
            // without an explicit sensitivity grant may only mine the Normal
            // tier (normal + elevated). Restricted/secret rows must not be
            // screened, proposed, or echoed as borderline snippets.
            guard a.adjectiveSensitivity.rawValue <= AdjectiveSensitivity.elevated.rawValue,
                  b.adjectiveSensitivity.rawValue <= AdjectiveSensitivity.elevated.rawValue
            else { continue }
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
