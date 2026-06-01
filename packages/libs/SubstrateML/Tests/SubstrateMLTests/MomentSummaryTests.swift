// MomentSummaryTests.swift
//
// Moment-summary fingerprint per cookbook § 8.7. swift-testing peer
// suite for Sources/SubstrateML/MomentSummary.swift, mirroring
// rust/src/moment_summary.rs (6 #[test]) case-for-case, using the
// same RowLite + captured_during call path.

import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("MomentSummary")
struct MomentSummaryTests {

    private func hlc(_ t: Int64) -> HLC { HLC(physicalTime: t, logicalCount: 0, nodeID: 1) }
    private func row(_ t: Int64, _ fp: Fingerprint256) -> RowLite {
        RowLite(fingerprint: fp, captureHLC: hlc(t))
    }

    @Test("empty input summarizes to the zero fingerprint")
    func emptyInputIsZero() {
        let result = MomentSummary.summarize(
            rows: [RowLite](),
            window: TimeRange(start: hlc(0), end: hlc(100)),
            activeDuring: MomentSummary.capturedDuring)
        #expect(result == Fingerprint256.zero)
    }

    @Test("a row outside the window does not contribute")
    func noMatchIsZero() {
        let r = row(50, Fingerprint256(block0: 0xFF, block1: 0, block2: 0, block3: 0))
        let result = MomentSummary.summarize(
            rows: [r],
            window: TimeRange(start: hlc(200), end: hlc(300)), // window after capture
            activeDuring: MomentSummary.capturedDuring)
        #expect(result == Fingerprint256.zero)
    }

    @Test("OR-reduce of two fingerprints unions their set bits")
    func orReduceTwoFingerprints() {
        let a = Fingerprint256(block0: 0xFF00, block1: 0x0001, block2: 0, block3: 0)
        let b = Fingerprint256(block0: 0x00FF, block1: 0x0010, block2: 0xABCD, block3: 0)
        let result = MomentSummary.orReduce([a, b])
        #expect(result.block0 == 0xFFFF)
        #expect(result.block1 == 0x0011)
        #expect(result.block2 == 0xABCD)
        #expect(result.block3 == 0)
    }

    @Test("summary is idempotent under duplicated rows")
    func idempotentUnderDuplication() {
        let r = row(50, Fingerprint256(block0: 0x1234, block1: 0x5678, block2: 0, block3: 0))
        let window = TimeRange(start: hlc(0), end: hlc(100))
        let once = MomentSummary.summarize(rows: [r], window: window, activeDuring: MomentSummary.capturedDuring)
        let twice = MomentSummary.summarize(rows: [r, r], window: window, activeDuring: MomentSummary.capturedDuring)
        #expect(once == twice)
    }

    @Test("summary is commutative under input permutation")
    func commutativeUnderPermutation() {
        let r1 = row(10, Fingerprint256(block0: 0xFF00, block1: 0, block2: 0, block3: 0))
        let r2 = row(20, Fingerprint256(block0: 0x00FF, block1: 0x0001, block2: 0, block3: 0))
        let r3 = row(30, Fingerprint256(block0: 0, block1: 0, block2: 0xABCD, block3: 0))
        let window = TimeRange(start: hlc(0), end: hlc(100))
        let a = MomentSummary.summarize(rows: [r1, r2, r3], window: window, activeDuring: MomentSummary.capturedDuring)
        let b = MomentSummary.summarize(rows: [r3, r1, r2], window: window, activeDuring: MomentSummary.capturedDuring)
        #expect(a == b)
    }

    @Test("summary is monotone under set inclusion")
    func monotoneUnderInclusion() {
        let r1 = row(10, Fingerprint256(block0: 0xFF00, block1: 0, block2: 0, block3: 0))
        let r2 = row(20, Fingerprint256(block0: 0x00FF, block1: 0, block2: 0, block3: 0))
        let window = TimeRange(start: hlc(0), end: hlc(100))
        let small = MomentSummary.summarize(rows: [r1], window: window, activeDuring: MomentSummary.capturedDuring)
        let large = MomentSummary.summarize(rows: [r1, r2], window: window, activeDuring: MomentSummary.capturedDuring)
        // Every bit set in `small` is set in `large`.
        #expect(small.block0 & large.block0 == small.block0)
        #expect(small.block1 & large.block1 == small.block1)
        #expect(small.block2 & large.block2 == small.block2)
        #expect(small.block3 & large.block3 == small.block3)
    }
}
