// CorpusKitErrorTests.swift
//
// Peer suite for CorpusKitError (Sources/CorpusKit/CorpusKitError.swift).
// The error enum is Equatable and Sendable; each case carries a
// diagnostic String. These assertions pin the Equatable contract the
// kit relies on for error matching, and confirm Error conformance.

import Testing
@testable import CorpusKit

@Suite("CorpusKitError")
struct CorpusKitErrorTests {

    @Test func equalWhenSameCaseAndPayload() {
        #expect(CorpusKitError.encodingFailure("x") == .encodingFailure("x"))
        #expect(CorpusKitError.storeUnavailable("db") == .storeUnavailable("db"))
    }

    @Test func notEqualWhenPayloadDiffers() {
        #expect(CorpusKitError.decodingFailure("a") != .decodingFailure("b"))
    }

    @Test func notEqualWhenCaseDiffers() {
        #expect(CorpusKitError.tokenizerUnavailable("t") != .modelUnavailable("t"))
        #expect(CorpusKitError.embeddingFailed("e") != .storeUnavailable("e"))
    }

    @Test func payloadIsPreserved() {
        let e = CorpusKitError.modelUnavailable("MiniLM-L6")
        guard case let .modelUnavailable(message) = e else {
            Issue.record("expected .modelUnavailable case")
            return
        }
        #expect(message == "MiniLM-L6")
    }

    @Test func conformsToError() {
        let thrown: Error = CorpusKitError.embeddingFailed("boom")
        #expect(thrown as? CorpusKitError == .embeddingFailed("boom"))
    }
}
