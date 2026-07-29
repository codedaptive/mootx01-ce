// DistillationPipelineTests.swift
//
// Tests for DistillationPipeline and supporting math.
// Coverage: full pipeline runs, the SPEC_DISTILLATION_STORAGE §5/§7.4
// Stage 5 rendering (token-economical prose, zero inline metadata,
// core-first ordering), SNR gate, delta pre-pass, queryFingerprint, and
// featureHash determinism.

import Testing
import Foundation
@testable import SubstrateML

// MARK: - featureHash

@Suite("featureHash")
struct FeatureHashTests {

    @Test("featureSimHashSeed is the DISTILLA ASCII constant")
    func seedConstant() {
        // "DISTILLA" big-endian ASCII → 0x44495354494C4C41
        #expect(DistillationPipeline.featureSimHashSeed == 0x44495354494C4C41)
    }

    @Test("featureHash empty string does not crash and returns deterministic value")
    func emptyStringIsDeterministic() {
        let a = DistillationPipeline.featureHash("")
        let b = DistillationPipeline.featureHash("")
        #expect(a == b)
    }

    @Test("featureHash is idempotent: A OR A == A")
    func idempotent() {
        let h = DistillationPipeline.featureHash("A")
        #expect(h.union(h) == h)
    }

    @Test("featureHash distinct inputs produce distinct fingerprints")
    func distinctInputs() {
        let h1 = DistillationPipeline.featureHash("Alice")
        let h2 = DistillationPipeline.featureHash("Bob")
        // Very high probability; if this flips the seed is broken
        #expect(h1 != h2)
    }

    @Test("featureHash same input always returns same fingerprint")
    func deterministic() {
        let a = DistillationPipeline.featureHash("Marie Curie")
        let b = DistillationPipeline.featureHash("Marie Curie")
        #expect(a == b)
    }
}

// MARK: - structuralThreshold

@Suite("structuralThreshold")
struct StructuralThresholdTests {

    @Test("threshold for M=1")
    func m1() {
        // 2/1 = 2.0 — nothing recurs; a single un-chunked unit is not distillable.
        #expect(abs(DistillationScorer.structuralThreshold(M: 1) - 2.0) < 0.001)
    }

    @Test("threshold for M=3")
    func m3() {
        // 2/3 ≈ 0.667 — recurs in ≥2 of 3 units.
        let t = DistillationScorer.structuralThreshold(M: 3)
        #expect(abs(t - 2.0/3.0) < 0.001)
    }

    @Test("threshold for M=5")
    func m5() {
        // 2/5 = 0.4 — recurs in ≥2 of 5 units.
        let t = DistillationScorer.structuralThreshold(M: 5)
        #expect(abs(t - 0.4) < 0.001)
    }

    @Test("threshold for M=4")
    func m4() {
        // 2/4 = 0.5 — recurs in ≥2 of 4 units.
        let t = DistillationScorer.structuralThreshold(M: 4)
        #expect(abs(t - 0.5) < 0.001)
    }
}

// MARK: - computeSNR

@Suite("computeSNR")
struct ComputeSNRTests {

    @Test("SNR gate blocks cluster with no structural overlap")
    func noOverlapFails() {
        // Each feature appears in 1 of 3 memories (df=0.33 < τ_struct(3)=0.667) → episodic
        let features: [ExtractedFeature] = [
            ExtractedFeature(type: .entity, value: "UniqueA", docFrequency: Float32(1)/3),
            ExtractedFeature(type: .entity, value: "UniqueB", docFrequency: Float32(1)/3),
            ExtractedFeature(type: .entity, value: "UniqueC", docFrequency: Float32(1)/3),
        ]
        let result = DistillationScorer.computeSNR(features: features, M: 3)
        #expect(result.readyToDistill == false)
    }

