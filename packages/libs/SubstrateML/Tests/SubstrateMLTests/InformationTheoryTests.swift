// InformationTheoryTests.swift
//
// Information-theoretic primitives per cookbook § 8.11. swift-testing
// peer suite for Sources/SubstrateML/InformationTheory.swift.
//
// rust/src/info_theory.rs carries NO #[test] (it is a straight
// mirror of this file with no inline tests), so this suite asserts
// the behavior set directly from the closed-form properties the
// implementation must satisfy: entropy of a fair coin is 1 bit,
// KL(p‖p)=0, H(p,p)=H(p), JS symmetry/bounds, and MI=0 under
// independence. Units are bits (log base 2) throughout.

import Testing
@testable import SubstrateML

@Suite("InformationTheory")
struct InformationTheoryTests {

    private let tol: Float32 = 1e-5

    // MARK: - Entropy

    @Test("entropy of a certain outcome is zero")
    func entropyCertainIsZero() {
        #expect(abs(InformationTheory.entropy([1.0])) < tol)
        #expect(abs(InformationTheory.entropy([1.0, 0.0, 0.0])) < tol)
    }

    @Test("entropy of a fair coin is exactly 1 bit")
    func entropyFairCoin() {
        #expect(abs(InformationTheory.entropy([0.5, 0.5]) - 1.0) < tol)
    }

    @Test("entropy of a uniform 4-way distribution is 2 bits")
    func entropyUniformFour() {
        let p: [Float32] = [0.25, 0.25, 0.25, 0.25]
        #expect(abs(InformationTheory.entropy(p) - 2.0) < tol)
    }

    @Test("zero-probability terms are skipped (0·log0 = 0)")
    func entropySkipsZeros() {
        // A zero entry must not perturb the result vs. its absence.
        #expect(abs(InformationTheory.entropy([0.5, 0.5, 0.0]) - 1.0) < tol)
    }

    // MARK: - KL divergence

    @Test("KL of a distribution against itself is zero")
    func klSelfIsZero() {
        let p: [Float32] = [0.1, 0.2, 0.3, 0.4]
        #expect(abs(InformationTheory.klDivergence(p, p)) < tol)
    }

    @Test("KL divergence is non-negative (Gibbs' inequality)")
    func klNonNegative() {
        let p: [Float32] = [0.7, 0.2, 0.1]
        let q: [Float32] = [0.3, 0.3, 0.4]
        #expect(InformationTheory.klDivergence(p, q) >= -tol)
    }

    @Test("KL divergence is asymmetric in general")
    func klAsymmetric() {
        let p: [Float32] = [0.7, 0.2, 0.1]
        let q: [Float32] = [0.3, 0.3, 0.4]
        #expect(InformationTheory.klDivergence(p, q) != InformationTheory.klDivergence(q, p))
    }

    // MARK: - Cross entropy

    @Test("cross entropy against itself equals entropy")
    func crossEntropyEqualsEntropyOnSelf() {
        let p: [Float32] = [0.25, 0.25, 0.5]
        #expect(abs(InformationTheory.crossEntropy(p, p) - InformationTheory.entropy(p)) < tol)
    }

    // MARK: - Jensen-Shannon

    @Test("Jensen-Shannon of a distribution against itself is zero")
    func jsSelfIsZero() {
        let p: [Float32] = [0.2, 0.3, 0.5]
        #expect(abs(InformationTheory.jensenShannon(p, p)) < tol)
    }

    @Test("Jensen-Shannon is symmetric and bounded in [0, 1]")
    func jsSymmetricAndBounded() {
        let p: [Float32] = [1.0, 0.0]
        let q: [Float32] = [0.0, 1.0]
        let jspq = InformationTheory.jensenShannon(p, q)
        let jsqp = InformationTheory.jensenShannon(q, p)
        #expect(abs(jspq - jsqp) < tol)            // symmetric
        #expect(jspq >= -tol && jspq <= 1.0 + tol) // bounded; orthogonal ⇒ 1 bit
        #expect(abs(jspq - 1.0) < tol)
    }

    // MARK: - Mutual information

    @Test("mutual information of an independent joint is zero")
    func miIndependentIsZero() {
        // Independent: p(x,y) = p(x)p(y). 2×2 outer product of
        // [0.5,0.5] ⊗ [0.5,0.5] ⇒ all cells 0.25.
        let joint: [[Float32]] = [[0.25, 0.25], [0.25, 0.25]]
        #expect(abs(InformationTheory.mutualInformation(joint: joint)) < tol)
    }

    @Test("mutual information of a perfectly-correlated joint equals the marginal entropy")
    func miPerfectCorrelation() {
        // Diagonal joint: X fully determines Y. I(X;Y) = H(X) = 1 bit.
        let joint: [[Float32]] = [[0.5, 0.0], [0.0, 0.5]]
        #expect(abs(InformationTheory.mutualInformation(joint: joint) - 1.0) < tol)
    }

    @Test("normalized mutual information is 1 under perfect correlation, 0 under independence")
    func nmiBounds() {
        let correlated: [[Float32]] = [[0.5, 0.0], [0.0, 0.5]]
        let independent: [[Float32]] = [[0.25, 0.25], [0.25, 0.25]]
        #expect(abs(InformationTheory.normalizedMutualInformation(joint: correlated) - 1.0) < tol)
        #expect(abs(InformationTheory.normalizedMutualInformation(joint: independent)) < tol)
    }
}
