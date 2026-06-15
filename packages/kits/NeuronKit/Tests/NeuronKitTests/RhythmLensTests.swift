import Testing
@testable import NeuronKit
import SubstrateML

// Rhythm lens tests (SPEC § 8.2, Lens 2 Prediction+Time).
// Verify spec behavioural claims: top-K dominant periods, relative magnitude,
// edge totality (B-8), determinism (B-5).

@Suite("Rhythm lens (SPEC § 8.2, Lens 2)")
struct RhythmLensTests {

    // B-8 edge: fewer than 4 buckets → empty.
    @Test("rhythm: series shorter than 4 buckets yields empty")
    func shortSeries() {
        let r1 = NeuronKit.rhythm(buckets: [], bucketDurationSeconds: 1.0, topK: 3)
        let r2 = NeuronKit.rhythm(buckets: [true, false, true], bucketDurationSeconds: 1.0, topK: 3)
        #expect(r1.isEmpty)
        #expect(r2.isEmpty)
    }

    // B-8 edge: all-constant series → empty.
    @Test("rhythm: all-true series yields empty")
    func allConstantTrue() {
        let result = NeuronKit.rhythm(buckets: [Bool](repeating: true, count: 8),
                                      bucketDurationSeconds: 1.0, topK: 3)
        #expect(result.isEmpty)
    }

    @Test("rhythm: all-false series yields empty")
    func allConstantFalse() {
        let result = NeuronKit.rhythm(buckets: [Bool](repeating: false, count: 8),
                                      bucketDurationSeconds: 1.0, topK: 3)
        #expect(result.isEmpty)
    }

    // B-8 edge: topK == 0 → empty.
    @Test("rhythm: topK zero yields empty")
    func topKZero() {
        let buckets = [true, false, true, false, true, false, true, false]
        let result = NeuronKit.rhythm(buckets: buckets, bucketDurationSeconds: 1.0, topK: 0)
        #expect(result.isEmpty)
    }

    // B-8 edge: non-positive bucketDurationSeconds → empty.
    @Test("rhythm: non-positive bucketDuration yields empty")
    func nonPositiveDuration() {
        let buckets = [true, false, true, false, true, false, true, false]
        let r1 = NeuronKit.rhythm(buckets: buckets, bucketDurationSeconds: 0.0, topK: 3)
        let r2 = NeuronKit.rhythm(buckets: buckets, bucketDurationSeconds: -1.0, topK: 3)
        #expect(r1.isEmpty)
        #expect(r2.isEmpty)
    }

    // Alternating true/false at 1-second buckets has a 2-second period (Nyquist).
    @Test("rhythm: alternating series has 2-second dominant period")
    func alternatingDominantPeriod() {
        let buckets = [true, false, true, false, true, false, true, false]
        let result = NeuronKit.rhythm(buckets: buckets, bucketDurationSeconds: 1.0, topK: 1)
        #expect(!result.isEmpty)
        // The Nyquist bin (N/2 = 4 for N=8) period = 2 * 1.0 s.
        #expect(abs(result[0].periodSeconds - 2.0) < 0.001,
                "alternating signal dominant period should be ~2 s")
    }

    // Result is sorted by relative magnitude descending.
    @Test("rhythm: result sorted by relative magnitude descending")
    func sortedDescending() {
        let buckets = [true, false, true, false, true, false, true, false,
                       true, false, true, false, true, false, true, false]
        let result = NeuronKit.rhythm(buckets: buckets, bucketDurationSeconds: 1.0, topK: 4)
        let mags = result.map(\.relativeMagnitude)
        #expect(mags == mags.sorted(by: >), "magnitudes must be descending")
    }

    // topK caps the result length.
    @Test("rhythm: result capped to topK")
    func cappedToTopK() {
        let buckets = [true, false, true, false, true, false, true, false]
        let result = NeuronKit.rhythm(buckets: buckets, bucketDurationSeconds: 1.0, topK: 2)
        #expect(result.count <= 2)
    }

    // Relative magnitudes sum to ≤ 1.0 (each is a fraction of total AC energy).
    @Test("rhythm: relative magnitudes sum at most 1.0")
    func relativeMagnitudeBound() {
        let buckets = [true, false, true, true, false, false, true, false]
        let result = NeuronKit.rhythm(buckets: buckets, bucketDurationSeconds: 60.0, topK: 10)
        let sum = result.map(\.relativeMagnitude).reduce(0.0, +)
        #expect(sum <= 1.0 + 1e-6, "relative magnitudes must sum to at most 1.0")
    }

    // B-5 determinism.
    @Test("rhythm: deterministic — same input produces same output")
    func deterministic() {
        let buckets = [true, false, true, false, true, false, true, false]
        let r1 = NeuronKit.rhythm(buckets: buckets, bucketDurationSeconds: 3600.0, topK: 3)
        let r2 = NeuronKit.rhythm(buckets: buckets, bucketDurationSeconds: 3600.0, topK: 3)
        #expect(r1 == r2)
    }

    // C-17 fidelity: dominant period from the lens equals what FFT.forward produces
    // when called directly on the same zero-padded series.
    @Test("rhythm fidelity (C-17): dominant period equals direct FFT.forward result")
    func c17FidelityPeriodMatchesPrimitive() {
        // Alternating series zero-padded to N=8 (already power-of-two for length 8).
        let buckets = [true, false, true, false, true, false, true, false]
        let duration = 1.0
        let real = buckets.map { $0 ? 1.0 : 0.0 }
        let spectrum = FFT.forward(real: real)  // N=8, no zero-padding needed
        // Positive bins 1..4; dominant for alternating = bin 4 (Nyquist).
        let domBin = (1...4).max(by: { spectrum[$0].magnitude < spectrum[$1].magnitude })!
        let expectedPeriod = Double(8) / Double(domBin) * duration
        let result = NeuronKit.rhythm(buckets: buckets, bucketDurationSeconds: duration, topK: 1)
        #expect(!result.isEmpty)
        #expect(abs(result[0].periodSeconds - expectedPeriod) < 1e-9,
                "lens period must equal FFT.forward bin period on the same inputs")
    }
}
