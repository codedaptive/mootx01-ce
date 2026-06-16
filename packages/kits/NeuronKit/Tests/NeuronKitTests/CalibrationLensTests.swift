import Testing
@testable import NeuronKit
import GeniusLocusKit

// Calibration lens tests (SPEC § 8.2, Lens 5 Grounding+Trust).
// Verify spec behavioural claims: data-backed mapping, isCalibrated flag,
// edge totality (B-8), determinism (B-5).

@Suite("Calibration lens (SPEC § 8.2, Lens 5)")
struct CalibrationLensTests {

    // B-8 edge: empty claimed → empty result.
    @Test("calibrate: empty claimed yields empty result")
    func emptyClaimed() {
        let curve = MatrixCalibrationCurve()
        let result = NeuronKit.calibrate(curve: curve, claimed: [])
        #expect(result.isEmpty)
    }

    // No-data curve: all values pass through uncalibrated.
    @Test("calibrate: no-data curve produces isCalibrated = false for every value")
    func noDataCurveUncalibrated() {
        let curve = MatrixCalibrationCurve()   // all bins empty
        let claimed: [Float] = [0.1, 0.5, 0.9]
        let result = NeuronKit.calibrate(curve: curve, claimed: claimed)
        #expect(result.count == 3)
        #expect(result.allSatisfy { !$0.isCalibrated })
    }

    // No-data curve: claimed value passes through unchanged.
    @Test("calibrate: no-data curve returns claimed value unchanged")
    func noDataCurvePassThrough() {
        let curve = MatrixCalibrationCurve()
        let result = NeuronKit.calibrate(curve: curve, claimed: [0.4])
        #expect(abs(result[0].calibrated - 0.4) < 1e-6)
        #expect(result[0].claimed == 0.4)
    }

    // After recording a success outcome, the matching bin has data.
    @Test("calibrate: bin with observations produces isCalibrated = true")
    func dataBackedBinIsCalibrated() {
        var curve = MatrixCalibrationCurve()
        // Record a success at confidence 0.7 — populates the bin for ~0.7.
        curve.record(claimedConfidence: 0.7, outcome: .success)
        let result = NeuronKit.calibrate(curve: curve, claimed: [0.7])
        #expect(result[0].isCalibrated)
    }

    // Calibrated value matches what MatrixCalibrationCurve.calibrate returns.
    @Test("calibrate: calibrated value matches curve.calibrate output")
    func calibratedValueMatchesCurve() {
        var curve = MatrixCalibrationCurve()
        curve.record(claimedConfidence: 0.3, outcome: .success)
        curve.record(claimedConfidence: 0.3, outcome: .failure)
        let claimed: Float = 0.3
        let result = NeuronKit.calibrate(curve: curve, claimed: [claimed])
        let direct = curve.calibrate(claimedConfidence: claimed)
        #expect(abs(result[0].calibrated - direct) < 1e-6)
    }

    // One-per-input: result length equals claimed length.
    @Test("calibrate: result length equals claimed length")
    func resultLengthMatchesClaimed() {
        let curve = MatrixCalibrationCurve()
        let claimed: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let result = NeuronKit.calibrate(curve: curve, claimed: claimed)
        #expect(result.count == claimed.count)
    }

    // claimed field is preserved verbatim.
    @Test("calibrate: claimed field preserved verbatim in result")
    func claimedFieldPreserved() {
        let curve = MatrixCalibrationCurve()
        let values: [Float] = [0.25, 0.75]
        let result = NeuronKit.calibrate(curve: curve, claimed: values)
        #expect(result[0].claimed == 0.25)
        #expect(result[1].claimed == 0.75)
    }

    // B-5 determinism.
    @Test("calibrate: deterministic — same input produces same output")
    func deterministic() {
        var curve = MatrixCalibrationCurve()
        curve.record(claimedConfidence: 0.5, outcome: .success)
        let claimed: [Float] = [0.5, 0.9]
        let r1 = NeuronKit.calibrate(curve: curve, claimed: claimed)
        let r2 = NeuronKit.calibrate(curve: curve, claimed: claimed)
        #expect(r1 == r2)
    }

    // C-17 fidelity: lens calibrated value equals MatrixCalibrationCurve.calibrate
    // called directly on the same input.
    @Test("calibrate fidelity (C-17): calibrated value equals direct curve.calibrate call")
    func c17FidelityCalibratedMatchesPrimitive() {
        var curve = MatrixCalibrationCurve()
        curve.record(claimedConfidence: 0.65, outcome: .success)
        curve.record(claimedConfidence: 0.65, outcome: .failure)
        let claimed: Float = 0.65
        let direct = curve.calibrate(claimedConfidence: claimed)
        let result = NeuronKit.calibrate(curve: curve, claimed: [claimed])
        #expect(result[0].calibrated == direct,
                "lens calibrated value must equal MatrixCalibrationCurve.calibrate on the same input")
    }
}
