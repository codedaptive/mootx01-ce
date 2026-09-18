import Foundation

public enum FactGroundingRejection: Sendable, Equatable {
    case responseIdentityMismatch
    case sourceDigestMismatch
    case tooManyCandidates
    case emptyField
    case fieldTooLong
    case invalidConfidence
    case evidenceNotFound
    case evidenceOutsideSelectedSpans
    case ambiguousEvidence
    case unsupportedValues
    case duplicate
}

public struct FactGroundingReport: Sendable, Equatable {
    public let accepted: [GroundedFactCandidate]
    public let rejected: [FactGroundingRejection]

    public init(accepted: [GroundedFactCandidate], rejected: [FactGroundingRejection]) {
        self.accepted = accepted
        self.rejected = rejected
    }
}

/// Deterministic post-model gate. No candidate becomes a durable assertion
/// until its verbatim quote resolves uniquely inside an eligible original-source span.
public enum FactGroundingValidator {
    public static let maximumFieldCharacters = 240
    public static let maximumEvidenceCharacters = 600
    public static let maximumAliasCount = 12

    public static func validate(
        response: FactExtractionResponse,
        request: FactExtractionRequest,
        originalSource: String,
        expectedSpec: FactExtractorModelSpec
    ) -> FactGroundingReport {
        guard response.providerID == expectedSpec.providerID,
              response.modelID == expectedSpec.modelID,
              response.modelVersion == expectedSpec.modelVersion,
              response.schemaVersion == expectedSpec.schemaVersion else {
            return FactGroundingReport(accepted: [], rejected: [.responseIdentityMismatch])
        }
        guard response.sourceDigest == request.sourceDigest else {
            return FactGroundingReport(accepted: [], rejected: [.sourceDigestMismatch])
        }
        guard response.candidates.count <= min(request.maximumFacts, expectedSpec.maximumFactsPerSource) else {
            return FactGroundingReport(accepted: [], rejected: [.tooManyCandidates])
        }

        // Unicode scalars are the shared Swift/Rust offset unit. UTF-8 byte
        // positions are carried separately on `FactSourceSpan`.
        let sourceScalars = Array(originalSource.unicodeScalars)
        var accepted: [GroundedFactCandidate] = []
        var rejected: [FactGroundingRejection] = []
        var seen = Set<String>()

        for candidate in response.candidates {
            let subject = normalized(candidate.subject)
            let predicate = normalized(candidate.predicate)
            let object = normalized(candidate.object)
            let evidence = candidate.evidenceQuote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty, !predicate.isEmpty, !object.isEmpty, !evidence.isEmpty else {
                rejected.append(.emptyField)
                continue
            }
            guard subject.unicodeScalars.count <= maximumFieldCharacters,
                  predicate.unicodeScalars.count <= maximumFieldCharacters,
                  object.unicodeScalars.count <= maximumFieldCharacters,
                  evidence.unicodeScalars.count <= maximumEvidenceCharacters else {
                rejected.append(.fieldTooLong)
                continue
            }
            guard candidate.confidence.isFinite,
                  (0.0...1.0).contains(candidate.confidence) else {
                rejected.append(.invalidConfidence)
                continue
            }

            let occurrences = scalarOccurrences(of: Array(evidence.unicodeScalars), in: sourceScalars)
            guard !occurrences.isEmpty else {
                rejected.append(.evidenceNotFound)
                continue
            }
            let eligible = occurrences.filter { occurrence in
                request.eligibleSourceSpans.contains { selected in
                    selected.start <= occurrence.start && occurrence.end <= selected.end
                }
            }
            guard !eligible.isEmpty else {
                rejected.append(.evidenceOutsideSelectedSpans)
                continue
            }
            guard eligible.count == 1, let occurrence = eligible.first else {
                rejected.append(.ambiguousEvidence)
                continue
            }
            let evidenceTokens = groundingTokens(evidence)
            guard groundingTokens(subject).isSubset(of: evidenceTokens),
                  groundingTokens(object).isSubset(of: evidenceTokens) else {
                rejected.append(.unsupportedValues)
                continue
            }

            let identity = [subject, predicate, object]
                .map { $0.lowercased() }
                .joined(separator: "\u{0}")
            guard seen.insert(identity).inserted else {
                rejected.append(.duplicate)
                continue
            }

            let aliases = normalizedAliases(candidate.searchAliases)
            let prefix = String(String.UnicodeScalarView(sourceScalars[..<occurrence.start]))
            let throughEvidence = String(String.UnicodeScalarView(sourceScalars[..<occurrence.end]))
            let span = FactSourceSpan(
                start: occurrence.start,
                end: occurrence.end,
                startUTF8Byte: prefix.utf8.count,
                endUTF8Byte: throughEvidence.utf8.count)
            accepted.append(GroundedFactCandidate(
                subject: subject,
                predicate: predicate,
                object: object,
                evidenceQuote: evidence,
                evidenceSpan: span,
                confidence: candidate.confidence,
                assertionKind: candidate.assertionKind,
                searchAliases: aliases,
                searchProjection: FactSearchProjection.build(
                    subject: subject, predicate: predicate, object: object, aliases: aliases)))
        }
        return FactGroundingReport(accepted: accepted, rejected: rejected)
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func normalizedAliases(_ aliases: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for alias in aliases {
            let value = normalized(alias)
            guard !value.isEmpty, value.unicodeScalars.count <= maximumFieldCharacters else { continue }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
            if result.count == maximumAliasCount { break }
        }
        return result
    }

    private static func scalarOccurrences(
        of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar]
    ) -> [(start: Int, end: Int)] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var result: [(start: Int, end: Int)] = []
        for start in 0...(haystack.count - needle.count) {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) {
                result.append((start, start + needle.count))
            }
        }
        return result
    }

    private static func groundingTokens(_ value: String) -> Set<String> {
        Set(value.unicodeScalars.split(whereSeparator: {
            !CharacterSet.alphanumerics.contains($0)
        }).map { String(String.UnicodeScalarView($0)).lowercased() })
    }
}

/// Rebuildable retrieval text. It is never presented as an assertion and may
/// be regenerated when the projection version changes.
public enum FactSearchProjection {
    public static let version = "kgfact-search-v1"

    public static func build(
        subject: String, predicate: String, object: String, aliases: [String]
    ) -> String {
        var seen = Set<String>()
        return ([subject, predicate, object] + aliases).compactMap { part in
            let normalized = part.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !normalized.isEmpty else { return nil }
            let key = normalized.lowercased()
            return seen.insert(key).inserted ? normalized : nil
        }.joined(separator: " ")
    }
}
