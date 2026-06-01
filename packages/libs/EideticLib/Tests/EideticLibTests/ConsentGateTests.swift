// ConsentGateTests.swift
//
// Verifies the consent gate is logged and unskippable: no fetch
// runs without a recorded ConsentRecord, every acceptance is in
// the ledger, and consent is per-scheme.

import Testing
import Foundation
@testable import EideticLib

@Suite("Consent gate")
struct ConsentGateTests {

    @Test("gate denies without consent")
    func gateDeniesWithoutConsent() async {
        let gate = ActivationConsent()
        let granted = await gate.verifyConsent(forScheme: "wikidata")
        #expect(!granted)
    }

    @Test("acceptance is recorded in ledger")
    func acceptanceIsRecordedInLedger() async {
        let gate = ActivationConsent()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recorded = await gate.accept(
            schemeID: "wikidata",
            licenseTextDigest: "abc123",
            now: now
        )
        #expect(recorded.schemeID == "wikidata")
        #expect(recorded.licenseTextDigest == "abc123")
        #expect(recorded.acceptedAt == now)

        let granted = await gate.verifyConsent(forScheme: "wikidata")
        #expect(granted)
    }

    @Test("consent is per scheme")
    func consentIsPerScheme() async {
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
        #expect(wikidata)
        #expect(!lcsh)
    }

    @Test("re-acceptance updates record")
    func reAcceptanceUpdatesRecord() async {
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
        #expect(record?.licenseTextDigest == "digest-v2")
        #expect(record?.acceptedAt == t2)
    }

    @Test("ledger records are Codable")
    func ledgerRecordsAreCodable() throws {
        let record = ConsentRecord(
            schemeID: "wikidata",
            licenseTextDigest: "abc123",
            acceptedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ConsentRecord.self, from: data)
        #expect(decoded == record)
    }
}
