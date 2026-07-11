// FDCSemanticRanker.swift
//
// Deterministic integer inference for the sparse FDC semantic-ranker model.
// The build tool emits a feature-major CSR matrix. Runtime text features use
// byte-defined ASCII tokenization and FNV-1a hashing so Swift and Rust produce
// identical feature IDs, scores, and top-k order without floating-point math.

import Foundation
import SubstrateKernel

public struct FDCSemanticCandidate: Equatable, Sendable {
    public let code: String
    public let score: Int64
    public let matchedFeatures: Int

    public init(code: String, score: Int64, matchedFeatures: Int) {
        self.code = code
        self.score = score
        self.matchedFeatures = matchedFeatures
    }
}

/// A confidence-gated hierarchy decision derived from semantic candidates.
/// `code` is never deeper than one subdivision below `mainClass`; semantic
/// evidence may choose a safe region, but it does not certify a narrow leaf.
public struct FDCSemanticDecision: Equatable, Sendable {
    public let code: String
    public let mainClass: String
    public let score: Int64
    public let runnerUpScore: Int64
    public let matchedFeatures: Int

    public init(
        code: String,
        mainClass: String,
        score: Int64,
        runnerUpScore: Int64,
        matchedFeatures: Int
    ) {
        self.code = code
        self.mainClass = mainClass
        self.score = score
        self.runnerUpScore = runnerUpScore
        self.matchedFeatures = matchedFeatures
    }
}

public struct FDCSemanticRanker: Sendable {
    public struct Metadata: Decodable, Sendable {
        public let version: String
        public let featureSchema: String
        public let featureCount: Int
        public let codeCount: Int
        public let entryCount: Int
        public let codes: [String]
        public let norms: [Int]
        public let modelSHA256: String

        private enum CodingKeys: String, CodingKey {
            case version, codes, norms
            case featureSchema = "feature_schema"
            case featureCount = "feature_count"
            case codeCount = "code_count"
            case entryCount = "entry_count"
            case modelSHA256 = "model_sha256"
        }
    }

    private static let magic = Array("FDCSMR1\0".utf8)
    private static let featureSchema = "ascii-word-bigram-affix-fnv1a-v1"
    private static let fnvOffset: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211
    private static let maximumTokens = 256
    private static let maximumFeatures = 1_024
    private static let aggregateCandidateLimit = 5
    private static let minimumMatchedFeatures = 8
    private static let stopWords: Set<String> = [
        "a", "about", "an", "and", "are", "as", "at", "be", "been", "by",
        "for", "from", "has", "have", "in", "into", "is", "it", "its", "of",
        "on", "or", "that", "the", "their", "this", "to", "was", "were", "with",
    ]

    public let metadata: Metadata
    private let offsets: [UInt32]
    private let codeIndices: [UInt16]
    private let weights: [UInt8]

    public init?(metadataData: Data, modelData: Data) {
        guard let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData),
              metadata.featureSchema == Self.featureSchema,
              metadata.featureCount > 0,
              metadata.featureCount <= 1_048_576,
              metadata.featureCount.nonzeroBitCount == 1,
              metadata.codeCount == metadata.codes.count,
              metadata.codeCount == metadata.norms.count,
              metadata.codeCount <= Int(UInt16.max),
              metadata.entryCount > 0,
              metadata.entryCount <= Int(UInt32.max),
              metadata.norms.allSatisfy({ $0 > 0 }),
              Self.expectedModelSize(
                featureCount: metadata.featureCount,
                entryCount: metadata.entryCount) == modelData.count,
              Self.sha256Hex(modelData) == metadata.modelSHA256 else { return nil }

        var cursor = BinaryCursor(data: modelData)
        guard cursor.readBytes(count: Self.magic.count) == Self.magic,
              let featureCount = cursor.readUInt32(),
              let codeCount = cursor.readUInt32(),
              let entryCount = cursor.readUInt32(),
              Int(featureCount) == metadata.featureCount,
              Int(codeCount) == metadata.codeCount,
              Int(entryCount) == metadata.entryCount else { return nil }

