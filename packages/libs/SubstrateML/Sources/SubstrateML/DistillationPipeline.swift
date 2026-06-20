// DistillationPipeline.swift
//
// Full five-stage cold-path distillation algorithm per
// DISTILLATION_MATH_SSA.md §1–7 and DISTILLATION_MATH_DIFFUSION.md §1–8.
//
// Mirrors Rust distillation_pipeline.rs (bit-identical output required).
// Conformance vectors: DistillationOutput for matching (query, memories) inputs.
//
// Callers:
//   NeuronKit.distillCluster  — thin lens wrapper that supplies the
//                               EideticLib feature extraction seam
//   DistilledRecall recipe    — DistilledHeader.parse() for result post-processing
//   ExpandMemory recipe       — DistilledHeader.parse() for factoid validation
//
// Prerequisite types (DeltaType, DeltaFeatureExtractor, DistillationFeatureType,
// TypedDecayWeighting, ExtractedFeature, DistillationSNR, FeatureGraph,
// DistillationScorer) live in their canonical files:
//   DeltaFeatureExtractor.swift (Ds1)
//   TypedDecayWeighting.swift   (Ds2)
//   DistillationScorer.swift    (Ds3)

import Foundation
import SubstrateTypes

// MARK: - DS4: DistillationPipeline core types

/// Input to the five-stage distillation pipeline.
public struct DistillationInput: Sendable {
    /// Raw text content of each memory in the cluster.
    public let memoryContents: [String]
    /// Optional timestamps; nil means uniform weighting (no temporal decay).
    public let memoryTimestamps: [Date]?
    /// UUID of the cluster being distilled (written to lineage_id on the factoid drawer).
    public let clusterID: String
    /// UUIDs of the source memory drawers (for provenance chain).
    public let sourceIDs: [String]
    /// Number of memories in the cluster.
    public var M: Int { memoryContents.count }

    public init(
        memoryContents: [String],
        memoryTimestamps: [Date]? = nil,
        clusterID: String,
        sourceIDs: [String]
    ) {
        self.memoryContents = memoryContents
        self.memoryTimestamps = memoryTimestamps
        self.clusterID = clusterID
        self.sourceIDs = sourceIDs
    }
}

/// Output from the five-stage distillation pipeline.
public struct DistillationOutput: Sendable {
    /// Content string for the "_distilled" drawer capture.
    /// Format: "[DIST|conf=X.XX|src=N|snr=Y.YY|delta=STATIC] prose text"
    public let drawerContent: String
    /// Confidence score conf(F*) ∈ [0, 1].
    public let confidence: Float32
    /// True when conf ∈ [0.4, 0.7): signal to inject with additional provenance.
    public let uncertain: Bool
    /// Cluster SNR at distillation time.
    public let snr: Float32
    /// DeltaType if a delta feature was the dominant contributor; nil for static clusters.
    public let deltaType: DeltaType?
    /// True when a factoid was successfully produced (conf >= 0.4 and SNR gate passed).
    public let succeeded: Bool
    /// Human-readable reason for failure when succeeded == false.
    public let failureReason: String?
    /// Structural fingerprint for the distilled tier's VectorKit lane.
    /// OR-reduce of featureHash(f.value) for each feature f in F*.
    /// Stored in VectorKit under modelID = "distillation-features-v1".
    /// No embedding model inference — pure Hamming arithmetic.
    public let featureFingerprint: Fingerprint256
}

/// Parser for the DIST header on "_distilled" drawers.
///
/// Co-located with the pipeline because the code that writes the format owns the
/// parser. Consumed by CognitionKit recipes (DistilledRecall, ExpandMemory) and
/// AriaMcpKit injection-depth post-processing.
public struct DistilledHeader: Sendable, Equatable {
    /// Factoid prose: everything after "] " in the DIST content string.
    public let prose: String
    /// Confidence score conf(F*) ∈ [0, 1].
    public let confidence: Float32
    /// Number of source memories M.
    public let sourceCount: Int
    /// Cluster SNR at distillation time.
    public let snr: Float32
    /// DeltaType of the dominant feature, if non-static.
    public let deltaType: DeltaType?
    /// True when confidence ∈ [0.4, 0.7).
    public let uncertain: Bool

