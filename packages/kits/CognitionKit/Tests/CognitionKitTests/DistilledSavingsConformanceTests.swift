// DistilledSavingsConformanceTests.swift
//
// Shared-vector conformance gate for DistilledSavings.
//
// Both this suite and the Rust `distilled_savings_conformance` test read
// Tests/CognitionKitTests/Fixtures/distilled_savings_vectors.json, sum the
// per-case records, call `DistilledSavings.measure`, and compare the full
// result against the decoded `expected` struct. A mismatch in either port
// is a cross-port drift signal.
//
// The expected objects in the fixture ARE `DistilledSavings` values; they
// are decoded directly as that type so the fixture is the wire contract.

import Testing
import Foundation
@testable import CognitionKit

// MARK: - Fixture schema

private struct FixtureRecord: Decodable {
    let distilledTokens: Int64
    let originalTokens: Int64
}

private struct FixtureCase: Decodable {
    let name: String
    let records: [FixtureRecord]
    let skimOmittedTokens: Int64?
    /// Decoded directly as DistilledSavings: the fixture IS the wire contract.
    let expected: DistilledSavings
}

private struct DistilledSavingsFixture: Decodable {
    let cases: [FixtureCase]
    let purpose: String
}

// MARK: - Gate

@Suite("DistilledSavingsConformanceTests: shared vector gate")
struct DistilledSavingsConformanceTests {

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/distilled_savings_vectors.json")
    }

    private func load() throws -> DistilledSavingsFixture {
        let data = try Data(contentsOf: Self.fixtureURL)
        return try JSONDecoder().decode(DistilledSavingsFixture.self, from: data)
    }

    // MARK: Fixture cases

    @Test("every fixture case reproduces the expected DistilledSavings")
    func fixtureVectorsReproduce() throws {
        let fixture = try load()
        for c in fixture.cases {
            let totalDistilled = c.records.map(\.distilledTokens).reduce(0, +)
            let totalOriginal  = c.records.map(\.originalTokens).reduce(0, +)
            let result = DistilledSavings.measure(
                originalTokens: totalOriginal,
                distilledTokens: totalDistilled,
                skimOmittedTokens: c.skimOmittedTokens)
            #expect(result == c.expected,
                "case \(c.name): computed DistilledSavings must equal the fixture expected")
        }
    }

    // MARK: Encoding: skim absent means no skim key in JSON

    @Test("encoding a no-skim savings omits the skim key")
    func encodingSkimAbsentOmitsKey() throws {
        let s = DistilledSavings.measure(
            originalTokens: 1000, distilledTokens: 800, skimOmittedTokens: nil)
        #expect(s.skim == nil)
        let data = try JSONEncoder().encode(s)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"skim\""),
            "skim key must be absent from JSON when skim is nil")
    }

    // MARK: Round-trip

    @Test("DistilledSavings round-trips through JSON with and without skim")
    func jsonRoundTrip() throws {
        // With skim
        let withSkim = DistilledSavings.measure(
            originalTokens: 2000, distilledTokens: 1200, skimOmittedTokens: 700)
        let data1 = try JSONEncoder().encode(withSkim)
        let back1 = try JSONDecoder().decode(DistilledSavings.self, from: data1)
        #expect(back1 == withSkim, "round-trip with skim must be lossless")

        // Without skim
        let noSkim = DistilledSavings.measure(
            originalTokens: 2000, distilledTokens: 1200, skimOmittedTokens: nil)
        let data2 = try JSONEncoder().encode(noSkim)
        let back2 = try JSONDecoder().decode(DistilledSavings.self, from: data2)
        #expect(back2 == noSkim, "round-trip without skim must be lossless")
    }

    // MARK: Rounding unit tests (beyond the fixture)

    @Test("rounding half-away-from-zero: original=3 distilled=2 -> savedPercent=33")
    func rounding33() {
        let s = DistilledSavings.measure(originalTokens: 3, distilledTokens: 2, skimOmittedTokens: nil)
        #expect(s.savedPercent == 33)
    }

    @Test("rounding half-away-from-zero: original=3 distilled=1 -> savedPercent=67")
    func rounding67() {
        let s = DistilledSavings.measure(originalTokens: 3, distilledTokens: 1, skimOmittedTokens: nil)
        #expect(s.savedPercent == 67)
    }

    @Test("rounding negative: original=2 distilled=3 -> savedPercent=-50")
    func roundingNegative50() {
        let s = DistilledSavings.measure(originalTokens: 2, distilledTokens: 3, skimOmittedTokens: nil)
        #expect(s.savedPercent == -50)
    }

    @Test("rounding 0.5 rounds away from zero to 1: original=200 distilled=199 -> savedPercent=1")
    func roundingHalfUp() {
        let s = DistilledSavings.measure(originalTokens: 200, distilledTokens: 199, skimOmittedTokens: nil)
        #expect(s.savedPercent == 1)
    }

    @Test("rounding -0.5 rounds away from zero to -1: original=200 distilled=201 -> savedPercent=-1")
    func roundingHalfDown() {
        let s = DistilledSavings.measure(originalTokens: 200, distilledTokens: 201, skimOmittedTokens: nil)
        #expect(s.savedPercent == -1)
    }
}
