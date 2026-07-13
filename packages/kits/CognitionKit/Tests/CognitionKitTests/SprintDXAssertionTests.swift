// SprintDXAssertionTests.swift
//
// Sprint DX milestone assertions — catalog count, routing, signal count.
//
// These tests serve as a single committed anchor that all Sprint DX
// deliverables landed correctly:
//
//   • RecipeCatalog.all.count == 30 (baseline 26 + 3 distillation recipes
//     from Dc4: consolidate, distilled_recall, recollect; + node_motion
//     diffusion node-layer lens).
//
//   • GeniusLocusKit.defaultStandingSignalNames.count == 10 — 7 baseline
//     + DistillationSignal (Dg4) + TrainingSignal (ADR-018 F1)
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
    /// Baseline 26 + 3 distillation-family recipes (consolidate,
    /// distilled_recall, recollect) registered by Dc4; + 1 diffusion
    /// node-layer lens (node_motion, ADR-DIFFUSION-001).
    @Test("CK-DX-1: RecipeCatalog.all.count == 30 (26 baseline + 3 distillation + node_motion)")
    func recipeCatalogCountIncludesDistillationTriple() {
        #expect(RecipeCatalog.all.count == 30,
            "RecipeCatalog must contain exactly 30 recipes: 26 baseline + 3 distillation (Dc4) + node_motion")
    }

    /// CK-DX-2: defaultStandingSignalNames contains all 10 standing signals.
    ///
    /// Ten signals: 7 baseline + DistillationSignal (Dg4) + TrainingSignal
    /// (ADR-018 F1) + ContradictionScoutSignal (contradiction hunter).
    /// The signal inventory table in GENIUSLOCUSKIT_SPEC.md defines the set.
    @Test("CK-DX-2: GeniusLocusKit.defaultStandingSignalNames.count == 10 (includes ContradictionScoutSignal)")
    func defaultStandingSignalNamesCountIsTen() {
        #expect(GeniusLocusKit.defaultStandingSignalNames.count == 10,
            "defaultStandingSignalNames must contain exactly 10 signals: 7 baseline + DistillationSignal (Dg4) + TrainingSignal (ADR-018 F1) + ContradictionScoutSignal")
    }
}
