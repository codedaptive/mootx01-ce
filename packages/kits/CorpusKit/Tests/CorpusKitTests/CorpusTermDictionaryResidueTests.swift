// CorpusTermDictionaryResidueTests.swift
//
// Regression guard for the V4 term dictionary deletion guarantee.
//
// Guarantee: corpus content that has been expunged leaves no trace in
// corpus_provider_term_dictionary or corpus_provider_term_payload. The
// term text introduced by deleted content must not be reachable through
// any derived structure after the content is removed and the model's
// term set is rewritten by reindex.
//
// Uses RandomIndexing provider (random-indexing-v1), the only provider that
// implements decomposeCounts() and therefore routes persistCounts through
// replaceTermPayloads into the v4 term dictionary (PPMI, LSA, NMF return nil
// from decomposeCounts() and use the blob write path instead).
//
// Deletion path traced (for reviewers):
//
//   Corpus.expunge(sourceID:) → Corpus.remove(sourceID:)
//     Clears: invertedIndex rows, vectorStore rows, removedSourceStore record.
//     Does NOT touch: corpus_provider_term_dictionary, corpus_provider_term_payload,
//                     corpus_provider_count_references.
//
//   The v4 term dictionary is rewritten by persistCounts →
//   replaceTermPayloads (when provider.decomposeCounts() is non-nil).
//   replaceTermPayloads clears this model's bit on every dictionary row whose
//   term is absent from the incoming set, and deletes rows whose bitmask
//   reaches zero. deleteTermPayloads does the same for the wholesale-drop path.
//
//   Corpus.reindex(now:) after expunge → corpus path (forced by population guard:
//     countsDocumentCount != activeChunks.count)
//       → replaceTermPayloads(modelID:terms:into:)
//             DELETE corpus_provider_term_payload WHERE model_id = <ri-int>
//             INSERT  one payload row per surviving term
//             CLEAR   model bit for every dict row absent from the new term set;
//                     DELETE dict row if bitmask reaches zero.
//
// This test was observed FAILING at commit 2637db720 (pre-fix), confirming
// that it discriminates between the defective and corrected behaviours.

import Foundation
import PersistenceKit
import PersistenceKitSQLite
import Testing

@testable import CorpusKit
import CorpusKitProviders

// MARK: - Nonce token

/// A unique alphabetic compound token that appears ONLY in content A.
/// Repeated many times so RI accumulates enough co-occurrences to store
/// a non-zero term vector, ensuring the term enters the v4 dictionary
/// after training.
private let nonceToken = "zxqvnoceresidterm"

private let textA = """
    \(nonceToken) \(nonceToken) \(nonceToken) researchers studied the \
    \(nonceToken) phenomenon using \(nonceToken) instruments under \
    \(nonceToken) laboratory conditions. Every \(nonceToken) experiment \
    produced \(nonceToken) results confirming the \(nonceToken) effect. \
    The \(nonceToken) team published \(nonceToken) findings about \
    \(nonceToken) applications in \(nonceToken) settings.
    """

/// Content B: no mention of the nonce token.
private let textB = """
    bioluminescence bioluminescence bioluminescence organisms produce bioluminescence \
    through enzymatic bioluminescence reactions. Deep-sea bioluminescence studies \
    reveal bioluminescence adaptations that aid bioluminescence survival. \
    Scientists study bioluminescence mechanisms in bioluminescence marine environments \
    to understand bioluminescence evolution and bioluminescence signalling.
    """

private let t1 = Date(timeIntervalSinceReferenceDate: 3_000_000)
private let t2 = Date(timeIntervalSinceReferenceDate: 3_100_000)

// MARK: - Row-level query helpers

/// The RI model integer and bitmask.
/// modelRegistry["random-indexing-v1"] == 0, so bit = 1 << 0 = 1.
private let riModelInt: Int64 = 0
private let riModelBit: Int64 = Int64(1) << riModelInt

