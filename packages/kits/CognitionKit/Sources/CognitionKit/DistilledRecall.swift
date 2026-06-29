// DistilledRecall.swift
//
// Dense-tier recall recipe: searches the distilled memory tier using
// structural fingerprint Hamming NN, returns factoid prose + metadata.
// Token budget ~10 per result. No embedding model inference.
//
// run() sequence per DISTILLATION_ARIA_TOOLS.md §2.2:
//   1. DistillationPipeline.queryFingerprint → Fingerprint256
//   2. kit.findNearestDistilled → [VectorMatch]
//   3. kit.hydrate → bodyMap [id: content]
//   4. DistilledHeader.parse per match → DistilledMatch array
//   5. classifyDistilledDiscrimination(scores) → DistilledDiscriminationLevel
//
// DiscriminationLevel is defined locally (DistilledDiscriminationLevel) because
// the canonical RecallDiscrimination + DiscriminationLevel live in AriaMcpKit,
// which is downstream of CognitionKit (topology inversion prevents import).
// Migration to NeuronKit is a tracked follow-up.
//
// Layer discipline B-1/B-2: one GLK findNearestDistilled + one hydrate call.
// Read-only (B-6, I-6). Deterministic: no Date() calls; queryFingerprint is
// a pure function of (query, extractor).

import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import SubstrateML

// MARK: - Output types

/// How well the top distilled result separates from the rest of the ranked list.
///
/// Mirrors AriaMcpKit.DiscriminationLevel case-for-case. Defined locally because
/// AriaMcpKit is downstream of CognitionKit and cannot be imported here.
/// Thresholds: HIGH_MARGIN = 0.25, LOW_MARGIN = 0.05, LOW_SPREAD = 0.15.
public enum DistilledDiscriminationLevel: Sendable, Equatable {
    /// Fewer than two results — nothing to compare.
    case single
    /// Top result is clearly separated from the second (topGap >= 0.25).
    case high
    /// Partial separation — some evidence of a best hit.
    case medium
    /// Top results within epsilon — effectively unranked.
    case low
}

/// One match from the distilled memory tier.
public struct DistilledMatch: Sendable, Equatable, Codable {
    /// Drawer UUID from the estate.
    public let id: String
    /// Factoid prose — DIST header stripped.
    public let prose: String
    /// Confidence score conf(F*) ∈ [0, 1].
    public let confidence: Float32
    /// Number of source memories M that produced this factoid.
    public let sourceCount: Int
    /// Cluster SNR at distillation time.
    public let snr: Float32
    /// DeltaType string ("CONVERGENT" | "MONOTONE" | "STATIC") or nil for absent/non-delta.
    public let deltaType: String?
    /// True when confidence ∈ [0.4, 0.7) — signals mid-confidence factoid.
    public let uncertain: Bool
    /// How much provenance context to inject alongside the factoid prose.
    /// conf >= 0.7 → .factoidOnly; [0.4, 0.7) → .factoidWithMeta; < 0.4 → .factoidWithProvenance.
    public let injectionDepth: InjectionDepth

    public init(
        id: String,
        prose: String,
        confidence: Float32,
        sourceCount: Int,
        snr: Float32,
        deltaType: String?,
        uncertain: Bool,
        injectionDepth: InjectionDepth
    ) {
        self.id = id
        self.prose = prose
        self.confidence = confidence
        self.sourceCount = sourceCount
        self.snr = snr
        self.deltaType = deltaType
        self.uncertain = uncertain
        self.injectionDepth = injectionDepth
    }
}

// MARK: - Codable for DistilledMatch

// InjectionDepth (NeuronKit) is Sendable + Equatable but NOT Codable. This
// extension provides a manual Codable bridge that encodes injectionDepth as
// its raw String name so DistilledMatch satisfies the spec's Codable requirement.
extension DistilledMatch {
    private enum CodingKeys: String, CodingKey {
        case id, prose, confidence, sourceCount, snr, deltaType, uncertain, injectionDepth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        prose = try c.decode(String.self, forKey: .prose)
        confidence = try c.decode(Float32.self, forKey: .confidence)
        sourceCount = try c.decode(Int.self, forKey: .sourceCount)
        snr = try c.decode(Float32.self, forKey: .snr)
        deltaType = try c.decodeIfPresent(String.self, forKey: .deltaType)
        uncertain = try c.decode(Bool.self, forKey: .uncertain)
        switch try c.decode(String.self, forKey: .injectionDepth) {
        case "factoidOnly": injectionDepth = .factoidOnly
        case "factoidWithMeta": injectionDepth = .factoidWithMeta
        default: injectionDepth = .factoidWithProvenance
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(prose, forKey: .prose)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(sourceCount, forKey: .sourceCount)
        try c.encode(snr, forKey: .snr)
        try c.encodeIfPresent(deltaType, forKey: .deltaType)
        try c.encode(uncertain, forKey: .uncertain)
        let depthString: String
        switch injectionDepth {
        case .factoidOnly: depthString = "factoidOnly"
        case .factoidWithMeta: depthString = "factoidWithMeta"
        case .factoidWithProvenance: depthString = "factoidWithProvenance"
        }
        try c.encode(depthString, forKey: .injectionDepth)
    }
}

// MARK: - Recipe

/// Dense-tier recall recipe. Searches the distillation-features-v1 VectorKit
/// lane via Hamming NN — no embedding model inference, no full corpus scan.
///
/// Hydrates matched drawers, parses DIST headers, and returns factoid prose
/// with a confidence-based discrimination signal.
///
/// RecipeCatalog registration is present.
public struct DistilledRecall: Recipe {

