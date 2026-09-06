#if MOOTX01_DENSE_FAMILIES
// Dense-family test — compiled only when DenseFamilies trait is on.
// Off by default (plan 70BC55F3, 2026-09-05). See Package.swift.
// CorpusCountsSentinelContractTests.swift
//
// MG-02 contract gates: Swift twin of corpus_counts_blob_sentinel_tests.rs,
// plus three Swift-only gates for the new sentinel-preserving flush guard.
//
// The upgrade migration writes an empty blob (the invalidatedCountsSentinel)
// into corpus_provider_counts.counts to mean "counts invalidated, rebuild from
// scratch", while preserving the doc_count / vocab_size growth anchors.
// The corrected contract defines three behaviours that must hold in both ports:
//
//   1. The predicate: an empty blob (and only an empty blob) is the sentinel.
//   2. The read intercept: restoreCounts returns false for a sentinel blob,
//      intercepting before any provider decoder is called.
//   3. The sentinel-preserving flush guard: persistCounts skips the write when
//      the provider's vocabulary is empty AND the stored row already carries
//      the sentinel, so the flush cannot overwrite the sentinel with a valid
//      empty-state blob.
//
// Two-file split: T5 (sentinel predicate self-check) lives in
// CorpusCountsSentinelPredicateTests.swift because it names the production
// symbols CorpusProviderCountsStore.invalidatedCountsSentinel and
// CorpusProviderCountsStore.isInvalidatedCounts(_:), which do not exist at
// the pre-fix SHA (6bdc6071e). Keeping T5 in this file would prevent
// T1/T2/T6/T8 from compiling pre-fix, making them miss-by-compile instead of
// miss-by-assertion. T5's compile failure IS a legitimate gate (it proves the
// API did not exist), and T5 is what licenses the literal Data() in
// seedSentinelRow below: T5 asserts that Data() and invalidatedCountsSentinel
// agree, so the contract still has exactly one definition.
//
// Suite cases (this file):
//   T1 -- sentinel recovery, no v4 term rows (mirrors Rust t1)
//   T2 -- sentinel recovery with surviving v4 term residue (mirrors Rust t2)
//   T3 -- no-weakening: valid blob still restores and returns true (mirrors Rust t3)
//   T4 -- non-empty undecodable blob still throws decodingFailure (mirrors Rust t4)
//   T6 -- flush guard preserves sentinel when provider accumulator is empty (Swift-only)
//   T7 -- flush guard does not suppress legitimate writes (Swift-only, structural gate)
//   T8 -- doc_count / vocab_size anchors survive a sentinel-preserving flush (Swift-only)
//
// Suite cases (CorpusCountsSentinelPredicateTests.swift):
//   T5 -- sentinel predicate self-check (mirrors Rust sentinel_predicate_is_consistent)
//
// Pre-fix behaviour (SHA 6bdc6071e) for the behavioural gates in this file:
//   seedSentinelRow seeds Data() (the empty literal) rather than the named
//   constant, so the call compiles against pre-fix source. The gates then fail
//   on their assertions, not on a missing symbol:
//   - T1 and T2: restoreCounts throws CorpusKitError.decodingFailure instead of
//     returning false -- no sentinel intercept exists pre-fix.
//   - T6: persistCounts overwrites the sentinel with a valid empty-state blob,
//     storedCounts.isEmpty is false -- no flush guard exists pre-fix.
//   - T8: flush overwrites anchors; doc_count and vocab_size become 0 instead
//     of the seeded values 42 and 17 -- same root cause as T6.
//
// Storage: on-disk SQLite scratch files. InMemory is not used because its
// semantic TypedValues mask the primitive .text/.int decode path SQLite returns
// on read, which would hide real round-trip regressions. See TestScratchStorage.swift
// for the full rationale.

import Foundation
import Testing
import PersistenceKit
import PersistenceKitSQLite

@testable import CorpusKit
import CorpusKitProviders

// ---- Epoch constant --------------------------------------------------------

