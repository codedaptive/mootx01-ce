// LLMCalibrationCurveTests.swift
//
// LLM calibration curve per cookbook § 6.6. swift-testing peer suite
// for Sources/SubstrateML/LLMCalibrationCurve.swift.
//
// rust/src/calibration.rs carries NO #[test], so this suite asserts
// the documented behavior set: 20-bucket binning with clamping,
// bucket midpoints, empirical hit rate, expected calibration error /
// Brier score against the y = x reference, and fractional decay.

import Testing
@testable import SubstrateML

@Suite("LLMCalibrationCurve")
struct LLMCalibrationCurveTests {

    private let tol: Float32 = 1e-4

    @Test("a fresh curve is empty")
    func emptyCurve() {
        let c = LLMCalibrationCurve()
        #expect(c.sampleCount == 0)
        #expect(c.actualRate(in: 5) == nil)
        #expect(c.expectedCalibrationError() == 0)
        #expect(c.brierScore() == 0)
    }

    @Test("observations land in the correct 0.05-width bucket, with clamping")
    func bucketingAndClamping() {
        var c = LLMCalibrationCurve()
        c.observe(claimedConfidence: 0.5, actualOutcome: true)   // bucket 10
        c.observe(claimedConfidence: 0.0, actualOutcome: true)   // bucket 0
        c.observe(claimedConfidence: 2.0, actualOutcome: true)   // clamp → bucket 19
        c.observe(claimedConfidence: -1.0, actualOutcome: true)  // clamp → bucket 0
        #expect(c.sampleCount == 4)
        #expect(c.actualRate(in: 10) == 1.0)
        #expect(c.actualRate(in: 0) == 1.0)   // two observations, both hits
        #expect(c.actualRate(in: 19) == 1.0)
        #expect(c.actualRate(in: 5) == nil)   // untouched bucket
    }

    @Test("bucket midpoints sit at the bin centers")
    func midpoints() {
        #expect(abs(LLMCalibrationCurve.midpoint(of: 0) - 0.025) < tol)
        #expect(abs(LLMCalibrationCurve.midpoint(of: 19) - 0.975) < tol)
    }

    @Test("empirical hit rate reflects hits over predictions")
    func actualRate() {
        var c = LLMCalibrationCurve()
        c.observe(claimedConfidence: 0.52, actualOutcome: true)  // bucket 10
        c.observe(claimedConfidence: 0.52, actualOutcome: false) // bucket 10
        #expect(c.actualRate(in: 10) == 0.5)
    }

    @Test("a maximally miscalibrated bucket yields large ECE and Brier")
    func miscalibration() {
        var c = LLMCalibrationCurve()
        // Claim ~0.975 confidence (bucket 19, midpoint 0.975) but always miss.
        for _ in 0..<10 { c.observe(claimedConfidence: 0.96, actualOutcome: false) }
        // actual rate 0 vs midpoint 0.975 ⇒ ECE = 0.975, Brier = 0.975².
        #expect(abs(c.expectedCalibrationError() - 0.975) < 1e-3)
        #expect(abs(c.brierScore() - 0.975 * 0.975) < 1e-3)
    }

    @Test("fractional decay scales the bin counts")
    func fractionalDecay() {
        var c = LLMCalibrationCurve()
        for _ in 0..<10 { c.observe(claimedConfidence: 0.5, actualOutcome: true) }
        c.decay(factor: 0.5)
        #expect(c.actualRate(in: 10) == 1.0)  // 5 hits / 5 predicted, ratio preserved
        #expect(c.sampleCount == 5)
        c.decay(factor: 1.0)                   // no-op
        #expect(c.sampleCount == 5)
    }
}