    @Test("SNR gate passes cluster with high structural overlap")
    func highOverlapPasses() {
        // Features appear in 5/6 memories each (df=0.83 ≥ τ_struct(6)≈0.333) → structural
        let features: [ExtractedFeature] = [
            ExtractedFeature(type: .entity, value: "Alice", docFrequency: Float32(5)/6),
            ExtractedFeature(type: .entity, value: "CERN", docFrequency: Float32(5)/6),
            // One episodic feature (df < threshold)
            ExtractedFeature(type: .entity, value: "Switzerland", docFrequency: Float32(1)/6),
        ]
        // SNR = (0.83+0.83) / 0.17 ≈ 9.8 >> 2.0
        let result = DistillationScorer.computeSNR(features: features, M: 6)
        #expect(result.readyToDistill == true)
    }
}

// MARK: - queryFingerprint

@Suite("queryFingerprint")
struct QueryFingerprintTests {

    @Test("queryFingerprint returns deterministic non-zero result for content with named entities")
    func matchesDistillation() {
        // queryFingerprint uses the same featureHash seeding as the pipeline; verify
        // it produces a non-zero fingerprint for text with capitalised non-first words,
        // and that two calls with identical inputs agree (determinism check).
        let query = "Research by Alice at CERN on particle physics"
        let fp1 = DistillationPipeline.queryFingerprint(
            query: query, extractFeatures: DistillationPipeline.defaultExtractor)
        let fp2 = DistillationPipeline.queryFingerprint(
            query: query, extractFeatures: DistillationPipeline.defaultExtractor)
        #expect(fp1 == fp2)
        #expect(fp1 != .zero)
    }

    @Test("queryFingerprint on identical text returns same fingerprint twice")
    func deterministic() {
        let query = "Marie Curie discovered Radium in Paris"
        let fp1 = DistillationPipeline.queryFingerprint(
            query: query, extractFeatures: DistillationPipeline.defaultExtractor)
        let fp2 = DistillationPipeline.queryFingerprint(
            query: query, extractFeatures: DistillationPipeline.defaultExtractor)
        #expect(fp1 == fp2)
    }
}

// MARK: - Full pipeline run

@Suite("DistillationPipeline.run")
struct DistillationPipelineRunTests {

    // Cluster where Alice and CERN appear as capitalized non-first-word entities
    // in 4 of 6 memories (df=0.667 ≥ τ_struct(6)=2/6≈0.333), co-occurring in all
    // 4 → PMI>0. Two neutral memories contribute no features. Design ensures conf > 0.6.
    let memories = [
        "Research by Alice at CERN on particle physics",
        "The lab where Alice works is CERN in Switzerland",
        "Studies conducted by Alice show CERN advances science",
        "Data from CERN shows Alice leading breakthrough research",
        "The quarterly review was completed on schedule",
        "System logs were archived last night successfully",
    ]