/// A fixed timestamp for all persisted rows. Never Date() -- determinism mandate.
/// 2025-08-18T01:33:20Z -- distant from zero to catch any accidental default-init.
private let fixedNow = Date(timeIntervalSince1970: 1_755_500_000)

// ---- Storage helper --------------------------------------------------------

/// Open a fresh SQLite scratch file and apply the current v4 CorpusKit counts
/// schema. Sufficient for all sentinel tests -- no migration ladder is needed
/// (we start from the fully-current schema, not an older version).
private func makeSentinelTestStorage() async throws -> any Storage {
    let storage = try makeScratchStorage()
    try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)
    return storage
}

// ---- Seeding helpers -------------------------------------------------------

/// Write a corpus_provider_counts row shaped exactly like a post-migration row:
///   counts     = Data() (the empty blob, which IS the sentinel value)
///   doc_count  = docCount  (monotone anchor preserved by migration)
///   vocab_size = vocabSize (monotone anchor preserved by migration)
///
/// WHY Data() AND NOT invalidatedCountsSentinel:
/// The behavioural gates T1, T2, T6, and T8 must compile and fail on their
/// assertions at the pre-fix SHA (6bdc6071e), where invalidatedCountsSentinel
/// does not yet exist. Using the named constant would make the entire test
/// target fail to compile pre-fix, so those four gates would never get a
/// chance to demonstrate their assertion failures.
///
/// Data() IS the sentinel value -- the migration writes an empty blob, and
/// the sentinel is defined as empty Data. T5 (in
/// CorpusCountsSentinelPredicateTests.swift) is what formally binds this
/// literal to the named constant: T5 asserts that invalidatedCountsSentinel
/// is empty and that isInvalidatedCounts(Data()) returns true. With T5 in
/// the suite, the contract still has exactly one definition and the names are
/// still pinned.
///
/// Do NOT "tidy" this Data() back into invalidatedCountsSentinel. Doing so
/// would silently destroy the pre-fix behavioural discrimination that this
/// suite is designed to provide. T5's compile-level failure is the correct
/// and intentional gate for the symbol's existence; these four gates are the
/// correct and intentional gates for the behaviour.
private func seedSentinelRow(
    in store: CorpusProviderCountsStore,
    modelID: String, modelVersion: String,
    docCount: Int, vocabSize: Int
) async throws {
    try await store.upsert(PersistedCounts(
        modelID: modelID,
        modelVersion: modelVersion,
        counts: Data(),             // empty blob == sentinel (T5 binds literal to constant)
        documentCount: docCount,
        vocabSize: vocabSize,
        updatedAt: fixedNow))
}

/// Write a corpus_provider_counts row with a valid, non-empty provider blob:
/// an untrained RandomIndexingProvider serialised to its counts format.
/// An untrained RI provider produces a valid magic header plus empty vocabulary,
/// so restore succeeds and returns a present-but-empty provider -- distinct from
/// the sentinel, which means "never had counts, rebuild from zero".
private func seedValidRow(in store: CorpusProviderCountsStore) async throws {
    let provider = RandomIndexingProvider()
    let blob = provider.serializeCounts()
    // A magic header plus an empty map is always non-empty.
    precondition(!blob.isEmpty,
        "serializeCounts on an untrained RI provider must produce a non-empty blob")
    try await store.upsert(PersistedCounts(
        modelID: "random-indexing-v1",
        modelVersion: "1.1.0",
        counts: blob,
        documentCount: 0,
        vocabSize: 0,
        updatedAt: fixedNow))
}

/// Write a corpus_provider_counts row with a non-empty but undecodable blob.
/// "not-a-valid-ri-blob" carries no magic header, so expectMagic rejects it,
/// which is the deliberate loud-failure path for genuine corruption.
private func seedCorruptRow(in store: CorpusProviderCountsStore) async throws {
    try await store.upsert(PersistedCounts(
        modelID: "random-indexing-v1",
        modelVersion: "1.1.0",
        counts: Data("not-a-valid-ri-blob".utf8),
        documentCount: 0,
        vocabSize: 0,
        updatedAt: fixedNow))
}

// ---- Test suite ------------------------------------------------------------

