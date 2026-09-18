// RecallTuningParametricTests.swift
//
// Tests for the parametric recall-tuning surface added in W4:
//
//   (a) RecallFrameTuning built from a RecallTuningManifest carries correct
//       field values — the manifest → RecallFrameTuning wiring.
//   (b) Default manifest produces the spec-default RecallFrameTuning exactly.
//   (c) CompositionGrid.named(_:applyingTuning:) overrides mmrLambda for MMR
//       compositions and leaves non-MMR compositions unchanged.
//   (d) Golden pin: non-default tuning (k=80, λ=0.6, bm25=0.4, vector=0.6)
//       is preserved on the RecallFrameTuning struct and the composition.
//   (e) mmrDiversityRerank math changes output with λ=0.5 vs λ=0.7 on a
//       redundant pool (proves the override actually reaches the math engine).

import Testing
import Foundation
import GeniusLocusKit
@testable import NeuronKit

// MARK: - RecallFrameTuning built from manifest

@Suite("RecallFrameTuning — manifest field wiring")
struct RecallFrameTuningManifestWiringTests {

    // MARK: (a) Field wiring

    @Test("manifest rrfK wires into RecallFrameTuning.rrfK")
    func manifestRrfKWired() {
        let manifest = RecallTuningManifest(rrfK: 80, mmrLambda: 0.7, rrfBm25Weight: 0.3, rrfVectorWeight: 0.7)
        let ft = RecallFrameTuning(
            bm25Weight: manifest.rrfBm25Weight,
            vectorWeight: manifest.rrfVectorWeight,
            rrfK: manifest.rrfK,
            mmrLambda: manifest.mmrLambda,
            pageSize: RecallFrameTuning.default.pageSize)
        #expect(ft.rrfK == 80)
    }

    @Test("manifest mmrLambda wires into RecallFrameTuning.mmrLambda")
    func manifestMmrLambdaWired() {
        let manifest = RecallTuningManifest(rrfK: 60, mmrLambda: 0.6, rrfBm25Weight: 0.3, rrfVectorWeight: 0.7)
        let ft = RecallFrameTuning(
            bm25Weight: manifest.rrfBm25Weight,
            vectorWeight: manifest.rrfVectorWeight,
            rrfK: manifest.rrfK,
            mmrLambda: manifest.mmrLambda,
            pageSize: RecallFrameTuning.default.pageSize)
        #expect(abs(ft.mmrLambda - 0.6) < 1e-6)
    }

    @Test("manifest bm25/vector weights wire into RecallFrameTuning blend fields")
    func manifestBlendWeightsWired() {
        let manifest = RecallTuningManifest(rrfK: 60, mmrLambda: 0.7, rrfBm25Weight: 0.4, rrfVectorWeight: 0.6)
        let ft = RecallFrameTuning(
            bm25Weight: manifest.rrfBm25Weight,
            vectorWeight: manifest.rrfVectorWeight,
            rrfK: manifest.rrfK,
            mmrLambda: manifest.mmrLambda,
            pageSize: RecallFrameTuning.default.pageSize)
        #expect(abs(ft.bm25Weight - 0.4) < 1e-6)
        #expect(abs(ft.vectorWeight - 0.6) < 1e-6)
    }

    // MARK: (b) Default manifest produces spec default

    @Test("default manifest produces spec-default RecallFrameTuning")
    func defaultManifestProducesSpecDefault() {
        let manifest = RecallTuningManifest.default
        let ft = RecallFrameTuning(
            bm25Weight: manifest.rrfBm25Weight,
            vectorWeight: manifest.rrfVectorWeight,
            rrfK: manifest.rrfK,
            mmrLambda: manifest.mmrLambda,
            pageSize: RecallFrameTuning.default.pageSize)
        // Byte-identical to the spec default means every field matches.
        #expect(ft == RecallFrameTuning.default)
    }
}

// MARK: - CompositionGrid.named(_:applyingTuning:)

@Suite("CompositionGrid — named(_:applyingTuning:)")
struct CompositionGridTuningTests {

    // MARK: (c) MMR composition receives overridden mmrLambda

