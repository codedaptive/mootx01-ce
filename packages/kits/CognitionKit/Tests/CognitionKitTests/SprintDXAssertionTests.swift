// SprintDXAssertionTests.swift
//
// Sprint DX milestone assertions — catalog count, routing, signal count.
//
// These tests serve as a single committed anchor that all Sprint DX
// deliverables landed correctly:
//
//   • RecipeCatalog.all.count == 30 (baseline 26 + 3 distillation recipes
//     from Dc4: consolidate, distilled_recall, expand_memory; + node_motion
//     diffusion node-layer lens).
//
//   • GeniusLocusKit.defaultStandingSignalNames.count == 8 — the Dg4
//     distillation signal is the eighth default, per architecture spec §11.2.
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
    /// distilled_recall, expand_memory) registered by Dc4; + 1 diffusion
    /// node-layer lens (node_motion, ADR-DIFFUSION-001).
    @Test("CK-DX-1: RecipeCatalog.all.count == 30 (26 baseline + 3 distillation + node_motion)")
    func recipeCatalogCountIncludesDistillationTriple() {
        #expect(RecipeCatalog.all.count == 30,
            "RecipeCatalog must contain exactly 30 recipes: 26 baseline + 3 distillation (Dc4) + node_motion")
    }

    /// CK-DX-2: defaultStandingSignalNames contains all 8 v1 signals.
    ///
    /// The DistillationSignal registered by Dg4 is the eighth entry.
    /// Architecture spec §11.2 defines the complete v1 set.
    @Test("CK-DX-2: GeniusLocusKit.defaultStandingSignalNames.count == 8 (Dg4 distillation signal present)")
    func defaultStandingSignalNamesCountIsEight() {
        #expect(GeniusLocusKit.defaultStandingSignalNames.count == 8,
            "defaultStandingSignalNames must contain exactly 8 signals: 7 prior + DistillationSignal (Dg4)")
    }
}
