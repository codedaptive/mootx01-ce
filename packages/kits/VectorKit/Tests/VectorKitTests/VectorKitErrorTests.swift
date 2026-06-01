import Testing
@testable import VectorKit

/// Tests for `VectorKitError` — the kit's structured error enum. Per
/// the MOOTx01 standard, errors are concrete enum cases (never an
/// optional plus a log line), and the type is `Equatable` so callers
/// and tests can match a thrown error against an expected case
/// including its associated value. This suite covers what the existing
/// suites only touch transitively: case-and-payload equality, the
/// distinctness of cases, and `Error` conformance.
@Suite("VectorKitError")
struct VectorKitErrorTests {

    /// Same case with the same associated value compares equal — the
    /// property callers rely on when matching `catch` results.
    @Test func testSameCaseSamePayloadAreEqual() {
        #expect(VectorKitError.embeddingFailed("coreml exploded")
                == VectorKitError.embeddingFailed("coreml exploded"))
        #expect(VectorKitError.modelUnavailable("minilm-v6")
                == VectorKitError.modelUnavailable("minilm-v6"))
        #expect(VectorKitError.storeUnavailable("disk full")
                == VectorKitError.storeUnavailable("disk full"))
    }

    /// Same case with a different associated value compares unequal —
    /// the payload participates in equality, it is not ignored.
    @Test func testSameCaseDifferentPayloadAreNotEqual() {
        #expect(VectorKitError.embeddingFailed("reason A")
                != VectorKitError.embeddingFailed("reason B"))
        #expect(VectorKitError.modelUnavailable("minilm")
                != VectorKitError.modelUnavailable("gemma"))
    }

    /// Different cases never compare equal, even when one carries a
    /// payload string equal to another case's name.
    @Test func testDifferentCasesAreNotEqual() {
        #expect(VectorKitError.embeddingFailed("x")
                != VectorKitError.storeUnavailable("x"))
        #expect(VectorKitError.modelUnavailable("notFound")
                != VectorKitError.notFound)
    }

    /// The payload-free `.notFound` case is equal to itself.
    @Test func testNotFoundEqualsItself() {
        #expect(VectorKitError.notFound == VectorKitError.notFound)
    }

    /// `VectorKitError` is a usable `Error`: it can be thrown and
    /// caught, and the caught value round-trips to the original case
    /// with its associated value intact.
    @Test func testIsThrowableErrorAndPreservesPayload() {
        func boom() throws { throw VectorKitError.embeddingFailed("inference timed out") }
        #expect(throws: VectorKitError.embeddingFailed("inference timed out")) {
            try boom()
        }
        do {
            try boom()
            Issue.record("expected VectorKitError to be thrown")
        } catch let error as VectorKitError {
            #expect(error == .embeddingFailed("inference timed out"))
        } catch {
            Issue.record("caught unexpected error type: \(error)")
        }
    }
}
