// TunnelReviewLedgerTests.swift
//
// MXE-CT3 P2.5 — codec tests for the tunnel ext review ledger.
// The GOLDEN fixture below is duplicated VERBATIM in the Rust twin
// (`tunnel_review_ledger.rs::tests::GOLDEN`); the pair of tests is the
// cross-port byte-identity gate for canonical serialization.

import Foundation
import Testing
@testable import LocusKit

@Suite("TunnelReviewLedgerTests")
struct TunnelReviewLedgerTests {

    /// MUST match Rust `tunnel_review_ledger::tests::GOLDEN` byte-for-byte.
    static let golden = "{\"endorsements\":[{\"at\":\"2026-08-07T12:00:00Z\",\"by\":\"apple-onboard\",\"tier\":2},{\"at\":\"2026-08-07T12:05:00Z\",\"by\":\"claude\",\"tier\":3}],\"objections\":[{\"at\":\"2026-08-07T12:10:00Z\",\"by\":\"dream-adjudicator@1\",\"tier\":2}],\"reviewedBy\":\"owner\",\"zFuture\":{\"keep\":true}}"

    @Test("golden fixture bytes — canonical serialization is byte-identical to the Rust port")
    func goldenFixtureBytes() throws {
        var ledger = try TunnelReviewLedger.parse("{\"zFuture\":{\"keep\":true}}")
        // Recorded out of order on purpose: canonical output must sort.
        ledger.recordEndorsement(by: "claude", atISO: "2026-08-07T12:05:00Z", tier: 3)
        ledger.recordEndorsement(by: "apple-onboard", atISO: "2026-08-07T12:00:00Z", tier: 2)
        ledger.recordObjection(by: "dream-adjudicator@1", atISO: "2026-08-07T12:10:00Z", tier: 2)
        ledger.recordReview(by: "owner")
        #expect(ledger.serialized() == Self.golden)
    }

    @Test("round-trip preserves unknown keys and content")
    func roundTripPreservesUnknownKeys() throws {
        let parsed = try TunnelReviewLedger.parse(Self.golden)
        #expect(parsed.serialized() == Self.golden)
        #expect(parsed.distinctEndorserCount == 2)
        #expect(parsed.isContestedEvidence)
        #expect(parsed.reviewedBy == "owner")
        #expect(parsed.latestActivityISO == "2026-08-07T12:10:00Z")
    }

    @Test("nil and blank ext parse to the empty ledger; empty ledger serializes to nil")
    func emptyLedger() throws {
        #expect(try TunnelReviewLedger.parse(nil).serialized() == nil)
        #expect(try TunnelReviewLedger.parse("  ").serialized() == nil)
    }

    @Test("endorsement is idempotent per endorser — one vote, timestamp refresh")
    func endorsementIdempotent() {
        var ledger = TunnelReviewLedger()
        let first = ledger.recordEndorsement(by: "claude", atISO: "2026-08-07T12:00:00Z", tier: 2)
        let repeat_ = ledger.recordEndorsement(by: "claude", atISO: "2026-08-07T13:00:00Z", tier: 2)
        #expect(first)
        #expect(!repeat_)
        #expect(ledger.distinctEndorserCount == 1)
        #expect(ledger.endorsements.first?.atISO == "2026-08-07T13:00:00Z")
    }

    @Test("malformed ext fails loud with a structured error")
    func malformedFailsLoud() {
        #expect(throws: LocusKitError.self) { _ = try TunnelReviewLedger.parse("not json {") }
        #expect(throws: LocusKitError.self) { _ = try TunnelReviewLedger.parse("[1,2]") }
        #expect(throws: LocusKitError.self) {
            _ = try TunnelReviewLedger.parse("{\"endorsements\":\"nope\"}")
        }
        #expect(throws: LocusKitError.self) {
            _ = try TunnelReviewLedger.parse("{\"reviewedBy\":7}")
        }
    }

    @Test("canonical ISO timestamps match known instants (shared civil algorithm)")
    func isoKnownInstants() {
        #expect(TunnelReviewLedger.isoTimestamp(epochSeconds: 0) == "1970-01-01T00:00:00Z")
        #expect(TunnelReviewLedger.isoTimestamp(epochSeconds: 1_700_000_000)
            == "2023-11-14T22:13:20Z")
        // Leap-year day.
        #expect(TunnelReviewLedger.isoTimestamp(epochSeconds: 1_709_164_800)
            == "2024-02-29T00:00:00Z")
        // Pre-epoch (euclidean division correctness).
        #expect(TunnelReviewLedger.isoTimestamp(epochSeconds: -1) == "1969-12-31T23:59:59Z")
        // Date entry point floors sub-second instants.
        #expect(TunnelReviewLedger.isoTimestamp(
            Date(timeIntervalSince1970: 1_700_000_000.9)) == "2023-11-14T22:13:20Z")
    }

    @Test("string escaping matches the cross-port contract")
    func escapingContract() {
        var ledger = TunnelReviewLedger()
        ledger.recordReview(by: "a\"b\\c\nd\u{01}")
        #expect(ledger.serialized() == "{\"reviewedBy\":\"a\\\"b\\\\c\\nd\\u0001\"}")
    }
}
