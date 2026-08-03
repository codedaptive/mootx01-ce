import Testing
@testable import SubstrateML

/// DCP normalizer overflow rejection — Swift leg. Mirrored by
/// `rust/tests/conflict_projection_overflow.rs`, which asserts the same
/// inputs produce the same nothing/something answer in the Rust port. The
/// two files are a CROSS-PORT FIXTURE: an input accepted by one port and
/// refused by the other is a conformance break at exactly the values an
/// attacker picks.
///
/// The normalizers already return an optional, so an out-of-range value is
/// reported the same way an unparseable one is: `nil`. Rejecting overflow
/// is not a range policy — `Int64.max` seconds is still accepted, because
/// it does not overflow.
///
/// Before the fix these multiplies were unchecked. Swift traps on integer
/// overflow, so each of these inputs crashed the test process rather than
/// returning `nil`; the Rust port's release build wrapped instead and
/// returned a silently negative value.
@Suite struct ConflictProjectionOverflowTests {

    /// The duration suffixes the normalizer accepts, with their
    /// multipliers. Enumerated rather than sampled: a suffix added later
    /// without a checked multiply would slip past a single-suffix test.
    static let durationSuffixes: [(String, Int64)] = [("min", 60), ("h", 3600), ("s", 1)]

    // MARK: - duration

    /// The reporter's input. `Int64.max * 3600` overflows; the answer is nil.
    @Test func durationReportedOverflowReturnsNil() {
        #expect(ConflictNormalize.duration("9223372036854775807h") == nil)
    }

    /// `Int64.max` and `Int64.min` against every suffix. `s` has multiplier
    /// 1, so the extremes are exactly representable and must still be
    /// ACCEPTED — this mission rejects overflow, it does not impose a
    /// maximum duration.
    @Test func durationExtremesRejectedOnlyWhereTheyOverflow() {
        for (suffix, mult) in Self.durationSuffixes {
            for extreme in [Int64.max, Int64.min] {
                let raw = "\(extreme)\(suffix)"
                let got = ConflictNormalize.duration(raw)
                let (product, didOverflow) = extreme.multipliedReportingOverflow(by: mult)
                if didOverflow {
                    #expect(got == nil, "\(raw) overflows but was accepted")
                } else {
                    #expect(got?.canonicalBytes == "dur:\(product)",
                            "\(raw) is representable and must still normalize")
                }
            }
        }
    }

    /// Ordinary durations normalize exactly as they did before the fix. The
    /// expected bytes are the same literals `ConflictProjectionGoldenTests`
    /// pins, so a checked-arithmetic change cannot quietly alter results.
    @Test func durationValidInputsUnchanged() {
        #expect(ConflictNormalize.duration("1h")?.canonicalBytes == "dur:3600")
        #expect(ConflictNormalize.duration("60 min")?.canonicalBytes == "dur:3600")
        #expect(ConflictNormalize.duration("30s")?.canonicalBytes == "dur:30")
        #expect(ConflictNormalize.duration("-1h")?.canonicalBytes == "dur:-3600")
        #expect(ConflictNormalize.duration("about an hour") == nil)
    }

    // MARK: - usdDecimal
    //
    // Three separate unchecked sites lived in this one function: the
    // fractional scaling multiply, the fraction add, and the suffix
    // multiply. Each gets its own test so a partial fix cannot pass.

    /// Overflow in the fractional scaling loop: `Int64.max * 10`.
    @Test func usdDecimalFractionScalingOverflowReturnsNil() {
        #expect(ConflictNormalize.usdDecimal("9223372036854775807.5") == nil)
    }

    /// Overflow in the fraction ADD, not the scaling multiply.
    /// `922337203685477580 * 10 == 9223372036854775800` still fits; adding
    /// the trailing `9` does not.
    @Test func usdDecimalFractionAddOverflowReturnsNil() {
        let (scaled, didOverflow) = Int64(922_337_203_685_477_580).multipliedReportingOverflow(by: 10)
        #expect(!didOverflow)
        #expect(scaled == 9_223_372_036_854_775_800)
        #expect(ConflictNormalize.usdDecimal("922337203685477580.9") == nil)
    }

    /// Overflow in the suffix multiply, for every scaling suffix.
    @Test func usdDecimalSuffixMultiplyOverflowReturnsNil() {
        for suffix in ["k", "m"] {
            #expect(ConflictNormalize.usdDecimal("9223372036854775807\(suffix)") == nil,
                    "9223372036854775807\(suffix) was accepted")
        }
        // No suffix, no multiply: Int64.max is representable and stays accepted.
        #expect(ConflictNormalize.usdDecimal("9223372036854775807")?.canonicalBytes
            == "d:9223372036854775807")
    }

    /// The registry route, not just the bare normalizer: the
    /// `dim.decision.budget_ceiling` rule funnels raw text through
    /// `usdDecimal`, and that is the path a meeting-decision extraction
    /// takes. An overflowing value must fall out as a refused value.
    @Test func registryBudgetCeilingRuleRefusesOverflow() {
        let rule = ConflictRuleRegistry.v01.rule(forDimension: "decision:budget_ceiling")
        #expect(rule != nil)
        #expect(rule?.normalize("9223372036854775807m") == nil)
        #expect(rule?.normalize("1,500k USD")?.canonicalBytes == "d:1500000")
    }

    /// Ordinary money normalizes exactly as before — same literals as the
    /// golden corpus.
    @Test func usdDecimalValidInputsUnchanged() {
        #expect(ConflictNormalize.usdDecimal("1,500k USD")?.canonicalBytes == "d:1500000")
        #expect(ConflictNormalize.usdDecimal("$1.5m")?.canonicalBytes == "d:1500000")
        #expect(ConflictNormalize.usdDecimal("12.50")?.canonicalBytes == "d:12.5")
        #expect(ConflictNormalize.usdDecimal("-0.125")?.canonicalBytes == "d:-0.125")
        #expect(ConflictNormalize.usdDecimal("about five") == nil)
    }
}
