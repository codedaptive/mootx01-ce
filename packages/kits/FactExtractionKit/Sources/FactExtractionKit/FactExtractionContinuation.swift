import Foundation

public extension FactExtractionError {
    var code: String {
        switch self {
        case .unavailable: "unavailable"
        case .invalidRequest: "invalidRequest"
        case .inferenceFailed: "inferenceFailed"
        case .malformedResponse: "malformedResponse"
        case .needsSubdivision: "needsSubdivision"
        case .timedOut: "timedOut"
        }
    }
    static func fromWire(code: String?, message: String) -> Self {
        switch code {
        case "unavailable": .unavailable(message)
        case "invalidRequest": .invalidRequest(message)
        case "malformedResponse": .malformedResponse(message)
        case "needsSubdivision": .needsSubdivision(message)
        case "timedOut": .timedOut(message)
        default: .inferenceFailed(message)
        }
    }
}

/// Shared wire vocabulary, not a claim that an unsuccessful extraction found no facts.
public enum FactExtractionOutcome: String, Codable, Sendable, CaseIterable {
    case pending, partial, completed, completedEmpty, notApplicable
    case needsSubdivision, rejected, retryScheduled, blockedProvider

    public var isTerminal: Bool {
        switch self {
        case .completed, .completedEmpty, .notApplicable, .rejected: true
        default: false
        }
    }
}

public extension FactSourceChunker {
    /// Materialize only the next bounded original-body slice. Cursor units are
    /// explicit on the wire; no array of the entire body or all chunks is built.
    static func next(
        originalSource: String, start: Int, startUTF8Byte: Int,
        maximumCharacters: Int
    ) -> FactSourceChunk? {
        guard maximumCharacters > 0, start >= 0, startUTF8Byte >= 0 else { return nil }
        let bytes = originalSource.utf8
        guard startUTF8Byte < bytes.count,
              let byteIndex = bytes.index(bytes.startIndex, offsetBy: startUTF8Byte,
                                          limitedBy: bytes.endIndex),
              let begin = byteIndex.samePosition(in: originalSource.unicodeScalars)
        else { return nil }
        let scalars = originalSource.unicodeScalars
        var end = begin
        var count = 0
        var boundary: (String.UnicodeScalarView.Index, Int)?
        while end < scalars.endIndex, count < maximumCharacters {
            let value = scalars[end]
            end = scalars.index(after: end)
            count += 1
            if count >= maximumCharacters / 2, value == "\n" {
                boundary = (end, count)
            }
        }
        if end < scalars.endIndex, let boundary { (end, count) = boundary }
        let text = String(scalars[begin..<end])
        return FactSourceChunk(text: text, span: FactSourceSpan(
            start: start, end: start + count, startUTF8Byte: startUTF8Byte,
            endUTF8Byte: startUTF8Byte + text.utf8.count))
    }
}

public extension FactGroundingValidator {
    /// Ground only within a source-exact chunk produced by FactSourceChunker.
    /// Preserve original-body offsets without allocating a scalar copy of the
    /// entire memory for every chunk. The caller owns the original snapshot.
    static func validateChunk(
        response: FactExtractionResponse, request: FactExtractionRequest,
        chunk: FactSourceChunk, expectedSpec: FactExtractorModelSpec
    ) -> FactGroundingReport {
        let scalarCount = chunk.text.unicodeScalars.count
        guard request.sourceText == chunk.text, request.eligibleSourceSpans.contains(chunk.span),
              chunk.span.end - chunk.span.start == scalarCount,
              chunk.span.endUTF8Byte - chunk.span.startUTF8Byte == chunk.text.utf8.count else {
            return FactGroundingReport(accepted: [], rejected: [.evidenceOutsideSelectedSpans])
        }
        let local = FactExtractionRequest(sourceID: request.sourceID, sourceDigest: request.sourceDigest,
            sourceText: chunk.text, eligibleSourceSpans: [FactSourceSpan(start: 0, end: scalarCount,
                startUTF8Byte: 0, endUTF8Byte: chunk.text.utf8.count)], maximumFacts: request.maximumFacts)
        let result = validate(response: response, request: local, originalSource: chunk.text, expectedSpec: expectedSpec)
        return FactGroundingReport(accepted: result.accepted.map { fact in
            GroundedFactCandidate(subject: fact.subject, predicate: fact.predicate, object: fact.object,
                evidenceQuote: fact.evidenceQuote, evidenceSpan: FactSourceSpan(
                    start: chunk.span.start + fact.evidenceSpan.start,
                    end: chunk.span.start + fact.evidenceSpan.end,
                    startUTF8Byte: chunk.span.startUTF8Byte + fact.evidenceSpan.startUTF8Byte,
                    endUTF8Byte: chunk.span.startUTF8Byte + fact.evidenceSpan.endUTF8Byte),
                confidence: fact.confidence, assertionKind: fact.assertionKind,
                searchAliases: fact.searchAliases, searchProjection: fact.searchProjection)
        }, rejected: result.rejected)
    }
}
