import Testing
@testable import NeuronKit

// Prediction lens (SPEC § 7.4). Tests assert the behavioral claims the spec
// makes — not the implementation. anticipate learns which actions reliably
// reach a target outcome, ranked by Wilson lower bound so a few lucky successes
// don't outrank a well-evidenced action. Pure, deterministic (B-5, I-18); total
// over edge inputs (B-8, C-16).

@Suite("Anticipation lens (SPEC § 7.4)")
struct AnticipationTests {

    private func obs(_ action: UInt8, _ outcome: UInt8, _ success: Bool, _ n: Int) -> [ActionObservation] {
        Array(repeating: ActionObservation(action: action, outcome: outcome, success: success), count: n)
    }

    // Spec's defining claim: a well-evidenced reliable action ranks above a
    // poorly-evidenced one for the target outcome. Action 1 succeeds 18/20;
    // action 2 succeeds 2/2 (lucky but thin). Wilson lower bound ranks the
    // well-evidenced action first.
    @Test("anticipate: a well-evidenced action outranks a lucky thin one")
    func anticipateWilsonRanking() {
        let target: UInt8 = 1
        var events: [ActionObservation] = []
        events += obs(1, target, true, 18) + obs(1, target, false, 2)   // 18/20
        events += obs(2, target, true, 2)                                // 2/2, thin
        let preds = NeuronKit.anticipate(observations: events, targetOutcome: target,
                                         k: 10, minObservations: 1)
        #expect(preds.first?.action == 1, "well-evidenced action ranks first by Wilson LB")
        // successRate field carries the Wilson lower bound (ranked desc).
        #expect(preds.map(\.successRate) == preds.map(\.successRate).sorted(by: >))
    }

    // Only actions seen at least minObservations times are returned.
    @Test("anticipate: filters actions below minObservations")
    func anticipateMinObservations() {
        let target: UInt8 = 1
        var events: [ActionObservation] = []
        events += obs(1, target, true, 10)      // seen 10×
        events += obs(2, target, true, 2)        // seen 2×
        let preds = NeuronKit.anticipate(observations: events, targetOutcome: target,
                                         k: 10, minObservations: 5)
        #expect(preds.contains { $0.action == 1 })
        #expect(!preds.contains { $0.action == 2 }, "below-threshold action filtered out")
    }

    // Only observations for the TARGET outcome count.
    @Test("anticipate: ignores observations for other outcomes")
    func anticipateOutcomeScoped() {
        var events: [ActionObservation] = []
        events += obs(1, 1, true, 10)            // action 1 → outcome 1
        events += obs(2, 2, true, 10)            // action 2 → outcome 2 (different target)
        let preds = NeuronKit.anticipate(observations: events, targetOutcome: 1,
                                         k: 10, minObservations: 1)
        #expect(preds.contains { $0.action == 1 })
        #expect(!preds.contains { $0.action == 2 }, "other-outcome action not predicted")
    }

    // Result is capped to k.
    @Test("anticipate: capped to k")
    func anticipateCapped() {
        let target: UInt8 = 1
        var events: [ActionObservation] = []
        for a: UInt8 in 1...5 { events += obs(a, target, true, 10) }
        let preds = NeuronKit.anticipate(observations: events, targetOutcome: target,
                                         k: 3, minObservations: 1)
        #expect(preds.count == 3)
    }

    // Count carried through is the total observations of that action→outcome.
    @Test("anticipate: count reflects total observations")
    func anticipateCount() {
        let target: UInt8 = 1
        let events = obs(1, target, true, 7) + obs(1, target, false, 3)   // 10 total
        let preds = NeuronKit.anticipate(observations: events, targetOutcome: target,
                                         k: 10, minObservations: 1)
        #expect(preds.first { $0.action == 1 }?.count == 10)
    }

    // Deterministic (B-5).
    @Test("anticipate: deterministic")
    func anticipateDeterministic() {
        let target: UInt8 = 1
        let events = obs(1, target, true, 8) + obs(2, target, true, 5) + obs(1, target, false, 2)
        let a = NeuronKit.anticipate(observations: events, targetOutcome: target, k: 10, minObservations: 1)
        let b = NeuronKit.anticipate(observations: events, targetOutcome: target, k: 10, minObservations: 1)
        #expect(a == b)
    }

    // Edge totality (C-16): no observations, or k == 0, ⇒ empty.
    @Test("anticipate: total over edge inputs")
    func anticipateEdgeTotality() {
        #expect(NeuronKit.anticipate(observations: [], targetOutcome: 1, k: 10, minObservations: 1).isEmpty)
        let events = obs(1, 1, true, 5)
        #expect(NeuronKit.anticipate(observations: events, targetOutcome: 1, k: 0, minObservations: 1).isEmpty)
    }
}
