// DistillationCycle.swift
//
// Per-item distillation for GeniusLocusKit — SPEC_DISTILLATION_STORAGE
// §7 (generation paths) and §8 (fingerprint lane).
//
// A distilled representation is a VIEW of one item: four nullable columns
// on the SOURCE drawer row (§4) plus one `distillation-features-v1` lane
// entry keyed by the SOURCE drawer id (§8). One distillation performs
// exactly those two writes (§7.2): it captures no drawer, writes no
// tunnel, and touches no lifecycle or lineage field of any row — the
// factoid-drawer model (room "_distilled", addedBy
// "distillation-daemon", `_distilled_from` tunnels) is retired on 1.1.x
// (§11).
//
// Two rendering paths, every item covered once swept (§7.4/§7.5):
//   • Matrix path (≥3 sentences): the intra-item M×|V| reduction via the
//     injected distillFn; Stage 5 renders token-economical prose
//     (core-first ordering, §7.6 compaction per unit).
//   • Short-item path (<3 sentences): the §7.6 token-compaction
//     transform applied to the content directly; the fingerprint is the
//     queryFingerprint construction over the content. Zero extracted
//     features ⇒ no lane entry, but the rendering is still stored — the
//     columns and the lane are independently valid.
//
// Determinism ("p1", §5.3 rule 6): the stored rendering is a function of
// (content, pipeline version) only. The p1 contract pins
// `DistillationPipeline.defaultExtractor` — the extractor present and
// bit-identical on BOTH legs — for every distillation write path, so the
// Swift and Rust sweeps produce byte-identical renderings and
// self-consistent lane fingerprints (queryFingerprint already used the
// default extractor at recall time). `distillFn` remains injectable for
// tests; production callers pass `GeniusLocusKit.defaultDistillFn`.
//
// NeuronKit is NOT a GeniusLocusKit dependency; DistillationInput and
// DistillationOutput come from SubstrateML, which IS one.

import EideticLib
import Foundation
import LocusKit
import OSLog
import SubstrateML
import SubstrateTypes
import VectorKit

// MARK: - Per-item distillation (intra-item reduction)

public extension GeniusLocusKit {

    /// The fixed VectorKit lane for structural fingerprints (§8). Keyed by
    /// the SOURCE drawer id; the no-inference Hamming NN structure is the
    /// Phase 2 consolidation cluster-detection substrate. No Phase 1
    /// recall route consumes it.
    static var distillationLaneModelID: String { "distillation-features-v1" }

    /// The p1 production distillation function: the intra-item pipeline
    /// with the contract-pinned default extractor. This is what the
    /// drain-stage and sweep run unless a test injects a stub.
    static var defaultDistillFn: @Sendable (DistillationInput) -> DistillationOutput {
        {
            DistillationPipeline.run(
                input: $0,
                extractFeatures: DistillationPipeline.defaultExtractor,
                intraItem: true)
        }
    }

