import Testing
import Foundation
@testable import NeuronKit

// Theme-weather lens (SPEC § 7.2). Tests assert the behavioral claims
// the spec makes — not any implementation. Theme weather reports
// per-category momentum (recent attention share vs historical share);
// recencyWeight is its thin decay helper. Pure and deterministic
// (B-5, I-18); total over edge inputs (B-8, C-16). Peer to
// Lenses/ThemeWeather.swift.

@Suite("Theme-weather lens (SPEC § 7.2)")
struct ThemeWeatherLensTests {

    // MARK: recencyWeight — the thin decay helper

    // Spec: 1.0 at "now" (zero elapsed), halving each half-life.
    @Test("recencyWeight: 1.0 now, halves each half-life")
    func recencyWeightHalving() {
        let hl = 100.0
        #expect(NeuronKit.recencyWeight(elapsedSeconds: 0, halfLifeSeconds: hl) == 1.0)
        let oneHalfLife = NeuronKit.recencyWeight(elapsedSeconds: hl, halfLifeSeconds: hl)
        #expect(abs(oneHalfLife - 0.5) < 1e-9, "one half-life ⇒ 0.5")
        let twoHalfLives = NeuronKit.recencyWeight(elapsedSeconds: 2 * hl, halfLifeSeconds: hl)
        #expect(abs(twoHalfLives - 0.25) < 1e-9, "two half-lives ⇒ 0.25")
    }

    // Monotonic: older ⇒ smaller weight.
    @Test("recencyWeight: monotonically decreasing in elapsed time")
    func recencyWeightMonotonic() {
        let hl = 50.0
        let recent = NeuronKit.recencyWeight(elapsedSeconds: 10, halfLifeSeconds: hl)
        let older = NeuronKit.recencyWeight(elapsedSeconds: 200, halfLifeSeconds: hl)
        #expect(recent > older)
    }

    // MARK: themeWeather — recency momentum

    // Spec's defining claim: a category whose recent attention share exceeds its
    // historical share is heating (positive momentum); one whose recent share
    // trails its historical share is cooling (negative). Construct exactly that:
    // two categories with equal raw counts, but one carries far more recent mass.
    @Test("themeWeather: a category with outsized recent share has positive momentum")
    func themeWeatherHeatingVsCooling() {
        // Equal historical counts (10 each). "rising" holds 90% of recent mass.
        let categories = [
            (category: "rising", rawCount: 10.0, weightedMass: 9.0),
            (category: "fading", rawCount: 10.0, weightedMass: 1.0),
        ]
        let w = NeuronKit.themeWeather(categories: categories)
        let rising = w.first { $0.category == "rising" }!
        let fading = w.first { $0.category == "fading" }!
        // rising: recent share 0.9 − historical share 0.5 = +0.4; fading: −0.4.
        #expect(rising.momentum > 0, "outsized recent share ⇒ heating")
        #expect(fading.momentum < 0, "undersized recent share ⇒ cooling")
        #expect(abs(rising.momentum + fading.momentum) < 1e-9, "shares are zero-sum across the set")
    }

    // Result is sorted by momentum descending (hottest first), ties by category name.
    @Test("themeWeather: sorted hottest-first, ties by category name")
    func themeWeatherSorted() {
        let categories = [
            (category: "b", rawCount: 10.0, weightedMass: 5.0),   // neutral
            (category: "a", rawCount: 10.0, weightedMass: 5.0),   // neutral (ties b)
            (category: "hot", rawCount: 10.0, weightedMass: 20.0),
        ]
        let w = NeuronKit.themeWeather(categories: categories)
        #expect(w.first?.category == "hot", "hottest first")
        let moms = w.map(\.momentum)
        #expect(moms == moms.sorted(by: >), "descending momentum")
        // a and b tie on momentum ⇒ "a" precedes "b".
        let ai = w.firstIndex { $0.category == "a" }!
        let bi = w.firstIndex { $0.category == "b" }!
        #expect(ai < bi, "ties broken by ascending category name")
    }

    // Edge totality (C-16): empty input ⇒ empty result.
    @Test("themeWeather: total over edge inputs")
    func themeWeatherEmpty() {
        #expect(NeuronKit.themeWeather(categories: []).isEmpty)
    }
}
