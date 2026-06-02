// LensVectorConformanceTests.swift
//
// The shared-vector conformance gate for the reasoning-lens surface
// (SPEC § 7, § 9). One artifact — Fixtures/lens_vectors.json — holds
// the inputs AND the expected outputs for every pure lens operation;
// this suite and the Rust `rust/tests/lens_conformance.rs` both read
// it, so the two versions are gated against the SAME vectors instead
// of mirrored-by-copy literals. Floats are carried as bit-pattern hex
// strings ("0x3f800000") so equality is exact and JSON-precision-safe.
//
// Regenerate (after a DELIBERATE behavioral change only):
//   RECORD_LENS_VECTORS=1 swift test --filter LensVectorConformance
// then re-run both legs in verify mode. A mismatch in verify mode is a
// cross-version drift signal, never something to silence by
// re-recording.

import Testing
import Foundation
import SubstrateTypes
@testable import NeuronKit

// MARK: - Bit-pattern hex codecs

private func hex(_ value: Float) -> String { String(format: "0x%08x", value.bitPattern) }
private func hex(_ value: Double) -> String { String(format: "0x%016llx", value.bitPattern) }
private func hex(_ value: UInt64) -> String { String(format: "0x%016llx", value) }
private func float(_ s: String) -> Float { Float(bitPattern: UInt32(s.dropFirst(2), radix: 16)!) }
private func double(_ s: String) -> Double { Double(bitPattern: UInt64(s.dropFirst(2), radix: 16)!) }
private func uint64(_ s: String) -> UInt64 { UInt64(s.dropFirst(2), radix: 16)! }

private func fingerprint(_ blocks: [String]) -> Fingerprint256 {
    Fingerprint256(block0: uint64(blocks[0]), block1: uint64(blocks[1]),
                   block2: uint64(blocks[2]), block3: uint64(blocks[3]))
}
private func blocks(_ fp: Fingerprint256) -> [String] {
    [hex(fp.block0), hex(fp.block1), hex(fp.block2), hex(fp.block3)]
}

// MARK: - Vector schema (mirrored by rust/tests/lens_conformance.rs)

private struct LensVectors: Codable {
    struct DriftCase: Codable {
        let p: [String]; let q: [String]
        var jensenShannon: String; var klDivergence: String
    }
    struct AnomalyCase: Codable {
        struct Flagged: Codable { let index: Int; var zScore: String }
        let values: [String]; let threshold: String
        var flagged: [Flagged]
    }
    struct KeystonesCase: Codable {
        struct Ranked: Codable { let id: String; var centrality: String }
        let nodeIDs: [String]; let edges: [[String]]; let topK: Int
        var ranked: [Ranked]
    }
    struct ConstellationCase: Codable {
        let nodeIDs: [String]; let edges: [[String]]; let maxPasses: Int
        var communities: [[String]]
    }
    struct ActivationCase: Codable {
        struct Edge: Codable { let node: Int; let weight: String }
        struct Activated: Codable { let node: Int; var activation: String }
        let adjacency: [[Edge]]; let seed: Int; let walkLength: Int
        let restartProb: String; let rngSeed: UInt64; let k: Int
        var activations: [Activated]
    }
    struct ThemeWeatherCase: Codable {
        struct Category: Codable { let category: String; let rawCount: String; let weightedMass: String }
        struct Momentum: Codable { let category: String; var momentum: String }
        let categories: [Category]
        var momenta: [Momentum]
    }
    struct LatentThemesCase: Codable {
        struct Pair: Codable { let labelA: String; let labelB: String; let weight: String }
        struct Loading: Codable { let label: String; var loadings: [String]; var dominantTheme: Int }
        let labels: [String]; let cooccurrence: [Pair]; let k: Int; let seed: UInt64
        var resultK: Int; var loadings: [Loading]; var reconstructionError: String
    }
    struct BiasCase: Codable {
        struct Mass: Codable { let label: String; let mass: String }
        struct Expected: Codable {
            let label: String; var estateShare: String; var referenceShare: String; var bias: String
        }
        let estate: [Mass]; let reference: [Mass]
        var biases: [Expected]
    }
    struct PreferenceCase: Codable {
        struct Record: Codable { let label: String; let endorsements: Int; let dismissals: Int }
        struct Strength: Codable {
            let label: String; var strength: String
            var confidenceLow: String; var confidenceHigh: String
            var endorsements: Int; var dismissals: Int
        }
        let records: [Record]
        var strengths: [Strength]
    }
    struct AnticipateCase: Codable {
        struct Observation: Codable { let action: UInt8; let outcome: UInt8; let success: Bool }
        struct Prediction: Codable { let action: UInt8; var successRate: String; var count: UInt32 }
        let observations: [Observation]; let targetOutcome: UInt8
        let k: Int; let minObservations: UInt32
        var predictions: [Prediction]
    }
    struct PartialRecallCase: Codable {
        struct Match: Codable { let row: Int; var score: String }
        let anchor: [String]; let rows: [[String]]
        let matchBlocks: [Int]; let differBlocks: [Int]; let k: Int
        var matches: [Match]
    }
    struct MindOverlapCase: Codable {
        let fingerprintsA: [[String]]; let fingerprintsB: [[String]]
        let epsilon: String; let delta: String; let kAnonymity: Int; let seed: UInt64
        var summaryA: [String]; var summaryB: [String]; var overlap: String
    }
    struct ShingleCase: Codable {
        let a: String; let b: String
        var similarity: String
    }