/// All corpus_provider_term_dictionary rows for `term`.
private func termDictRows(
    _ term: String, storage: any Storage
) async throws -> [StorageRow] {
    let all = try await storage.rowStore.query(
        table: "corpus_provider_term_dictionary",
        where: .isTrue, orderBy: [], limit: nil, offset: nil)
    return all.filter {
        guard case let .text(t) = $0["term"] ?? .null else { return false }
        return t == term
    }
}

/// All corpus_provider_term_payload rows whose term_id matches one of
/// `dictRows` AND whose model_id is the RI model integer.
private func termPayloadRows(
    dictRows: [StorageRow], storage: any Storage
) async throws -> [StorageRow] {
    guard !dictRows.isEmpty else { return [] }
    let termIDs: Set<Int64> = Set(dictRows.compactMap {
        guard case let .int(id) = $0["term_id"] ?? .null else { return nil }
        return id
    })
    let all = try await storage.rowStore.query(
        table: "corpus_provider_term_payload",
        where: .isTrue, orderBy: [], limit: nil, offset: nil)
    return all.filter {
        guard case let .int(model) = $0["model_id"] ?? .null,
              case let .int(id) = $0["term_id"] ?? .null
        else { return false }
        return model == riModelInt && termIDs.contains(id)
    }
}

// MARK: - Suite

@Suite("CorpusTermDictionaryResidue", .serialized)
struct CorpusTermDictionaryResidueTests {

    /// V4 term dictionary carries no residue for deleted corpus content.
    ///
    /// Sequence: ingest A (nonce) → reindex → expunge A → ingest B → reindex.
    ///
    /// Three assertions made after expunge + reindex:
    ///   (1) corpus_provider_term_payload: no row for nonce term.
    ///   (2) corpus_provider_term_dictionary: no row with the RI bit set for
    ///       the nonce term. replaceTermPayloads now clears the bit and deletes
    ///       the row when no model claims the term.
    ///   (3) loadTermPayloads("random-indexing-v1"): nonce term absent.
    @Test("V4 term dictionary carries no residue for deleted corpus content")
    func dictionaryCarriesNoResidueForDeletedContent() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let riProvider = RandomIndexingProvider()
            let corpus = try await Corpus(
                storage: storage,
                model: .randomIndexing(provider: riProvider))

            // Phase 1: ingest content A, which contributes the nonce term many times.
            // RI accumulates co-occurrence vectors in-memory; persistMaintainedCounts
            // calls persistCounts → replaceTermPayloads, writing the nonce term into
            // corpus_provider_term_dictionary and corpus_provider_term_payload.
            try await corpus.ingest(textA, sourceID: "source-A", now: t1)

            // Phase 2: first reindex. Ensures a trained RI basis with the nonce
            // term's vector is persisted to the v4 tables.
            try await corpus.reindex(now: t1)

            // Pre-expunge baseline: nonce term must appear in the dictionary.
            // If it does not, the provider did not use the v4 path and the test
            // is non-discriminating (all three assertions would trivially pass).
            let dictBeforeExpunge = try await termDictRows(nonceToken, storage: storage)
            guard !dictBeforeExpunge.isEmpty else {
                Issue.record(
                    """
                    Pre-expunge baseline failed: '\(nonceToken)' not found in \
                    corpus_provider_term_dictionary after ingest + reindex. \
                    RI must produce a non-zero vocab entry for the nonce token. \
                    Check that the tokenizer preserves the token as a single unit \
                    and that RandomIndexingProvider.decomposeCounts() returned non-nil.
                    """)
                return
            }

            // Phase 3: expunge content A. Clears invertedIndex, vectorStore,
            // removedSourceStore. Does NOT directly touch corpus_provider_term_dictionary
            // or corpus_provider_term_payload — those are repaired on the next reindex.
            try await corpus.expunge(sourceID: "source-A")

