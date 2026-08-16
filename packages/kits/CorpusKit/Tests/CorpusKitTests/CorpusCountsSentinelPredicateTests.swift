// CorpusCountsSentinelPredicateTests.swift
//
// MG-02 predicate gate: T5 (sentinel predicate self-check), isolated from the
// behavioural gates in CorpusCountsSentinelContractTests.swift.
//
// WHY THIS IS A SEPARATE FILE:
// T5 names two production symbols that do not exist at the pre-fix SHA
// (6bdc6071e):
//   CorpusProviderCountsStore.invalidatedCountsSentinel
//   CorpusProviderCountsStore.isInvalidatedCounts(_:)
//
// Keeping T5 in the main file would prevent the entire test target from
// compiling against pre-fix source, turning T1/T2/T6/T8 from assertion
// failures into compile failures. Those four gates must fail on their
// assertions (missing sentinel intercept, missing flush guard) to constitute
// strong behavioural evidence. A compile failure only shows the API changed,
// not that the behaviour did.
//
// T5's compile failure against pre-fix source IS a legitimate gate: it
// proves that invalidatedCountsSentinel and isInvalidatedCounts did not
// exist. Running this file alone against pre-fix source will produce a
// compile error; that is the expected and correct outcome for T5.
//
// T5 is also what licenses the Data() literal in seedSentinelRow (in
// CorpusCountsSentinelContractTests.swift): T5 asserts that
// invalidatedCountsSentinel is empty Data and that isInvalidatedCounts
// returns true for it. With T5 in the suite, the contract has exactly one
// canonical definition, and the literal in seedSentinelRow cannot drift
// without T5 catching it.
//
// Mirrors Rust sentinel_predicate_is_consistent.

import Foundation
import Testing

@testable import CorpusKit

// ---- Test suite ------------------------------------------------------------

@Suite("CorpusCountsSentinelPredicate")
struct CorpusCountsSentinelPredicateTests {

    // MARK: - T5: sentinel predicate self-check

    /// T5 -- the sentinel predicate is consistent with the migration's write pattern.
    ///
    /// Pins the shared contract so a future format change (e.g. a 4-byte magic
    /// header on the sentinel) requires a deliberate, reviewed decision and cannot
    /// happen silently. Also licenses the Data() literal in seedSentinelRow:
    /// because T5 asserts that invalidatedCountsSentinel == Data() (isEmpty is
    /// true) and isInvalidatedCounts(Data()) == true, the behavioural gates may
    /// seed with the literal and remain correct.
    ///
    /// Pre-fix (6bdc6071e): fails to compile -- invalidatedCountsSentinel and
    /// isInvalidatedCounts are the production symbols this mission adds.
    /// This compile failure is the correct and expected gate for symbol existence.
    ///
    /// Post-fix: all four assertions pass.
    @Test("T5: sentinel predicate is consistent with the migration's write contract")
    func t5SentinelPredicateIsConsistent() {
        // The sentinel is empty Data -- migration writes TypedValue.blob(Data()).
        #expect(
            CorpusProviderCountsStore.invalidatedCountsSentinel.isEmpty,
            "invalidatedCountsSentinel must be empty Data, matching the migration's write")

        #expect(
            CorpusProviderCountsStore.isInvalidatedCounts(
                CorpusProviderCountsStore.invalidatedCountsSentinel),
            "isInvalidatedCounts(invalidatedCountsSentinel) must return true")

        // A one-byte slice is NOT the sentinel: non-empty means real data.
        #expect(
            !CorpusProviderCountsStore.isInvalidatedCounts(Data([0])),
            "isInvalidatedCounts must return false for any non-empty byte sequence")

        // A realistic magic header prefix is NOT the sentinel.
        #expect(
            !CorpusProviderCountsStore.isInvalidatedCounts(Data("RICT1".utf8)),
            "isInvalidatedCounts must return false for a non-empty blob")
    }
}
