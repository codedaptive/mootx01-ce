import Testing
import Foundation
@testable import mcp_benchmarker

// PayloadArmTests — unit tests for the payload-economics shape-variant arms
// (PAYLOAD-ARMS). One fixed 6-column ruled row is pushed through every arm
// and the documented field subset is asserted verbatim. The arms are a
// HARNESS-SIDE post-process of the full ruled ARIA 2.0.0 payload; the
// product payload never changes, so the fixture row here IS the contract
// shape (`<UUID> · <subject> · <bestSpan> · <sscFacts> · <eventTime> ·
// <score>`, separator space-middledot-space U+00B7; S2 rows carry 5 columns
// with score absent).

@Suite("PayloadArm — shape-variant stripping")
struct PayloadArmTests {

    /// The fixed full ruled row (S1, 6 columns) used by every arm assertion.
    static let row = "0B1F4C2A-9D8E-4F00-B2C3-A5D6E7F80912 \u{00B7} kettle descaling schedule \u{00B7} The kettle needs descaling every six weeks. \u{00B7} SSC17 \u{00B7} 2026-08-01T09:30:00Z \u{00B7} 0.9312"

    @Test("v0 keeps uuid+subject+eventTime+score; sentinels bestSpan and sscFacts")
    func v0Floor() {
        #expect(PayloadArm.v0.strip(row: Self.row) ==
            "0B1F4C2A-9D8E-4F00-B2C3-A5D6E7F80912 \u{00B7} kettle descaling schedule \u{00B7} - \u{00B7} - \u{00B7} 2026-08-01T09:30:00Z \u{00B7} 0.9312")
    }

    @Test("v1 adds bestSpan to the floor; only sscFacts sentineled")
    func v1BestSpan() {
        #expect(PayloadArm.v1.strip(row: Self.row) ==
            "0B1F4C2A-9D8E-4F00-B2C3-A5D6E7F80912 \u{00B7} kettle descaling schedule \u{00B7} The kettle needs descaling every six weeks. \u{00B7} - \u{00B7} 2026-08-01T09:30:00Z \u{00B7} 0.9312")
    }

    @Test("v4 is the identity transform (full ruled row)")
    func v4Identity() {
        #expect(PayloadArm.v4.strip(row: Self.row) == Self.row)
    }

    @Test("v5 keeps rows whole but suppresses control lines")
    func v5ControlLines() {
        let payload = "found 1 candidate memories, one per line\n\(Self.row)"
        #expect(PayloadArm.v5.apply(toPayload: payload) == Self.row)
        // The row itself is never stripped under v5.
        #expect(PayloadArm.v5.strip(row: Self.row) == Self.row)
    }

    @Test("v5 leaves a payload with no dense rows untouched (hydrated bodies)")
    func v5NoRowsPassthrough() {
        let hydrated = "Full memory body text.\nSecond line of the body."
        #expect(PayloadArm.v5.apply(toPayload: hydrated) == hydrated)
    }

    @Test("non-row lines pass through v0-v4 payload application")
    func controlLinesKeptBelowV5() {
        let payload = "found 1 candidate memories, one per line\n\(Self.row)"
        let out = PayloadArm.v0.apply(toPayload: payload)
        #expect(out.hasPrefix("found 1 candidate memories, one per line\n"))
        #expect(out.contains(" \u{00B7} - \u{00B7} "))
    }

    @Test("a 5-column S2 row strips by the same column positions")
    func fiveColumnS2Row() {
        // S2 row: uuid · subject · bestSpan · sscFacts · eventTime (no score).
        let s2 = "0B1F4C2A-9D8E-4F00-B2C3-A5D6E7F80912 \u{00B7} kettle descaling schedule \u{00B7} The kettle needs descaling every six weeks. \u{00B7} SSC17 \u{00B7} 2026-08-01T09:30:00Z"
        // V0 suppresses columns 2 (bestSpan) and 3 (sscFacts).
        #expect(PayloadArm.v0.strip(row: s2) ==
            "0B1F4C2A-9D8E-4F00-B2C3-A5D6E7F80912 \u{00B7} kettle descaling schedule \u{00B7} - \u{00B7} - \u{00B7} 2026-08-01T09:30:00Z")
    }

    @Test("stripping is idempotent")
    func idempotent() {
        let once = PayloadArm.v0.strip(row: Self.row)
        #expect(PayloadArm.v0.strip(row: once) == once)
    }

    // MARK: — flag/env parsing

    @Test("parsePayloadArm: nil in, nil out; valid arms parse; junk and removed arms throw")
    func parsing() throws {
        #expect(try parsePayloadArm(nil) == nil)
        #expect(try parsePayloadArm("v0") == .v0)
        #expect(try parsePayloadArm("v1") == .v1)
        #expect(try parsePayloadArm("v4") == .v4)
        #expect(try parsePayloadArm("v5") == .v5)
        // v2 and v3 were defined solely by the adornment column, which no longer
        // exists in the 6-column format. They must fail loudly.
        #expect(throws: MCPError.self) { try parsePayloadArm("v2") }
        #expect(throws: MCPError.self) { try parsePayloadArm("v3") }
        #expect(throws: MCPError.self) { try parsePayloadArm("v9") }
    }
}
