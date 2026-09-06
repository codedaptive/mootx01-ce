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
// INDEX COMPOSITION (schema 19): both lanes index the verbatim `content`.
// The lexical lane's BM25 document is `content` plus the SSC facts
// supplement the engine derives from `drawers.ssc_facts`
// (`SSCFacts.lexicalSupplement`); the dense lane reads the same verbatim
// text through `CorpusContentRecord.effectiveDenseText`. This is the one
// composition every estate indexes.
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
    /// The record carries the verbatim `content` as `text`, no separate
    /// dense composition (the dense lane falls back to `text` through
    /// `effectiveDenseText`), and the drawer's `ssc_facts` column value for
    /// the engine's BM25 supplement. The digest keys on the verbatim text.
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
            denseCompositionText: nil,
            // The engine appends `SSCFacts.lexicalSupplement(sscFacts)` to the
            // BM25 document; the column is written by the enrichment stage
            // before the drawer is indexed (contract sheet §6).
            sscFacts: drawer.sscFacts)
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
    /// model weights (RI random projections) across runs from the same corpus,
    /// causing recall scores to drift between replay runs even when the corpus
    /// and capture timestamps are bit-identical.
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
