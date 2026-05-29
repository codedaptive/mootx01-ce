import Testing
@testable import LocusKit

/// Tests for the five operator primitives defined in
/// GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md § 7.7.
///
/// The `0x3845` example bitmap exercises all four packed fields used
/// throughout the LocusKit adjective schema:
///   bits 0–3:  state         = 0x5 (withdrawn)
///   bits 4–7:  accessTier    = 0x4 (elevated)
///   bits 8–11: exportability = 0x8 (public/exportable)
///   bits 12–15: trust         = 0x3 (canonical)
@Suite("BitmapOpsTests")
struct BitmapOpsTests {

    // MARK: - AND-with-mask

    @Test("andMask: state field equals withdrawn (5)")
    func andMaskStateWithdrawn() {
        #expect(andMask(0x3845, mask: 0xF, expected: 0x5) == true)
    }

    @Test("andMask: state field does not equal 3")
    func andMaskStateNotThree() {
        #expect(andMask(0x3845, mask: 0xF, expected: 0x3) == false)
    }

    @Test("andMask: accessTier field equals elevated (4)")
    func andMaskAccessTierElevated() {
        #expect(andMask(0x3845, mask: 0xF0, expected: 0x40) == true)
    }

    @Test("andMask: zero bitmap with zero expected matches")
    func andMaskZeroBitmap() {
        #expect(andMask(0, mask: 0xF, expected: 0) == true)
    }

    @Test("andMask: zero mask always matches zero")
    func andMaskZeroMask() {
        #expect(andMask(0x3845, mask: 0, expected: 0) == true)
    }

    // MARK: - Threshold-compare

    @Test("thresholdCompare: state=2 is in know-now cluster (< 3)")
    func thresholdStateInKnowNow() {
        #expect(thresholdCompare(0x2, mask: 0xF, shift: 0, op: .lessThan, value: 3) == true)
    }

    @Test("thresholdCompare: state=3 is not in know-now cluster (< 3)")
    func thresholdStateNotInKnowNow() {
        #expect(thresholdCompare(0x3, mask: 0xF, shift: 0, op: .lessThan, value: 3) == false)
    }

    @Test("thresholdCompare: state=3 meets knew-past lower bound (>= 3)")
    func thresholdStateKnewPastLowerBound() {
        #expect(thresholdCompare(0x3, mask: 0xF, shift: 0, op: .greaterThanOrEqual, value: 3) == true)
    }

    @Test("thresholdCompare: state=7 is not in knew-past cluster (< 7)")
    func thresholdStateNotInKnewPast() {
        #expect(thresholdCompare(0x7, mask: 0xF, shift: 0, op: .lessThan, value: 7) == false)
    }

    @Test("thresholdCompare: trust=3 is trustworthy (< 4)")
    func thresholdTrustTrustworthy() {
        #expect(thresholdCompare(0x3000, mask: 0xF000, shift: 12, op: .lessThan, value: 4) == true)
    }

    @Test("thresholdCompare: trust=4 is not trustworthy (< 4)")
    func thresholdTrustNotTrustworthy() {
        #expect(thresholdCompare(0x4000, mask: 0xF000, shift: 12, op: .lessThan, value: 4) == false)
    }

    // MARK: - Shift-extract

    @Test("shiftExtract: state field (bits 0–3) reads 5")
    func shiftExtractState() {
        #expect(shiftExtract(0x3845, shift: 0, mask: 0xF) == 5)
    }

    @Test("shiftExtract: accessTier field (bits 4–7) reads 4")
    func shiftExtractAccessTier() {
        #expect(shiftExtract(0x3845, shift: 4, mask: 0xF) == 4)
    }

    @Test("shiftExtract: exportability field (bits 8–11) reads 8")
    func shiftExtractExportability() {
        #expect(shiftExtract(0x3845, shift: 8, mask: 0xF) == 8)
    }

    @Test("shiftExtract: trust field (bits 12–15) reads 3")
    func shiftExtractTrust() {
        #expect(shiftExtract(0x3845, shift: 12, mask: 0xF) == 3)
    }

    @Test("shiftExtract: zero bitmap extracts zero")
    func shiftExtractZeroBitmap() {
        #expect(shiftExtract(0, shift: 0, mask: 0xF) == 0)
    }

    @Test("shiftExtract: zero mask after shift yields zero")
    func shiftExtractZeroMask() {
        #expect(shiftExtract(0x3845, shift: 0, mask: 0) == 0)
    }

    // MARK: - Cross-primitive integration
    //
    // Simulates the `.currentlyBelieve` filter from spec § 7.9.2:
    // the recall evaluator compiles `currentlyBelieve` into a
    // `thresholdCompare` over the state field (mask 0xF, shift 0)
    // with `< 3` semantics, then folds rows through a vanilla
    // `Collection.filter`. (SIMD-ballot lived in BitmapOps before the
    // v0.8 provenance clean and was removed as a redundant restatement
    // of the spec primitive set; per-row predicates compose naturally
    // with `Collection.filter`.)

    @Test("integration: currentlyBelieve filter selects know-now rows")
    func integrationCurrentlyBelieveFilter() {
        let adjBitmaps: [Int64] = [0x0, 0x1, 0x2, 0x3000_0003, 0x7]
        let knowNow = adjBitmaps.indices.filter { idx in
            thresholdCompare(adjBitmaps[idx], mask: 0xF, shift: 0, op: .lessThan, value: 3)
        }
        #expect(knowNow == [0, 1, 2])
    }
}