@Suite("CorpusCountsSentinelContract", .serialized)
struct CorpusCountsSentinelContractTests {

    // MARK: - T1: sentinel recovery, no v4 term rows

    /// T1 -- open-path sentinel recovery: an empty-blob post-migration counts row
    /// with no v4 term rows and no v3 vocab rows returns false from restoreCounts,
    /// indicating "nothing stored, start from zero".
    ///
    /// Mirrors Rust t1_sentinel_recovery_no_term_rows.
    ///
    /// Pre-fix (6bdc6071e): compiles (seedSentinelRow uses Data() literal, not
    /// the absent invalidatedCountsSentinel constant). Fails on assertion:
    /// without the sentinel intercept, restoreCounts takes the legacy blob path
    /// and calls provider.restoreCounts(from: emptyData), which calls expectMagic
    /// on an empty slice and throws CorpusKitError.decodingFailure instead of
    /// returning false.
    ///
    /// Post-fix: sentinel intercept fires before any provider call; returns false.
    @Test("T1: sentinel recovery returns false -- no v4 term rows")
    func t1SentinelRecoveryNoTermRows() async throws {
        let storage = try await makeSentinelTestStorage()
        let store = CorpusProviderCountsStore(storage: storage)
        // doc_count=42, vocab_size=17: the monotone anchors the migration preserves.
        try await seedSentinelRow(
            in: store, modelID: "random-indexing-v1", modelVersion: "1.1.0",
            docCount: 42, vocabSize: 17)

        let provider = RandomIndexingProvider()
        let result = try await store.restoreCounts(
            into: provider, modelID: "random-indexing-v1", modelVersion: "1.1.0")

        #expect(
            !result,
            "restoreCounts must return false for a sentinel blob; empty blob is the invalidation signal")
        // The provider must be untouched: zero vocabulary, ready to train from scratch.
        #expect(
            provider.countsVocabularySize == 0,
            "provider vocabulary must be zero after sentinel recovery: no counts were transferred")
        await storage.close()
    }

    // MARK: - T2: sentinel recovery with surviving v4 term residue

    /// T2 -- sentinel recovery when v4 term rows survive the migration.
    ///
    /// The migration does NOT delete corpus_provider_term_dictionary or
    /// corpus_provider_term_payload rows; they can outlive the invalidated blob.
    /// The sentinel intercept must fire BEFORE the v4 branch so the empty blob
    /// never reaches restoreCounts(header:terms:).
    ///
    /// Mirrors Rust t2_sentinel_recovery_with_v4_term_residue.
    ///
    /// Pre-fix (6bdc6071e): compiles. If the sentinel intercept is absent,
    /// restoreCounts calls provider.restoreCounts(header: emptyData, terms: v4Terms),
    /// which calls expectMagic on the empty header and throws decodingFailure.
    ///
    /// Post-fix: sentinel intercept fires before the v4 branch; returns false.
    @Test("T2: sentinel recovery returns false -- even with v4 term residue present")
    func t2SentinelRecoveryWithV4TermResidue() async throws {
        let storage = try await makeSentinelTestStorage()
        let store = CorpusProviderCountsStore(storage: storage)
        try await seedSentinelRow(
            in: store, modelID: "random-indexing-v1", modelVersion: "1.1.0",
            docCount: 10, vocabSize: 5)

        // Seed two surviving v4 term rows, simulating the migration leaving the
        // v4 dictionary/payload pair intact. The migration's scope is the counts
        // blob and vocab table only; the term pair is not touched.
        // 8192 bytes = 2048 f32 per term: the RI term vector width.
        let residueTerms: [(term: String, vector: Data)] = [
            (term: "alpha", vector: Data(repeating: 1, count: 8192)),
            (term: "beta",  vector: Data(repeating: 2, count: 8192))
        ]
        try await store.replaceTermPayloads(
            modelID: "random-indexing-v1", terms: residueTerms, into: storage.rowStore)

        // Confirm the residue is present so the test genuinely covers the v4 branch.
        let preRestoreTerms = try await store.loadTermPayloads(modelID: "random-indexing-v1")
        #expect(
            preRestoreTerms.count == 2,
            "two v4 term rows must be present before the restore to confirm the v4 branch path")

        let provider = RandomIndexingProvider()
        let result = try await store.restoreCounts(
            into: provider, modelID: "random-indexing-v1", modelVersion: "1.1.0")

        #expect(
            !result,
            "restoreCounts must return false even when v4 term rows survive; sentinel check fires before v4 branch")
        #expect(
            provider.countsVocabularySize == 0,
            "provider vocabulary must be zero: sentinel recovery transfers no counts")
        await storage.close()
    }

    // MARK: - T3: no-weakening guard

    /// T3 -- a valid non-empty blob still restores and returns true.
    ///
    /// The sentinel check is narrow: it fires only on the empty sentinel, never
    /// on a real counts blob. If this test begins failing after the sentinel fix,
    /// the fix is too broad and swallows valid blobs.
    ///
    /// Mirrors Rust t3_valid_blob_still_restores.
    ///
    /// Structural gate: passes both pre-fix and post-fix (once the file compiles).
    @Test("T3: valid blob still restores and returns true (structural gate)")
    func t3ValidBlobStillRestores() async throws {
        let storage = try await makeSentinelTestStorage()
        let store = CorpusProviderCountsStore(storage: storage)
        try await seedValidRow(in: store)

        let provider = RandomIndexingProvider()
        let result = try await store.restoreCounts(
            into: provider, modelID: "random-indexing-v1", modelVersion: "1.1.0")

        #expect(
            result,
            "restoreCounts must return true for a valid non-empty blob; sentinel fix must not swallow real counts")
        await storage.close()
    }

    // MARK: - T4: non-empty undecodable blob still errors

    /// T4 -- a non-empty but undecodable blob propagates CorpusKitError.decodingFailure.
    ///
    /// The sentinel check is narrowly (isEmpty only). A non-empty blob with a
    /// corrupt or missing magic header still reaches the provider's expectMagic
    /// and fails loudly. This behaviour is intentional: a loud error is the right
    /// response to genuine corruption -- swallowing it would convert data loss to silence.
    ///
    /// Mirrors Rust t4_non_empty_undecodable_blob_errors.
    ///
    /// Structural gate: passes both pre-fix and post-fix (once the file compiles).
    @Test("T4: non-empty undecodable blob propagates decodingFailure (structural gate)")
    func t4NonEmptyUndecodableBlobErrors() async throws {
        let storage = try await makeSentinelTestStorage()
        let store = CorpusProviderCountsStore(storage: storage)
        try await seedCorruptRow(in: store)

        let provider = RandomIndexingProvider()
        // Must throw CorpusKitError. The sentinel fix must not widen the
        // empty-blob check to cover non-empty corrupt blobs.
        await #expect(throws: CorpusKitError.self) {
            _ = try await store.restoreCounts(
                into: provider, modelID: "random-indexing-v1", modelVersion: "1.1.0")
        }
        await storage.close()
    }

    // MARK: - T6: flush guard preserves sentinel when accumulator is empty

    /// T6 -- the sentinel-preserving flush guard in persistCounts.
    ///
    /// Scenario: after a mootx01 upgrade step the migration writes the sentinel
    /// into corpus_provider_counts.counts. The live accumulator is empty (no new
    /// ingest has run yet). Without the flush guard, persistCounts serialises the
    /// empty provider state into a VALID empty-state blob and writes it over the
    /// sentinel. The restore path then returns true (real counts, albeit empty),
    /// so the caller guard that routes to a full-corpus retrain cannot fire, and a
    /// zero-vocabulary basis is published over the trained basis the migration
    /// deliberately left intact.
    ///
    /// Post-fix: the guard detects (countsVocabularySize == 0 AND sentinel stored)
    /// and returns early, leaving the sentinel intact.
    ///
    /// PpmiProvider is used because it does NOT implement decomposeCounts, so the
    /// else-branch (blob write) is the one the guard protects. RI covers the
    /// decomposeCounts branch in T8.
    ///
    /// Pre-fix (6bdc6071e): compiles (seedSentinelRow uses Data() literal).
    /// Fails on assertion: no flush guard exists -> persistCounts calls
    /// provider.serializeCounts() and writes the resulting non-empty blob over
    /// the sentinel -> storedCounts.isEmpty is false -> assertion fails.
    ///
    /// storedCounts.isEmpty is used directly (not isInvalidatedCounts) so that
    /// this gate compiles against pre-fix source. T5 asserts that isEmpty and
    /// isInvalidatedCounts agree, so the two checks are equivalent post-fix.
    @Test("T6: flush guard preserves sentinel when provider accumulator is empty")
    func t6FlushGuardPreservesSentinelWhenAccumulatorIsEmpty() async throws {
        let storage = try await makeSentinelTestStorage()
        let store = CorpusProviderCountsStore(storage: storage)
        // doc_count=42, vocab_size=17: the growth anchors that must survive.
        try await seedSentinelRow(
            in: store, modelID: "ppmi-v1", modelVersion: "1.1.0",
            docCount: 42, vocabSize: 17)

        // Untrained PPMI provider: zero accumulated vocabulary.
        // PPMI does not implement decomposeCounts, so persistCounts routes to
        // provider.serializeCounts() in the else branch -- the branch the guard protects.
        let provider = PpmiProvider()
        #expect(
            provider.countsVocabularySize == 0,
            "fixture: PpmiProvider must start with zero vocabulary")

        try await store.persistCounts(
            provider: provider,
            modelID: "ppmi-v1",
            modelVersion: "1.1.0",
            documentCount: 0,
            vocabSize: 0,
            updatedAt: fixedNow,
            into: storage.rowStore)

        // Load the stored row and verify the sentinel was NOT overwritten.
        let stored = try await store.load(modelID: "ppmi-v1", modelVersion: "1.1.0")
        let storedCounts = try #require(
            stored?.counts,
            "the counts row must still exist after the suppressed flush")
        // storedCounts.isEmpty is used directly instead of isInvalidatedCounts(_:)
        // so this gate compiles against pre-fix source. T5 proves the two are equivalent.
        #expect(
            storedCounts.isEmpty,
            "persistCounts must leave sentinel intact when countsVocabularySize==0; pre-fix overwrites it")
        await storage.close()
    }

    // MARK: - T7: a non-retrain flush never clears the sentinel

    /// T7 -- an accumulator with vocabulary is NOT enough to clear the sentinel.
    ///
    /// INVERTED when the write-path guard replaced the vocabulary-size guard.
    /// This test previously required a flush with any accumulated term to
    /// overwrite the sentinel, which pinned the defect as intended behaviour:
    /// between the migration and the queued reindex, a single ingest puts a term
    /// in the fresh accumulator, so the flush wrote a PARTIAL counts blob over
    /// the invalidation signal. With the old doc_count anchor preserved, the
    /// population guard could then accept those partial counts as complete and
    /// publish a basis trained only on post-migration content.
    ///
    /// The discriminator is the WRITE PATH: only a full-corpus retrain
    /// (clearsInvalidation: true) may replace the sentinel.
    ///
    /// The guard fires only when countsVocabularySize == 0. A provider that has
    /// accumulated even one term must produce a write regardless of what is stored
    /// on disk. This test pins that the guard cannot accidentally suppress real counts.
    ///
    /// PpmiProvider is used (same as T6) so the two tests together show the guard
    /// no longer turns on the accumulator at all: sentinel preserved whether the
    /// provider is empty (T6) or trained (T7).
    @Test("T7: a non-retrain flush never clears the sentinel, even with vocabulary")
    func t7NonRetrainFlushNeverClearsSentinel() async throws {
        let storage = try await makeSentinelTestStorage()
        let store = CorpusProviderCountsStore(storage: storage)
        // Start with the sentinel so T7 and T6 share the same pre-condition.
        try await seedSentinelRow(
            in: store, modelID: "ppmi-v1", modelVersion: "1.1.0",
            docCount: 0, vocabSize: 0)

        // Train the PPMI provider so it has accumulated vocabulary.
        let provider = PpmiProvider()
        provider.trainOnCorpus(texts: [
            "alpha beta gamma delta",
            "beta gamma epsilon",
            "gamma delta zeta eta"
        ])
        #expect(
            provider.countsVocabularySize > 0,
            "fixture: provider must have accumulated vocabulary after training")

        try await store.persistCounts(
            provider: provider,
            modelID: "ppmi-v1",
            modelVersion: "1.1.0",
            documentCount: 3,
            vocabSize: provider.countsVocabularySize,
            updatedAt: fixedNow,
            into: storage.rowStore)

        // The write must have happened: the stored blob must no longer be the sentinel.
        let stored = try await store.load(modelID: "ppmi-v1", modelVersion: "1.1.0")
        let storedCounts = try #require(
            stored?.counts,
            "counts row must exist after persistCounts with a trained provider")
        #expect(
            CorpusProviderCountsStore.isInvalidatedCounts(storedCounts),
            """
            A trained accumulator is not a licence to clear the sentinel. Only the \
            full-corpus retrain may replace it; every other path leaves the \
            invalidation signal standing so the queued reindex still fires.
            """)
        await storage.close()
    }

    // MARK: - T8: anchors survive sentinel-preserving flush

    /// T8 -- doc_count and vocab_size survive a sentinel-preserving flush.
    ///
    /// The whole reason the migration writes a sentinel instead of deleting the
    /// row is that the doc_count / vocab_size monotone anchors must survive the
    /// rebuild window. If persistCounts overwrites those anchors with the live
    /// accumulator's (zero) values, the governor loses its size estimate.
    ///
    /// RandomIndexingProvider is used (covers the decomposeCounts branch); T6
    /// covers the non-decomposing branch. Together the two tests show the guard
    /// fires regardless of which persistCounts branch the provider triggers.
    ///
    /// Pre-fix (6bdc6071e): compiles (seedSentinelRow uses Data() literal).
    /// Fails on assertions: no flush guard -> persistCounts calls
    /// provider.decomposeCounts() (always non-nil for RI) -> upserts with
    /// documentCount=0, vocabSize=0 -> anchors overwritten -> growthAnchor
    /// returns {0, 0} -> doc_count and vocab_size assertions fail.
    ///
    /// Post-fix: flush guard fires (countsVocabularySize == 0 AND sentinel stored)
    /// -> returns early without writing -> anchors unchanged at {42, 17}.
    @Test("T8: doc_count and vocab_size survive a sentinel-preserving flush")
    func t8AnchorsSurviveSentinelPreservingFlush() async throws {
        let storage = try await makeSentinelTestStorage()
        let store = CorpusProviderCountsStore(storage: storage)
        // doc_count=42, vocab_size=17: the anchors the migration preserves.
        try await seedSentinelRow(
            in: store, modelID: "random-indexing-v1", modelVersion: "1.1.0",
            docCount: 42, vocabSize: 17)

        // Untrained RI provider: zero vocabulary. The guard must intercept this
        // call and skip the flush to preserve the anchors.
        let provider = RandomIndexingProvider()
        #expect(
            provider.countsVocabularySize == 0,
            "fixture: RI provider must start with zero vocabulary")

        try await store.persistCounts(
            provider: provider,
            modelID: "random-indexing-v1",
            modelVersion: "1.1.0",
            documentCount: 0,   // the live-accumulator's (wrong) values that
            vocabSize: 0,       // would overwrite the anchors if the guard did not fire
            updatedAt: fixedNow,
            into: storage.rowStore)

        // The growth anchors must still be 42 and 17, unchanged from the seeded row.
        let anchor = try await store.growthAnchor(
            modelID: "random-indexing-v1", modelVersion: "1.1.0")
        let resolved = try #require(anchor,
            "growthAnchor must be readable after a suppressed flush")
        #expect(
            resolved.documentCount == 42,
            "doc_count must be preserved at 42; pre-fix flush overwrites it with 0")
        #expect(
            resolved.vocabSize == 17,
            "vocab_size must be preserved at 17; pre-fix flush overwrites it with 0")
        await storage.close()
    }
}

#endif // MOOTX01_DENSE_FAMILIES
