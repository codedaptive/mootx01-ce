import Foundation

/// The durable classification written into `KGFact.operationalBitmap`.
public enum FactExtractorKind: String, Sendable, Codable, CaseIterable {
    case foundationModel
    case specializedModel
}

/// How directly a candidate is asserted by its evidence.
public enum FactAssertionKind: String, Sendable, Codable, CaseIterable {
    case asserted
    case inferred
    case hypothesized
}

/// One registered extractor recipe. Provider and model identity are separate:
/// switching either creates a new row and new extraction debt.
public struct FactExtractorModelSpec: Sendable, Codable, Equatable, Hashable {
    public let providerID: String
    public let modelID: String
    public let modelVersion: String
    public let schemaVersion: String
    public let extractorKind: FactExtractorKind
    public let maximumInputCharacters: Int
    public let maximumFactsPerSource: Int

    public init(
        providerID: String,
        modelID: String,
        modelVersion: String,
        schemaVersion: String,
        extractorKind: FactExtractorKind,
        maximumInputCharacters: Int,
        maximumFactsPerSource: Int
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.schemaVersion = schemaVersion
        self.extractorKind = extractorKind
        self.maximumInputCharacters = maximumInputCharacters
        self.maximumFactsPerSource = maximumFactsPerSource
    }
}

/// A source range in the original drawer body. Both offset systems are carried
/// because Foundation strings and worker protocols do not share an implicit
/// indexing unit.
public struct FactSourceSpan: Sendable, Codable, Equatable, Hashable {
    public let start: Int
    public let end: Int
    public let startUTF8Byte: Int
    public let endUTF8Byte: Int

    public init(start: Int, end: Int, startUTF8Byte: Int, endUTF8Byte: Int) {
        self.start = start
        self.end = end
        self.startUTF8Byte = startUTF8Byte
        self.endUTF8Byte = endUTF8Byte
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case startUTF8Byte = "startUtf8Byte"
        case endUTF8Byte = "endUtf8Byte"
    }
}

/// Provider input. `sourceText` is an exact contiguous slice of the original
/// drawer body; the host validates model evidence against that same body.
public struct FactExtractionRequest: Sendable, Codable, Equatable {
    public let sourceID: String
    public let sourceDigest: String
    public let sourceText: String
    public let eligibleSourceSpans: [FactSourceSpan]
    public let maximumFacts: Int

    public init(
        sourceID: String,
        sourceDigest: String,
        sourceText: String,
        eligibleSourceSpans: [FactSourceSpan],
        maximumFacts: Int
    ) {
        self.sourceID = sourceID
        self.sourceDigest = sourceDigest
        self.sourceText = sourceText
        self.eligibleSourceSpans = eligibleSourceSpans
        self.maximumFacts = maximumFacts
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "sourceId"
        case sourceDigest
        case sourceText
        case eligibleSourceSpans
        case maximumFacts
    }
}

/// One source-exact model input and its offsets in the original drawer body.
public struct FactSourceChunk: Sendable, Equatable {
    public let text: String
    public let span: FactSourceSpan

    public init(text: String, span: FactSourceSpan) {
        self.text = text
        self.span = span
    }
}

/// Deterministic source-exact chunking for model context limits. Adjacent
/// chunks overlap by up to the grounding evidence limit so a supported quote
/// is not lost merely because it crosses a model-input boundary.
public enum FactSourceChunker {
    public static func chunks(
        originalSource: String,
        maximumCharacters: Int,
        overlapCharacters: Int = FactGroundingValidator.maximumEvidenceCharacters
    ) -> [FactSourceChunk] {
        guard maximumCharacters > 0, !originalSource.isEmpty else { return [] }
        let scalars = Array(originalSource.unicodeScalars)
        let overlap = min(max(overlapCharacters, 0), max(maximumCharacters - 1, 0))
        var byteOffsets = [Int](repeating: 0, count: scalars.count + 1)
        for index in scalars.indices {
            byteOffsets[index + 1] = byteOffsets[index] + String(scalars[index]).utf8.count
        }

        var result: [FactSourceChunk] = []
        var start = 0
        while start < scalars.count {
            let end = min(start + maximumCharacters, scalars.count)
            result.append(FactSourceChunk(
                text: String(String.UnicodeScalarView(scalars[start..<end])),
                span: FactSourceSpan(
                    start: start, end: end,
                    startUTF8Byte: byteOffsets[start], endUTF8Byte: byteOffsets[end])))
            guard end < scalars.count else { break }
            start = end - overlap
        }
        return result
    }
}

/// Untrusted structured output from a model. Evidence offsets are deliberately
/// absent: the host resolves the quote against the original source so a model
/// cannot claim a fabricated location.
public struct FactCandidate: Sendable, Codable, Equatable {
    public let subject: String
    public let predicate: String
    public let object: String
    public let evidenceQuote: String
    public let confidence: Double
    public let assertionKind: FactAssertionKind
    public let searchAliases: [String]

    public init(
        subject: String,
        predicate: String,
        object: String,
        evidenceQuote: String,
        confidence: Double,
        assertionKind: FactAssertionKind = .asserted,
        searchAliases: [String] = []
    ) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.evidenceQuote = evidenceQuote
        self.confidence = confidence
        self.assertionKind = assertionKind
        self.searchAliases = searchAliases
    }
}

/// Provider response stamped with the recipe that produced it.
public struct FactExtractionResponse: Sendable, Codable, Equatable {
    public let sourceDigest: String
    public let providerID: String
    public let modelID: String
    public let modelVersion: String
    public let schemaVersion: String
    public let candidates: [FactCandidate]

    public init(
        sourceDigest: String,
        providerID: String,
        modelID: String,
        modelVersion: String,
        schemaVersion: String,
        candidates: [FactCandidate]
    ) {
        self.sourceDigest = sourceDigest
        self.providerID = providerID
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.schemaVersion = schemaVersion
        self.candidates = candidates
    }

    private enum CodingKeys: String, CodingKey {
        case sourceDigest
        case providerID = "providerId"
        case modelID = "modelId"
        case modelVersion
        case schemaVersion
        case candidates
    }
}

/// A candidate that has been resolved to exact original-source offsets.
public struct GroundedFactCandidate: Sendable, Codable, Equatable {
    public let subject: String
    public let predicate: String
    public let object: String
    public let evidenceQuote: String
    public let evidenceSpan: FactSourceSpan
    public let confidence: Double
    public let assertionKind: FactAssertionKind
    public let searchAliases: [String]
    public let searchProjection: String

    public init(
        subject: String,
        predicate: String,
        object: String,
        evidenceQuote: String,
        evidenceSpan: FactSourceSpan,
        confidence: Double,
        assertionKind: FactAssertionKind,
        searchAliases: [String],
        searchProjection: String
    ) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.evidenceQuote = evidenceQuote
        self.evidenceSpan = evidenceSpan
        self.confidence = confidence
        self.assertionKind = assertionKind
        self.searchAliases = searchAliases
        self.searchProjection = searchProjection
    }
}

public enum FactExtractionError: Error, Sendable, Equatable {
    case unavailable(String)
    case invalidRequest(String)
    case inferenceFailed(String)
    case malformedResponse(String)
    /// Context overflow or output exhaustion: retry a smaller source-exact slice.
    case needsSubdivision(String)
    case timedOut(String)
}

/// Provider-neutral extraction seam. Implementations include Apple's
/// Foundation Models and native NuExtract adapters.
public protocol FactExtractor: Sendable {
    var spec: FactExtractorModelSpec { get }
    func extract(_ request: FactExtractionRequest) async throws -> FactExtractionResponse
}
