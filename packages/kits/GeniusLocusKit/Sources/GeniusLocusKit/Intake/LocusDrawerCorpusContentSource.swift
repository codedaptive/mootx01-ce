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
// INDEX COMPOSITION POLICY (CDL-03):
// `record(for:)` composes the lexical and dense texts according to the
// `compositionPolicy` supplied at adapter construction time. The default
// policy — `.current` — preserves the established dense-over-distillate
// behaviour (Stream F / MISSION_11X_RECALL_GAP_01):
//   • lexical text = verbatim `drawer.content` (BM25)
//   • dense text   = `drawer.distilled` (nil → fallback to verbatim via
//                    `CorpusContentRecord.effectiveDenseText`)
//
// When the policy includes adornments (`lexicalNeedsAdornments` or
// `denseNeedsAdornments`), active adornment texts are fetched from the
// estate in ascending minter-ID order and appended to the base text on
// separate lines ("\n"). The digest always keys on the verbatim `text`
// (content did not change when only the distillate or adornments changed),
// so the BM25 idempotence anchor is unaffected by policy.
//
// Rust twin: `rust/src/intake.rs` (`LocusDrawerContentSource`).

import AdornmentLib
import CorpusKit
import Foundation
import LocusKit

/// LocusKit-Drawer-backed `CorpusContentSource` for one open estate.
public struct LocusDrawerCorpusContentSource: CorpusContentSource {

    private let estate: Estate
    /// The named index composition policy that controls which texts each lane
    /// receives (CDL-03). Defaults to `.current` — preserves the established
    /// dense-over-distillate behaviour before CDL-03.
    private let compositionPolicy: IndexCompositionPolicy

    public init(estate: Estate, compositionPolicy: IndexCompositionPolicy = .current) {
        self.estate = estate
        self.compositionPolicy = compositionPolicy
    }

    /// Resolve the CURRENT canonical record for a Drawer ID. Empty-content
    /// and non-resolving drawers return nil (nothing to index; the engine
    /// clears derived state for a previously-indexed ID that stops
    /// resolving).
    ///
    /// Composes lexical and dense texts according to `compositionPolicy`.
    /// For the `.current` policy (cell A), this is identical to the
    /// established dense-over-distillate behaviour: BM25 indexes verbatim
    /// `text`, the dense lane gets `distilled` (nil → `effectiveDenseText`
    /// fallback to verbatim). The digest always keys on the verbatim `text`.
    public func record(for id: CorpusContentID) async throws -> CorpusContentRecord? {
        guard let drawer = try await estate.getDrawers(ids: [id]).first,
              !drawer.content.isEmpty,
              drawer.contentKind != .dataset,
              drawer.embeddingModelID != datasetHandleEmbeddingModelID else {
            return nil
        }

        // Fetch adornments only when the policy requires them — avoids the
        // store read on the common `.current` path.
        var adornmentTexts: [String] = []
        if compositionPolicy.needsAdornments {
            let adornmentMap = try await estate.activeAdornments(drawerIDs: [drawer.id])
            // Ascending minter-ID order for deterministic composition across
            // runs with the same corpus and adornment set.
            adornmentTexts = (adornmentMap[drawer.id] ?? [])
                .sorted { $0.minterID < $1.minterID }
                .map(\.text)
        }

        // Compose the lexical text per policy.
        let lexicalText = composedText(
            base: lexicalBase(drawer: drawer),
            adornments: compositionPolicy.lexicalNeedsAdornments ? adornmentTexts : [])

        // Compose the dense text per policy.
        // Nil propagates to `effectiveDenseText` fallback in CorpusContentRecord.
        let denseText: String?
        let denseBase = denseBase(drawer: drawer)
        if compositionPolicy.denseNeedsAdornments && !adornmentTexts.isEmpty {
            denseText = composedText(base: denseBase ?? drawer.content,
                                     adornments: adornmentTexts)
        } else {
            denseText = denseBase
        }

        return CorpusContentRecord(
            id: drawer.id,
            revision: 1,
            // The digest keys on verbatim content — unchanged when only the
            // distillate or adornments change, so BM25 idempotence is preserved
            // (SPEC_DISTILLATION_STORAGE §9).
            digest: CorpusContentDigest.digest(drawer.content),
            text: lexicalText,
            denseCompositionText: denseText)
    }

    // MARK: - Composition helpers

    /// The base text for the lexical lane under the configured policy.
    private func lexicalBase(drawer: Drawer) -> String {
        switch compositionPolicy.lexicalSource {
        case .original, .originalPlusAdornments:
            // Verbatim content — the BM25 token source.
            return drawer.content
        case .distilled, .distilledPlusAdornments:
            // Distillate as lexical base; fall back to verbatim when nil.
            return drawer.distilled ?? drawer.content
        }
    }

    /// The base text for the dense lane under the configured policy. Returns
    /// nil when the policy requests `.distilled` and the distillate is absent
    /// (nil propagates to `effectiveDenseText` fallback in the record).
    private func denseBase(drawer: Drawer) -> String? {
        switch compositionPolicy.denseSource {
        case .distilled, .distilledPlusAdornments:
            // Distillate-over-verbatim (Stream F): nil when not yet distilled.
            return drawer.distilled
        case .original:
            // Lexical-only ablation (cell E): dense = verbatim.
            return drawer.content
        }
    }

    /// Append adornment texts to a base string. Each adornment is on its own
    /// line preceded by "\n". When `adornments` is empty, returns `base` unchanged.
    private func composedText(base: String, adornments: [String]) -> String {
        guard !adornments.isEmpty else { return base }
        // "\n" separator between base and each adornment — identical in both ports.
        return ([base] + adornments).joined(separator: "\n")
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
