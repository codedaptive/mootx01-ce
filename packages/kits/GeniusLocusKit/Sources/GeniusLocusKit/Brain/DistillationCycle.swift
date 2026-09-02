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
// The stored text is produced by ContextDistillLib (CDL-02): the intent-span
// converter selects exact source spans around operative intent, appends the
// projected enrichment trailer, and is byte-identical across the Swift and
// Rust ports by conformance to the frozen oracle vectors. Its input is the
// item's content plus the deterministic categorizer trailer computed from
// that content (EnrichmentStage). No pronoun rewriting is applied: the
// representation is exact source text by contract.
//
// The structural fingerprint lane is independent of the text (§8): items
// with ≥3 sentences take the intra-item M×|V| reduction through the
// injected distillFn and store its feature fingerprint; shorter items use
// the queryFingerprint construction over the content. Zero extracted
// features ⇒ no lane entry, but the representation is still stored — the
// columns and the lane are independently valid (§7.5).
//
// Determinism: the stored representation is a function of (content,
// converter ID) only; the fingerprint is a function of (content,
// `DistillationPipeline.defaultExtractor`) only. `distillFn` remains
// injectable for tests; production callers pass
// `GeniusLocusKit.defaultDistillFn`.
//
// NeuronKit is NOT a GeniusLocusKit dependency; DistillationInput and
// DistillationOutput come from SubstrateML, which IS one.