    /// Parse a "_distilled" drawer's content string.
    ///
    /// Expected format (from DISTILLATION_DESIGN.md §1):
    ///   "[DIST|conf=0.85|src=5|snr=6.2|delta=STATIC] prose text"
    ///   "[DIST|conf=0.55|src=3|snr=3.1|delta=CONVERGENT|uncertain] prose"
    ///
    /// Returns nil if the content does not start with "[DIST|".
    public static func parse(_ content: String) -> DistilledHeader? {
        guard content.hasPrefix("[DIST|") else { return nil }

        // Find the closing bracket
        guard let bracketEnd = content.firstIndex(of: "]") else { return nil }

        // Extract the header fields (after "[DIST|" and before "]")
        let headerStart = content.index(content.startIndex, offsetBy: 6)  // skip "[DIST|"
        let headerStr = String(content[headerStart..<bracketEnd])

        // Prose is everything after "] "
        let afterBracket = content.index(after: bracketEnd)
        let prose: String
        if afterBracket < content.endIndex && content[afterBracket] == " " {
            prose = String(content[content.index(after: afterBracket)...])
        } else {
            prose = afterBracket < content.endIndex ? String(content[afterBracket...]) : ""
        }

        // Parse key=value pairs from header
        var conf: Float32 = 0
        var src: Int = 0
        var snr: Float32 = 0
        var delta: DeltaType? = nil
        var uncertain = false

        for part in headerStr.split(separator: "|") {
            let s = String(part)
            if s == "uncertain" {
                uncertain = true
                continue
            }
            guard let eqIdx = s.firstIndex(of: "=") else { continue }
            let key = String(s[s.startIndex..<eqIdx])
            let val = String(s[s.index(after: eqIdx)...])
            switch key {
            case "conf": conf = Float32(val) ?? 0
            case "src":  src = Int(val) ?? 0
            case "snr":  snr = Float32(val) ?? 0
            case "delta": delta = DeltaType(rawValue: val)
            default: break
            }
        }

        return DistilledHeader(
            prose: prose, confidence: conf, sourceCount: src,
            snr: snr, deltaType: delta, uncertain: uncertain)
    }
}

// MARK: - DistillationPipeline

/// The five-stage cold-path distillation pipeline.
///
/// Pure function — no I/O, no state. Feature extraction is injected via
/// `FeatureExtractor` so callers (NeuronKit) supply the EideticLib HMM tagger
/// or a test stub.
///
/// Stage 1: Build feature incidence matrix from extractFeatures.
/// Stage 2: Apply typed decay weighting (if timestamps), compute SNR gate,
///          apply majority threshold.
/// Stage 2.5: DeltaFeatureExtractor pass on failing features; rescue
///             CONVERGENT/MONOTONE sequences.
/// Stage 3: Build PMI coherence graph, select dominant component (F*).
/// Stage 4: Compute structural scores on F*.
/// Stage 5: Compute confidence, format drawerContent, compute featureFingerprint.
public enum DistillationPipeline {

    /// Feature extractor signature. Called once per (memory, featureType) pair.
    /// Returns extracted features; docFrequency field is ignored (set by pipeline).
    public typealias FeatureExtractor =
        @Sendable (String, DistillationFeatureType) -> [ExtractedFeature]

    /// Fixed seed for feature-to-Fingerprint256 hashing.
    ///
    /// "DISTILLA" encoded as ASCII bytes in big-endian UInt64:
    ///   D=0x44 I=0x49 S=0x53 T=0x54 I=0x49 L=0x4C L=0x4C A=0x41
    ///   → 0x44495354494C4C41
    ///
    /// Changing this constant invalidates all stored distillation fingerprints —
    /// requires a full re-distillation sweep of all clusters.
    /// Must be identical in the Rust port (conformance gate).
    public static let featureSimHashSeed: UInt64 = 0x44495354494C4C41

    /// Hash a single feature value string to a Fingerprint256 using the fixed seed.
    ///
    /// Algorithm: mix each UTF-8 byte into the seed state using SplitMix64 avalanche
    /// steps, then expand the resulting 64-bit state to four blocks via SplitMix64.
    /// Deterministic and bit-identical in the Rust port.
    ///
    /// featureHash("") does not crash; returns a deterministic non-zero fingerprint.
    public static func featureHash(_ value: String) -> Fingerprint256 {
        // Mix each UTF-8 byte into the running state
        var state: UInt64 = featureSimHashSeed
        for byte in value.utf8 {
            // XOR-fold the byte, then apply one SplitMix64 avalanche round
            state ^= UInt64(byte)
            state = state &+ 0x9E3779B97F4A7C15
            state = (state ^ (state >> 30)) &* 0xBF58476D1CE4E5B9
            state = (state ^ (state >> 27)) &* 0x94D049BB133111EB
            state = state ^ (state >> 31)
        }
        // Expand 64-bit state to four 64-bit blocks
        var rng = SplitMix64(seed: state)
        return Fingerprint256(
            block0: rng.next(),
            block1: rng.next(),
            block2: rng.next(),
            block3: rng.next()
        )
    }

