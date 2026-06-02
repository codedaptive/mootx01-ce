import Testing
import Foundation
@testable import NeuronKit

// Latent-themes lens (SPEC § 7.2). Tests assert the behavioral claims
// the spec makes — not any implementation. Latent themes factors a
// co-occurrence into soft topic loadings. Pure and deterministic
// (B-5, I-18); total over edge inputs (B-8, C-16). Peer to
// Lenses/LatentThemes.swift.

@Suite("Latent-themes lens (SPEC § 7.2)")
struct LatentThemesLensTests {

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