import ContextDistillLib
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

    /// The production fingerprint pipeline: the intra-item reduction with
    /// the contract-pinned default extractor. Its feature fingerprint feeds
    /// the `distillation-features-v1` lane; the stored text comes from
    /// ContextDistillLib. Injectable so tests can stub the fingerprint.
    static var defaultDistillFn: @Sendable (SubstrateML.DistillationInput) -> DistillationOutput {
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
    ///   - content: the item's text content.
    ///   - distillFn: injected fingerprint pipeline; production callers
    ///     pass `GeniusLocusKit.defaultDistillFn`.
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
        distillFn: @escaping @Sendable (SubstrateML.DistillationInput) -> DistillationOutput,
        now: Date
    ) async throws -> Bool {
        guard storages[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        guard !content.isEmpty else { return false }
        let estate = try estate(for: handle)

        // Structural fingerprint (§8). Same segmenter the corpus Chunker
        // uses, so the reduction units are consistent with the dense index.
        let sentences = EideticLib.sentences(content).map(String.init)
        let fingerprint: Fingerprint256
        if sentences.count >= 3 {
            // Matrix path (§7.4): intra-item M×|V| reduction; only its
            // OR-reduced structural fingerprint is consumed here.
            // memoryTimestamps stays nil ON PURPOSE (W2.5 S6): one item's
            // sentences share the item's single timestamp — equal ages make
            // TypedDecayWeighting's weights cancel in the normalizer
            // (wdf ≡ df), so threading the timestamp is a mathematical no-op.
            // The decay branch is live in the CROSS-ITEM consolidation path
            // (ConsolidationCycle), which also consumes the rendered text.
            fingerprint = distillFn(SubstrateML.DistillationInput(
                memoryContents: sentences,
                memoryTimestamps: nil,
                clusterID: drawerID,
                sourceIDs: [drawerID])).featureFingerprint
        } else {
            // Short-item path (§7.5): fingerprint via the queryFingerprint
            // construction over the content.
            fingerprint = DistillationPipeline.queryFingerprint(
                query: content,
                extractFeatures: DistillationPipeline.defaultExtractor)
        }

        // Stored text (CDL-02): see `distilledRepresentation(forContent:)`.
        let distilled = Self.distilledRepresentation(forContent: content)

        // Write 1 of 2 (§7.2): the four representation columns, atomically.
        let updated = try await estate.setDistilledRepresentation(
            drawerId: drawerID,
            distilled: distilled,
            pipelineVersion: Self.distillationConverterID,
            tokenCount: Self.distilledTokenCount(distilled),
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
        distillFn: @escaping @Sendable (SubstrateML.DistillationInput) -> DistillationOutput,
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
        // encode which converter produced them. Read the stale-room
        // set once through a metadata-only projection so a fully represented
        // room is skipped only when every representation is also current.
        // Current rooms retain the fast path: no drawer content is hydrated.
        let staleRooms = try await estate.roomsWithStaleDistilledRepresentations(
            pipelineVersion: Self.distillationConverterID)
        let staleRoomKeys = Set(staleRooms.map { "\($0.wing)\u{0}\($0.room)" })
        let skipBit = DrawerFeatureFlags.hasCurrentRepresentation.rawValue

        rooms: for entry in rooms {
            // Skip this room when the AND proves every active drawer already
            // has bit 19 set AND the metadata projection found no stale
            // converter ID. The AND is an under-approximation so if it
            // shows 1 for bit 19 the true AND is also 1; the ID check
            // closes the separate stale-converter eligibility path.
            let roomKey = "\(entry.wing)\u{0}\(entry.room)"
            if (entry.fingerprint.operationalAnd & skipBit) == skipBit,
               !staleRoomKeys.contains(roomKey) {
                continue
            }

            // Deterministic conversation order: (eventTime, filedAt, id).
            // A capped sweep must reach the same rows on both ports, so the
            // order is fixed rather than storage order.
            let drawers = try await estate.drawersIn(wing: entry.wing, room: entry.room)
                .sorted { a, b in
                    if a.eventTime != b.eventTime { return a.eventTime < b.eventTime }
                    if a.filedAt != b.filedAt { return a.filedAt < b.filedAt }
                    return a.id < b.id
                }
            for drawer in drawers {
                if let cap = limit, produced >= cap { break rooms }
                guard !drawer.content.isEmpty else { continue }
                // Eligibility (§7.1): bit 19 (has_current_representation)
                // clear means the row has no representation yet; OR the
                // representation was produced under a different converter
                // (cookbook §2.4.1 / SPEC §7.1). The bitmap test avoids
                // materializing the text column for the eligibility read;
                // the ID comparison is what makes a converter bump
                // regenerate every legacy row.
                guard !drawer.hasCurrentRepresentation
                    || drawer.distilledPipelineVersion != Self.distillationConverterID
                else { continue }
                if try await distillItem(
                    handle: handle, drawerID: drawer.id, content: drawer.content,
                    distillFn: distillFn, now: now) {
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
                    _ = try? await corpusKits[handle]?.recomposeDenseVector(
                        id: drawer.id, now: now)
                }
            }
        }
        return produced
    }

    /// Force-redistill ALL active non-empty items in the estate — used by the
    /// `moot_redistill` verb (CDL-02). Unlike `distillItemsSweep`, this sweep:
    ///
    ///  • Ignores `hasCurrentRepresentation` and the stored converter ID —
    ///    every active non-empty drawer is re-distilled unconditionally.
    ///  • Skips the room-level AND optimisation — no room is short-circuited.
    ///  • Does NOT call `recomposeDenseVector` per item: the caller is responsible
    ///    for running `reindexCorpus(handle:now:)` with `laneScope .all` after this
    ///    sweep returns, which re-embeds all dense vectors and rebuilds the BM25
    ///    index from the newly-written distillates (including trailer tokens admitted
    ///    via `TrailerLexicalSupplement`). Per-item recompose would be redundant and
    ///    would race the full reindex.
    ///
    /// Drawers within each room are swept in (eventTime, filedAt, id) order,
    /// exactly as in `distillItemsSweep`, so a capped pass is deterministic.
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - distillFn: injected distillation function; production callers pass
    ///     `GeniusLocusKit.defaultDistillFn`.
    ///   - now: deterministic clock, stamped into `distilled_at`.
    ///   - limit: optional cap on items redistilled this sweep (nil = all items).
    /// - Returns: count of drawer rows whose representation columns were
    ///   (re)populated this sweep.
    func redistillItemsSweep(
        handle: EstateHandle,
        distillFn: @escaping @Sendable (SubstrateML.DistillationInput) -> DistillationOutput,
        now: Date,
        limit: Int? = nil
    ) async throws -> Int {
        let estate = try estate(for: handle)
        var produced = 0

        // Enumerate all rooms without the AND-based skip: this is a force sweep,
        // so every room is scanned regardless of its operationalAND fingerprint.
        let rooms = try await estate.roomLevelFingerprints()

        rooms: for entry in rooms {
            // Deterministic conversation order: (eventTime, filedAt, id).
            // A capped sweep must reach the same rows on both ports, so the
            // order is fixed rather than storage order.
            let drawers = try await estate.drawersIn(wing: entry.wing, room: entry.room)
                .sorted { a, b in
                    if a.eventTime != b.eventTime { return a.eventTime < b.eventTime }
                    if a.filedAt != b.filedAt { return a.filedAt < b.filedAt }
                    return a.id < b.id
                }
            for drawer in drawers {
                if let cap = limit, produced >= cap { break rooms }
                // Skip only empty content — tombstoned rows are excluded by
                // drawersIn(wing:room:) at the storage tier. No eligibility
                // gate: force-distill every active non-empty drawer regardless
                // of hasCurrentRepresentation or the stored converter ID.
                if try await distillItem(
                    handle: handle, drawerID: drawer.id, content: drawer.content,
                    distillFn: distillFn, now: now) {
                    produced += 1
                    // Dense vectors are NOT recomposed per-item here: the caller
                    // (Redistill recipe) calls reindexCorpus(handle:now:) with
                    // laneScope .all immediately after this sweep, which re-embeds
                    // all dense vectors from the updated distillates and rebuilds
                    // the BM25 posting lists to admit trailer tokens.
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