    /// Compute the query fingerprint for distilled recall.
    ///
    /// Extracts features from the query string for each feature type, hashes each
    /// feature value via featureHash, then OR-reduces into a single Fingerprint256.
    ///
    /// Called by DistilledRecall at query time — no embedding model inference.
    /// The result is a probe for Hamming NN over the distillation-features-v1 lane.
    public static func queryFingerprint(
        query: String,
        extractFeatures: FeatureExtractor
    ) -> Fingerprint256 {
        var result = Fingerprint256.zero
        for featureType in DistillationFeatureType.allCases {
            let features = extractFeatures(query, featureType)
            for feature in features {
                result = result.union(featureHash(feature.value))
            }
        }
        return result
    }

    /// Capitalization-heuristic feature extractor for testing.
    ///
    /// Extracts ENT features: words starting with an uppercase letter that are
    /// not the first word of the text (to avoid treating sentence-initial words
    /// as named entities). Returns empty for non-entity feature types.
    public static let defaultExtractor: FeatureExtractor = { text, featureType in
        guard featureType == .entity else { return [] }
        var results: [ExtractedFeature] = []
        let words = text.split(separator: " ")
        for (i, word) in words.enumerated() {
            guard i > 0,
                  let firstChar = word.first, firstChar.isUppercase,
                  word.count > 1 else { continue }
            let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
            guard !trimmed.isEmpty else { continue }
            results.append(ExtractedFeature(type: .entity, value: trimmed, docFrequency: 0))
        }
        return results
    }

    // MARK: - run()