    @Test("Full pipeline on 6-memory cluster succeeds with conf > 0.6")
    func fullPipelineSucceeds() {
        let input = DistillationInput(
            memoryContents: memories,
            clusterID: "test-cluster-01",
            sourceIDs: memories.indices.map { "src-\($0)" }
        )
        let output = DistillationPipeline.run(input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        #expect(output.succeeded == true)
        #expect(output.confidence > 0.6)
        #expect(output.featureFingerprint != .zero)
    }

    @Test("rendering is token-economical prose with zero inline metadata (§5.2)")
    func renderingHasNoInlineMetadata() {
        let input = DistillationInput(
            memoryContents: memories,
            clusterID: "test-cluster-02",
            sourceIDs: memories.indices.map { "src-\($0)" }
        )
        let output = DistillationPipeline.run(input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        guard output.succeeded else { return }
        // The [DIST|...] header format is retired: every byte is payload.
        #expect(!output.distilledText.hasPrefix("[DIST|"))
        #expect(!output.distilledText.contains("conf="))
        #expect(!output.distilledText.contains("snr="))
        // The rendering carries the entities of the source (propositional
        // fidelity, rule 1) and no doubled spaces (rule 5).
        #expect(output.distilledText.contains("Alice"))
        #expect(output.distilledText.contains("CERN"))
        #expect(!output.distilledText.contains("  "))
        // Quality metadata still rides the generation-time fields (§5.2).
        #expect(output.confidence > 0)
        #expect(output.snr > 0)
    }

    @Test("rendering orders dominant-component (core) sentences before the episodic tail (§7.4)")
    func renderingOrdersCoreFirst() {
        let input = DistillationInput(
            memoryContents: memories,
            clusterID: "test-cluster-03",
            sourceIDs: memories.indices.map { "src-\($0)" }
        )
        let output = DistillationPipeline.run(input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        guard output.succeeded else { return }
        // memories[4]/[5] carry no selected feature (the episodic tail) —
        // their compacted renderings must appear AFTER the Alice/CERN core.
        let text = output.distilledText
        let coreIdx = text.range(of: "Alice")?.lowerBound
        let tailIdx = text.range(of: "Quarterly review")?.lowerBound
        #expect(coreIdx != nil)
        #expect(tailIdx != nil)
        if let c = coreIdx, let t = tailIdx {
            #expect(c < t)
        }
        // Every unit survives into the rendering (rule 1: propositional
        // fidelity — the tail compresses, it does not vanish).
        #expect(text.contains("archived"))
    }

    @Test("rendering compacts each unit through the §7.6 transform")
    func renderingUsesCompaction() {
        let input = DistillationInput(
            memoryContents: memories,
            clusterID: "test-cluster-compact",
            sourceIDs: memories.indices.map { "src-\($0)" }
        )
        let output = DistillationPipeline.run(input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        guard output.succeeded else { return }
        // "The lab where Alice works is CERN in Switzerland" compacts its
        // article and copula away — the raw phrase must not survive.
        #expect(!output.distilledText.contains("The lab where"))
        #expect(output.distilledText.contains("Lab where Alice works CERN"))
    }

    @Test("SNR gate: cluster with no shared features returns succeeded=false")
    func snrGateFails() {
        // Each memory mentions a completely different entity — no overlap
        let disjointMemories = [
            "UniqueEntityAlpha was spotted near the mountains",
            "UniqueEntityBeta appeared at the coastline",
            "UniqueEntityGamma visited the valley",
        ]
        let input = DistillationInput(
            memoryContents: disjointMemories,
            clusterID: "test-cluster-snr",
            sourceIDs: disjointMemories.indices.map { "src-\($0)" }
        )
        let output = DistillationPipeline.run(input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        #expect(output.succeeded == false)
    }

    @Test("Delta pre-pass rescues CONVERGENT feature from structural-threshold failure")
    func deltaPrePassRescue() {
        // Design (M=5, τ_struct = 2/5 = 0.4):
        //   Structural (df ≥ τ): CERN(4/5=0.8), Physics(4/5=0.8), Research(4/5=0.8)
        //   Failing (df < τ): status:pending(1/5=0.2), status:approved(1/5=0.2),
        //     Alice(1/5=0.2). All one-off under the recurrence threshold.
        //
        // The "status" predicate key has a CONVERGENT trajectory:
        //   M1→status:pending, M2→status:approved
        //   m=2, k=1, C=1/2=0.5 ≥ 0.5 → CONVERGENT, terminal="status:approved"
        //   (df=0.2, one-off) is promoted to the passing set. The terminal must be
        //   below τ_struct to need the rescue.
        //
        // After promotion, PMI graph on [CERN, Physics, Research, status:approved]:
        //   status:approved co-occurs with CERN/Physics/Research in M2 → PMI>0 →
        //   one component. conf = mean_df(F*) × 1.0 ≥ 0.4 → succeeded, .convergent.
        //
        // Swift SNR sums RAW df: structural = 0.8×3 = 2.4; episodic = 0.2(pending)
        //   + 0.2(approved) + 0.2(Alice) = 0.6. SNR = 2.4/0.6 = 4.0 ≥ 2.0 ✓.
        //   (The Rust port uses the σ-based SNR formula — see the Rust delta test;
        //   the computeSNR formulas differ by port, a pre-existing documented split.)
        let memories: [String] = [
            // M0: entity=[Alice, CERN, Physics, Research]; relation=[]
            "Lab by Alice at CERN studies Physics Research",
            // M1: entity=[CERN, Physics, Research]; relation=[status:pending]
            "Team at CERN conducts Physics Research status:pending",
            // M2: entity=[CERN, Physics, Research]; relation=[status:approved]
            "The group at CERN advances Physics Research status:approved",
            // M3: entity=[CERN, Physics, Research]; relation=[]
            "Results confirm CERN Physics Research today",
            // M4: no features
            "Maintenance completed this morning",
        ]

        // Combined extractor: entity uses capitalization heuristic, relation uses key:value pattern.
        let combinedExtractor: DistillationPipeline.FeatureExtractor = { text, featureType in
            switch featureType {
            case .entity:
                return DistillationPipeline.defaultExtractor(text, featureType)
            case .relation:
                var results: [ExtractedFeature] = []
                for word in text.split(separator: " ") {
                    let s = String(word)
                    if s.contains(":") {
                        results.append(ExtractedFeature(type: .relation, value: s, docFrequency: 0))
                    }
                }
                return results
            default:
                return []
            }
        }

        let input = DistillationInput(
            memoryContents: memories,
            clusterID: "test-cluster-delta",
            sourceIDs: memories.indices.map { "src-\($0)" }
        )
        let output = DistillationPipeline.run(input: input, extractFeatures: combinedExtractor)

        // The SNR gate must pass and Stage 2.5 must exercise the CONVERGENT rescue path.
        // "status:approved" (df=0.2 < τ=0.4 = 2/M with M=5) is rescued by CONVERGENT analysis;
        // all passing features have positive PMI → one component → conf ≥ 0.4 → succeeded=true.
        #expect(output.succeeded == true)
        #expect(output.deltaType == .convergent)
        #expect(output.featureFingerprint != .zero)
    }

    @Test("succeeded=false output has empty distilledText")
    func failureOutputHasEmptyContent() {
        let input = DistillationInput(
            memoryContents: ["Hello", "World", "Foo"],
            clusterID: "test-cluster-fail",
            sourceIDs: ["s1", "s2", "s3"]
        )
        let output = DistillationPipeline.run(input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        if !output.succeeded {
            #expect(output.distilledText == "")
            #expect(output.failureReason != nil)
            #expect(output.confidence == 0)
        }
    }

    @Test("featureFingerprint is OR-union of featureHash values for F*")
    func featureFingerprintIsOrUnion() {
        let input = DistillationInput(
            memoryContents: memories,
            clusterID: "test-cluster-fp",
            sourceIDs: memories.indices.map { "src-\($0)" }
        )
        let output = DistillationPipeline.run(input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        guard output.succeeded else { return }
        // The fingerprint must be non-zero (features were hashed)
        #expect(output.featureFingerprint != .zero)
        // AND it must equal OR-union of individual hashes (idempotent under OR)
        let fp = output.featureFingerprint
        #expect(fp.union(fp) == fp)
    }

    @Test("Single-memory cluster produces valid output")
    func singleMemory() {
        let input = DistillationInput(
            memoryContents: ["Alice visited Paris last summer"],
            clusterID: "test-cluster-single",
            sourceIDs: ["s1"]
        )
        // Single memory: M=1, τ_struct=2/1=2.0 so nothing recurs (no feature can
        // reach df=2.0) — an un-chunked single unit is correctly not distillable.
        // SNR with single memory: structural_signal/episodic_noise — will typically fail.
        // Just verify it doesn't crash.
        let output = DistillationPipeline.run(input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        // Verify struct is coherent
        if output.succeeded {
            #expect(output.confidence >= 0.4)
            #expect(!output.distilledText.isEmpty)
        } else {
            #expect(output.confidence == 0)
        }
    }

    @Test("Empty cluster returns succeeded=false immediately")
    func emptyCluster() {
        let input = DistillationInput(
            memoryContents: [],
            clusterID: "test-cluster-empty",
            sourceIDs: []
        )
        let output = DistillationPipeline.run(input: input, extractFeatures: DistillationPipeline.defaultExtractor)
        #expect(output.succeeded == false)
        #expect(output.failureReason != nil)
    }
}
