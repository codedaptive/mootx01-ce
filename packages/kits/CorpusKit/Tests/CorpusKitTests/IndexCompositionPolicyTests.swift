// IndexCompositionPolicyTests.swift
//
// CDL-03: the named index composition policy — which text each derived lane
// (BM25 lexical, dense float) consumes — is a first-class, recorded value.
// These tests pin the id format (the persistence anchor stored in
// `corpus_index_state.composition_policy`), the MOOT_INDEX_COMPOSITION
// parser, the adornment-need predicates, Codable round-trip, and the
// mismatch check the engine runs at open.
//
// Rust twin: rust/src/index_composition_policy.rs (unit tests in-module).

import Foundation
import Testing
@testable import CorpusKit

@Suite("IndexCompositionPolicy — id format and named cells")
struct IndexCompositionPolicyIDTests {

    @Test("cell A (.current) id is lex=original;dense=distilled")
    func currentID() {
        #expect(IndexCompositionPolicy.current.id == "lex=original;dense=distilled")
        #expect(IndexCompositionPolicy.current.lexicalSource == .original)
        #expect(IndexCompositionPolicy.current.denseSource == .distilled)
    }

    @Test("every named cell has the documented id")
    func namedCellIDs() {
        #expect(IndexCompositionPolicy.lexicalAdornments.id
                == "lex=originalPlusAdornments;dense=distilled")
        #expect(IndexCompositionPolicy.denseAdornments.id
                == "lex=original;dense=distilledPlusAdornments")
        #expect(IndexCompositionPolicy.bothAdornments.id
                == "lex=originalPlusAdornments;dense=distilledPlusAdornments")
        #expect(IndexCompositionPolicy.lexicalBaseline.id
                == "lex=original;dense=original")
    }

    @Test("ids are distinct across the full lexical x dense product")
    func idsDistinct() {
        var seen = Set<String>()
        for lex in LexicalIndexSource.allCases {
            for dense in DenseIndexSource.allCases {
                let id = IndexCompositionPolicy(lexicalSource: lex, denseSource: dense).id
                #expect(seen.insert(id).inserted, "duplicate id \(id)")
            }
        }
        #expect(seen.count == LexicalIndexSource.allCases.count * DenseIndexSource.allCases.count)
    }
}

@Suite("IndexCompositionPolicy — MOOT_INDEX_COMPOSITION parser")
struct IndexCompositionPolicyParseTests {

    @Test("every named cell round-trips through fromEnvironmentValue")
    func roundTripNamed() {
        let named: [IndexCompositionPolicy] = [
            .current, .lexicalAdornments, .denseAdornments, .bothAdornments, .lexicalBaseline,
        ]
        for policy in named {
            #expect(IndexCompositionPolicy.fromEnvironmentValue(policy.id) == policy)
        }
    }

    @Test("every lexical x dense combination round-trips")
    func roundTripProduct() {
        for lex in LexicalIndexSource.allCases {
            for dense in DenseIndexSource.allCases {
                let policy = IndexCompositionPolicy(lexicalSource: lex, denseSource: dense)
                #expect(IndexCompositionPolicy.fromEnvironmentValue(policy.id) == policy)
            }
        }
    }

    @Test("malformed values return nil, never a silent default",
          arguments: [
            "", "original", "lex=original", "dense=distilled",
            "lex=original;dense=", "lex=;dense=distilled",
            "lex=Original;dense=distilled",          // case-sensitive rawValues
            "lex=original;dense=distilled;extra=1",  // exactly two parts
            "dense=distilled;lex=original",          // fixed order
            "lex=original,dense=distilled",          // ';' separator only
            "lex=unknown;dense=distilled",
            "lex=original;dense=unknown",
          ])
    func malformedIsNil(value: String) {
        #expect(IndexCompositionPolicy.fromEnvironmentValue(value) == nil)
    }
}

@Suite("IndexCompositionPolicy — adornment need predicates")
struct IndexCompositionPolicyNeedTests {

    @Test("cell A needs no adornments (no store read on the default path)")
    func currentNeedsNone() {
        #expect(!IndexCompositionPolicy.current.lexicalNeedsAdornments)
        #expect(!IndexCompositionPolicy.current.denseNeedsAdornments)
        #expect(!IndexCompositionPolicy.current.needsAdornments)
    }

    @Test("lexical-only, dense-only, and both")
    func perLane() {
        #expect(IndexCompositionPolicy.lexicalAdornments.lexicalNeedsAdornments)
        #expect(!IndexCompositionPolicy.lexicalAdornments.denseNeedsAdornments)
        #expect(!IndexCompositionPolicy.denseAdornments.lexicalNeedsAdornments)
        #expect(IndexCompositionPolicy.denseAdornments.denseNeedsAdornments)
        #expect(IndexCompositionPolicy.bothAdornments.needsAdornments)
        #expect(!IndexCompositionPolicy.lexicalBaseline.needsAdornments)
        // distilledPlusAdornments on the lexical lane also needs adornments.
        #expect(IndexCompositionPolicy(
            lexicalSource: .distilledPlusAdornments, denseSource: .distilled
        ).lexicalNeedsAdornments)
    }
}