    var drift: [DriftCase]
    var anomalies: [AnomalyCase]
    var keystones: [KeystonesCase]
    var constellations: [ConstellationCase]
    var spreadingActivation: [ActivationCase]
    var themeWeather: [ThemeWeatherCase]
    var latentThemes: [LatentThemesCase]
    var representationBias: [BiasCase]
    var learnedPreference: [PreferenceCase]
    var anticipate: [AnticipateCase]
    var partialRecall: [PartialRecallCase]
    var mindOverlap: [MindOverlapCase]
    var shingleSimilarity: [ShingleCase]
}

// MARK: - The gate

@Suite("Lens vector conformance (shared artifact, SPEC § 9)", .serialized)
struct LensVectorConformanceTests {

    /// In-repo path (record mode writes here; the committed copy is the
    /// artifact both legs read).
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/lens_vectors.json")
    }

    private func load() throws -> LensVectors {
        let data = try Data(contentsOf: Self.fixtureURL)
        return try JSONDecoder().decode(LensVectors.self, from: data)
    }

    /// Compute every case's outputs with the live Swift lenses.
    private func computed(from vectors: LensVectors) -> LensVectors {
        var v = vectors
        v.drift = vectors.drift.map { c in
            var c = c
            let out = NeuronKit.drift(from: c.p.map(float), to: c.q.map(float))
            c.jensenShannon = hex(out.jensenShannon)
            c.klDivergence = hex(out.klDivergence)
            return c
        }
        v.anomalies = vectors.anomalies.map { c in
            var c = c
            c.flagged = NeuronKit.anomalies(values: c.values.map(float), threshold: float(c.threshold))
                .map { .init(index: $0.index, zScore: hex($0.zScore)) }
            return c
        }
        v.keystones = vectors.keystones.map { c in
            var c = c
            c.ranked = NeuronKit.keystones(
                nodeIDs: c.nodeIDs, edges: c.edges.map { ($0[0], $0[1]) }, topK: c.topK)
                .map { .init(id: $0.id, centrality: hex($0.centrality)) }
            return c
        }
        v.constellations = vectors.constellations.map { c in
            var c = c
            c.communities = NeuronKit.constellations(
                nodeIDs: c.nodeIDs, edges: c.edges.map { ($0[0], $0[1]) },
                maxPasses: c.maxPasses).communities
            return c
        }
        v.spreadingActivation = vectors.spreadingActivation.map { c in
            var c = c
            let adjacency = c.adjacency.map { $0.map { (node: $0.node, weight: double($0.weight)) } }
            c.activations = NeuronKit.spreadingActivation(
                adjacency: adjacency, seed: c.seed, walkLength: c.walkLength,
                restartProb: double(c.restartProb), rngSeed: c.rngSeed, k: c.k)
                .map { .init(node: $0.node, activation: hex($0.activation)) }
            return c
        }
        v.themeWeather = vectors.themeWeather.map { c in
            var c = c
            c.momenta = NeuronKit.themeWeather(
                categories: c.categories.map {
                    (category: $0.category, rawCount: double($0.rawCount),
                     weightedMass: double($0.weightedMass))
                })
                .map { .init(category: $0.category, momentum: hex($0.momentum)) }
            return c
        }
        v.latentThemes = vectors.latentThemes.map { c in
            var c = c
            let out = NeuronKit.latentThemes(
                labels: c.labels,
                cooccurrence: c.cooccurrence.map { ($0.labelA, $0.labelB, double($0.weight)) },
                k: c.k, seed: c.seed)
            c.resultK = out.k
            c.loadings = out.loadings.map {
                .init(label: $0.label, loadings: $0.loadings.map(hex),
                      dominantTheme: $0.dominantTheme)
            }
            c.reconstructionError = hex(out.reconstructionError)
            return c
        }
        v.representationBias = vectors.representationBias.map { c in
            var c = c
            c.biases = NeuronKit.representationBias(
                estate: c.estate.map { ($0.label, double($0.mass)) },
                reference: c.reference.map { ($0.label, double($0.mass)) })
                .map {
                    .init(label: $0.label, estateShare: hex($0.estateShare),
                          referenceShare: hex($0.referenceShare), bias: hex($0.bias))
                }
            return c
        }
        v.learnedPreference = vectors.learnedPreference.map { c in
            var c = c
            c.strengths = try! NeuronKit.learnedPreference(
                records: c.records.map { ($0.label, $0.endorsements, $0.dismissals) })
                .map {
                    .init(label: $0.label, strength: hex($0.strength),
                          confidenceLow: hex($0.confidenceLow),
                          confidenceHigh: hex($0.confidenceHigh),
                          endorsements: $0.endorsements, dismissals: $0.dismissals)
                }
            return c
        }
        v.anticipate = vectors.anticipate.map { c in
            var c = c
            c.predictions = NeuronKit.anticipate(
                observations: c.observations.map {
                    ActionObservation(action: $0.action, outcome: $0.outcome, success: $0.success)
                },
                targetOutcome: c.targetOutcome, k: c.k, minObservations: c.minObservations)
                .map { .init(action: $0.action, successRate: hex($0.successRate), count: $0.count) }
            return c
        }
        v.partialRecall = vectors.partialRecall.map { c in
            var c = c
            // Rows are index-keyed in the artifact; each leg maps the
            // index through its own row-id type.
            let rowIDs = c.rows.indices.map { _ in UUID() }
            let rows = zip(rowIDs, c.rows).map { (rowID: $0, fingerprint: fingerprint($1)) }
            let indexOf = Dictionary(uniqueKeysWithValues: zip(rowIDs, c.rows.indices))
            c.matches = NeuronKit.partialRecall(
                anchor: fingerprint(c.anchor), rows: rows,
                matchBlocks: Set(c.matchBlocks.map { FingerprintBlock(rawValue: $0)! }),
                differBlocks: Set(c.differBlocks.map { FingerprintBlock(rawValue: $0)! }),
                k: c.k)
                .map { .init(row: indexOf[$0.rowID]!, score: hex($0.score)) }
            return c
        }
        v.mindOverlap = vectors.mindOverlap.map { c in
            var c = c
            let summaryA = NeuronKit.dpSummary(
                fingerprints: c.fingerprintsA.map(fingerprint), epsilon: double(c.epsilon),
                delta: double(c.delta), kAnonymity: c.kAnonymity, seed: c.seed)
            let summaryB = NeuronKit.dpSummary(
                fingerprints: c.fingerprintsB.map(fingerprint), epsilon: double(c.epsilon),
                delta: double(c.delta), kAnonymity: c.kAnonymity, seed: c.seed)
            c.summaryA = blocks(summaryA)
            c.summaryB = blocks(summaryB)
            c.overlap = hex(NeuronKit.summaryOverlap(summaryA, summaryB))
            return c
        }
        v.shingleSimilarity = vectors.shingleSimilarity.map { c in
            var c = c
            c.similarity = hex(NeuronKit.shingleSimilarity(c.a, c.b))
            return c
        }
        return v
    }

    @Test("every lens reproduces the shared vectors bit-for-bit")
    func lensesReproduceSharedVectors() throws {
        let vectors = try load()
        let live = computed(from: vectors)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let expected = try encoder.encode(vectors)
        let actual = try encoder.encode(live)

        if ProcessInfo.processInfo.environment["RECORD_LENS_VECTORS"] == "1" {
            try actual.write(to: Self.fixtureURL)
            Issue.record("RECORD MODE: re-recorded \(Self.fixtureURL.lastPathComponent); rerun in verify mode")
            return
        }

        #expect(expected == actual,
                "cross-version drift: a lens no longer reproduces the shared vectors")
    }
}
