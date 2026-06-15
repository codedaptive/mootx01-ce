// ISO8601FormatterTests.swift
//
// Verifies that the ISO8601 enum in SQLiteConnection produces correct
// internet date-time format with fractional seconds, that round-trips
// preserve the date within millisecond precision, and that cached
// static formatter instances avoid per-call udat_open overhead.
//
// Test 4 (performance) is the RED gate for HOTFIX-HF2: it will fail
// against per-call instantiation (~10s for 10_000 calls) and pass
// after the static-let cache lands (~1ms for 10_000 calls).

@testable import PersistenceKitSQLite
import Testing
import Foundation

@Suite("ISO8601 formatter — correctness and performance")
struct ISO8601FormatterTests {

    // Spot-checks the output format: internet date-time with fractional seconds
    // (as required by .withInternetDateTime + .withFractionalSeconds).
    @Test("string(from:) produces internet date-time with fractional seconds")
    func formatProducesInternetDateTimeFormat() {
        let epoch = Date(timeIntervalSince1970: 0)
        let s = ISO8601.string(from: epoch)
        // Must contain the date-time separator.
        #expect(s.contains("T"), "expected T separator in '\(s)'")
        // Must contain a UTC marker or numeric offset.
        #expect(s.hasSuffix("Z") || s.contains("+") || (s.dropFirst(20).contains("-")),
                "expected UTC marker in '\(s)'")
        // Fractional seconds present.
        #expect(s.contains("."), "expected fractional seconds in '\(s)'")
        // Minimum plausible length for a full internet date-time: "1970-01-01T00:00:00.000Z" = 24 chars.
        #expect(s.count >= 24, "date string '\(s)' is too short")
    }

    // A known epoch value encodes and decodes symmetrically.
    @Test("round-trip preserves date within millisecond precision")
    func roundTripPreservesDate() {
        // 1_000_000.5s since epoch: non-trivial value with fractional seconds.
        let original = Date(timeIntervalSince1970: 1_000_000.5)
        let encoded = ISO8601.string(from: original)
        let decoded = ISO8601.date(from: encoded)
        #expect(decoded != nil, "ISO8601.date(from:) must parse a string it produced")
        if let d = decoded {
            let diff = abs(d.timeIntervalSince1970 - original.timeIntervalSince1970)
            // Fractional seconds are stored to millisecond precision.
            #expect(diff < 0.001, "round-trip error \(diff)s exceeds 1ms tolerance")
        }
    }

    // Malformed input must not crash; it must return nil.
    @Test("date(from:) returns nil for invalid input")
    func dateFromInvalidStringReturnsNil() {
        #expect(ISO8601.date(from: "not-a-date") == nil)
        #expect(ISO8601.date(from: "") == nil)
        #expect(ISO8601.date(from: "2026-99-99") == nil)
    }

    // Multiple distinct dates encode to distinct strings (no aliasing).
    @Test("distinct dates produce distinct strings")
    func distinctDatesProduceDistinctStrings() {
        let a = ISO8601.string(from: Date(timeIntervalSince1970: 1_000))
        let b = ISO8601.string(from: Date(timeIntervalSince1970: 2_000))
        let c = ISO8601.string(from: Date(timeIntervalSince1970: 1_000))
        #expect(a != b, "different dates must produce different strings")
        #expect(a == c, "same date must produce the same string")
    }

    // RED gate for HOTFIX-HF2: 10_000 calls must complete in under 100ms on ARM64.
    // Per-call ISO8601DateFormatter instantiation triggers udat_open (ICU format init)
    // on every call — at 10_000 calls this takes > 10s. After the static-let cache
    // this completes in < 10ms. The 100ms threshold is conservative (10× headroom)
    // to avoid false failures under heavy CI load.
    @Test("10_000 calls to string(from:) complete in under 100ms (cache gate)")
    func cachedFormatterPerformance() {
        let date = Date(timeIntervalSince1970: 1_000_000.0)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10_000 {
            _ = ISO8601.string(from: date)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        // Report elapsed time on failure to diagnose whether the cache is missing.
        if elapsed >= 0.1 {
            Issue.record("10_000 calls took \(String(format: "%.3f", elapsed))s — expected < 0.100s. Formatters must be cached as static constants, not created per call.")
        }
        #expect(elapsed < 0.1, "10_000 calls exceeded 100ms — formatter cache missing")
    }
}
