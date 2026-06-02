import Testing
@testable import NeuronKit

// Drift lens (SPEC § 7.5). Tests assert the behavioral claims the spec
// makes — not the implementation. drift quantifies how far distribution
// q has moved from p: Jensen-Shannon (symmetric, bounded — the primary
// signal) and KL D(p‖q) (asymmetric — how surprising q is under p).
// Pure, deterministic (B-5, I-18); total over edge inputs (B-8).

@Suite("Drift lens (SPEC § 7.5)")
struct DriftTests {

    // DR-1: identical distributions have zero Jensen-Shannon drift —
    // no shift ⇒ no drift.
    @Test("identical distributions have zero drift")
    func identicalIsZeroDrift() {
        let p: [Float] = [0.5, 0.3, 0.2]
        let score = NeuronKit.drift(from: p, to: p)
        #expect(abs(score.jensenShannon) < 1e-5)
    }

    // DR-2: a clear shift registers more drift than a slight one — JS
    // grows monotonically with separation.
    @Test("a bigger shift drifts more")
    func biggerShiftMoreDrift() {
        let p: [Float] = [0.8, 0.1, 0.1]
        let slight = NeuronKit.drift(from: p, to: [0.7, 0.2, 0.1]).jensenShannon
        let big = NeuronKit.drift(from: p, to: [0.1, 0.1, 0.8]).jensenShannon
        #expect(big > slight)
    }

    // DR-3: maximally disjoint distributions drift the most (mass moved
    // to a bin that was empty).
    @Test("disjoint support is high drift")
    func disjointIsHighDrift() {
        let score = NeuronKit.drift(from: [1.0, 0.0], to: [0.0, 1.0])
        #expect(score.jensenShannon > 0.5)
    }
}
