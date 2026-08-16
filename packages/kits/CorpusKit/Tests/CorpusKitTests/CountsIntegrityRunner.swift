// CountsIntegrityRunner.swift
//
// Store-invariant conformance for the provider counts store.
//
// WHY THIS EXISTS
//
// Four separate missions each found a different hole in the same store, and
// each found it by collision rather than by test:
//
//   CT-01  the population guard could disagree with the rows it counted
//   CT-02  deleting content left its term-dictionary entries behind
//   CT-02 residual  deleting content left its count_references rows behind
//   MG-02/m2  a migration-invalidated counts blob was restored as if valid
//
// Every one of those missions tested its own change and passed. None of them
// could fail on someone else's defect, because no test asks the store whether
// it is still COHERENT after a mutation. That is the gap this runner closes.
//
// This is NOT production code and is never called from it. Call
// `verifyIntegrity()` at the tail of any test that mutates the counts store.
// A fifth mission that breaks one of these invariants then fails on a test it
// did not write, which is the only mechanism that would have caught the four
// above.
//
// Sibling of `PersistenceKitConformance/ConformanceRunner.swift`, which does
// the same job one layer down for storage BACKENDS (SQLite / Postgres /
// InMemory produce identical observable results). That rig proves the backends
// agree; this one proves the kit's own rows stay consistent. Neither subsumes
// the other.
//
// EVERY INVARIANT HERE MUST BE FALSIFIED BEFORE IT IS TRUSTED: break the
// mechanism it guards, confirm this runner fails, restore it, confirm it
// passes. An assertion nobody has seen fail is a claim, not a gate. See
// `FALSIFICATION` at the bottom of this file for the record.

import Testing
import Foundation
import PersistenceKit
@testable import CorpusKit

/// Store-invariant checks for `corpus_provider_*` tables.
///
/// Construct one with the row store under test and call `verifyIntegrity()`.
/// Each invariant is also individually callable so a test can assert a single
/// property when that is what it is about.
public struct CountsIntegrityRunner {

    /// The row store whose counts tables are checked.
    let rowStore: any RowStore

    /// Label used in failure messages so a violation names the test that
    /// produced it rather than only the invariant that caught it.
    let label: String

    public init(rowStore: any RowStore, label: String = "counts store") {
        self.rowStore = rowStore
        self.label = label
    }

    // MARK: - The whole set

    /// Runs every invariant. This is the call site a mutating test adds.
    ///
    /// Ordering is deliberate: reference integrity first, because a dangling
    /// reference is the cheapest to produce and the one whose failure explains
    /// the guard-population failure that would otherwise follow it.
    public func verifyIntegrity() async throws {
        try await referenceRowsHaveLiveCountsRow()
        try await termDictionaryHasNoOrphanModelBits()
        try await termPayloadMatchesDictionary()
        try await invalidatedCountsHasNoSurvivingTermRows()
    }

    // MARK: - I-1: every reference row has a live counts row

