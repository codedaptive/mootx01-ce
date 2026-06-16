import Testing
@testable import NeuronKit
import SubstrateML

// Complexity lens tests (SPEC § 8.2, Lens 4 Topics).
// Verify spec behavioural claims: Shannon entropy, mutual information,
// edge totality (B-8), determinism (B-5).

@Suite("Complexity lens (SPEC § 8.2, Lens 4)")
struct ComplexityLensTests {

    // B-8 edge: empty countsA → entropyA = 0.
    @Test("complexity: empty countsA yields entropyA = 0")
    func emptyCountsAYieldsZeroEntropy() {
        let result = NeuronKit.complexity(countsA: [])
        #expect(result.entropyA == 0.0)
        #expect(result.entropyB == nil)
        #expect(result.mutualInformation == nil)
    }

    // B-8 edge: all-zero counts → entropy 0.
    @Test("complexity: all-zero countsA yields entropyA = 0")
    func allZeroCounts() {
        let result = NeuronKit.complexity(countsA: [0, 0, 0])
        #expect(result.entropyA == 0.0)
    }

    // Uniform distribution of N categories has entropy = log2(N).
    @Test("complexity: uniform distribution yields log2(N) entropy")
    func uniformDistributionEntropy() {
        // 4 equal-count categories: entropy = log2(4) = 2 bits.
        let result = NeuronKit.complexity(countsA: [1, 1, 1, 1])
        #expect(abs(result.entropyA - 2.0) < 0.001,
                "uniform 4-category entropy should be 2.0 bits")
    }

    // Certain distribution (one non-zero bin): entropy = 0.
    @Test("complexity: certain distribution has entropy 0")
    func certainDistributionHasZeroEntropy() {
        let result = NeuronKit.complexity(countsA: [0, 10, 0, 0])
        #expect(result.entropyA == 0.0)
    }

    // countsB = nil → entropyB = nil.
    @Test("complexity: omitting countsB yields nil entropyB")
    func omittedCountsBYieldsNil() {
        let result = NeuronKit.complexity(countsA: [1, 2, 3])
        #expect(result.entropyB == nil)
    }

    // Supplying countsB → entropyB is non-nil.
    @Test("complexity: supplying countsB populates entropyB")
    func suppliedCountsBPopulatesEntropyB() {
        let result = NeuronKit.complexity(countsA: [1, 1], countsB: [1, 1])
        #expect(result.entropyB != nil)
        // Uniform 2-category: 1 bit.
        #expect(abs(result.entropyB! - 1.0) < 0.001)
    }

    // joint = nil → mutualInformation = nil.
    @Test("complexity: omitting joint yields nil mutualInformation")
    func omittedJointYieldsNil() {
        let result = NeuronKit.complexity(countsA: [1, 2])
        #expect(result.mutualInformation == nil)
    }

    // Independent joint distribution (outer product of marginals) → MI ≈ 0.
    @Test("complexity: independent joint yields near-zero mutual information")
    func independentJointYieldsNearZeroMI() {
        // P(A,B) = P(A)·P(B) for independent variables → MI ≈ 0.
        // A = uniform {0,1}, B = uniform {0,1}: joint = [[0.25, 0.25], [0.25, 0.25]]
        let joint: [[Float32]] = [[1, 1], [1, 1]]
        let result = NeuronKit.complexity(countsA: [1, 1], countsB: [1, 1], joint: joint)
        #expect(result.mutualInformation != nil)
        #expect(abs(result.mutualInformation!) < 0.01,
                "independent joint distribution should yield near-zero MI")
    }

    // B-5 determinism.
    @Test("complexity: deterministic — same input produces same output")
    func deterministic() {
        let counts: [Float32] = [3, 1, 2, 4]
        let r1 = NeuronKit.complexity(countsA: counts)
        let r2 = NeuronKit.complexity(countsA: counts)
        #expect(r1 == r2)
    }

    // C-17 fidelity: lens entropyA equals InformationTheory.entropy called directly
    // on the same normalised distribution.
    @Test("complexity fidelity (C-17): entropyA equals direct InformationTheory.entropy call")
    func c17FidelityEntropyMatchesPrimitive() {
        let counts: [Float32] = [1, 2, 3, 4]
        let total: Float32 = counts.reduce(0, +)
        let normalised = counts.map { $0 / total }
        let direct = InformationTheory.entropy(normalised)
        let result = NeuronKit.complexity(countsA: counts)
        #expect(result.entropyA == direct,
                "lens entropyA must equal InformationTheory.entropy on the normalised distribution")
    }
}