    // MARK: Input

    public struct Input: Sendable {
        /// Query text — feature-extracted and fingerprinted at query time.
        public let query: String
        /// ARIA adjective filter applied during frame-aware hydration. The
        /// distillation Hamming NN lane only produces candidate ids; normal
        /// recall liveness, trust, and sensitivity defaults are enforced before
        /// any factoid body is returned.
        public let filter: LocusKit.Filter
        /// Maximum factoids to return. Default 20.
        public let limit: Int
        /// Coarse candidate pool size. Included for future extensibility;
        /// current implementation passes limit directly to findNearestDistilled.
        public let pool: Int

        public init(
            query: String,
            filter: LocusKit.Filter = .unconfirmed,
            limit: Int = 20,
            pool: Int? = nil
        ) {
            self.query = query
            self.filter = filter
            self.limit = limit
            self.pool = pool ?? max(limit * 5, 50)
        }
    }

    // MARK: Output

    public struct Output: Sendable {
        public let matches: [DistilledMatch]
        public let discrimination: DistilledDiscriminationLevel

        public init(matches: [DistilledMatch], discrimination: DistilledDiscriminationLevel) {
            self.matches = matches
            self.discrimination = discrimination
        }
    }

    // MARK: Recipe identity

    public let name = "distilled_recall"
    public let version = "1.0.0"
    public let description =
        "Dense recall: search the distilled memory tier and return factoid " +
        "prose (~10 tokens/hit) for AI reasoning. Uses structural fingerprint " +
        "Hamming NN — no embedding model inference, no full corpus scan."

    // No NeuronKit reasoning calls — fingerprint hash and header parse only.
    public let requiredCapabilities: [NeuronKitCapability] = []

    public init() {}

    // MARK: run()

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        // 1. Feature-extract the query into a structural fingerprint.
        //    defaultExtractor is the capitalization-heuristic stub (test-safe).
        //    Production callers supply the EideticLib HMM tagger via the
        //    distillation lens when a richer extractor lands.
        let queryFP = DistillationPipeline.queryFingerprint(
            query: input.query,
            extractFeatures: DistillationPipeline.defaultExtractor)

        // 2. Hamming NN over the "distillation-features-v1" lane only.
        //    No full corpus scan; no embedding model call.
        let matches = try await kit.findNearestDistilled(
            estate, engram: queryFP, limit: input.limit)

        // Empty result is valid — return early with no crash.
        guard !matches.isEmpty else {
            return Output(matches: [], discrimination: .single)
        }

        // 3. Hydrate matched drawers in one frame-aware round-trip. This
        //    applies the same liveness/trust/sensitivity defaults as normal
        //    recall and excludes tombstoned rows before DIST content is parsed.
        let frame = RecallFrame(
            filterChain: [input.filter], hydrationLevel: .full, limit: input.limit)
        let bodies = try await kit.hydrate(
            estate, ids: matches.map(\.itemID), matchingFrame: frame, hydrationLevel: .full)
        let bodyMap = Dictionary(uniqueKeysWithValues: bodies.map { ($0.id, $0.content) })

        // 4. Parse DIST header per match, build DistilledMatch array.
        //    Drawers absent from bodyMap or lacking a DIST header are silently
        //    skipped — they are not valid distilled factoids.
        var distilledMatches: [DistilledMatch] = []
        for match in matches {
            guard let body = bodyMap[match.itemID],
                  let header = DistilledHeader.parse(body) else { continue }
            let depth: InjectionDepth = header.confidence >= 0.7 ? .factoidOnly
                : header.confidence >= 0.4 ? .factoidWithMeta : .factoidWithProvenance
            distilledMatches.append(DistilledMatch(
                id: match.itemID,
                prose: header.prose,
                confidence: header.confidence,
                sourceCount: header.sourceCount,
                snr: header.snr,
                deltaType: header.deltaType?.rawValue,
                uncertain: header.uncertain,
                injectionDepth: depth))
        }

        // 5. Discrimination over confidence scores.
        return Output(
            matches: distilledMatches,
            discrimination: classifyDistilledDiscrimination(
                distilledMatches.map { Double($0.confidence) }))
    }
}

// MARK: - Discrimination classifier

/// Classify how well confidence scores separate the top distilled match from the rest.
///
/// Thresholds mirror AriaMcpKit.RecallDiscrimination:
///   HIGH_MARGIN = 0.25 — topGap at which rank-1 is clearly the best match.
///   LOW_MARGIN  = 0.05 — topGap below which rank-1 is indistinguishable from rank-2.
///   LOW_SPREAD  = 0.15 — spread below which the entire list is effectively flat.
///   EPS         = 1e-9 — prevents division by zero on all-zero score vectors.
private func classifyDistilledDiscrimination(_ scores: [Double]) -> DistilledDiscriminationLevel {
    guard scores.count >= 2 else { return .single }
    let s0 = scores[0]
    let s1 = scores[1]
    let sLast = scores[scores.count - 1]
    let denom = max(abs(s0), 1e-9)
    let topGap = (s0 - s1) / denom
    let spread = (s0 - sLast) / denom
    if topGap >= 0.25 { return .high }
    if topGap < 0.05 && spread < 0.15 { return .low }
    return .medium
}
