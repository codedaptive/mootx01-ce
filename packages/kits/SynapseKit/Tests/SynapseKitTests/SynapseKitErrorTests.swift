import Testing
@testable import SynapseKit

/// Tests for `SynapseKitError` — the kit's structured error enum. Per
/// the MOOTx01 standard, errors are concrete enum cases (never an
/// optional plus a log line), and the type is `Equatable` so callers
/// and tests can match a thrown error against an expected case
/// including its associated value. This suite covers what the existing
/// suites only touch transitively: case-and-payload equality, the
/// distinctness of cases, and `Error` conformance.
@Suite("SynapseKitError")
struct SynapseKitErrorTests {

    /// Same case with the same associated value compares equal — the
    /// property callers rely on when matching `catch` results.
    @Test func testSameCaseSamePayloadAreEqual() {
        #expect(SynapseKitError.embeddingFailed("coreml exploded")
                == SynapseKitError.embeddingFailed("coreml exploded"))
        #expect(SynapseKitError.modelUnavailable("minilm-v6")
                == SynapseKitError.modelUnavailable("minilm-v6"))
        #expect(SynapseKitError.storeUnavailable("disk full")
                == SynapseKitError.storeUnavailable("disk full"))
    }

    /// Same case with a different associated value compares unequal —
    /// the payload participates in equality, it is not ignored.
    @Test func testSameCaseDifferentPayloadAreNotEqual() {
        #expect(SynapseKitError.embeddingFailed("reason A")
                != SynapseKitError.embeddingFailed("reason B"))
        #expect(SynapseKitError.modelUnavailable("minilm")
                != SynapseKitError.modelUnavailable("gemma"))
    }

    /// Different cases never compare equal, even when one carries a
    /// payload string equal to another case's name.
    @Test func testDifferentCasesAreNotEqual() {
        #expect(SynapseKitError.embeddingFailed("x")
                != SynapseKitError.storeUnavailable("x"))
        #expect(SynapseKitError.modelUnavailable("notFound")
                != SynapseKitError.notFound)
    }

    /// The payload-free `.notFound` case is equal to itself.
    @Test func testNotFoundEqualsItself() {
        #expect(SynapseKitError.notFound == SynapseKitError.notFound)
    }

    /// `SynapseKitError` is a usable `Error`: it can be thrown and
    /// caught, and the caught value round-trips to the original case
    /// with its associated value intact.
    @Test func testIsThrowableErrorAndPreservesPayload() {
        func boom() throws { throw SynapseKitError.embeddingFailed("inference timed out") }
        #expect(throws: SynapseKitError.embeddingFailed("inference timed out")) {
            try boom()
        }
        do {
            try boom()
            Issue.record("expected SynapseKitError to be thrown")
        } catch let error as SynapseKitError {
            #expect(error == .embeddingFailed("inference timed out"))
        } catch {
            Issue.record("caught unexpected error type: \(error)")
        }
    }
}