    @Test("text+mmr with spec-default tuning has mmrLambda 0.7")
    func textMmrDefaultTuningHasSpecLambda() {
        let comp = NeuronKit.CompositionGrid.named("text+mmr", applyingTuning: .default)
        // Spec constant originates as Float(0.7); converting through Double adds a small
        // representation gap (~2.4e-8). Use 1e-5 tolerance to cover Float↔Double drift.
        #expect(abs(comp.mmrLambda - 0.7) < 1e-5)
    }

    @Test("text+mmr with non-default tuning has overridden mmrLambda")
    func textMmrNonDefaultTuningOverridesLambda() {
        let tuning = RecallTuningManifest(rrfK: 60, mmrLambda: 0.5, rrfBm25Weight: 0.3, rrfVectorWeight: 0.7)
        let comp = NeuronKit.CompositionGrid.named("text+mmr", applyingTuning: tuning)
        // Float→Double conversion adds ~2.4e-8 gap; 1e-5 tolerance covers it.
        #expect(abs(comp.mmrLambda - 0.5) < 1e-5)
    }

    @Test("named(_:applyingTuning:) preserves name and terms for text+mmr")
    func textMmrTuningPreservesNameAndTerms() {
        let base = NeuronKit.CompositionGrid.named("text+mmr")
        let tuning = RecallTuningManifest(rrfK: 60, mmrLambda: 0.5, rrfBm25Weight: 0.3, rrfVectorWeight: 0.7)
        let tuned = NeuronKit.CompositionGrid.named("text+mmr", applyingTuning: tuning)
        #expect(tuned.name == base.name)
        #expect(tuned.terms == base.terms)
    }

    // Non-MMR compositions unchanged

    @Test("non-MMR text composition is returned unchanged by applyingTuning")
    func nonMmrTextCompositionUnchanged() {
        let base = NeuronKit.CompositionGrid.named("text")
        let tuning = RecallTuningManifest(rrfK: 80, mmrLambda: 0.5, rrfBm25Weight: 0.4, rrfVectorWeight: 0.6)
        let tuned = NeuronKit.CompositionGrid.named("text", applyingTuning: tuning)
        #expect(tuned == base)
    }

    @Test("non-MMR hamming+tokenExact is unchanged by applyingTuning")
    func nonMmrHammingTokenExactUnchanged() {
        let base = NeuronKit.CompositionGrid.named("hamming+tokenExact")
        let tuning = RecallTuningManifest(rrfK: 80, mmrLambda: 0.5, rrfBm25Weight: 0.4, rrfVectorWeight: 0.6)
        let tuned = NeuronKit.CompositionGrid.named("hamming+tokenExact", applyingTuning: tuning)
        #expect(tuned == base)
    }

    @Test("named(_:applyingTuning:) falls back to text for unknown name")
    func unknownNameFallsBackToText() {
        let tuning = RecallTuningManifest(rrfK: 80, mmrLambda: 0.5, rrfBm25Weight: 0.4, rrfVectorWeight: 0.6)
        let result = NeuronKit.CompositionGrid.named("no-such-composition", applyingTuning: tuning)
        #expect(result.name == "text")
    }

    // MARK: (d) Golden pin

    @Test("golden pin: k=80 λ=0.6 bm25=0.4 vector=0.6 are all stored on the resolved structs")
    func goldenPinNonDefaultTuningStoredOnStructs() {
        // Golden pin: these non-default values differ from every spec constant
        // (k: 80≠60, λ: 0.6≠0.7, bm25: 0.4≠0.3, vector: 0.6≠0.7).
        let manifest = RecallTuningManifest(
            rrfK: 80, mmrLambda: 0.6, rrfBm25Weight: 0.4, rrfVectorWeight: 0.6)

        // RecallFrameTuning built from this manifest.
        let ft = RecallFrameTuning(
            bm25Weight: manifest.rrfBm25Weight,
            vectorWeight: manifest.rrfVectorWeight,
            rrfK: manifest.rrfK,
            mmrLambda: manifest.mmrLambda,
            pageSize: RecallFrameTuning.default.pageSize)
        #expect(ft.rrfK == 80)
        #expect(abs(ft.mmrLambda - 0.6) < 1e-6)
        #expect(abs(ft.bm25Weight - 0.4) < 1e-6)
        #expect(abs(ft.vectorWeight - 0.6) < 1e-6)

        // Composition built with this manifest has overridden mmrLambda.
        // Float(0.6) → Double conversion yields ~0.6000000238, not Double(0.6); use 1e-5.
        let comp = NeuronKit.CompositionGrid.named("text+mmr", applyingTuning: manifest)
        #expect(abs(comp.mmrLambda - 0.6) < 1e-5)
    }
}

