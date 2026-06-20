// DistillationConformanceTests.swift
//
// Cross-language conformance gate for the SubstrateML distillation pipeline.
//
// These tests assert FIXED numerical outputs for FIXED inputs. The identical
// assertions appear in Rust (distillation_conformance.rs). Any divergence
// between Swift and Rust is a parity failure — both sides must produce
// bit-identical Float32 results.
//
// Conformance vectors are sourced from the distillation conformance
// specification (§9).
//
// Inputs and expected values MUST NOT be changed to make tests pass.
// If a value doesn't match, fix the algorithm, not the vector.

import Testing
import Foundation
@testable import SubstrateML
@testable import SubstrateTypes

// MARK: - Shared fixture timestamps
// t0…t3 are arbitrary fixed epoch offsets (1s apart) chosen to produce
// age-in-units = 0 when referenceDate = t_i (self-anchored weight = 1.0).
private let t0 = Date(timeIntervalSince1970: 0)
private let t1 = Date(timeIntervalSince1970: 1)
private let t2 = Date(timeIntervalSince1970: 2)
private let t3 = Date(timeIntervalSince1970: 3)

// MARK: - Custom extractors

// singleWordExtractor: extracts the feature "provenance" for any text
// that contains the substring "provenance". Used for the cluster_5 fixture
// because defaultExtractor only captures capitalized non-first words, which
// the sentence "provenance is invariant in ingestion" does not contain.
private let singleWordExtractor: DistillationPipeline.FeatureExtractor = { text, featureType in
    guard featureType == .entity else { return [] }
    guard text.contains("provenance") else { return [] }
    return [ExtractedFeature(type: .entity, value: "provenance", docFrequency: 0)]
}

// MARK: - DeltaFeatureExtractor conformance

@Suite("DeltaFeatureExtractor conformance")
struct DeltaFeatureExtractorConformanceTests {

    // Fixture: input_cat_convergent
    // sequence = [("A",t0),("B",t1),("B",t2)], λ=0.5
    // k=2 (trailing "B"s), M=3, C=2/3≈0.6667 ≥ 0.5 → CONVERGENT
    // terminalValue="B", convergenceScore=2/3, confidence=2/3
    @Test func categoricalConvergent() {
        let sequence: [(value: String, timestamp: Date)] = [
            ("A", t0), ("B", t1), ("B", t2)
        ]
        let result = DeltaFeatureExtractor.analyzeCategorical(
            sequence: sequence, decayLambda: 0.5
        )
        #expect(result.deltaType == .convergent)
        #expect(result.terminalValue == "B")
        #expect(abs(result.convergenceScore - (2.0 / 3.0)) < 1e-5)
        #expect(abs(result.confidence - (2.0 / 3.0)) < 1e-5)
        #expect(result.slope == nil)
    }

    // Fixture: input_cat_static
    // sequence = [("X",t0),("X",t1),("X",t2)], λ=0.5
    // All identical → STATIC, C=1.0, confidence=1.0
    @Test func categoricalStatic() {
        let sequence: [(value: String, timestamp: Date)] = [
            ("X", t0), ("X", t1), ("X", t2)
        ]
        let result = DeltaFeatureExtractor.analyzeCategorical(
            sequence: sequence, decayLambda: 0.5
        )
        #expect(result.deltaType == .static)
        #expect(result.terminalValue == "X")
        #expect(abs(result.convergenceScore - 1.0) < 1e-5)
        #expect(abs(result.confidence - 1.0) < 1e-5)
        #expect(result.slope == nil)
    }

    // Fixture: input_cat_oscillating
    // sequence = [("A",t0),("B",t1),("A",t2),("B",t3)], λ=0.5
    // M≥4, tail=[A,B,A,B]: tail[0]==tail[2] && tail[1]==tail[3] && tail[0]≠tail[1]
    // → OSCILLATING, convergenceScore=0.0, confidence=0.0
    @Test func categoricalOscillating() {
        let sequence: [(value: String, timestamp: Date)] = [
            ("A", t0), ("B", t1), ("A", t2), ("B", t3)
        ]
        let result = DeltaFeatureExtractor.analyzeCategorical(
            sequence: sequence, decayLambda: 0.5
        )
        #expect(result.deltaType == .oscillating)
        #expect(abs(result.convergenceScore - 0.0) < 1e-5)
        #expect(abs(result.confidence - 0.0) < 1e-5)
    }