        var offsets: [UInt32] = []
        offsets.reserveCapacity(metadata.featureCount + 1)
        for _ in 0...metadata.featureCount {
            guard let value = cursor.readUInt32() else { return nil }
            offsets.append(value)
        }
        guard offsets.first == 0,
              offsets.last == entryCount,
              zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }

        var codeIndices: [UInt16] = []
        codeIndices.reserveCapacity(metadata.entryCount)
        for _ in 0..<metadata.entryCount {
            guard let value = cursor.readUInt16(), Int(value) < metadata.codeCount else { return nil }
            codeIndices.append(value)
        }
        guard let weights = cursor.readBytes(count: metadata.entryCount),
              !weights.contains(0), cursor.isAtEnd else { return nil }

        self.metadata = metadata
        self.offsets = offsets
        self.codeIndices = codeIndices
        self.weights = weights
    }

    public func rank(_ text: String, limit: Int = 8) -> [FDCSemanticCandidate] {
        guard limit > 0 else { return [] }
        let features = Self.features(text, dimension: metadata.featureCount)
        guard !features.isEmpty else { return [] }

        var scores = [Int64](repeating: 0, count: metadata.codeCount)
        var matched = [Int](repeating: 0, count: metadata.codeCount)
        for feature in features {
            let start = Int(offsets[feature])
            let end = Int(offsets[feature + 1])
            guard start < end else { continue }
            for index in start..<end {
                let codeIndex = Int(codeIndices[index])
                scores[codeIndex] += Int64(weights[index])
                matched[codeIndex] += 1
            }
        }

        var candidates: [FDCSemanticCandidate] = []
        candidates.reserveCapacity(metadata.codeCount)
        for index in 0..<metadata.codeCount where scores[index] > 0 {
            let normalized = scores[index] * 1_000_000 / Int64(metadata.norms[index])
            candidates.append(FDCSemanticCandidate(
                code: metadata.codes[index],
                score: normalized,
                matchedFeatures: matched[index]))
        }
        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.matchedFeatures != $1.matchedFeatures {
                return $0.matchedFeatures > $1.matchedFeatures
            }
            return $0.code < $1.code
        }
        return Array(candidates.prefix(limit))
    }

    /// Convert noisy code-level rankings into conservative hierarchy evidence.
    /// Main classes are selected from the five strongest candidates per class.
    /// A single candidate may select its class only when it dominates the next
    /// candidate by 3:2. One further hierarchy level is allowed when multiple
    /// candidates agree on that subtree; final leaf precision remains the job
    /// of the source-owned v3 evidence policy.
    public func hierarchyDecision(_ text: String, frame: FDCFrame) -> FDCSemanticDecision? {
        let candidates = rank(text, limit: metadata.codeCount)
        return hierarchyDecision(candidates, frame: frame)
    }

    func hierarchyDecision(
        _ candidates: [FDCSemanticCandidate],
        frame: FDCFrame
    ) -> FDCSemanticDecision? {
        guard let top = candidates.first,
              top.matchedFeatures >= Self.minimumMatchedFeatures else { return nil }

        let topMain = mainClass(for: top.code, frame: frame)
        let secondScore = candidates.dropFirst().first?.score ?? 0
        let dominantTop = ratioAtLeast(
            top.score, secondScore, numerator: 3, denominator: 2)

        let mainBuckets = aggregate(candidates) { mainClass(for: $0.code, frame: frame) }
        guard let aggregateWinner = mainBuckets.first else { return nil }
        let aggregateRunnerScore = mainBuckets.dropFirst().first?.score ?? 0

        let selectedMain: String
        let selectedScore: Int64
        let selectedRunnerScore: Int64
        if dominantTop {
            selectedMain = topMain
            selectedScore = top.score
            selectedRunnerScore = secondScore
        } else {
            guard ratioAtLeast(
                aggregateWinner.score,
                aggregateRunnerScore,
                numerator: 6,
                denominator: 5) else { return nil }
            selectedMain = aggregateWinner.key
            selectedScore = aggregateWinner.score
            selectedRunnerScore = aggregateRunnerScore
        }

        let selectedCandidates = candidates.filter {
            mainClass(for: $0.code, frame: frame) == selectedMain
        }
        let selectedTop = selectedCandidates.first ?? top
        var selectedCode = selectedMain

        let childBuckets = aggregate(selectedCandidates) { candidate in
            child(onPathTo: candidate.code, below: selectedMain, frame: frame)
        }
        if let childWinner = childBuckets.first, childWinner.count >= 2 {
            let childRunnerScore = childBuckets.dropFirst().first?.score ?? 0
            let ordinaryDominance = ratioAtLeast(
                childWinner.score, childRunnerScore, numerator: 4, denominator: 3)
            let strongDominance = ratioAtLeast(
                childWinner.score, childRunnerScore, numerator: 8, denominator: 5)
            let leadingChildren = selectedCandidates.prefix(2).compactMap {
                child(onPathTo: $0.code, below: selectedMain, frame: frame)
            }
            let leadingConsensus = leadingChildren.count == 2
                && leadingChildren.allSatisfy { $0 == childWinner.key }
            if ordinaryDominance && (leadingConsensus || strongDominance) {
                selectedCode = childWinner.key
            }
        }

        return FDCSemanticDecision(
            code: selectedCode,
            mainClass: selectedMain,
            score: selectedScore,
            runnerUpScore: selectedRunnerScore,
            matchedFeatures: selectedTop.matchedFeatures)
    }

    private struct AggregateBucket {
        let key: String
        let score: Int64
        let count: Int
    }

    private func aggregate(
        _ candidates: [FDCSemanticCandidate],
        key: (FDCSemanticCandidate) -> String?
    ) -> [AggregateBucket] {
        var scores: [String: [Int64]] = [:]
        for candidate in candidates {
            guard let bucket = key(candidate) else { continue }
            scores[bucket, default: []].append(candidate.score)
        }
        return scores.map { bucket, values in
            let strongest = values.sorted(by: >).prefix(Self.aggregateCandidateLimit)
            return AggregateBucket(
                key: bucket,
                score: strongest.reduce(0, +),
                count: values.count)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.key < $1.key
        }
    }

    private func mainClass(for code: String, frame: FDCFrame) -> String {
        if Self.isMainClass(code) { return code }
        return frame.ancestors(of: code).reversed().first(where: Self.isMainClass) ?? "000"
    }

    private func child(onPathTo code: String, below node: String, frame: FDCFrame) -> String? {
        let path = frame.ancestors(of: code) + [code]
        guard let index = path.firstIndex(of: node), index + 1 < path.count else { return nil }
        return path[index + 1]
    }

    private static func isMainClass(_ code: String) -> Bool {
        let bytes = Array(code.utf8)
        return bytes.count == 3
            && bytes.allSatisfy { $0 >= 48 && $0 <= 57 }
            && bytes[1] == 48 && bytes[2] == 48
    }

    private func ratioAtLeast(
        _ winner: Int64,
        _ runner: Int64,
        numerator: Int64,
        denominator: Int64
    ) -> Bool {
        guard winner > 0 else { return false }
        return runner == 0 || winner * denominator >= runner * numerator
    }

    static func features(_ text: String, dimension: Int) -> [Int] {
        guard dimension > 0, dimension.nonzeroBitCount == 1 else { return [] }
        let tokens = asciiTokens(text).prefix(maximumTokens)
        var features: Set<Int> = []
        features.reserveCapacity(min(maximumFeatures, tokens.count * 8))
        var previous: [UInt8]?

        for tokenSlice in tokens {
            let token = Array(tokenSlice.utf8)
            if token == previous { continue }
            insert(prefix: "w:", value: token, dimension: dimension, into: &features)
            for length in 3...5 where token.count >= length {
                insert(prefix: "p\(length):", value: Array(token.prefix(length)),
                       dimension: dimension, into: &features)
                insert(prefix: "s\(length):", value: Array(token.suffix(length)),
                       dimension: dimension, into: &features)
            }
            if let previous {
                var bigram = previous
                bigram.append(UInt8(ascii: "|"))
                bigram.append(contentsOf: token)
                insert(prefix: "b:", value: bigram, dimension: dimension, into: &features)
            }
            previous = token
            if features.count >= maximumFeatures { break }
        }
        return features.sorted().prefix(maximumFeatures).map { $0 }
    }

    private static func asciiTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current: [UInt8] = []
        for byte in text.utf8 {
            let value: UInt8?
            switch byte {
            case 65...90: value = byte + 32
            case 97...122, 48...57: value = byte
            default: value = nil
            }
            if let value {
                current.append(value)
            } else if !current.isEmpty {
                appendToken(current, to: &tokens)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { appendToken(current, to: &tokens) }
        return tokens
    }

    private static func appendToken(_ bytes: [UInt8], to tokens: inout [String]) {
        guard let token = String(bytes: bytes, encoding: .ascii),
              !stopWords.contains(token) else { return }
        tokens.append(token)
    }

    private static func insert(
        prefix: String,
        value: [UInt8],
        dimension: Int,
        into features: inout Set<Int>
    ) {
        var bytes = Array(prefix.utf8)
        bytes.append(contentsOf: value)
        features.insert(Int(fnv1a(bytes) & UInt64(dimension - 1)))
    }

    private static func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var value = fnvOffset
        for byte in bytes {
            value ^= UInt64(byte)
            value = value &* fnvPrime
        }
        return value
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(Array(data)).map { String(format: "%02x", $0) }.joined()
    }

    private static func expectedModelSize(featureCount: Int, entryCount: Int) -> Int? {
        let (offsetCount, offsetOverflow) = featureCount.addingReportingOverflow(1)
        let (offsetBytes, offsetByteOverflow) = offsetCount.multipliedReportingOverflow(by: 4)
        let (postingBytes, postingOverflow) = entryCount.multipliedReportingOverflow(by: 3)
        let (headerAndOffsets, firstAddOverflow) = 20.addingReportingOverflow(offsetBytes)
        let (total, secondAddOverflow) = headerAndOffsets.addingReportingOverflow(postingBytes)
        guard !offsetOverflow, !offsetByteOverflow, !postingOverflow,
              !firstAddOverflow, !secondAddOverflow else { return nil }
        return total
    }
}

private struct BinaryCursor {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readBytes(count: Int) -> [UInt8]? {
        guard count >= 0, offset <= data.count - count else { return nil }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }

    mutating func readUInt16() -> UInt16? {
        guard let bytes = readBytes(count: 2) else { return nil }
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(count: 4) else { return nil }
        return UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
    }
}
