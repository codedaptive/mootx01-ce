// SprintDXAssertionTests.swift
//
// Sprint DX milestone assertions — catalog count, routing, signal count.
//
// These tests serve as a single committed anchor that all Sprint DX
// deliverables landed correctly:
//
//   • RecipeCatalog.all.count == 29 (baseline 26 + 2 distillation recipes:
//     distill, distilled_recall; + node_motion
//     diffusion node-layer lens).
//
//   • GeniusLocusKit.defaultStandingSignalNames.count == 11 — 7 baseline
//     + DistillationSignal (Dg4) + TrainingSignal
//     + ContradictionScoutSignal (contradiction hunter).
//
// isRecipeTool assertions for the three distillation tools live in
// AriaMcpKit/RecipeToolsTests.swift (they require AriaMcpKit scope).
//
// Test IDs: CK-DX-1, CK-DX-2

import Testing
import GeniusLocusKit
@testable import CognitionKit

@Suite("SprintDXAssertionTests — Sprint DX milestone gate")
struct SprintDXAssertionTests {

    /// CK-DX-1: RecipeCatalog carries all 30 Sprint DX recipes.
    ///
    /// Baseline 26 + 2 distillation-family recipes (distill,
    /// distilled_recall — recollect retired with the factoid tier,
    /// SPEC_DISTILLATION_STORAGE §11); + 1 diffusion
    /// node-layer lens (node_motion, node motion modeling).
    @Test("CK-DX-1: RecipeCatalog.all.count == 29 (26 baseline + 2 distillation + node_motion)")
    func recipeCatalogCountIncludesDistillationTriple() {
        #expect(RecipeCatalog.all.count == 29,
            "RecipeCatalog must contain exactly 29 recipes: 26 baseline + 2 distillation + node_motion")
    }

    /// CK-DX-2: defaultStandingSignalNames contains all 11 standing signals.
    ///
    /// Eleven signals: 7 baseline + DistillationSignal (Dg4) + TrainingSignal
    /// + ContradictionScoutSignal (contradiction hunter).
    /// The signal inventory table in GENIUSLOCUSKIT_SPEC.md defines the set.
    @Test("CK-DX-2: GeniusLocusKit.defaultStandingSignalNames.count == 11 (includes ContradictionScoutSignal)")
    func defaultStandingSignalNamesCountIsEleven() {
        #expect(GeniusLocusKit.defaultStandingSignalNames.count == 11,
            "defaultStandingSignalNames must contain exactly 11 signals: 7 baseline + DistillationSignal (Dg4) + TrainingSignal + ContradictionScoutSignal")
    }
}