    // Fixture: input_num_monotone
    // sequence = [(1.0,t0),(2.0,t1),(3.0,t2)], λ=0.8
    // diffs = [1.0, 1.0], all positive → MONOTONE
    // slope = mean(diffs) = 1.0, confidence = λ = 0.8
    @Test func numericalMonotone() {
        let sequence: [(value: Double, timestamp: Date)] = [
            (1.0, t0), (2.0, t1), (3.0, t2)
        ]
        let result = DeltaFeatureExtractor.analyzeNumerical(
            sequence: sequence, decayLambda: 0.8
        )
        #expect(result.deltaType == .monotone)
        #expect(result.slope != nil)
        #expect(abs(result.slope! - 1.0) < 1e-5)
        #expect(abs(result.confidence - 0.8) < 1e-5)
    }
}

// MARK: - TypedDecayWeighting conformance

@Suite("TypedDecayWeighting conformance")
struct TypedDecayWeightingConformanceTests {

    // Fixture: weight(ENT, 5.0)
    // λ=0.1, age=5.0 → exp(-0.1×5)=exp(-0.5)≈0.60653
    // Tolerance: 1e-5 (Float32 precision for exp(-0.5))
    @Test func weightENTAge5() {
        let w = TypedDecayWeighting.weight(featureType: .entity, ageInUnits: 5.0)
        let expected: Float32 = 0.60653066 // exp(-0.5)
        #expect(abs(w - expected) < 1e-5)
    }

    // Fixture: weight(REL, 5.0)
    // λ=0.2, age=5.0 → exp(-1.0)≈0.36788
    @Test func weightRELAge5() {
        let w = TypedDecayWeighting.weight(featureType: .relation, ageInUnits: 5.0)
        let expected: Float32 = 0.36787944 // exp(-1.0)
        #expect(abs(w - expected) < 1e-5)
    }

    // Fixture: weight(TMP, 5.0)
    // λ=0.5, age=5.0 → exp(-2.5)≈0.08208
    @Test func weightTMPAge5() {
        let w = TypedDecayWeighting.weight(featureType: .temporal, ageInUnits: 5.0)
        let expected: Float32 = 0.08208500 // exp(-2.5)
        #expect(abs(w - expected) < 1e-5)
    }

    // Fixture: weight(NUM, 5.0)
    // λ=0.8, age=5.0 → exp(-4.0)≈0.01832
    @Test func weightNUMAge5() {
        let w = TypedDecayWeighting.weight(featureType: .numerical, ageInUnits: 5.0)
        let expected: Float32 = 0.01831564 // exp(-4.0)
        #expect(abs(w - expected) < 1e-5)
    }

    // age=0 → weight=1.0 for all types (exp(0)=1)
    @Test func weightAtAge0() {
        for type_ in DistillationFeatureType.allCases {
            let w = TypedDecayWeighting.weight(featureType: type_, ageInUnits: 0.0)
            #expect(abs(w - 1.0) < 1e-6)
        }
    }

    // Negative age clamped to 0 → weight=1.0 (future timestamps treated as present)
    @Test func weightNegativeAgeClamped() {
        let w = TypedDecayWeighting.weight(featureType: .entity, ageInUnits: -10.0)
        #expect(abs(w - 1.0) < 1e-6)
    }
}

// MARK: - DistillationPipeline.featureHash conformance

@Suite("DistillationPipeline.featureHash conformance")
struct FeatureHashConformanceTests {

    // Fixture: featureHash("provenance") must be non-zero (deterministic hash)
    @Test func provenanceNonZero() {
        let h = DistillationPipeline.featureHash("provenance")
        let isZero = h.block0 == 0 && h.block1 == 0 && h.block2 == 0 && h.block3 == 0
        #expect(!isZero)
    }

    // Fixture: exact 256-bit value of featureHash("provenance")
    // Computed by simulating the SplitMix64 mix+expand in Python against
    // featureSimHashSeed = 0x44495354494C4C41 ("DISTILLA" ASCII big-endian).
    // This value is the cross-language conformance anchor — the Rust port
    // must produce these exact 64-bit blocks from the same algorithm.
    @Test func provenanceExactBits() {
        let h = DistillationPipeline.featureHash("provenance")
        #expect(h.block0 == 0xd06e3650b74eb209)
        #expect(h.block1 == 0x6e9d3d0f52394bc5)
        #expect(h.block2 == 0x8e3b3aa6cbe0f400)
        #expect(h.block3 == 0xcef0a66667eb79a5)
    }

