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
//   • GeniusLocusKit.defaultStandingSignalNames.count == 12 — 7 baseline
//     + TrainingSignal + ContradictionScoutSignal (contradiction hunter)
//     + ConsolidationSignal + AnomalySweepSignal + SpanEncodeSignal.
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

    /// CK-DX-2: defaultStandingSignalNames contains all 12 standing signals.
    ///
    /// Twelve signals: 7 baseline + TrainingSignal
    /// + ContradictionScoutSignal (contradiction hunter) + ConsolidationSignal
    /// + AnomalySweepSignal (signal 11, P3a anomaly-flag sweep)
    /// + SpanEncodeSignal (signal 12, span-encode drain signal).
    /// The signal inventory table in GENIUSLOCUSKIT_SPEC.md defines the set.
    @Test("CK-DX-2: GeniusLocusKit.defaultStandingSignalNames.count == 12 (includes SpanEncodeSignal)")
    func defaultStandingSignalNamesCountIsTwelve() {
        #expect(GeniusLocusKit.defaultStandingSignalNames.count == 12,
            "defaultStandingSignalNames must contain exactly 12 signals per the GENIUSLOCUSKIT_SPEC inventory (12th: SpanEncodeSignal)")
    }
}
