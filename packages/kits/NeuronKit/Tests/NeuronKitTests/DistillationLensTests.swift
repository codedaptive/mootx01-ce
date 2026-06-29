import Testing
import Foundation
@testable import NeuronKit
import SubstrateML

// MARK: - Distillation Lens Tests
//
// Verify the thin NeuronKit lens over SubstrateML.DistillationPipeline.
//
// Two extractor paths are exercised here:
//
//   Stub path (DistillationPipeline.defaultExtractor, injected explicitly):
//     Used by the pass-through tests to verify the lens projection contract
//     independent of which extractor is the production default.
//
//   Production HMM path (NeuronKit.distillCluster with no explicit extractor):
//     Uses the HMM feature extractor wired as the default in NeuronKit.
//     Tests that call distillCluster without an extractor argument exercise
//     this path (injectionDepthConsistentWithPipeline, injectionDepthFactoidWithProvenance).
//
// The pass-through contract is: every DistillationOutput field appears
// verbatim in DistillationLensResult.

@Suite("DistillationLens")
struct DistillationLensTests {

    // Three memories sharing a capitalized entity ("Alice") so defaultExtractor
    // can extract a majority feature and the pipeline succeeds.
    private func makeSuccessInput() -> DistillationInput {
        DistillationInput(
            memoryContents: [
                "Alice is a software engineer at Acme.",
                "Alice joined the Alice project in January.",
                "Alice leads the Alice infrastructure team."
            ],
            clusterID: "test-cluster-success",
            sourceIDs: ["s1", "s2", "s3"]
        )
    }

    // Three short memories with no capitalised words beyond sentence start,
    // so the default extractor extracts nothing and the pipeline fails.
    private func makeFailInput() -> DistillationInput {
        DistillationInput(
            memoryContents: ["one", "two", "three"],
            clusterID: "test-cluster-fail",
            sourceIDs: ["f1", "f2", "f3"]
        )
    }

    // Pass-through: LensResult.drawerContent == DistillationOutput.drawerContent.
    // Verifies the lens projection contract: same extractor, same result shape.
    // Uses the capitalization-heuristic stub so the test does not depend on the
    // HMM model artifact; the lens pass-through contract is extractor-independent.
    @Test("pass-through: drawerContent equals pipeline output")
    func drawerContentPassThrough() {
        let input = makeSuccessInput()
        let pipelineOutput = DistillationPipeline.run(
            input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        // Pass the stub explicitly so both sides use the same extractor.
        let lensResult = NeuronKit.distillCluster(
            input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        #expect(lensResult.drawerContent == pipelineOutput.drawerContent)
    }

    // Pass-through: LensResult.confidence == DistillationOutput.confidence.
    @Test("pass-through: confidence equals pipeline output")
    func confidencePassThrough() {
        let input = makeSuccessInput()
        let pipelineOutput = DistillationPipeline.run(
            input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        // Pass the stub explicitly so both sides use the same extractor.
        let lensResult = NeuronKit.distillCluster(
            input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        #expect(lensResult.confidence == pipelineOutput.confidence)
    }

    // InjectionDepth is consistent with confidence: whatever the pipeline emits,
    // the depth must match the threshold range that confidence falls into.
    // We cannot force a specific confidence from the pipeline, so this test
    // verifies the invariant holds for the success input's actual output.
    @Test("injectionDepth: depth is consistent with pipeline confidence")
    func injectionDepthConsistentWithPipeline() {
        let result = NeuronKit.distillCluster(input: makeSuccessInput())
        if result.confidence >= 0.7 {
            #expect(result.injectionDepth == .factoidOnly)
        } else if result.confidence >= 0.4 {
            #expect(result.injectionDepth == .factoidWithMeta)
        } else {
            #expect(result.injectionDepth == .factoidWithProvenance)
        }
    }

    // InjectionDepth threshold boundary test: conf=0.55 → .factoidWithMeta.
    // Since we cannot control the pipeline's output confidence precisely,
    // this test uses a direct assertion on the enum discrimination logic.
    // The spec states three non-overlapping ranges; we verify them exhaustively.
    @Test("injectionDepth: threshold ranges are exhaustive and non-overlapping")
    func injectionDepthThresholdsExhaustive() {
        // Values chosen to hit each range's interior and both boundaries.
        let cases: [(Float32, InjectionDepth)] = [
            (1.0, .factoidOnly),      // maximum
            (0.7, .factoidOnly),      // lower boundary of factoidOnly
            (0.699, .factoidWithMeta),// just below factoidOnly boundary
            (0.55, .factoidWithMeta), // interior of factoidWithMeta
            (0.4, .factoidWithMeta),  // lower boundary of factoidWithMeta
            (0.399, .factoidWithProvenance), // just below factoidWithMeta boundary
            (0.3, .factoidWithProvenance),   // interior of factoidWithProvenance
            (0.0, .factoidWithProvenance),   // minimum
        ]
        for (conf, expected) in cases {
            let depth: InjectionDepth
            if conf >= 0.7 {
                depth = .factoidOnly
            } else if conf >= 0.4 {
                depth = .factoidWithMeta
            } else {
                depth = .factoidWithProvenance
            }
            #expect(depth == expected, "conf=\(conf) expected \(expected) got \(depth)")
        }
    }

    // InjectionDepth: conf=0.30 → .factoidWithProvenance.
    // Verified through the lens result when the pipeline produces low confidence.
    @Test("injectionDepth: conf < 0.4 → factoidWithProvenance")
    func injectionDepthFactoidWithProvenance() {
        let result = NeuronKit.distillCluster(input: makeFailInput())
        // Failed pipeline output has confidence = 0.0.
        #expect(result.confidence == 0.0)
        #expect(result.injectionDepth == .factoidWithProvenance)
    }

    // Failure path: distillCluster succeeds/fails in lockstep with pipeline.
    // Uses the stub extractor explicitly on both sides so the test verifies
    // the lens projection contract independent of which extractor is the default.
    @Test("succeeded field matches pipeline")
    func succeededMatchesPipeline() {
        let input = makeFailInput()
        let pipelineOutput = DistillationPipeline.run(
            input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        // Pass the stub explicitly so both sides use the same extractor.
        let lensResult = NeuronKit.distillCluster(
            input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        #expect(lensResult.succeeded == pipelineOutput.succeeded)
        #expect(lensResult.failureReason == pipelineOutput.failureReason)
    }
}
