import Testing
@testable import NeuronKit

// Preference lenses (SPEC § 7.3). Tests assert the behavioral claims the spec
// makes — not any implementation. representationBias reports the signed
// share-difference between an estate and a reference; learnedPreference fits a
// Bradley-Terry utility from curation records via the anchor reduction. Pure,
// deterministic (B-5, I-18); representationBias is total, learnedPreference
// forwards the fitter's typed error only on the baseline-sentinel name (C-16,
// § 6).

@Suite("Bias lenses (SPEC § 7.3)")
struct BiasTests {

    // MARK: representationBias — distributional

    // Spec's defining claim: bias = estate share − reference share, per
    // category over the UNION of both label sets. Over-represented ⇒ positive;
    // a category present only in the reference (estate share 0) ⇒ strongly
    // negative = avoided.
    @Test("representationBias: over- and under-representation are signed shares")
    func biasSignedShares() {
        // Estate is all "work"; reference splits work/play evenly.
        let estate = [(label: "work", mass: 10.0)]
        let reference = [(label: "work", mass: 5.0), (label: "play", mass: 5.0)]
        let bias = NeuronKit.representationBias(estate: estate, reference: reference)
        let work = bias.first { $0.label == "work" }!
        let play = bias.first { $0.label == "play" }!
        // work: estate 1.0 − ref 0.5 = +0.5; play: estate 0.0 − ref 0.5 = −0.5.
        #expect(abs(work.bias - 0.5) < 1e-9)
        #expect(abs(play.bias + 0.5) < 1e-9, "category absent from estate is avoided (negative)")
        #expect(abs(work.estateShare - 1.0) < 1e-9)
        #expect(abs(play.estateShare) < 1e-9)
    }

    // Sorted by bias descending — most over-represented first, most avoided
    // last, ties by label.
    @Test("representationBias: sorted bias-descending, ties by label")
    func biasSorted() {
        let estate = [(label: "a", mass: 1.0), (label: "b", mass: 1.0), (label: "hot", mass: 8.0)]
        let reference = [(label: "a", mass: 1.0), (label: "b", mass: 1.0), (label: "hot", mass: 1.0)]
        let bias = NeuronKit.representationBias(estate: estate, reference: reference)
        #expect(bias.first?.label == "hot", "most over-represented first")
        let vals = bias.map(\.bias)
        #expect(vals == vals.sorted(by: >), "descending bias")
        // a and b have equal bias ⇒ "a" precedes "b".
        let ai = bias.firstIndex { $0.label == "a" }!
        let bi = bias.firstIndex { $0.label == "b" }!
        #expect(ai < bi, "ties broken by ascending label")
    }

    // Edge totality (C-16): both empty ⇒ empty.
    @Test("representationBias: total over edge inputs")
    func biasEmpty() {
        #expect(NeuronKit.representationBias(estate: [], reference: []).isEmpty)
    }

    // MARK: learnedPreference — Bradley-Terry from curation

    // Spec's defining claim: a room with more endorsements than dismissals has
    // positive learned strength; one with more dismissals, negative; the
    // baseline re-centres to ~0. Strength is preference relative to neutral.
    @Test("learnedPreference: endorsed rooms outrank dismissed rooms")
    func learnedPreferenceSign() throws {
        let records = [
            (label: "loved", endorsements: 8, dismissals: 1),
            (label: "mixed", endorsements: 3, dismissals: 3),
            (label: "disliked", endorsements: 1, dismissals: 8),
        ]
        let prefs = try NeuronKit.learnedPreference(records: records)
        let loved = prefs.first { $0.label == "loved" }!
        let mixed = prefs.first { $0.label == "mixed" }!
        let disliked = prefs.first { $0.label == "disliked" }!
        #expect(loved.strength > 0, "net-endorsed ⇒ positive")
        #expect(disliked.strength < 0, "net-dismissed ⇒ negative")
        #expect(abs(mixed.strength) < loved.strength, "balanced room sits near neutral")
        // Returned strongest first.
        #expect(prefs.first?.label == "loved")
        // Each carries its endorsement/dismissal counts through.
        #expect(loved.endorsements == 8 && loved.dismissals == 1)
    }

    // The anchor reduction makes the graph strongly connected by construction,
    // so an only-endorsed or only-dismissed room still fits (no
    // disconnectedComparisonGraph). This is the spec's explicit guarantee.
    @Test("learnedPreference: only-endorsed and only-dismissed rooms still fit")
    func learnedPreferenceOnlyOneSided() throws {
        let records = [
            (label: "alwaysKept", endorsements: 5, dismissals: 0),
            (label: "alwaysTossed", endorsements: 0, dismissals: 5),
        ]
        let prefs = try NeuronKit.learnedPreference(records: records)
        #expect(prefs.count == 2, "fit succeeds despite one-sided records")
        #expect(prefs.first { $0.label == "alwaysKept" }!.strength
                > prefs.first { $0.label == "alwaysTossed" }!.strength)
    }

    // A room with little curation signal shrinks toward the baseline (strength
    // ≈ 0 = "no learned preference yet").
    @Test("learnedPreference: sparse-signal room shrinks toward neutral")
    func learnedPreferenceShrinksToNeutral() throws {
        let records = [
            (label: "barelyTouched", endorsements: 1, dismissals: 1),
            (label: "stronglyLoved", endorsements: 20, dismissals: 0),
        ]
        let prefs = try NeuronKit.learnedPreference(records: records)
        let barely = prefs.first { $0.label == "barelyTouched" }!
        #expect(abs(barely.strength) < 0.5, "near neutral with little signal")
    }

    // Deterministic (B-5).
    @Test("learnedPreference: deterministic")
    func learnedPreferenceDeterministic() throws {
        let records = [
            (label: "x", endorsements: 4, dismissals: 2),
            (label: "y", endorsements: 2, dismissals: 4),
        ]
        let a = try NeuronKit.learnedPreference(records: records)
        let b = try NeuronKit.learnedPreference(records: records)
        #expect(a == b)
    }

    // Edge totality (C-16): empty input ⇒ empty output.
    @Test("learnedPreference: empty input is empty output")
    func learnedPreferenceEmpty() throws {
        #expect(try NeuronKit.learnedPreference(records: []).isEmpty)
    }

    // § 6: selfPairing propagates only if a room is literally named the
    // baseline sentinel (the one reserved competitor name).
    @Test("learnedPreference: a room named the baseline sentinel throws selfPairing")
    func learnedPreferenceBaselineSentinelThrows() {
        let records = [(label: NeuronKit.preferenceBaselineSentinel, endorsements: 3, dismissals: 1)]
        #expect(throws: MOOTx01Error.self) {
            try NeuronKit.learnedPreference(records: records)
        }
    }
}
