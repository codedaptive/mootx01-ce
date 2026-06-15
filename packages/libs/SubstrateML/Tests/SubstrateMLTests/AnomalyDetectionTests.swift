// AnomalyDetectionTests.swift
//
// Statistical anomaly scoring per cookbook § 8.13. swift-testing peer
// suite for Sources/SubstrateML/AnomalyDetection.swift.
//
// rust/src/anomaly.rs carries NO #[test], so this suite asserts the
// behavior set the file documents: classic z-score, rolling z-score,
// the MAD-based modified z-score (robust to outliers), and the
// |z| ≥ threshold rule. Float32 comparisons use a 1e-5 tolerance.
//
// Isolation strategy:
//   rollingZScore() and rollingModifiedZScore() call Intellectus.report()
//   whenever the window is non-empty. Tests that call these functions with
//   non-empty windows wrap their body in GlobalTestLock.shared.withLock { }
//   to prevent concurrent VizGraphSignalTests from capturing stray samples.
//   Pure-math functions (zScore, modifiedZScore, isAnomalous) and the
//   empty-window early-return path are exempt.

import Testing
@testable import SubstrateML

@Suite("AnomalyDetection")
struct AnomalyDetectionTests {

    private let tol: Float32 = 1e-5

    @Test("z-score is (value − mean) / stddev")
    func zScoreBasic() {
        #expect(abs(AnomalyDetection.zScore(value: 5, mean: 3, stddev: 2) - 1.0) < tol)
        #expect(abs(AnomalyDetection.zScore(value: 3, mean: 3, stddev: 2)) < tol)
    }

    @Test("z-score is zero when stddev is zero")
    func zScoreZeroStddev() {
        #expect(AnomalyDetection.zScore(value: 5, mean: 3, stddev: 0) == 0)
    }

    @Test("rolling z-score over an empty window is zero")
    func rollingZScoreEmptyWindow() {
        #expect(AnomalyDetection.rollingZScore(window: [], current: 5) == 0)
    }

    @Test("rolling z-score over a constant window is zero (no spread)")
    func rollingZScoreConstantWindow() async {
        // rollingZScore() calls Intellectus.report() on non-empty windows — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            #expect(AnomalyDetection.rollingZScore(window: [4, 4, 4, 4], current: 9) == 0)
        }
    }

    @Test("rolling z-score flags a value far from the window mean")
    func rollingZScoreFlagsOutlier() async {
        // rollingZScore() calls Intellectus.report() (two calls here) — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            // window mean 3, population variance 2, stddev √2 ≈ 1.4142.
            let z = AnomalyDetection.rollingZScore(window: [1, 2, 3, 4, 5], current: 3)
            #expect(abs(z) < tol)                       // the mean scores 0
            let zHigh = AnomalyDetection.rollingZScore(window: [1, 2, 3, 4, 5], current: 5)
            #expect(zHigh > 1.0)                          // (5−3)/1.414 ≈ 1.414
        }
    }

    @Test("modified z-score is zero when MAD is zero")
    func modifiedZScoreZeroMAD() {
        #expect(AnomalyDetection.modifiedZScore(value: 5, median: 3, mad: 0) == 0)
    }

    @Test("modified z-score applies the 0.6745 consistency constant")
    func modifiedZScoreConstant() {
        // 0.6745 * (5 − 3) / 1 = 1.349.
        let z = AnomalyDetection.modifiedZScore(value: 5, median: 3, mad: 1)
        #expect(abs(z - 1.349) < tol)
    }

    @Test("rolling modified z-score is zero for a flat window")
    func rollingModifiedZScoreFlat() async {
        // rollingModifiedZScore() calls Intellectus.report() on non-empty windows — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            #expect(AnomalyDetection.rollingModifiedZScore(window: [3, 3, 3, 3, 3], current: 3) == 0)
        }
    }

    @Test("the |z| ≥ threshold rule fires at and above the threshold")
    func isAnomalousThreshold() {
        #expect(AnomalyDetection.isAnomalous(zScore: 3.0))           // default 3.0, inclusive
        #expect(AnomalyDetection.isAnomalous(zScore: -3.5))          // sign-independent
        #expect(AnomalyDetection.isAnomalous(zScore: 2.9) == false)
        #expect(AnomalyDetection.isAnomalous(zScore: 1.0, threshold: 0.5))
    }
}
