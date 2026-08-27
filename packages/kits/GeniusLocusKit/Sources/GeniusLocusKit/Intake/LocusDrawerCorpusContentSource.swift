// LocusDrawerCorpusContentSource.swift
//
// The GLK-owned LocusKit-backed content source
// (GLK shared-content 1.1, P3).
//
// COMPOSITION RULE: `CorpusContentSource` is declared by CorpusKit; GLK
// owns this adapter; LocusKit never imports CorpusKit. The adapter
// resolves canonical content — LocusKit Drawers — into the content
// boundary the one indexing engine consumes. The canonical public
// identity is `Drawer.id`, verbatim; the engine keys every derived row by
// it, so recall hydrates Drawers directly with no translation join.
//
// REVISION SEMANTICS: a Drawer's `content` is immutable for its ID —
// revisions of known content are NEW drawers linked by `lineageID`
// (LocusKit § 5.10). Every live drawer therefore reports revision 1, and
// the digest (lowercase SHA-256 over the verbatim content) is the
// change-detection anchor. A withdrawn/expunged drawer stops resolving,
// which the engine treats as removal.
//
// The CHANGE FEED is not served here: GLK pushes Drawer change references
// (`ContentIndexJob`) onto the engine's encode queue at the capture and
// withdraw verbs — the estate's own verbs ARE the change stream. The feed
// surface returns empty; rebuilds stream `activeContentIDs()` +
// `record(for:)` in deterministic ID order instead.
//
// DENSE-OVER-DISTILLATE (MISSION_11X_RECALL_GAP_01 Stream F):
// `record(for:)` supplies `denseCompositionText: drawer.distilled`. When
// `distilled` is nil (pre-sweep / edit-to-regeneration window), nil
// propagates and `CorpusContentRecord.effectiveDenseText` falls back to
// the verbatim `text` — zero behavior change for undistilled rows. When
// non-nil, the engine uses the distillate for the dense float vector lane
// while BM25 continues to index `text` unchanged (BM25 search isolation,
// SPEC_DISTILLATION_STORAGE §9, is preserved: the content digest keys on
// `text` and BM25 tokens come from `text`).
//
// Recomposability: on retrain / reindex the engine calls `source.record(for:)`
// again. If the distillate is present, the re-embedded vector is distillate-
// based; if swept away (content edit → NULL), the vector reverts to lexical.
// Either way the persisted `distilled` column is the single source of truth —
// no additional basis dependency is introduced.
//
// Rust twin: `rust/src/intake.rs` (`LocusDrawerContentSource`).

import CorpusKit
import Foundation
import LocusKit

/// LocusKit-Drawer-backed `CorpusContentSource` for one open estate.
public struct LocusDrawerCorpusContentSource: CorpusContentSource {

    private let estate: Estate

    public init(estate: Estate) {
        self.estate = estate
    }

    /// Resolve the CURRENT canonical record for a Drawer ID. Empty-content
    /// and non-resolving drawers return nil (nothing to index; the engine
    /// clears derived state for a previously-indexed ID that stops
    /// resolving).
    ///
    /// Supplies `denseCompositionText: drawer.distilled` so the dense
    /// float lane is composed from the distillate when available. A nil
    /// `distilled` column propagates as nil and `effectiveDenseText` falls
    /// back to the verbatim `text` — the BM25 lane is always `text`.
    public func record(for id: CorpusContentID) async throws -> CorpusContentRecord? {
        guard let drawer = try await estate.getDrawers(ids: [id]).first,
              !drawer.content.isEmpty,
              drawer.contentKind != .dataset,
              drawer.embeddingModelID != datasetHandleEmbeddingModelID else {
            return nil
        }
        return CorpusContentRecord(
            id: drawer.id,
            revision: 1,
            digest: CorpusContentDigest.digest(drawer.content),
            text: drawer.content,
            // Dense-over-distillate (Stream F): the distillate column is the
            // dense-composition text when set. Nil = lexical fallback via
            // effectiveDenseText. The digest always keys on `text` (content
            // did not change when only the distillate was written), so the
            // BM25 idempotence anchor is unaffected by distillation.
            denseCompositionText: drawer.distilled)
    }

    /// The estate verbs are the change stream — the polling feed is empty.
    public func changes(
        since cursor: String?, limit: Int
    ) async throws -> CorpusContentChangeBatch {
        .empty
    }

    /// Every active Drawer ID with non-empty content in a deterministic order
    /// suitable for training. Paged so no single call materializes an
    /// unbounded drawer set.
    ///
    /// Sort key: `(filedAt ascending, content ascending)`. UUID order is NOT
    /// used because drawer UUIDs are random per fresh estate — sorting by UUID
    /// produces a non-deterministic encounter order for `TermDocumentCounts`,
    /// which assigns vocabulary indices as terms are first seen across the
    /// training sequence. Non-deterministic vocabulary indices produce different
    /// model weights (RI random projections, PPMI PMI scores, LSA/NMF factor
    /// matrices) across runs from the same corpus, causing recall scores to
    /// drift between replay runs even when the corpus and capture timestamps
    /// are bit-identical.
    ///
    /// `filedAt` is seed-derived when `MOOT_BENCH_EPOCH_NOW` is active (set to
    /// `captureDate` from the seed file), making it stable across replay runs.
    /// `content` is the stable tiebreak for same-`filedAt` records (e.g.
    /// contradiction pairs that share an event_time): it is a pure function of
    /// the corpus and does not depend on drawer identity.
    ///
    /// Rust twin: `intake.rs` `active_content_ids`.
    public func activeContentIDs() async throws -> [CorpusContentID] {
        // Collect (filedAt, content, id) tuples so the final sort uses the
        // stable keys rather than the random drawer UUID.
        var entries: [(filedAt: Date, content: String, id: String)] = []
        var cursor: String?
        let pageSize = 2_000
        while true {
            let page = try await estate.activeDrawersAfter(id: cursor, limit: pageSize)
            if page.isEmpty { break }
            cursor = page.last?.id
            for drawer in page where !drawer.content.isEmpty
                && drawer.contentKind != .dataset
                && drawer.embeddingModelID != datasetHandleEmbeddingModelID
            {
                entries.append((drawer.filedAt, drawer.content, drawer.id))
            }
            if page.count < pageSize { break }
        }
        // filedAt ascending, then content ascending as a stable tiebreak for
        // same-instant records. Content comparison only fires for the rare
        // same-filedAt case (e.g. two drawers in a contradiction pair), so the
        // overhead of carrying the content string here is negligible in practice.
        return entries.sorted {
            if $0.filedAt != $1.filedAt { return $0.filedAt < $1.filedAt }
            return $0.content < $1.content
        }.map { $0.id }
    }
}
