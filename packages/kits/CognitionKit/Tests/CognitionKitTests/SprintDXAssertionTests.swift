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
//   • GeniusLocusKit.defaultStandingSignalNames.count == 13 — 7 baseline
//     + DistillationSignal (Dg4) + TrainingSignal
//     + ContradictionScoutSignal (contradiction hunter)
//     + ConsolidationSignal + AnomalySweepSignal + AdornmentPassSignal.
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

    /// CK-DX-1: RecipeCatalog carries all 31 recipes.
    ///
    /// Baseline 26 + 2 distillation-family recipes (distill,
    /// distilled_recall — recollect retired with the factoid tier,
    /// SPEC_DISTILLATION_STORAGE §11); + 1 diffusion node-layer lens
    /// (node_motion); + 1 escalation-ladder recall recipe (walk_recall, D10);
    /// + redistill (CDL-02, force-redistill all items + laneScope .all reindex).
    @Test("CK-DX-1: RecipeCatalog.all.count == 31 (26 baseline + 2 distillation + node_motion + walk_recall + redistill)")
    func recipeCatalogCountIncludesDistillationTriple() {
        #expect(RecipeCatalog.all.count == 31,
            "RecipeCatalog must contain exactly 31 recipes: 26 baseline + 2 distillation + node_motion + walk_recall + redistill (CDL-02)")
    }

    /// CK-DX-2: defaultStandingSignalNames contains all 13 standing signals.
    ///
    /// Thirteen signals: 7 baseline + DistillationSignal (Dg4) + TrainingSignal
    /// + ContradictionScoutSignal (contradiction hunter) + ConsolidationSignal
    /// + AnomalySweepSignal (signal 12, P3a anomaly-flag sweep)
    /// + AdornmentPassSignal (signal 13, GENIUSLOCUSKIT_SPEC 2.0.0 § 16).
    /// The signal inventory table in GENIUSLOCUSKIT_SPEC.md defines the set.
    @Test("CK-DX-2: GeniusLocusKit.defaultStandingSignalNames.count == 13 (includes AdornmentPassSignal)")
    func defaultStandingSignalNamesCountIsThirteen() {
        #expect(GeniusLocusKit.defaultStandingSignalNames.count == 13,
            "defaultStandingSignalNames must contain exactly 13 signals per the GENIUSLOCUSKIT_SPEC inventory (13th: adornment-pass)")
    }
}
