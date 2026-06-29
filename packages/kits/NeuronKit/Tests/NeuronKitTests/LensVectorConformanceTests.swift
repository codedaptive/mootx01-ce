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
// Families covered (as of TASK-MXE-N4):
//   NeuronKit: drift, anomalies, keystones, constellations,
//     spreadingActivation, themeWeather, latentThemes,
//     representationBias, learnedPreference, anticipate,
//     partialRecall, mindOverlap, shingleSimilarity,
//     benchmarkScoring, mmrRank, hybridRecall, scenarioProfile,
//     contextSynthesizer, bradleyTerry,
//     momentSignature, rhythm, precedence, complexity, calibration
//   SubstrateML: formalConceptAnalysis, associationRuleMining
//
// Regenerate (after a DELIBERATE behavioral change only):
//   RECORD_LENS_VECTORS=1 swift test --filter LensVectorConformance
// then re-run both legs in verify mode. A mismatch in verify mode is a
// cross-version drift signal, never something to silence by
// re-recording.

import Testing
import Foundation
import SubstrateML
import SubstrateTypes
import EngramLib
import GeniusLocusKit
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

    // MARK: — Families migrated by BYCOPY_MIGRATION_001

    // benchmark_scoring: BS-1..5 cases from BenchmarkScoringTests.swift.
    // Inputs: string id arrays; outputs: 4 scalar floats (hex) + 2 string arrays.
    struct BenchmarkScoringCase: Codable {
        let expectedIDs: [String]
        let foundPerQuery: [[String]]
        var queryCount: Int
        var recallOverlap: String        // Float hex (f32)
        var recallPrecision: String      // Float hex (f32)
        var meanReciprocalRank: String   // Float hex (f32)
        var notFoundInBranch: [String]
        var newInBranch: [String]
    }

    // mmr_rank: Engram inputs encoded as bit-set counts (lowBits).
    // Each candidate has an id (for ordering) and a set-bit count
    // per 256-bit block so both legs reconstruct the same fingerprint.
    // Expected: selection order as ids (Swift) + as input-position
    // indices (Rust). Both legs carry the same cases.
    struct MMRRankCase: Codable {
        struct Candidate: Codable {
            let id: String
            // lowBits count per 64-bit block [block0, block1, block2, block3].
            // Each value is the number of low bits set (0..64).
            let blockBits: [Int]
        }
        let candidates: [Candidate]
        let lambda: Float
        let k: Int
        var expectedIDs: [String]      // Swift selection order by id
        var expectedIndices: [Int]     // Rust selection order by input index
    }

    // formal_concept_analysis: rows of FormalAttribute triples,
    // miner params, expected concepts. Ordering is deterministic per
    // BoundedConceptMiner: support desc, then intent size asc, then
    // lexicographic intent (as documented in FormalConceptAnalysisTests).
    struct FCACase: Codable {
        struct Attr: Codable {
            let namespace: String; let key: String; let value: String
        }
        struct Concept: Codable {
            let extent: [Int]                 // sorted row indices
            let intent: [Attr]               // sorted attributes
            let support: Int
        }
        let rows: [[Attr]]
        let minSupport: Int
        let maxIntentSize: Int
        let maxConcepts: Int
        var concepts: [Concept]
    }

    // hybrid_recall: rerank cases + paging cases.
    // shingleSimilarity cases already in the artifact (shingleSimilarity section).
    struct HybridRecallCase: Codable {
        struct DrawerInput: Codable { let id: String; let content: String }
        struct RerankCase: Codable {
            let drawers: [DrawerInput]
            let mmrLambda: Float
            var expectedOrder: [String]   // expected ids in reranked order
        }
        struct PageEntry: Codable {
            var ids: [String]
            var isLast: Bool
            var pageIndex: Int
        }
        struct PagingCase: Codable {
            let rows: [DrawerInput]
            let pageSize: Int
            var pages: [PageEntry]
        }
        var rerankCases: [RerankCase]
        var pagingCases: [PagingCase]
    }

    // association_rule_mining: rows as [(field: UInt8, value: UInt8)] pairs,
    // activeRowCount N, thresholds (minSupport, minConfidence), expected rules
    // in ascending packed-key order. 5 metrics as f64 hex. Infinite conviction
    // encoded as the sentinel string "inf".
    struct AssocRuleCase: Codable {
        struct ItemPair: Codable { let field: UInt8; let value: UInt8 }
        struct Rule: Codable {
            let antecedentField: UInt8; let antecedentValue: UInt8
            let consequentField: UInt8; let consequentValue: UInt8
            var support: String          // f64 hex
            var confidence: String       // f64 hex
            var lift: String             // f64 hex
            var leverage: String         // f64 hex
            var conviction: String       // f64 hex or "inf"
        }
        let rows: [[ItemPair]]           // each row is the field-value pairs for that row
        let activeRowCount: Int
        let minSupport: Double
        let minConfidence: Double
        var rules: [Rule]
    }

    // scenario_profile: inputs = plain field values; canonicalJson is the
    // Swift sorted-keys encoding and BOTH legs must reproduce it byte-for-byte
    // (SCENARIO_WIRE_PARITY_001: shared camelCase wire vocabulary via serde
    // renames; Double/f64 values — the shortest-roundtrip f64 text is the
    // Swift/Rust/Go three-leg fixed point).
    struct ScenarioProfileCase: Codable {
        let profileID: String
        let name: String
        let framingParameters: [String: String]
        let scoringBreakdown: [String: Double]   // f64 — the three-leg wire fixed point
        let preferenceWeights: [String: Double]  // (Swift/Rust/Go shortest-roundtrip agree)
        let createdAt: String                  // ISO8601 string
        let trainingEligible: Bool
        var canonicalJson: String              // sorted-keys JSON, set by RECORD mode
    }

    // context_synthesizer: rows with content + wing + room + adjectiveBitmap.
    // The Rust loader derives is_currently_believed from adjectiveBitmap bits 0-5
    // (LocusKit State enum, bits 0-5). Cluster A (currently believed) =
    // (state_raw >> 4) & 0x3 == 0, covering raws 0-15: active=0, pending=1,
    // contested=2, accepted=3. Cluster B (raws 16-31) and C (32+) are NOT
    // currently believed. This matches Drawer.isCurrentlyBelieved exactly.
    // Expected: summary (deterministic string), patterns, keyInsights (deterministic),
    // successRate (f32 hex), recommendationsCount (Int — content non-deterministic).
    struct ContextSynthesizerCase: Codable {
        struct RowInput: Codable {
            let content: String
            let wing: String
            let room: String
            let adjectiveBitmap: Int64    // bits 0-5 = State; believed = (raw >> 4) & 0x3 == 0 (cluster A)
            // Parent node id — the node-tree anchor the summary names ("dominant
            // node {id}"). Optional for back-compat decode of pre-node fixtures;
            // the builder normalises a nil to the canonical test node so the
            // emitted fixture always carries it (and the Rust leg can read it).
            var parentNodeId: String?
        }
        var rows: [RowInput]
        var summary: String
        var patterns: [String]
        var keyInsights: [String]
        var successRate: String           // f32 hex
        var recommendationsCount: Int
    }

    // bradley_terry: PairwiseOutcome inputs + per-case tolerance field.
    // Expected strength/confidenceLow/confidenceHigh per competitor as f64 hex.
    // Contract: tolerance-based (NOT bit-equality) — documented C-6-adjacent
    // contract; the tolerance string "1e-6" is included in the artifact so both
    // legs can assert within the same documented bound.
    struct BradleyTerryCase: Codable {
        struct Outcome: Codable {
            let winner: String; let loser: String; let count: Int
        }
        struct Score: Codable {
            let competitorID: String
            var strength: String           // f64 hex
            var confidenceLow: String      // f64 hex
            var confidenceHigh: String     // f64 hex
        }
        let outcomes: [Outcome]
        let tolerance: String              // e.g. "1e-6"
        var scores: [Score]
    }

    // MARK: — Five-Lenses families (TASK-MXE-N4)

    // moment_signature: rows as 4-block fingerprint hex arrays; candidates same.
    // Output: signature blocks + ranked [{candidate blocks, hammingDistance}].
    struct MomentSignatureCase: Codable {
        struct RankedCandidate: Codable { let candidate: [String]; var hammingDistance: Int }
        let rows: [[String]]            // each row: 4-element block-hex array
        let candidates: [[String]]      // same shape
        var signatureBlocks: [String]   // 4-element block-hex array
        var ranking: [RankedCandidate]
    }

    // rhythm: bool activity series, duration as f64 hex, topK int.
    // Output: [{periodSeconds: f64 hex, relativeMagnitude: f64 hex}].
    struct RhythmCase: Codable {
        struct Period: Codable { var periodSeconds: String; var relativeMagnitude: String }
        let buckets: [Bool]
        let bucketDurationSeconds: String  // f64 hex
        let topK: Int
        var periods: [Period]
    }

    // precedence: pre-folded T-matrix pairs encoded inline; k antecedents.
    // Output: ranked [{sourceField, sourceValue, lagBucket, count}].
    struct PrecedenceCase: Codable {
        struct Pair: Codable {
            let sourceField: String; let sourceValue: String
            let targetField: String; let targetValue: String
            let lagBucket: Int; let count: Int
        }
        struct RankedAntecedent: Codable {
            let sourceField: String; let sourceValue: String
            let lagBucket: Int; var count: Int
        }
        let pairs: [Pair]
        let targetField: String; let targetValue: String; let k: Int
        var ranked: [RankedAntecedent]
    }

    // complexity: f32 hex count arrays; countsB and joint are omitted when nil.
    // Output: f32 hex entropyA; entropyB and mutualInformation omitted when nil.
    struct ComplexityCase: Codable {
        let countsA: [String]           // f32 hex
        let countsB: [String]?          // f32 hex; nil = not provided
        let joint: [[String]]?          // f32 hex; nil = not provided
        var entropyA: String            // f32 hex
        var entropyB: String?           // f32 hex; nil when countsB is nil
        var mutualInformation: String?  // f32 hex; nil when joint is nil
    }

    // calibration: curve built from replay records {value: f32 hex, outcome: "success"|"failure"}.
    // Output: [{claimedHex: f32 hex, calibratedHex: f32 hex, isCalibrated: Bool}].
    struct CalibrationCase: Codable {
        struct Record: Codable { let value: String; let outcome: String }
        struct Output: Codable {
            let claimedHex: String
            var calibratedHex: String
            var isCalibrated: Bool
        }
        let records: [Record]           // replay to build the curve
        let claimed: [String]           // f32 hex values to calibrate
        var calibrated: [Output]
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
    // Families migrated by BYCOPY_MIGRATION_001:
    var benchmarkScoring: [BenchmarkScoringCase]
    var mmrRank: [MMRRankCase]
    var formalConceptAnalysis: [FCACase]
    var hybridRecall: HybridRecallCase
    var associationRuleMining: [AssocRuleCase]
    var scenarioProfile: [ScenarioProfileCase]
    var contextSynthesizer: [ContextSynthesizerCase]
    var bradleyTerry: [BradleyTerryCase]
    var momentSignature: [MomentSignatureCase]
    var rhythm: [RhythmCase]
    var precedence: [PrecedenceCase]
    var complexity: [ComplexityCase]
    var calibration: [CalibrationCase]
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

        // MARK: — BYCOPY_MIGRATION_001 families

        // benchmark_scoring: call BenchmarkScoring.score; encode 4 float
        // metrics as f32 hex for bit-identical cross-version comparison.
        v.benchmarkScoring = vectors.benchmarkScoring.map { c in
            var c = c
            let s = BenchmarkScoring.score(
                expectedIDs: c.expectedIDs,
                foundPerQuery: c.foundPerQuery)
            c.queryCount = s.queryCount
            c.recallOverlap = hex(s.recallOverlap)
            c.recallPrecision = hex(s.recallPrecision)
            c.meanReciprocalRank = hex(s.meanReciprocalRank)
            c.notFoundInBranch = s.notFoundInBranch
            c.newInBranch = s.newInBranch
            return c
        }

        // mmr_rank: reconstruct Engram fingerprints from the blockBits
        // encoding (each element is the count of low bits set in that
        // 64-bit block). Uses EngramLib.Engram(blocks:_:_:_:).
        // The query is the all-zero engram.
        v.mmrRank = vectors.mmrRank.map { c in
            var c = c
            let query = Engram(blocks: 0, 0, 0, 0)
            func buildEngram(_ candidate: LensVectors.MMRRankCase.Candidate) -> Engram {
                func lowBits(_ count: Int) -> UInt64 {
                    count >= 64 ? ~UInt64(0) : (UInt64(1) << count) - 1
                }
                let bb = candidate.blockBits
                return Engram(blocks: lowBits(bb[0]), lowBits(bb[1]),
                              lowBits(bb[2]), lowBits(bb[3]))
            }
            let drawers: [Drawer] = c.candidates.map { cand in
                Drawer(
                    id: cand.id, content: "",
                    parentNodeId: "test-room-node",
                    sourceFile: nil, chunkIndex: nil,
                    addedBy: "test",
                    filedAt: Date(timeIntervalSince1970: 0),
                    embeddingModelID: "test-embed-v1",
                    tombstonedAt: nil, removedByBatch: nil,
                    provenance: 0, adjectiveBitmap: 0,
                    operationalBitmap: 0,
                    lineageID: UUID(), udcCode: "",
                    udcFacets: nil, wikidataQID: nil,
                    wikidataQidsSecondary: nil)
            }
            let fingerprintMap: [String: Engram] = Dictionary(
                uniqueKeysWithValues: zip(c.candidates.map(\.id), c.candidates.map(buildEngram)))
            let result = mmrRank(
                candidates: drawers,
                query: query,
                lambda: c.lambda,
                k: c.k,
                fingerprint: { d in fingerprintMap[d.id] ?? Engram(blocks: 0, 0, 0, 0) })
            c.expectedIDs = result.map(\.id)
            // expectedIndices: map each output id back to its input position
            let inputIndex = Dictionary(uniqueKeysWithValues:
                zip(c.candidates.indices.map { $0 }, c.candidates.map(\.id))
                    .map { ($0.1, $0.0) })
            c.expectedIndices = result.map { inputIndex[$0.id] ?? -1 }
            return c
        }

        // formal_concept_analysis: reconstruct FormalContext from rows
        // of FormalAttribute triples; run BoundedConceptMiner with
        // the artifact's params.
        v.formalConceptAnalysis = vectors.formalConceptAnalysis.map { c in
            var c = c
            func toAttr(_ a: LensVectors.FCACase.Attr) -> FormalAttribute {
                FormalAttribute(namespace: a.namespace, key: a.key, value: a.value)
            }
            let ctx = FormalContext(rows: c.rows.map { $0.map(toAttr) })
            let miner = BoundedConceptMiner(
                minSupport: c.minSupport,
                maxIntentSize: c.maxIntentSize,
                maxConcepts: c.maxConcepts)
            c.concepts = miner.mine(context: ctx).map { concept in
                LensVectors.FCACase.Concept(
                    // FormalContext.RowID is UInt32; serialize as Int for JSON portability.
                    extent: concept.extent.map { Int($0) },
                    intent: concept.intent.map { a in
                        LensVectors.FCACase.Attr(
                            namespace: a.namespace, key: a.key, value: a.value)
                    },
                    support: concept.support)
            }
            return c
        }

        // hybrid_recall: rerank cases + paging cases.
        // shingleSimilarity is already covered in the shingleSimilarity section.
        do {
            var hr = vectors.hybridRecall
            hr.rerankCases = vectors.hybridRecall.rerankCases.map { rc in
                var rc = rc
                let drawers: [Drawer] = rc.drawers.map { di in
                    Drawer(
                        id: di.id, content: di.content,
                        parentNodeId: "test-room-node",
                        sourceFile: nil, chunkIndex: nil,
                        addedBy: "test",
                        filedAt: Date(timeIntervalSince1970: 0),
                        embeddingModelID: "test-embed-v1",
                        tombstonedAt: nil, removedByBatch: nil,
                        provenance: 0, adjectiveBitmap: 0,
                        operationalBitmap: 0,
                        lineageID: UUID(), udcCode: "",
                        udcFacets: nil, wikidataQID: nil,
                        wikidataQidsSecondary: nil)
                }
                let tuning = RecallFrameTuning(mmrLambda: rc.mmrLambda)
                rc.expectedOrder = HybridRecallEngine.rerank(drawers: drawers, tuning: tuning).map(\.id)
                return rc
            }
            hr.pagingCases = vectors.hybridRecall.pagingCases.map { pc in
                var pc = pc
                let drawers: [Drawer] = pc.rows.map { di in
                    Drawer(
                        id: di.id, content: di.content,
                        parentNodeId: "test-room-node",
                        sourceFile: nil, chunkIndex: nil,
                        addedBy: "test",
                        filedAt: Date(timeIntervalSince1970: 0),
                        embeddingModelID: "test-embed-v1",
                        tombstonedAt: nil, removedByBatch: nil,
                        provenance: 0, adjectiveBitmap: 0,
                        operationalBitmap: 0,
                        lineageID: UUID(), udcCode: "",
                        udcFacets: nil, wikidataQID: nil,
                        wikidataQidsSecondary: nil)
                }
                let reranked = HybridRecallEngine.rerank(drawers: drawers, tuning: .default)
                // Replicate RecallStream paging logic synchronously so the
                // computed(from:) function stays non-async. Same chunking
                // invariants: pageSize < 1 clamps to 1; empty input emits
                // one final page at index 0.
                let size = Swift.max(1, pc.pageSize)
                var pages: [LensVectors.HybridRecallCase.PageEntry] = []
                if reranked.isEmpty {
                    pages.append(LensVectors.HybridRecallCase.PageEntry(
                        ids: [], isLast: true, pageIndex: 0))
                } else {
                    var offset = 0
                    var pageIndex = 0
                    while offset < reranked.count {
                        let end = Swift.min(offset + size, reranked.count)
                        let isLast = end >= reranked.count
                        pages.append(LensVectors.HybridRecallCase.PageEntry(
                            ids: reranked[offset..<end].map(\.id),
                            isLast: isLast,
                            pageIndex: pageIndex))
                        offset = end
                        pageIndex += 1
                    }
                }
                pc.pages = pages
                return pc
            }
            v.hybridRecall = hr
        }

        // association_rule_mining: rebuild MatrixO from rows via applyRow,
        // run mineAssociationRules with the artifact's thresholds.
        // Infinite conviction → sentinel "inf" (both legs use this convention).
        v.associationRuleMining = vectors.associationRuleMining.map { c in
            var c = c
            var matrix = MatrixO()
            for row in c.rows {
                let fieldValues = row.map { (field: $0.field, value: $0.value) }
                matrix.applyRow(delta: 1, fieldValues: fieldValues)
            }
            let thresholds = MiningThresholds(
                minSupport: c.minSupport,
                minConfidence: c.minConfidence)
            c.rules = mineAssociationRules(
                matrix: matrix,
                activeRowCount: Int64(c.activeRowCount),
                thresholds: thresholds
            ).map { rule in
                LensVectors.AssocRuleCase.Rule(
                    antecedentField: rule.antecedent.field,
                    antecedentValue: rule.antecedent.value,
                    consequentField: rule.consequent.field,
                    consequentValue: rule.consequent.value,
                    support: hex(rule.support),
                    confidence: hex(rule.confidence),
                    lift: hex(rule.lift),
                    leverage: hex(rule.leverage),
                    conviction: rule.conviction.isInfinite ? "inf" : hex(rule.conviction))
            }
            return c
        }

        // scenario_profile: build ScenarioProfile, encode with .sortedKeys and
        // .iso8601 date strategy. The ISO8601 date strategy encodes Date as a
        // string rather than a Unix timestamp Double, matching the Rust
        // ScenarioProfile.created_at: String field. The recorded canonicalJson
        // is the Swift sorted-keys encoding, which the Rust leg byte-compares
        // against (shared camelCase wire vocabulary since wire parity landed).
        v.scenarioProfile = vectors.scenarioProfile.map { c in
            var c = c
            let profile = ScenarioProfile(
                profileID: UUID(uuidString: c.profileID)!,
                name: c.name,
                framingParameters: c.framingParameters,
                scoringBreakdown: c.scoringBreakdown,
                preferenceWeights: c.preferenceWeights,
                createdAt: ISO8601DateFormatter().date(from: c.createdAt)
                    ?? Date(timeIntervalSince1970: 0),
                trainingEligible: c.trainingEligible)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            // Use ISO8601 date encoding so Date serializes as a string,
            // matching the Rust side's String field; keys and values are
            // byte-identical across legs (see the section comment above).
            encoder.dateEncodingStrategy = .iso8601
            let data = try! encoder.encode(profile)
            c.canonicalJson = String(data: data, encoding: .utf8) ?? ""
            return c
        }

        // context_synthesizer: build Drawer rows with the given
        // adjectiveBitmap (bits 0-5 = State; Drawer.isCurrentlyBelieved is
        // the cluster-A predicate (raw >> 4) & 0x3 == 0),
        // synthesize via ContextSynthesisEngine, record deterministic outputs.
        v.contextSynthesizer = vectors.contextSynthesizer.map { c in
            var c = c
            // Normalise each row's parentNodeId (nil → canonical test node) so the
            // emitted fixture carries it and the summary names the node.
            c.rows = c.rows.map { ri in
                var ri = ri
                ri.parentNodeId = ri.parentNodeId ?? "test-room-node"
                return ri
            }
            let rows: [Drawer] = c.rows.map { ri in
                Drawer(
                    id: UUID().uuidString,
                    content: ri.content,
                    parentNodeId: ri.parentNodeId ?? "test-room-node",
                    sourceFile: nil, chunkIndex: nil,
                    addedBy: "test",
                    filedAt: Date(timeIntervalSince1970: 0),
                    embeddingModelID: "test-embed-v1",
                    tombstonedAt: nil, removedByBatch: nil,
                    provenance: 0,
                    adjectiveBitmap: ri.adjectiveBitmap,
                    operationalBitmap: 0,
                    lineageID: UUID(), udcCode: "",
                    udcFacets: nil, wikidataQID: nil,
                    wikidataQidsSecondary: nil)
            }
            let page = RecallStream.Page(rows: rows, pageIndex: 0, isLast: true)
            let doc = ContextSynthesisEngine.synthesize(page: page)
            c.summary = doc.summary
            c.patterns = doc.patterns
            c.keyInsights = doc.keyInsights
            c.successRate = hex(doc.successRate)
            c.recommendationsCount = doc.recommendations.count
            return c
        }

        // bradley_terry: fit the MLE; record strength + CI per competitor
        // as f64 hex. Tolerance-based (not bit-exact) — the "tolerance"
        // field carries the documented bound "1e-6" so the Rust leg can
        // assert within the same bound.
        v.bradleyTerry = vectors.bradleyTerry.map { c in
            var c = c
            let outcomes = c.outcomes.map {
                PairwiseOutcome(winner: $0.winner, loser: $0.loser, count: $0.count)
            }
            let fitted = try! bradleyTerry(outcomes: outcomes)
            c.scores = fitted.map { score in
                LensVectors.BradleyTerryCase.Score(
                    competitorID: score.competitorID,
                    strength: hex(score.strength),
                    confidenceLow: hex(score.confidenceLow),
                    confidenceHigh: hex(score.confidenceHigh))
            }
            return c
        }

        // MARK: — Five-Lenses computation blocks (TASK-MXE-N4)

        // moment_signature: decode block-hex rows and candidates → call NeuronKit.momentSignature.
        v.momentSignature = vectors.momentSignature.map { c in
            var c = c
            let rows = c.rows.map { b in
                RowLite(fingerprint: fingerprint(b),
                        captureHLC: HLC(physicalTime: 0, logicalCount: 0, nodeID: 0))
            }
            let candidates = c.candidates.map { fingerprint($0) }
            let result = NeuronKit.momentSignature(fingerprints: rows, candidates: candidates)
            c.signatureBlocks = blocks(result.signature)
            c.ranking = result.ranking.map {
                .init(candidate: blocks($0.candidate),
                      hammingDistance: Int($0.hammingDistance))
            }
            return c
        }

        // rhythm: decode f64 hex duration → call NeuronKit.rhythm.
        v.rhythm = vectors.rhythm.map { c in
            var c = c
            let periods = NeuronKit.rhythm(
                buckets: c.buckets,
                bucketDurationSeconds: double(c.bucketDurationSeconds),
                topK: c.topK)
            c.periods = periods.map {
                .init(periodSeconds: hex($0.periodSeconds),
                      relativeMagnitude: hex($0.relativeMagnitude))
            }
            return c
        }

        // precedence: rebuild pairs as (TemporalCausalityKey, Int64) → call NeuronKit.precedence.
        v.precedence = vectors.precedence.map { c in
            var c = c
            let target = TemporalFieldCoord(fieldPath: c.targetField, valueRepr: c.targetValue)
            let pairs: [(TemporalCausalityKey, Int64)] = c.pairs.map { p in
                let src = TemporalFieldCoord(fieldPath: p.sourceField, valueRepr: p.sourceValue)
                let tgt = TemporalFieldCoord(fieldPath: p.targetField, valueRepr: p.targetValue)
                let key = TemporalCausalityKey(source: src, target: tgt, lagBucket: p.lagBucket)
                return (key, Int64(p.count))
            }
            let result = NeuronKit.precedence(pairs: pairs, target: target, k: c.k)
            c.ranked = result.map {
                .init(sourceField: $0.source.fieldPath,
                      sourceValue: $0.source.valueRepr,
                      lagBucket: $0.lagBucket,
                      count: Int($0.count))
            }
            return c
        }

        // complexity: decode f32 hex count arrays → call NeuronKit.complexity.
        v.complexity = vectors.complexity.map { c in
            var c = c
            let countsA = c.countsA.map(float)
            let countsB = c.countsB.map { $0.map(float) }
            let joint = c.joint.map { $0.map { row in row.map(float) } }
            let result = NeuronKit.complexity(countsA: countsA, countsB: countsB, joint: joint)
            c.entropyA = hex(result.entropyA)
            c.entropyB = result.entropyB.map(hex)
            c.mutualInformation = result.mutualInformation.map(hex)
            return c
        }

        // calibration: replay records to build the curve → call NeuronKit.calibrate.
        v.calibration = vectors.calibration.map { c in
            var c = c
            var curve = MatrixCalibrationCurve()
            for r in c.records {
                let outcome: MatrixCalibrationOutcome = r.outcome == "success" ? .success : .failure
                curve.record(claimedConfidence: float(r.value), outcome: outcome)
            }
            let results = NeuronKit.calibrate(curve: curve, claimed: c.claimed.map(float))
            c.calibrated = zip(c.claimed, results).map { (claimedHex, out) in
                .init(claimedHex: claimedHex,
                      calibratedHex: hex(out.calibrated),
                      isCalibrated: out.isCalibrated)
            }
            return c
        }

        return v
    }

    // computed(from:) calls HybridRecallEngine.rerank() and bradleyTerry()
    // which both emit to the global Intellectus singleton. Acquire the
    // process-wide mutex for the full duration of this test so no
    // concurrent telemetry test sees phantom emissions.
    @Test("every lens reproduces the shared vectors bit-for-bit")
    func lensesReproduceSharedVectors() async throws {
        try await withIntellectusLock {
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
}