    /// Distill a SINGLE item into its on-row representation (§7.2).
    ///
    /// Writes the four representation columns on the source drawer row in
    /// one atomic UPDATE, and replaces the item's
    /// `distillation-features-v1` lane entry when a non-zero structural
    /// fingerprint was computed. VectorStore absence is non-fatal: the
    /// columns are still written (the lane is simply dark, matching the
    /// estate's semantic-tier wiring).
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - drawerID: the source item's drawer id.
    ///   - content: the item's text content (sentence-segmented here).
    ///   - distillFn: injected distillation function; production callers
    ///     pass `GeniusLocusKit.defaultDistillFn` (the p1 contract).
    ///   - now: deterministic clock, stamped into `distilled_at` and the
    ///     lane entry. Passed in — never read here.
    /// - Returns: true when the representation columns were written
    ///   (false only when the drawer row no longer exists or the content
    ///   is empty).
    @discardableResult
    func distillItem(
        handle: EstateHandle,
        drawerID: String,
        content: String,
        distillFn: @escaping @Sendable (DistillationInput) -> DistillationOutput,
        now: Date,
        corefPool: [CorefStage.Antecedent] = []
    ) async throws -> Bool {
        guard storages[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        guard !content.isEmpty else { return false }
        let estate = try estate(for: handle)

        // Segment the item's own content into sentences — the per-item
        // reduction units. Same segmenter the corpus Chunker uses, so the
        // units are consistent with the dense index.
        let sentences = EideticLib.sentences(content).map(String.init)

        let rendering: String
        let fingerprint: Fingerprint256
        if sentences.count >= 3 {
            // Matrix path (§7.4): intra-item M×|V| reduction. Stage 5
            // renders core-first compacted prose and computes the
            // OR-reduced structural fingerprint.
            // memoryTimestamps stays nil ON PURPOSE (W2.5 S6): the
            // "memories" here are one item's sentences, which all share the
            // item's single timestamp — equal ages make TypedDecayWeighting's
            // weights cancel in the normalizer (wdf ≡ df), so threading the
            // timestamp is a mathematical no-op. The decay branch is live in
            // the CROSS-ITEM consolidation path (ConsolidationCycle).
            let output = distillFn(DistillationInput(
                memoryContents: sentences,
                memoryTimestamps: nil,
                clusterID: drawerID,
                sourceIDs: [drawerID]))
            if output.distilledText.isEmpty {
                // Degenerate matrix (no features extracted at all): fall
                // back to the short-item transform so §13.1 population
                // holds for every non-empty item.
                rendering = Self.compactionRendering(of: content)
            } else {
                rendering = output.distilledText
            }
            fingerprint = output.featureFingerprint
        } else {
            // Short-item path (§7.5): token-compaction fallback — rules
            // 2–5 applied directly, rule 1 trivially preserved (no
            // proposition is dropped). Fingerprint via the
            // queryFingerprint construction over the content.
            rendering = Self.compactionRendering(of: content)
            fingerprint = DistillationPipeline.queryFingerprint(
                query: content,
                extractFeatures: DistillationPipeline.defaultExtractor)
        }

        // Pipeline p2.3 stage A (W2.2, accepted design A1): resolve
        // third-person pronouns in the RENDERING against the session
        // antecedent pool the sweep hands in (empty for single-item
        // callers → no-op). Runs BEFORE the trailer weld so trailer facts
        // stay verbatim-derived and the grammar block is never rewritten.
        let resolved = CorefStage.resolve(rendering: rendering, pool: corefPool)

        // Pipeline p2 (DECISION_DENSE_LANE_ENRICHMENT): weld the categorizer
        // trailer onto the rendering. Facts come from the VERBATIM content
        // (the enrichment source of truth), the trailer rides the distilled
        // lane only, and CorpusKit's trailer lexical supplement admits its
        // tokens to BM25 at index time.
        let enriched = resolved + EnrichmentStage.trailer(forContent: content)

        // Write 1 of 2 (§7.2): the four representation columns, atomically.
        let updated = try await estate.setDistilledRepresentation(
            drawerId: drawerID,
            distilled: enriched,
            pipelineVersion: DistillationPipelineVersion.current,
            tokenCount: TokenCompaction.estimateTokenCount(enriched),
            at: now)
        guard updated == 1 else { return false }

        // Write 2 of 2 (§7.2/§8): the lane entry, keyed by the SOURCE
        // drawer id. addVector upserts on (itemID, modelID), which is the
        // §8 replace-on-regeneration semantic. Zero fingerprint (no
        // extracted features) writes no entry — columns and lane are
        // independently valid (§7.5).
        if fingerprint != .zero, let vectorStore = vectorStores[handle] {
            try await vectorStore.addVector(
                itemID: drawerID,
                engram: fingerprint,
                modelID: Self.distillationLaneModelID,
                modelVersion: "1",
                filedAt: now)
        }
        return true
    }

    /// Per-item distillation sweep (§7.1 "sweep" path — the
    /// `moot_distill` tool): distill every active drawer with non-empty
    /// content whose representation is NULL or was produced under a
    /// different pipeline contract.
    ///
    /// Idempotent by the NULL predicate: a swept row carries
    /// `distilled != nil` at the current pipeline version and is skipped
    /// on re-run. There is no provenance scan — eligibility is read off
    /// the row itself (§11.4).
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - distillFn: injected distillation function; production callers
    ///     pass `GeniusLocusKit.defaultDistillFn`.
    ///   - now: deterministic clock.
    ///   - limit: optional cap on items distilled this sweep (nil = all
    ///     eligible).
    /// - Returns: count of drawer rows whose representation columns were
    ///   populated this sweep.
    func distillItemsSweep(
        handle: EstateHandle,
        distillFn: @escaping @Sendable (DistillationInput) -> DistillationOutput,
        now: Date,
        limit: Int? = nil
    ) async throws -> Int {
        let estate = try estate(for: handle)
        var produced = 0

        // Rooms-first sweep: enumerate room-level fingerprint entries, skip
        // rooms whose operationalAND proves every active drawer already carries
        // bit 19 (hasCurrentRepresentation), and load the remaining rooms via
        // drawersIn(wing:room:).
        //
        // Safety invariant — AND is an under-approximation:
        //   Falsely-ABSENT bit 19 in operationalAND → room scanned unnecessarily
        //   (harmless over-work).  Falsely-PRESENT bit 19 in operationalAND
        //   would skip a room with eligible work (UNSAFE); rebuildAll at estate
        //   open prevents this by recomputing the AND from scratch.
        //   Mid-session, the AND can only worsen in the safe direction (capture
        //   lowers AND; only rebuildAll raises it).
        let rooms = try await estate.roomLevelFingerprints()
        // Bit 19 means the representation columns are populated; it does not
        // encode which pipeline contract produced them. Read the stale-room
        // set once through a metadata-only projection so a fully represented
        // room is skipped only when every representation is also current.
        // Current rooms retain the fast path: no drawer content is hydrated.
        let staleRooms = try await estate.roomsWithStaleDistilledRepresentations(
            pipelineVersion: DistillationPipelineVersion.current)
        let staleRoomKeys = Set(staleRooms.map { "\($0.wing)\u{0}\($0.room)" })
        let skipBit = DrawerFeatureFlags.hasCurrentRepresentation.rawValue

        rooms: for entry in rooms {
            // Skip this room when the AND proves every active drawer already
            // has bit 19 set AND the metadata projection found no stale
            // pipeline version. The AND is an under-approximation so if it
            // shows 1 for bit 19 the true AND is also 1; the version check
            // closes the separate stale-contract eligibility path.
            let roomKey = "\(entry.wing)\u{0}\(entry.room)"
            if (entry.fingerprint.operationalAnd & skipBit) == skipBit,
               !staleRoomKeys.contains(roomKey) {
                continue
            }

            // Session order for the coref window (W2.2 A1): the room's
            // drawers sorted by (eventTime, filedAt, id) — deterministic and
            // conversation-shaped. The antecedent pool for item i is the
            // anchored entities of up to CorefStage.windowItems PRECEDING
            // items whose eventTime lies within CorefStage.windowMinutes.
            let drawers = try await estate.drawersIn(wing: entry.wing, room: entry.room)
                .sorted { a, b in
                    if a.eventTime != b.eventTime { return a.eventTime < b.eventTime }
                    if a.filedAt != b.filedAt { return a.filedAt < b.filedAt }
                    return a.id < b.id
                }
            for (position, drawer) in drawers.enumerated() {
                if let cap = limit, produced >= cap { break rooms }
                guard !drawer.content.isEmpty else { continue }
                // Eligibility (§7.1): bit 19 (has_current_representation)
                // clear means the row has no representation yet; OR the
                // representation was produced under a different pipeline
                // contract (cookbook §2.4.1 / SPEC §7.1). The bitmap test
                // replaces the previous `distilled == nil` column-presence
                // check — both are correct (§4 invariant), but the bit is
                // the authoritative indicator and avoids materializing the
                // text column for the eligibility read.
                guard !drawer.hasCurrentRepresentation
                    || drawer.distilledPipelineVersion != DistillationPipelineVersion.current
                else { continue }
                // Antecedent pool: entities contributed by the session
                // window, oldest first (resolution prefers the pool's ONLY
                // compatible candidate, so order matters only for the
                // deterministic first-seen dedup inside the stage).
                let windowStart = drawer.eventTime.addingTimeInterval(
                    -Double(CorefStage.windowMinutes) * 60)
                // Sensitivity ceiling (codex finding 2026-08-26): a
                // predecessor may contribute antecedents ONLY when its
                // sensitivity is at or below the drawer being distilled —
                // substitution copies the predecessor's entity text into
                // THIS drawer's persisted distillate, and by-id reads gate
                // on the returned drawer's own sensitivity, so an
                // uphill-sourced antecedent would surface Restricted/Secret
                // entity text through a Normal row without a grant.
                let ceiling = drawer.sensitivity.rawValue
                let pool = drawers[..<position]
                    .suffix(CorefStage.windowItems)
                    .filter { $0.eventTime >= windowStart }
                    .filter { $0.sensitivity.rawValue <= ceiling }
                    .flatMap { CorefStage.contributedEntities(from: $0.content) }
                if try await distillItem(
                    handle: handle, drawerID: drawer.id, content: drawer.content,
                    distillFn: distillFn, now: now, corefPool: pool) {
                    produced += 1
                    // Dense-over-distillate (Stream F): recompose the dense float
                    // vector from the newly-written distillate. The idempotence gate
                    // in CorpusContentEngine keys on content digest (not on
                    // denseCompositionText), so a normal index() call would be
                    // silently skipped — force=true is required. recomposeDenseVector
                    // encapsulates this and routes through the CCE actor so counts-
                    // admission serialization is preserved.
                    // Best-effort: non-fatal when the engine is absent (non-corpus
                    // estate) or when the record resolves nil (expunged between
                    // distillation and here).
                    try? await corpusKits[handle]?.recomposeDenseVector(
                        id: drawer.id, now: now)
                }
            }
        }
        return produced
    }
}

// MARK: - Private helpers

extension GeniusLocusKit {

    /// The §7.5 short-item rendering: the §7.6 compaction transform, with
    /// the content itself as the last-resort rendering when compaction
    /// eliminates everything (pathological all-stopword content) — §13.1
    /// requires every non-empty item to carry a representation.
    internal static func compactionRendering(of content: String) -> String {
        let compacted = TokenCompaction.compact(content)
        return compacted.isEmpty ? content : compacted
    }
}
