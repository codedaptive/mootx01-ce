// ISO8601ParseTests.swift
//
// Pins the fast ISO-8601 parse path in `ISO8601.date(from:)` against an
// independent `ISO8601DateFormatter` reference.
//
// Why this exists: `ISO8601DateFormatter.date(from:)` is ICU-backed and
// pathologically slow at scale. The Merkle rollup re-decodes every drawer in a
// room on each insert, so during a large import this parse runs O(N²) times and
// dominated the CPU profile (~80%). `ISO8601.date(from:)` now hand-parses the
// canonical UTC shape this kit writes (`YYYY-MM-DDTHH:MM:SS[.fff…]Z`) and falls
// back to the formatters for anything else. These tests guarantee the fast path
// is behavior-identical to the formatter — same Date for valid canonical
// inputs (fractional seconds retained), and `nil` for everything the formatter
// rejects (the corrupt-stored-value gate).

import Foundation
import Testing
@testable import PersistenceKitSQLite

@Suite("ISO8601 fast-parse parity")
struct ISO8601ParseTests {

    /// Independent reference: a fresh formatter pair, identical options to the
    /// ones `ISO8601` uses internally. The fast path must match this exactly.
    private let refFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let refPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private func reference(_ s: String) -> Date? {
        refFraction.date(from: s) ?? refPlain.date(from: s)
    }

    /// Assert `ISO8601.date(from:)` agrees with the reference for `s`:
    /// both nil, or both a Date within 1µs (fractional seconds retained).
    private func assertMatches(_ s: String, _ sourceLocation: SourceLocation = #_sourceLocation) {
        let got = ISO8601.date(from: s)
        let want = reference(s)
        switch (got, want) {
        case (nil, nil):
            break
        case let (g?, w?):
            #expect(
                abs(g.timeIntervalSince1970 - w.timeIntervalSince1970) < 1e-6,
                "parse(\(s)) = \(g.timeIntervalSince1970), reference = \(w.timeIntervalSince1970)",
                sourceLocation: sourceLocation
            )
        default:
            Issue.record(
                "parse(\(s)) = \(String(describing: got)) but reference = \(String(describing: want))",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: - Canonical forms (fast path)

    @Test func canonicalWithFractionalSeconds() {
        // Millisecond and coarser fractions — the shapes this kit writes
        // (`%.3f`) — must match the reference formatter exactly.
        assertMatches("2026-06-12T18:02:48.000Z")
        assertMatches("2026-06-23T06:07:06.319Z")
        assertMatches("2026-06-23T06:07:06.1Z")
        assertMatches("2026-06-23T06:07:06.12Z")
    }

    @Test func superFinePrecisionBeyondMilliseconds() {
        // "Super fine" date: the fast path preserves FULL sub-second precision.
        // NSISO8601DateFormatter caps at milliseconds, so for >3 fractional
        // digits the fast path is deliberately MORE precise than the formatter.
        // The kit writes only millisecond precision, so this only matters for
        // externally-authored timestamps — where keeping the extra precision is
        // the correct, non-lossy behavior.
        let d = ISO8601.date(from: "2026-06-23T06:07:06.123456Z")
        #expect(d != nil)
        let frac = (d?.timeIntervalSince1970 ?? 0).truncatingRemainder(dividingBy: 1)
        #expect(abs(frac - 0.123456) < 1e-6)
    }

    @Test func canonicalWholeSeconds() {
        assertMatches("2026-06-12T18:02:48Z")
        assertMatches("2000-01-01T00:00:00Z")
        assertMatches("1999-12-31T23:59:59Z")
    }

    @Test func epochIsZero() {
        let d = ISO8601.date(from: "1970-01-01T00:00:00Z")
        #expect(d != nil)
        #expect(abs((d?.timeIntervalSince1970 ?? .nan) - 0) < 1e-9)
    }

    @Test func fractionalSecondsAreRetained() {
        // The fast path must preserve full sub-second precision (the "super
        // fine" date) — it must NOT truncate to whole seconds.
        let d = ISO8601.date(from: "2026-06-23T06:07:06.319Z")
        #expect(d != nil)
        let frac = (d?.timeIntervalSince1970 ?? 0).truncatingRemainder(dividingBy: 1)
        #expect(abs(frac - 0.319) < 1e-6)
    }

    @Test func leapDayValid() {
        assertMatches("2024-02-29T12:00:00Z")  // 2024 is a leap year
        assertMatches("2000-02-29T00:00:00.000Z")  // 2000 divisible by 400
    }

    // MARK: - Rejections (must equal the formatter's nil)

    @Test func invalidCalendarDatesRejected() {
        assertMatches("2023-02-29T12:00:00Z")  // 2023 not a leap year
        assertMatches("2026-13-01T00:00:00Z")  // month 13
        assertMatches("2026-06-31T00:00:00Z")  // June has 30 days
        assertMatches("2026-00-10T00:00:00Z")  // month 0
        assertMatches("2026-06-00T00:00:00Z")  // day 0
        assertMatches("2026-06-12T24:00:00Z")  // hour 24
        assertMatches("2026-06-12T18:60:00Z")  // minute 60
    }

    @Test func malformedRejected() {
        assertMatches("")
        assertMatches("not-a-date")
        assertMatches("2026-06-12")               // date only
        assertMatches("2026-06-12T18:02:48")      // no zone
        assertMatches("2026-06-12T18:02:48Zxyz")  // trailing garbage
        assertMatches("2026/06/12T18:02:48Z")     // wrong separators
        assertMatches("2026-06-12T18:02:48.Z")    // dot with no digits
    }

    // MARK: - Non-canonical valid forms (fall back to the formatter)

    @Test func numericOffsetsFallBackAndMatch() {
        assertMatches("2026-06-12T18:02:48+05:00")
        assertMatches("2026-06-12T18:02:48-08:00")
        assertMatches("2026-06-12T18:02:48.250+00:00")
    }

    // MARK: - Round trip with string(from:)

    @Test func roundTripThroughStringFrom() {
        let samples: [TimeInterval] = [0, 1, 1_000_000, 1_765_000_000, 1_765_000_000.319, -1, 946_684_800]
        for secs in samples {
            let original = Date(timeIntervalSince1970: secs)
            let text = ISO8601.string(from: original)
            let parsed = ISO8601.date(from: text)
            #expect(parsed != nil, "round trip failed to parse \(text)")
            // string(from:) emits millisecond precision; compare to the ms.
            #expect(abs((parsed?.timeIntervalSince1970 ?? .nan) - secs) < 1e-3)
        }
    }

    // MARK: - Parity sweep (fast path == formatter across many values)

    @Test func paritySweepAgainstFormatter() {
        // Format a spread of instants with the reference formatter, then assert
        // the fast parse reproduces them. This is the core safety guarantee.
        var t = 0.0
        for i in 0..<2000 {
            // Spread across decades, with and without fractional seconds.
            t = Double(i) * 123_457.0 + (i % 3 == 0 ? 0.137 : 0.0)
            let d = Date(timeIntervalSince1970: t)
            let withFrac = refFraction.string(from: d)
            let withoutFrac = refPlain.string(from: d)
            assertMatches(withFrac)
            assertMatches(withoutFrac)
        }
    }
}
