// ConsentGateTests.swift
//
// Verifies the consent gate is logged and unskippable: no fetch
// runs without a recorded ConsentRecord, every acceptance is in
// the ledger, and consent is per-scheme.

import XCTest
@testable import EideticLib

final class ConsentGateTests: XCTestCase {

    func testGateDeniesWithoutConsent() async {
        let gate = ActivationConsent()
        let granted = await gate.verifyConsent(forScheme: "wikidata")
        XCTAssertFalse(granted)
    }

    func testAcceptanceIsRecordedInLedger() async {
        let gate = ActivationConsent()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recorded = await gate.accept(
            schemeID: "wikidata",
            licenseTextDigest: "abc123",
            now: now
        )
        XCTAssertEqual(recorded.schemeID, "wikidata")
        XCTAssertEqual(recorded.licenseTextDigest, "abc123")
        XCTAssertEqual(recorded.acceptedAt, now)

        let granted = await gate.verifyConsent(forScheme: "wikidata")
        XCTAssertTrue(granted)
    }

    func testConsentIsPerScheme() async {
        let gate = ActivationConsent()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await gate.accept(
            schemeID: "wikidata",
            licenseTextDigest: "abc",
            now: now
        )
        // Granting Wikidata does not grant LCSH.
        let wikidata = await gate.verifyConsent(forScheme: "wikidata")
        let lcsh = await gate.verifyConsent(forScheme: "lcsh")
        XCTAssertTrue(wikidata)
        XCTAssertFalse(lcsh)
    }

    func testReAcceptanceUpdatesRecord() async {
        let gate = ActivationConsent()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await gate.accept(
            schemeID: "ddc",
            licenseTextDigest: "digest-v1",
            now: t1
        )
        _ = await gate.accept(
            schemeID: "ddc",
            licenseTextDigest: "digest-v2",
            now: t2
        )
        let record = await gate.ledger.consent(forScheme: "ddc")
        XCTAssertEqual(record?.licenseTextDigest, "digest-v2")
        XCTAssertEqual(record?.acceptedAt, t2)
    }

    func testLedgerRecordsAreCodable() throws {
        let record = ConsentRecord(
            schemeID: "wikidata",
            licenseTextDigest: "abc123",
            acceptedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ConsentRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }
}
