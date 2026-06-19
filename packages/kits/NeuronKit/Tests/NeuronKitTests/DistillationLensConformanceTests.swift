import Testing
import Foundation
@testable import NeuronKit
import SubstrateML

// MARK: - Distillation Lens Conformance Tests
//
// Conformance gate: fixed DistillationInput (cluster_5) → assert LensResult
// fields match expected values and match the Rust leg (distillation_lens_conformance.rs).
//
// cluster_5: Alice+CERN appear in 4/5 memories (df=0.8 > τ_maj for M=5),
// M5 has no features. The capitalization-heuristic defaultExtractor produces
// succeeded=true and confidence >= 0.7 on this fixture.
//
// Cross-language parity: the identical cluster_5 fixture is driven through
// distill_cluster in Rust (distillation_lens_conformance.rs). Both legs
// assert the same field values, establishing Swift-Rust conformance.

@Suite("DistillationLensConformance")
struct DistillationLensConformanceTests {

    // cluster_5 fixture: identical input used by the Rust conformance leg.
    // Cluster ID is "test-cluster-dp2" to avoid collision with existing pipeline tests.
    private func cluster5() -> DistillationInput {
        DistillationInput(
            memoryContents: [
                "Research by Alice at CERN on particle physics",
                "The lab where Alice works is CERN facility",
                "Studies conducted by Alice show CERN advances science",
                "Data from CERN shows Alice leading breakthrough research",
                "Maintenance was completed on schedule today",
            ],
            clusterID: "test-cluster-dp2",
            sourceIDs: ["src-0", "src-1", "src-2", "src-3", "src-4"]
        )
    }

    // drawerContent starts with "[DIST|" — DIST header format per DISTILLATION_DESIGN.md §1.
    // Both Swift and Rust conformance legs assert this same prefix.
    @Test("cluster_5: drawerContent starts with [DIST| marker")
    func drawerContentPrefix() {
        let result = NeuronKit.distillCluster(input: cluster5())
        #expect(result.succeeded)
        #expect(result.drawerContent.hasPrefix("[DIST|"))
    }

    // confidence is passed through from DistillationOutput unchanged.
    // Running the pipeline directly and through the lens must yield identical confidence.
    @Test("cluster_5: confidence equals pipeline output (pass-through)")
    func confidencePassThrough() {
        let input = cluster5()
        let pipelineOutput = DistillationPipeline.run(
            input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        let lensResult = NeuronKit.distillCluster(input: input)
        #expect(lensResult.confidence == pipelineOutput.confidence)
    }

    // injectionDepth == .factoidOnly for cluster_5.
    // cluster_5 produces confidence >= 0.7 with defaultExtractor, placing it in
    // the factoidOnly range (conf >= 0.7) per InjectionDepth thresholds.
    // Rust leg asserts InjectionDepth::FactoidOnly for the same fixture.
    @Test("cluster_5: injectionDepth is .factoidOnly (conf >= 0.7)")
    func injectionDepthFactoidOnly() {
        let result = NeuronKit.distillCluster(input: cluster5())
        #expect(result.confidence >= 0.7)
        #expect(result.injectionDepth == .factoidOnly)
    }
}