            // Phase 4: ingest content B (no nonce term).
            try await corpus.ingest(textB, sourceID: "source-B", now: t2)

            // Phase 5: second reindex. Population guard fires (countsDocumentCount
            // after ingest A + B != activeChunks after expunge A), forcing corpus
            // path. replaceTermPayloads is called with B's term set only.
            //
            // Fixed behaviour: after writing B's terms, replaceTermPayloads clears
            // the RI bit on the nonce term's dictionary row (it is absent from B's
            // set), then deletes the row because no other model claimed it.
            try await corpus.reindex(now: t2)

            // Fetch the nonce term's current dictionary and payload rows.
            let dictRows = try await termDictRows(nonceToken, storage: storage)
            let payloadRows = try await termPayloadRows(dictRows: dictRows, storage: storage)

            // MARK: Assertion (1) — no payload row
            //
            // replaceTermPayloads blanket-deletes all payload rows for the model,
            // then re-inserts only the surviving terms. The nonce is absent from
            // B's term set, so its payload row is not re-inserted.
            #expect(payloadRows.isEmpty,
                    """
                    corpus_provider_term_payload must have no row for '\(nonceToken)' \
                    (RI model_id=\(riModelInt)) after expunge + reindex. \
                    Found \(payloadRows.count) row(s). replaceTermPayloads should have \
                    deleted the payload during the corpus-path write.
                    """)

            // MARK: Assertion (2) — no dictionary row at all for the nonce term
            //
            // replaceTermPayloads clears the model's bit for terms absent from the
            // incoming set and deletes the row when the bitmask reaches zero.
            // The nonce term is not in B's set and no other model claimed it,
            // so the row must be gone entirely.
            //
            // The row itself is what this asserts, not just the bitmask. The term
            // TEXT is the deleted content's token: a row left behind carrying
            // models=0 would still hold that text in the estate, which is the
            // residue this guarantee forbids. Clearing the bit alone does not
            // satisfy it.
            #expect(dictRows.isEmpty,
                    """
                    corpus_provider_term_dictionary must have NO row for '\(nonceToken)' \
                    after expunge + reindex — the term text belongs to deleted content. \
                    Found \(dictRows.count) row(s): \(dictRows). A row surviving with a \
                    zeroed bitmask is still residue.
                    """)

            // And, specifically, no row still claimed by the RI model.
            let nonceDictWithBit: [StorageRow] = dictRows.filter {
                guard case let .int(models) = $0["models"] ?? .null else { return false }
                return models & riModelBit != 0
            }
            #expect(nonceDictWithBit.isEmpty,
                    """
                    corpus_provider_term_dictionary must have no row with the RI bit \
                    (\(riModelBit)) set for '\(nonceToken)' after expunge + reindex. \
                    Found \(nonceDictWithBit.count) row(s) with models bitmask including \
                    bit \(riModelBit). The cleanup in replaceTermPayloads must remove \
                    the row when no model claims the term.
                    """)

            // MARK: Assertion (3) — loadTermPayloads returns no nonce term
            //
            // loadTermPayloads inner-joins corpus_provider_term_payload against
            // corpus_provider_term_dictionary filtered by the model bit. Both the
            // payload row and the dictionary row are gone, so the nonce term does
            // not appear in the loaded result.
            let countsStore = CorpusProviderCountsStore(storage: storage)
            let loadedTerms = try await countsStore.loadTermPayloads(modelID: "random-indexing-v1")
            let noncePresent = loadedTerms.map(\.term).contains(nonceToken)
            #expect(!noncePresent,
                    """
                    loadTermPayloads('random-indexing-v1') must not return '\(nonceToken)' \
                    after expunge + reindex. Both the payload row and the dictionary row \
                    are deleted, so the join returns nothing for this term. \
                    Found the nonce among \(loadedTerms.count) loaded terms.
                    """)
        }
    }
}