    /// Execute the five-stage distillation pipeline on a memory cluster.
    ///
    /// - Parameters:
    ///   - input: the reduction units (one item's sentences for intra-item
    ///     distillation), optional timestamps, source id, source IDs.
    ///   - extractFeatures: feature extraction function (injected by caller).
    ///   - intraItem: distill a SINGLE item from its own units (sentences) rather
    ///     than a cross-memory cluster. This turns off the pipeline's cross-memory
    ///     consensus machinery, which otherwise discards a single item's signal:
    ///       • SNR hold — a single item never grows, so the "wait for the cluster
    ///         to accumulate more members" hold does not apply; the item is reduced
    ///         now from whatever recurring structure it carries (confidence
    ///         annotates quality / injection depth rather than blocking).
    ///       • PMI dominant-component pruning — a single document is ONE coherent
    ///         thing, so EVERY recurring feature is its content. "Pick the single
    ///         shared theme across memories" splits the item and drops real content
    ///         (the Falcon doc lost database/tables/shadow to a non-dominant
    ///         component). Intra-item keeps all structural features.
    ///     Default false preserves the cross-memory cluster behaviour.
    /// - Returns: DistillationOutput with drawerContent, confidence, featureFingerprint.
    public static func run(
        input: DistillationInput,
        extractFeatures: FeatureExtractor,
        intraItem: Bool = false
    ) -> DistillationOutput {
        // Five pipeline stages share the incidence matrix, vocabulary, and feature array.
        // Extracting sub-functions would require threading these large structures through
        // parameter lists — the monolithic body keeps all state in one stack frame.
        let M = input.M
        guard M >= 1 else {
            return .failure(snr: 0, reason: "Empty cluster")
        }

        // ── Stage 1: Feature extraction and incidence matrix ──────────────────

        // Collect extracted features per memory
        let perMemoryFeatures: [[ExtractedFeature]] = input.memoryContents.map { memory in
            var features: [ExtractedFeature] = []
            for featureType in DistillationFeatureType.allCases {
                features += extractFeatures(memory, featureType)
            }
            return features
        }

        // Build vocabulary (unique feature values in encounter order). The key is
        // the stemmed `value`; the first surface form seen for each stem is kept
        // as the display form for the factoid prose.
        var vocabOrder: [String] = []
        var vocabIndex: [String: Int] = [:]
        // Also track the feature type and display surface for each vocab entry.
        var vocabTypes: [DistillationFeatureType] = []
        var vocabDisplay: [String] = []

        for features in perMemoryFeatures {
            for feature in features {
                if vocabIndex[feature.value] == nil {
                    vocabIndex[feature.value] = vocabOrder.count
                    vocabOrder.append(feature.value)
                    vocabTypes.append(feature.type)
                    vocabDisplay.append(feature.display)
                }
            }
        }

        let V = vocabOrder.count
        guard V > 0 else {
            return .failure(snr: 0, reason: "No features extracted from memories")
        }

        // Build incidence matrix: X[i][j] = true iff feature j appears in memory i
        let incidence: [[Bool]] = (0..<M).map { i in
            let present = Set(perMemoryFeatures[i].map { $0.value })
            return vocabOrder.map { present.contains($0) }
        }

        // ── Stage 2: Frequency scoring, SNR gate, majority threshold ──────────

        // Compute doc frequencies for each feature. Carry the display surface
        // form so the factoid prose renders readable words, not stems.
        var allFeatures: [ExtractedFeature] = vocabOrder.enumerated().map { j, value in
            ExtractedFeature(type: vocabTypes[j], value: value, docFrequency: 0,
                             display: vocabDisplay[j])
        }

        let timestamps = input.memoryTimestamps
        if let ts = timestamps, ts.count == M, let refDate = ts.max() {
            // Weighted: type-specific decay
            for j in 0..<V {
                let presenceTimestamps = (0..<M).compactMap { i -> Date? in
                    incidence[i][j] ? ts[i] : nil
                }
                let df = Float32(presenceTimestamps.count) / Float32(M)
                let wdf = TypedDecayWeighting.weightedDocFrequency(
                    featureType: allFeatures[j].type,
                    presenceTimestamps: presenceTimestamps,
                    allMemoryTimestamps: ts,
                    referenceDate: refDate
                )
                allFeatures[j].docFrequency = df
                allFeatures[j].weightedDocFrequency = wdf
            }
        } else {
            // Uniform: plain doc frequency
            for j in 0..<V {
                let count = Float32((0..<M).filter { i in incidence[i][j] }.count)
                let df = count / Float32(M)
                allFeatures[j].docFrequency = df
                allFeatures[j].weightedDocFrequency = df
            }
        }

        // SNR gate: check cluster quality before running full distillation
        let snrResult = DistillationScorer.computeSNR(features: allFeatures, M: M)
        if !intraItem && !snrResult.readyToDistill {
            return .failure(
                snr: snrResult.snr,
                reason: "SNR \(snrResult.snr) < 2.0: cluster is episodically dense, not ready")
        }

        // Apply the structural (recurrence) threshold: keep features that recur
        // across ≥2 of the item's units; the one-off tail is episodic.
        var (passing, failing) = DistillationScorer.applyStructuralThreshold(
            features: allFeatures, M: M)

        // ── Stage 2.5: Delta pre-pass ─────────────────────────────────────────
        //
        // For failing features, group by predicate key (part before ":" in value).
        // Analyze each key's value sequence across memories for convergence.
        // Promote CONVERGENT or MONOTONE terminal values to the passing set.

        var deltaTypeForFactoid: DeltaType? = nil

        if !failing.isEmpty {
            // Build a map: predicate key → list of (memory index, full feature value)
            var keyToOccurrences: [String: [(memIdx: Int, value: String)]] = [:]
            for (i, features) in perMemoryFeatures.enumerated() {
                for feature in features {
                    let key: String
                    if let colonIdx = feature.value.firstIndex(of: ":") {
                        key = String(feature.value[..<colonIdx])
                    } else {
                        key = feature.value
                    }
                    keyToOccurrences[key, default: []].append((memIdx: i, value: feature.value))
                }
            }

            let failingValues = Set(failing.map { $0.value })

            for (_, occurrences) in keyToOccurrences {
                // Skip keys with no failing features
                let hasFailingFeature = occurrences.contains { failingValues.contains($0.value) }
                guard hasFailingFeature else { continue }

                // Sort by memory index (chronological)
                let sorted = occurrences.sorted { $0.memIdx < $1.memIdx }

                // Build categorical sequence
                let catSeq: [(value: String, timestamp: Date)]
                if let ts = timestamps, ts.count == M {
                    catSeq = sorted.map { (value: $0.value, timestamp: ts[$0.memIdx]) }
                } else {
                    // No timestamps: use memory index as proxy (seconds from epoch)
                    catSeq = sorted.enumerated().map { (idx, item) in
                        (value: item.value, timestamp: Date(timeIntervalSince1970: Double(idx)))
                    }
                }

                let analysis = DeltaFeatureExtractor.analyzeCategorical(sequence: catSeq)

                if analysis.deltaType == .convergent || analysis.deltaType == .monotone {
                    // Promote the terminal value's feature if it's in the failing set
                    let terminal = analysis.terminalValue
                    if failingValues.contains(terminal),
                       let idx = failing.firstIndex(where: { $0.value == terminal }) {
                        var promoted = failing[idx]
                        promoted.weightedDocFrequency = analysis.confidence
                        promoted.docFrequency = passing.isEmpty ? 0.5 : promoted.docFrequency
                        passing.append(promoted)
                        if deltaTypeForFactoid == nil {
                            deltaTypeForFactoid = analysis.deltaType
                        }
                    }
                }
            }
        }

        guard !passing.isEmpty else {
            return .failure(snr: snrResult.snr, reason: "No features survived threshold or delta pre-pass")
        }

        // ── Stage 3: PMI coherence graph and dominant component ───────────────

        // Build incidence matrix restricted to passing features
        let passingValues = Set(passing.map { $0.value })
        let passingIndices = vocabOrder.enumerated().compactMap { j, value in
            passingValues.contains(value) ? j : nil
        }

        let restrictedIncidence: [[Bool]] = (0..<M).map { i in
            passingIndices.map { j in incidence[i][j] }
        }

        let graph = DistillationScorer.buildPMIGraph(
            thresholdFeatures: passing,
            incidenceMatrix: restrictedIncidence,
            M: M
        )
        var selected: [ExtractedFeature]
        if intraItem {
            // Intra-item: the item is ONE coherent thing — every recurring,
            // non-stopword feature is its content. Keep them all (the PMI graph
            // is the cross-memory "single shared theme" pruner and would split
            // the document and drop real content).
            selected = passing
        } else {
            selected = DistillationScorer.selectDominantComponent(graph: graph)
            // Ubiquity inclusion: a feature present in (near) ALL members is the
            // spine — yet PMI isolates it. A feature in every member has
            // p(f∧x) = p(x), so PMI(f,x) = log₂(1) = 0 with EVERY other feature,
            // giving it no positive edges, so selectDominantComponent drops it,
            // silently discarding the most central feature. Re-add any passing
            // feature in ≥ M-1 of the M members not already selected: core by
            // ubiquity, not frequent-but-independent noise.
            let ubiquityThreshold = Float32(M - 1) / Float32(M)
            let selectedValues = Set(selected.map { $0.value })
            for f in passing where f.docFrequency >= ubiquityThreshold
                && !selectedValues.contains(f.value) {
                selected.append(f)
            }
        }

        guard !selected.isEmpty else {
            return .failure(snr: snrResult.snr, reason: "PMI graph produced no dominant component")
        }

        // ── Stage 4: Structural scores ────────────────────────────────────────
        DistillationScorer.computeStructuralScores(features: &selected)

        // ── Stage 5: Confidence, content, fingerprint ─────────────────────────

        let confidence = DistillationScorer.computeConfidence(
            selected: selected, allThreshold: passing)
        let uncertain = confidence >= 0.4 && confidence < 0.7

        // Format drawerContent: "[DIST|conf=X.XX|src=N|snr=Y.YY|delta=Z] prose"
        let confStr = String(format: "%.2f", confidence)
        let snrStr  = String(format: "%.1f", snrResult.snr)
        let deltaStr = deltaTypeForFactoid?.rawValue ?? DeltaType.static.rawValue
        let uncertainFlag = uncertain ? "|uncertain" : ""

        // Prose: top features by structural score, rendered as readable surface
        // forms (display), not stems.
        let prose = selected
            .sorted { $0.structuralScore > $1.structuralScore }
            .map { $0.display }
            .joined(separator: " ")

        let drawerContent = "[DIST|conf=\(confStr)|src=\(M)|snr=\(snrStr)|delta=\(deltaStr)\(uncertainFlag)] \(prose)"

        // Feature fingerprint: OR-reduce of featureHash for each selected feature
        let fingerprint = selected.reduce(Fingerprint256.zero) { acc, feature in
            acc.union(featureHash(feature.value))
        }

        return DistillationOutput(
            drawerContent: drawerContent,
            confidence: confidence,
            uncertain: uncertain,
            snr: snrResult.snr,
            deltaType: deltaTypeForFactoid,
            succeeded: confidence >= 0.4,
            failureReason: confidence < 0.4 ? "Confidence \(confidence) below 0.4 threshold" : nil,
            featureFingerprint: fingerprint
        )
    }
}

// MARK: - DistillationOutput convenience

private extension DistillationOutput {
    /// Construct a failure output with zero fingerprint.
    static func failure(snr: Float32, reason: String) -> DistillationOutput {
        DistillationOutput(
            drawerContent: "",
            confidence: 0,
            uncertain: false,
            snr: snr,
            deltaType: nil,
            succeeded: false,
            failureReason: reason,
            featureFingerprint: .zero
        )
    }
}
