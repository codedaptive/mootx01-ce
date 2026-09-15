// SprintDXAssertionTests.swift
//
// Sprint DX milestone assertions — catalog count, routing, signal count.
//
// These tests serve as a single committed anchor that all Sprint DX
// deliverables landed correctly:
//
//   • RecipeCatalog.all.count == 29 (baseline 26 + distilled_recall +
//     node_motion + walk_recall).
//
//   • GeniusLocusKit.defaultStandingSignalNames.count == 6 (the always-on
//     set) and GeniusLocusKit.preferenceGatedStandingSignalNames carries the
//     eight preference-gated signals: consolidation sweep, contradiction
//     sweep, the maintenance family (maintenance-daemon, decay-sweep,
//     by-reference-validity) and the adaptive-recall trio
//     (temporal-causality-fold, training-daemon, end-of-day-tournament).
//
// isRecipeTool assertions for the distilled-recall tool live in
// AriaMcpKit/RecipeToolsTests.swift (they require AriaMcpKit scope).
//
// Test IDs: CK-DX-1, CK-DX-2

import Testing
import GeniusLocusKit
@testable import CognitionKit

@Suite("SprintDXAssertionTests — Sprint DX milestone gate")
struct SprintDXAssertionTests {

    /// CK-DX-1: RecipeCatalog carries all 29 recipes.
    ///
    /// Baseline 26 + distilled_recall (inline rendering via ContextDistillLib);
    /// + 1 diffusion node-layer lens (node_motion);
    /// + 1 escalation-ladder recall recipe (walk_recall, D10).
    @Test("CK-DX-1: RecipeCatalog.all.count == 29 (26 baseline + distilled_recall + node_motion + walk_recall)")
    func recipeCatalogCountIsCorrect() {
        #expect(RecipeCatalog.all.count == 29,
            "RecipeCatalog must contain exactly 29 recipes: 26 baseline + distilled_recall + node_motion + walk_recall")
    }

    /// CK-DX-2: the standing-signal vocabulary is split into two lists in
    /// DefaultStandingSignals.swift and this test pins both.
    ///
    /// `defaultStandingSignalNames` is the always-on set (six names:
    /// dreaming-daemon, vector-similarity, contradiction-scout,
    /// anomaly-flag-sweep, span-encode, fact-extraction). The
    /// preference-gated signals live in `preferenceGatedStandingSignalNames`
    /// and register only when the host passes a live cycle closure, so
    /// they are pinned by name rather than folded into the always-on count:
    /// consolidation sweep, contradiction sweep, the maintenance family
    /// (maintenance-daemon, decay-sweep, by-reference-validity) and the
    /// adaptive-recall trio (temporal-causality-fold, training-daemon,
    /// end-of-day-tournament).
    @Test("CK-DX-2: defaultStandingSignalNames.count == 6 and preferenceGatedStandingSignalNames carries the eight gated names")
    func standingSignalVocabularyIsPinned() {
        #expect(GeniusLocusKit.defaultStandingSignalNames.count == 6,
            "defaultStandingSignalNames must contain exactly the 6 always-on signals")

        let gated = GeniusLocusKit.preferenceGatedStandingSignalNames
        let expectedGated = [
            "consolidation-sweep",
            "contradiction-sweep",
            "maintenance-daemon",
            "decay-sweep",
            "by-reference-validity",
            "temporal-causality-fold",
            "training-daemon",
            "end-of-day-tournament",
        ]
        for name in expectedGated {
            #expect(gated.contains(name),
                "preferenceGatedStandingSignalNames must contain \(name)")
        }
        #expect(gated.count == expectedGated.count,
            "preferenceGatedStandingSignalNames must contain exactly the 8 gated signals")
    }
}
