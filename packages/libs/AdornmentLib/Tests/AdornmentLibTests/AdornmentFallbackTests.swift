import Testing
@testable import AdornmentLib

/// Mechanical mint fallback (Bob ruling 2026-08-27): a null adornment is
/// not allowed for a non-blank drawer. When generation refuses (Apple
/// guardrail) or its output normalizes to empty (small-model code/blank
/// replies), `mintAdornmentMapReduce` mints the mechanical claim line
/// extracted from the record content, truncated to the contract length.
/// Twin of `fallback_tests` in rust/src/adornment_generator.rs — the
/// golden literals below are asserted identically in both ports.
struct AdornmentFallbackTests {

    // Golden pin shared with the Rust twin.
    static let content =
        "user: The quarterly planning meeting moved to Thursday.\nassistant: Noted."
    static let fallback = "user: The quarterly planning meeting moved to Thursday."

    @Test("refusing generator yields the mechanical fallback")
    func refusingGeneratorFallsBack() async {
        let out = await mintAdornmentMapReduce(
            drawerContent: Self.content, eventDate: nil) { _ in nil }
        #expect(out == Self.fallback)
    }

    @Test("empty generator output yields the mechanical fallback")
    func emptyOutputFallsBack() async {
        let out = await mintAdornmentMapReduce(
            drawerContent: Self.content, eventDate: nil) { _ in "" }
        #expect(out == Self.fallback)
    }

    @Test("successful generation is unchanged")
    func successfulGenerationUnchanged() async {
        let out = await mintAdornmentMapReduce(
            drawerContent: Self.content, eventDate: nil) { _ in
                "planning meeting; Thursday move"
            }
        #expect(out == "planning meeting; Thursday move")
    }

    @Test("fallback respects the contract length")
    func fallbackRespectsMaxLength() async {
        let long = "user: " + String(repeating: "x", count: 500)
        let out = await mintAdornmentMapReduce(
            drawerContent: long, eventDate: nil) { _ in nil }
        #expect(out?.count == 280)
    }

    @Test("oversized record with a refusing generator still mints")
    func oversizedRecordFallsBack() async {
        let big = "First durable fact line.\n"
            + String(repeating: "filler line\n", count: 30)
        let out = await mintAdornmentMapReduce(
            drawerContent: big, eventDate: nil, chunkThreshold: 64) { _ in nil }
        #expect(out == "First durable fact line.")
    }

    @Test("blank content stays nil")
    func blankContentStaysNil() async {
        let out = await mintAdornmentMapReduce(
            drawerContent: "   \n  ", eventDate: nil) { _ in nil }
        #expect(out == nil)
    }
}