@Suite("IndexCompositionPolicy — Codable")
struct IndexCompositionPolicyCodableTests {

    @Test("JSON round-trip preserves the policy and uses the enum rawValues")
    func jsonRoundTrip() throws {
        let policy = IndexCompositionPolicy.bothAdornments
        let data = try JSONEncoder().encode(policy)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"originalPlusAdornments\""))
        #expect(json.contains("\"distilledPlusAdornments\""))
        let decoded = try JSONDecoder().decode(IndexCompositionPolicy.self, from: data)
        #expect(decoded == policy)
        #expect(decoded.id == policy.id)
    }
}

@Suite("IndexCompositionPolicy — recorded-vs-configured mismatch at open")
struct IndexCompositionPolicyMismatchTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// An active, lexically-indexed state row written under `policyID`.
    private static func activeRow(_ id: String, policyID: String) -> CorpusIndexState {
        CorpusIndexState(
            contentID: id, revision: 1, digest: CorpusContentDigest.digest(id),
            indexVersion: 1, appliedCursor: nil, updatedAt: now,
            operationalBitmap: indexBitLexicallyIndexed,
            compositionPolicyID: policyID)
    }

    private static func store() async throws -> CorpusIndexStateStore {
        let storage = try makeScratchStorage()
        try await storage.migrate(to: CorpusIndexStateStore.schemaDeclaration)
        return CorpusIndexStateStore(storage: storage)
    }

    @Test("fresh estate (no rows) never mismatches")
    func freshEstate() async throws {
        let store = try await Self.store()
        #expect(try await store.mismatchedCompositionPolicy(
            configuredPolicyID: IndexCompositionPolicy.bothAdornments.id) == nil)
    }

    @Test("rows stamped with the configured policy agree")
    func agreeingRows() async throws {
        let store = try await Self.store()
        let id = IndexCompositionPolicy.lexicalAdornments.id
        try await store.advance(Self.activeRow("d1", policyID: id))
        try await store.advance(Self.activeRow("d2", policyID: id))
        #expect(try await store.mismatchedCompositionPolicy(configuredPolicyID: id) == nil)
    }

    @Test("a row stamped under another policy is reported, not silently served")
    func disagreeingRow() async throws {
        let store = try await Self.store()
        try await store.advance(Self.activeRow(
            "d1", policyID: IndexCompositionPolicy.current.id))
        try await store.advance(Self.activeRow(
            "d2", policyID: IndexCompositionPolicy.denseAdornments.id))
        let recorded = try await store.mismatchedCompositionPolicy(
            configuredPolicyID: IndexCompositionPolicy.current.id)
        #expect(recorded == IndexCompositionPolicy.denseAdornments.id)
    }

    @Test("pre-CDL-03 rows (empty policy) read as .current")
    func preCDL03RowsAreCurrent() async throws {
        let store = try await Self.store()
        try await store.advance(Self.activeRow("d1", policyID: ""))
        // Configured .current: the legacy row agrees.
        #expect(try await store.mismatchedCompositionPolicy(
            configuredPolicyID: IndexCompositionPolicy.current.id) == nil)
        // Configured anything else: the legacy row is reported as .current.
        #expect(try await store.mismatchedCompositionPolicy(
            configuredPolicyID: IndexCompositionPolicy.bothAdornments.id)
            == IndexCompositionPolicy.current.id)
    }

    @Test("removed and never-indexed rows do not participate")
    func inactiveRowsIgnored() async throws {
        let store = try await Self.store()
        // Never lexically indexed (bitmap 0): ignored.
        try await store.advance(CorpusIndexState(
            contentID: "d1", revision: 1, digest: CorpusContentDigest.digest("d1"),
            indexVersion: 1, appliedCursor: nil, updatedAt: Self.now,
            operationalBitmap: 0,
            compositionPolicyID: IndexCompositionPolicy.bothAdornments.id))
        // Indexed then removed: ignored.
        try await store.advance(CorpusIndexState(
            contentID: "d2", revision: 1, digest: CorpusContentDigest.digest("d2"),
            indexVersion: 1, appliedCursor: nil, updatedAt: Self.now,
            operationalBitmap: indexBitLexicallyIndexed | indexBitRemoved,
            compositionPolicyID: IndexCompositionPolicy.bothAdornments.id))
        #expect(try await store.mismatchedCompositionPolicy(
            configuredPolicyID: IndexCompositionPolicy.current.id) == nil)
    }

    @Test("the engine surfaces the mismatch as a structured CorpusKitError case")
    func errorCaseExists() {
        let error = CorpusKitError.compositionPolicyMismatch("recorded=x;configured=y")
        if case let .compositionPolicyMismatch(detail) = error {
            #expect(detail.contains("recorded=x"))
        } else {
            Issue.record("expected compositionPolicyMismatch")
        }
    }
}
