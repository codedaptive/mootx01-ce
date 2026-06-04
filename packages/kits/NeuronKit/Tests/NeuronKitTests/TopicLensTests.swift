import Testing
import Foundation
@testable import NeuronKit

// Topic lenses (SPEC § 7.2). Tests assert the behavioral claims the spec makes
// — not any implementation. Theme weather reports per-category momentum (recent
// attention share vs historical share); latent themes factors a co-occurrence
// into soft topic loadings. Both pure and deterministic (B-5, I-18); total over
// edge inputs (B-8, C-16).

@Suite("Topic lenses (SPEC § 7.2)")
struct TopicLensTests {

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

    // MARK: latentThemes — soft topic factors

    // Spec's defining claim: labels that co-occur load onto shared themes;
    // mixed-membership, not a hard bucket. Build two clusters of labels that
    // co-occur strongly within cluster and not across, ask for k=2, and expect
    // each label's dominant theme to separate the two clusters.
    @Test("latentThemes: co-occurring labels share a latent theme")
    func latentThemesSeparatesClusters() {
        let labels = ["a1", "a2", "a3", "b1", "b2", "b3"]
        // Strong within-cluster co-occurrence, none across.
        let cooc = [
            (labelA: "a1", labelB: "a2", weight: 5.0),
            (labelA: "a1", labelB: "a3", weight: 5.0),
            (labelA: "a2", labelB: "a3", weight: 5.0),
            (labelA: "b1", labelB: "b2", weight: 5.0),
            (labelA: "b1", labelB: "b3", weight: 5.0),
            (labelA: "b2", labelB: "b3", weight: 5.0),
        ]
        let themes = NeuronKit.latentThemes(labels: labels, cooccurrence: cooc, k: 2, seed: 42)
        #expect(themes.k == 2)
        #expect(themes.loadings.count == 6, "one loading vector per label")
        let dom = Dictionary(uniqueKeysWithValues: themes.loadings.map { ($0.label, $0.dominantTheme) })
        // The three a-labels share a dominant theme; the three b-labels share the other.
        #expect(dom["a1"] == dom["a2"] && dom["a2"] == dom["a3"], "a-cluster shares a theme")
        #expect(dom["b1"] == dom["b2"] && dom["b2"] == dom["b3"], "b-cluster shares a theme")
        #expect(dom["a1"] != dom["b1"], "the two clusters separate")
    }

    // k is clamped to the label count.
    @Test("latentThemes: k clamped to label count")
    func latentThemesKClamped() {
        let labels = ["x", "y"]
        let cooc = [(labelA: "x", labelB: "y", weight: 1.0)]
        let themes = NeuronKit.latentThemes(labels: labels, cooccurrence: cooc, k: 99, seed: 7)
        #expect(themes.k <= 2, "k cannot exceed the number of labels")
    }

    // Deterministic for a fixed seed (B-5).
    @Test("latentThemes: deterministic for a fixed seed")
    func latentThemesDeterministic() {
        let labels = ["a1", "a2", "b1", "b2"]
        let cooc = [
            (labelA: "a1", labelB: "a2", weight: 3.0),
            (labelA: "b1", labelB: "b2", weight: 3.0),
        ]
        let first = NeuronKit.latentThemes(labels: labels, cooccurrence: cooc, k: 2, seed: 123)
        let second = NeuronKit.latentThemes(labels: labels, cooccurrence: cooc, k: 2, seed: 123)
        #expect(first == second)
    }

    // Edge totality (C-16): no labels, or k == 0, ⇒ empty factorization.
    @Test("latentThemes: total over edge inputs")
    func latentThemesEdgeTotality() {
        let empty = NeuronKit.latentThemes(labels: [], cooccurrence: [], k: 3, seed: 1)
        #expect(empty.k == 0 && empty.loadings.isEmpty)
        let zeroK = NeuronKit.latentThemes(labels: ["x", "y"], cooccurrence: [], k: 0, seed: 1)
        #expect(zeroK.k == 0 && zeroK.loadings.isEmpty)
    }
}