// MARK: - mmrDiversityRerank math changes with λ

@Suite("mmrDiversityRerank — lambda drives output diversity")
struct MmrDiversityRerankLambdaTests {

    // Helper to create a ReductionCandidate with a given content string.
    private static func makeCandidate(id: String, content: String, rank: Int) -> NeuronKit.ReductionCandidate {
        NeuronKit.ReductionCandidate(
            id: id, content: content, room: "test-room",
            score: RecallScoreVector(
                locus: 0, bm25: 0, vector: 0, fieldFit: 0,
                coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                redundancyPenalty: 0, final: 0),
            udcCode: "", qid: "",
            udcFacets: nil,
            coarseRank: rank,
            precisionScore: Double(3 - rank))
    }

    // MARK: (e) Math changes with lambda

    @Test("lower lambda produces earlier diversity promotion (C appears before B)")
    func lowerLambdaPromotesDiversityEarlier() {
        // Pool: A (very relevant), B (near-duplicate of A), C (disjoint content).
        // At high λ (0.9 ≈ pure relevance), A then B then C.
        // At low λ (0.1 ≈ pure diversity), A then C then B (C is diverse, B is redundant).
        let poolA = Self.makeCandidate(id: "a", content: "organic chemistry carbon compounds bonds", rank: 0)
        let poolB = Self.makeCandidate(id: "b", content: "organic chemistry carbon molecules bonds", rank: 1)
        let poolC = Self.makeCandidate(id: "c", content: "quantum electrodynamics photon field", rank: 2)
        let pool = [poolA, poolB, poolC]

        // High lambda (relevance dominant) — preserves order A, B, C because B is
        // slightly less relevant than A but more relevant than C.
        let highLambdaResult = NeuronKit.mmrDiversityRerank(pool, lambda: 0.9)
        // Low lambda (diversity dominant) — C should beat B at second pick because
        // C has near-zero shingle overlap with A, while B shares most of A's shingles.
        let lowLambdaResult = NeuronKit.mmrDiversityRerank(pool, lambda: 0.1)

        // A is always first (highest relevance, nothing selected yet).
        #expect(highLambdaResult[0].id == "a")
        #expect(lowLambdaResult[0].id == "a")

        // The second pick must differ between the two lambdas — this is the behavioral
        // proof that lambda actually reaches the math engine.
        // At λ=0.9: high relevance weight means B (slightly more relevant than C) wins.
        // At λ=0.1: high diversity weight means C (disjoint from A) wins over B.
        #expect(highLambdaResult[1].id != lowLambdaResult[1].id,
                "second pick must differ between λ=0.9 and λ=0.1 on a redundant pool")
    }

    @Test("spec-default lambda 0.7 matches named(text+mmr).mmrLambda")
    func specDefaultLambdaMatchesGrid() {
        // The grid declares mmrLambda: 0.7 as a Double literal directly, so no
        // Float→Double conversion occurs here; tight tolerance is fine.
        let comp = NeuronKit.CompositionGrid.named("text+mmr")
        #expect(abs(comp.mmrLambda - 0.7) < 1e-9)
    }

    @Test("named(text+mmr applyingTuning) with λ=0.5 differs from spec default")
    func tuningDiffersFromSpec() {
        // Float(0.5) → Double = exactly 0.5 (power-of-two fraction); Double(0.7)
        // is different, so the strict != comparison is reliable here.
        let defaultLambda = NeuronKit.CompositionGrid.named("text+mmr").mmrLambda
        let tuned = NeuronKit.CompositionGrid.named(
            "text+mmr",
            applyingTuning: RecallTuningManifest(rrfK: 60, mmrLambda: 0.5, rrfBm25Weight: 0.3, rrfVectorWeight: 0.7))
        #expect(tuned.mmrLambda != defaultLambda)
    }
}