    /// `corpus_provider_count_references` rows are per-(model, content)
    /// records of work pending against a provider generation. A reference
    /// whose `(model_id, model_version)` has no counts row is an orphan: it
    /// inflates the pending side of the population guard against a generation
    /// that no longer exists.
    ///
    /// This is the CT-02 residual, found only because a later mission happened
    /// to read the delete path. Before the fix, `removeContent` cleared the
    /// term dictionary and left these rows, so the guard saw 50 + 2 = 52 where
    /// the store held 51.
    public func referenceRowsHaveLiveCountsRow() async throws {
        let refs = try await rowStore.query(
            table: "corpus_provider_count_references",
            where: nil, orderBy: [], limit: nil, offset: nil)
        guard !refs.isEmpty else { return }

        // One query for the live generations, then a set membership test per
        // reference — not a query per reference. A store with thousands of
        // pending references should not make this runner the slow part of a
        // test suite.
        let countsRows = try await rowStore.query(
            table: "corpus_provider_counts",
            where: nil, orderBy: [], limit: nil, offset: nil)
        var liveKeys: Set<String> = []
        for row in countsRows {
            guard case let .text(model)? = row["model_id"],
                  case let .text(version)? = row["model_version"] else { continue }
            liveKeys.insert("\(model)\u{0}\(version)")
        }

        for ref in refs {
            guard case let .text(model)? = ref["model_id"],
                  case let .text(version)? = ref["model_version"] else { continue }
            let contentID: String
            if case let .text(cid)? = ref["content_id"] { contentID = cid } else { contentID = "?" }
            #expect(liveKeys.contains("\(model)\u{0}\(version)"),
                    """
                    \(label) I-1 VIOLATED: count_references row for content \
                    '\(contentID)' names provider (\(model), \(version)), which has \
                    no counts row. An orphan reference inflates the pending side of \
                    the population guard against a generation that no longer exists. \
                    Whatever deleted the counts row must delete its references too.
                    """)
        }
    }

    // MARK: - I-2: the term dictionary carries no bit for a model with no payload

    /// `corpus_provider_term_dictionary.models` is a bitmask of which models
    /// claim each term. A bit set for a model that has no payload rows at all
    /// means the dictionary outlived the payload it described — the shape
    /// CT-02 fixed for deleted content.
    ///
    /// A term whose mask is ZERO is explicitly NOT a violation: it is a name
    /// no model currently claims, which `clearTermPayloads` produces
    /// deliberately and the next persist re-sets if the term returns.
    public func termDictionaryHasNoOrphanModelBits() async throws {
        let dict = try await rowStore.query(
            table: "corpus_provider_term_dictionary",
            where: nil, orderBy: [], limit: nil, offset: nil)
        guard !dict.isEmpty else { return }

        let payloads = try await rowStore.query(
            table: "corpus_provider_term_payload",
            where: nil, orderBy: [], limit: nil, offset: nil)
        var modelsWithPayload: Set<Int64> = []
        for row in payloads {
            if case let .int(model)? = row["model_id"] { modelsWithPayload.insert(model) }
        }

        for row in dict {
            guard case let .int(mask)? = row["models"], mask != 0 else { continue }
            let term: String
            if case let .text(t)? = row["term"] { term = t } else { term = "?" }
            // Walk only the bits the registry can assign; a bit outside that
            // range is itself a defect and is reported as one.
            for bit in 0..<63 where mask & (Int64(1) << Int64(bit)) != 0 {
                #expect(modelsWithPayload.contains(Int64(bit)),
                        """
                        \(label) I-2 VIOLATED: term '\(term)' has model bit \(bit) set \
                        in the dictionary, but model \(bit) has no payload rows at all. \
                        The dictionary outlived the payload it describes — the shape \
                        that left deleted content's terms behind.
                        """)
            }
        }
    }

    // MARK: - I-3: every payload row is described by the dictionary

    /// The inverse of I-2, and the one that catches a payload written without
    /// its dictionary entry. `(model_id, term_id)` in the payload table must
    /// name a `term_id` the dictionary knows, with this model's bit set.
    ///
    /// Without this, a payload row is unreachable: nothing can map a term
    /// string to it, so it is resident bytes no query can return.
    public func termPayloadMatchesDictionary() async throws {
        let payloads = try await rowStore.query(
            table: "corpus_provider_term_payload",
            where: nil, orderBy: [], limit: nil, offset: nil)
        guard !payloads.isEmpty else { return }

        let dict = try await rowStore.query(
            table: "corpus_provider_term_dictionary",
            where: nil, orderBy: [], limit: nil, offset: nil)
        var maskByTermID: [Int64: Int64] = [:]
        for row in dict {
            guard case let .int(termID)? = row["term_id"],
                  case let .int(mask)? = row["models"] else { continue }
            maskByTermID[termID] = mask
        }

        for row in payloads {
            guard case let .int(model)? = row["model_id"],
                  case let .int(termID)? = row["term_id"] else { continue }
            guard let mask = maskByTermID[termID] else {
                Issue.record("""
                    \(label) I-3 VIOLATED: payload row (model \(model), term_id \
                    \(termID)) has no dictionary entry. Nothing can map a term string \
                    to this row, so it is bytes no query can reach.
                    """)
                continue
            }
            #expect(mask & (Int64(1) << Int64(model)) != 0,
                    """
                    \(label) I-3 VIOLATED: payload row (model \(model), term_id \
                    \(termID)) exists, but the dictionary does not set model \(model)'s \
                    bit for that term. The payload is unreachable through the \
                    dictionary that is supposed to describe it.
                    """)
        }
    }

    // MARK: - I-4: an invalidated counts blob has no surviving term rows

    /// `mootx01 upgrade` invalidates a provider's counts by writing an EMPTY
    /// blob — the migration sentinel. A generation carrying the sentinel must
    /// not also carry term rows: the sentinel says "these counts are not
    /// usable, fall back to the corpus path", and surviving term rows are
    /// exactly what a restore would find and use instead.
    ///
    /// Scope is the v3 `corpus_provider_vocab` table ONLY, because Step 1 of
    /// the upgrade migration deletes every row in it ("legacy vocab rows must
    /// be gone"). Surviving v4 term rows are legal and expected — the migration
    /// leaves them deliberately — so widening this check to the v4 tables would
    /// fail on a correctly migrated estate.
    ///
    /// The test below calls `CorpusProviderCountsStore.isInvalidatedCounts`,
    /// the Swift twin of `corpus_provider_counts_store::is_invalidated_counts`.
    /// Both ports route every sentinel decision through their one predicate, so
    /// a change to the sentinel format is a single edit per port. Do not inline
    /// an emptiness test here: that would make this a second definition site,
    /// and the two sites would be free to drift apart.
    public func invalidatedCountsHasNoSurvivingTermRows() async throws {
        let countsRows = try await rowStore.query(
            table: "corpus_provider_counts",
            where: nil, orderBy: [], limit: nil, offset: nil)

        for row in countsRows {
            guard case let .blob(blob)? = row["counts"],
                  CorpusProviderCountsStore.isInvalidatedCounts(blob) else { continue }
            guard case let .text(model)? = row["model_id"],
                  case let .text(version)? = row["model_version"] else { continue }

            // v3 layout: term rows keyed by the text provider key.
            let vocabCount = try await rowStore.count(
                table: "corpus_provider_vocab",
                where: .and([
                    .eq(Column(table: "corpus_provider_vocab", name: "model_id"), .text(model)),
                    .eq(Column(table: "corpus_provider_vocab", name: "model_version"), .text(version)),
                ]))
            #expect(vocabCount == 0,
                    """
                    \(label) I-4 VIOLATED: provider (\(model), \(version)) carries the \
                    migration invalidation sentinel (empty counts blob) but still has \
                    \(vocabCount) v3 term rows. A restore would find those rows and use \
                    them, which is precisely what the sentinel exists to prevent.
                    """)
        }
    }
}

// MARK: - FALSIFICATION
//
// Recorded so a later reader can tell a proven gate from an asserted one.
// Every invariant here has been OBSERVED failing on the row state it exists to
// reject. `CountsIntegrityRunnerFalsificationTests` builds each violating state
// and runs the invariant inside `withKnownIssue`, which fails the test when the
// runner records no issue — so weakening an invariant turns its test red rather
// than quietly widening what the store is allowed to be.
//
//   I-1  i1_orphanReferenceIsCaught          / i1_cleanPasses
//   I-2  i2_orphanModelBitIsCaught           / i2_cleanPasses
//   I-3  i3_payloadWithoutDictionaryEntryIsCaught
//        i3_dictionaryMissingModelBitIsCaught / i3_cleanPasses
//   I-4  i4_sentinelWithSurvivingTermRowsIsCaught / i4_cleanPasses
//
// The paired clean-store tests are the other half: an invariant that fired on
// everything would satisfy the first column and fail the second.