    // Fixture: featureHash("A").union(featureHash("B")) exact bits
    // OR-reduce of two independent hashes. Both Rust and Swift must
    // compute the same per-block OR from the same individual hashes.
    @Test func unionABExactBits() {
        let hA = DistillationPipeline.featureHash("A")
        let hB = DistillationPipeline.featureHash("B")
        let union = hA.union(hB)
        #expect(union.block0 == 0xdfcabff67e7ce1fd)
        #expect(union.block1 == 0xe33ff5f225916ff5)
        #expect(union.block2 == 0xfbfd77fabdbdaff7)
        #expect(union.block3 == 0xbbe273bf37e6fab4)
    }

    // Union is idempotent: h.union(h) == h (OR-reduce with self = self)
    @Test func unionIdempotent() {
        let h = DistillationPipeline.featureHash("provenance")
        let unioned = h.union(h)
        #expect(unioned.block0 == h.block0)
        #expect(unioned.block1 == h.block1)
        #expect(unioned.block2 == h.block2)
        #expect(unioned.block3 == h.block3)
    }

    // Union with .zero = self (OR identity)
    @Test func unionWithZeroIsIdentity() {
        let h = DistillationPipeline.featureHash("provenance")
        let unioned = h.union(.zero)
        #expect(unioned.block0 == h.block0)
        #expect(unioned.block1 == h.block1)
        #expect(unioned.block2 == h.block2)
        #expect(unioned.block3 == h.block3)
    }
}

// MARK: - DistillationPipeline.run conformance

@Suite("DistillationPipeline.run conformance")
struct DistillationPipelineRunConformanceTests {

    // Fixture: cluster_5
    // 5 identical memories: "provenance is invariant in ingestion"
    // Extractor: singleWordExtractor (extracts "provenance" from each memory)
    // M=5, V={"provenance"}, df("provenance")=5/5=1.0
    // τ_struct(M=5) = 2/5 = 0.4, so df=1.0 ≥ 0.4 → passes the structural threshold
    // Single-node PMI graph: F*={"provenance"}, |F*|=1, |Vthresh|=1
    // confidence = meanDf × (|F*|/|Vthresh|) = 1.0 × 1.0 = 1.0
    // SNR: structuralSignal=1 node in dominant component/|V|=1 → signal>>noise → passes
    // succeeded=true, confidence≥0.6
    // featureFingerprint = featureHash("provenance") ≠ zero
    @Test func cluster5Succeeded() {
        let memories = Array(repeating: "provenance is invariant in ingestion", count: 5)
        let input = DistillationInput(
            memoryContents: memories,
            memoryTimestamps: nil,
            clusterID: "cluster-5-fixture",
            sourceIDs: Array(0..<5).map { "src-\($0)" }
        )
        let output = DistillationPipeline.run(input: input, extractFeatures: singleWordExtractor)
        #expect(output.succeeded == true)
        #expect(output.confidence > 0.6)
        let isZero = output.featureFingerprint.block0 == 0
            && output.featureFingerprint.block1 == 0
            && output.featureFingerprint.block2 == 0
            && output.featureFingerprint.block3 == 0
        #expect(!isZero)
    }

    // cluster_5: featureFingerprint must equal featureHash("provenance")
    @Test func cluster5FingerprintEqualsProvenanceHash() {
        let memories = Array(repeating: "provenance is invariant in ingestion", count: 5)
        let input = DistillationInput(
            memoryContents: memories,
            memoryTimestamps: nil,
            clusterID: "cluster-5-fixture",
            sourceIDs: Array(0..<5).map { "src-\($0)" }
        )
        let output = DistillationPipeline.run(input: input, extractFeatures: singleWordExtractor)
        let expected = DistillationPipeline.featureHash("provenance")
        #expect(output.featureFingerprint.block0 == expected.block0)
        #expect(output.featureFingerprint.block1 == expected.block1)
        #expect(output.featureFingerprint.block2 == expected.block2)
        #expect(output.featureFingerprint.block3 == expected.block3)
    }

    // Fixture: cluster_noise
    // 3 memories with no overlapping features → no feature reaches the threshold
    // Using singleWordExtractor: none of the texts contain "provenance" → V=0
    // Empty vocabulary → "No features extracted" → succeeded=false
    @Test func clusterNoiseFailure() {
        let memories = [
            "the quick brown fox",
            "jumped over the lazy dog",
            "lorem ipsum dolor sit amet"
        ]
        let input = DistillationInput(
            memoryContents: memories,
            memoryTimestamps: nil,
            clusterID: "cluster-noise-fixture",
            sourceIDs: ["src-0", "src-1", "src-2"]
        )
        let output = DistillationPipeline.run(input: input, extractFeatures: singleWordExtractor)
        #expect(output.succeeded == false)
    }
}
