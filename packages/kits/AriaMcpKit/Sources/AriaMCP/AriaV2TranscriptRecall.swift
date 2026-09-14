import AriaMCPWire
import CognitionKit
import Foundation
import GeniusLocusKit
import LocusKit

/// The intentionally small v2 contract for the strict transcript vertical.
/// Transcript eligibility and the fixed rerank composition belong to the
/// lower recipe; this boundary accepts only the source-backed public inputs.
public struct AriaV2TranscriptRecallRequest: Sendable, Equatable {
    public static let toolName = "moot_memory_recall_transcript"

    public let query: String
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(
            arguments, allowedKeys: ["query", "estate_id"])
        let rawQuery = try decoder.requireString("query")
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw AriaV2InvalidArgument(
                path: "query",
                message: "Argument 'query' must not be empty.").jsonRPCError
        }
        // Classification and strict rerank consume the caller's original
        // query bytes. Trimming is validation only; changing the query here
        // would make Swift diverge from the pinned cross-port recipe.
        query = rawQuery
        estateID = try decoder.optionalUUID("estate_id")
    }
}

/// Typed-only seam around the CognitionKit recipe. It deliberately exchanges
/// its output rather than a rendered tool response, so the v2 adapter cannot
/// accidentally accept a legacy generic-recall fallback.
public protocol AriaV2TranscriptRecallBackend: Sendable {
    func recall(
        _ request: AriaV2TranscriptRecallRequest,
        context: AriaV2MemoryOperationContext
    ) async throws -> TranscriptRecall.Output
}

/// Production bridge to the committed strict recipe. No activation happens at
/// this boundary: the recipe's strict lower stage only observes active encoder
/// state and reports an unavailable outcome when its requirements are absent.
public struct AriaV2GeniusLocusTranscriptRecallBackend: AriaV2TranscriptRecallBackend {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle

    public init(kit: GeniusLocusKit, handle: EstateHandle) {
        self.kit = kit
        self.handle = handle
    }

    public func recall(
        _ request: AriaV2TranscriptRecallRequest,
        context: AriaV2MemoryOperationContext
    ) async throws -> TranscriptRecall.Output {
        guard request.estateID == nil || request.estateID == context.estateID,
              context.estateID == handle.estateUUID else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "The requested estate is not available to this caller.")
        }
        let output = try await TranscriptRecall().run(
            input: .init(
                query: request.query,
                filter: .sensitivityAtMost(context.maximumSensitivity)),
            estate: handle,
            kit: kit)
        try await AriaV2Withheld.recall(kit: kit, handle: handle, frame: .init(
            filterChain: [.sensitivityAtMost(context.maximumSensitivity)],
            hydrationLevel: .full, limit: 50, ordering: .byCaptureTimeDesc))
        return output
    }
}

/// Projects the strict recipe's typed result into the v2 MCP envelope.
/// A non-applied outcome is operationally unavailable, never a successful
/// generic result with a different ordering or membership.
public struct AriaV2TranscriptRecallService: Sendable {
    public let backend: any AriaV2TranscriptRecallBackend
    public let context: AriaV2MemoryOperationContext

    public init(
        backend: any AriaV2TranscriptRecallBackend,
        context: AriaV2MemoryOperationContext
    ) {
        self.backend = backend
        self.context = context
    }

    public func recall(arguments: JSONValue) async throws -> JSONValue {
        try await recall(AriaV2TranscriptRecallRequest(arguments: arguments))
    }

    public func recall(_ request: AriaV2TranscriptRecallRequest) async throws -> JSONValue {
        let output: TranscriptRecall.Output
        do {
            output = try await backend.recall(request, context: context)
        } catch let error as JSONRPCError {
            throw error
        } catch {
            return unavailable()
        }

        guard output.outcome.status == .applied else {
            return unavailable(outcome: output.outcome)
        }

        var rows: [JSONValue] = []
        rows.reserveCapacity(output.matches.count)
        for match in output.matches {
            guard let memoryID = UUID(uuidString: match.id), match.score.isFinite else {
                return unavailable(outcome: output.outcome)
            }
            rows.append(Self.match(match, memoryID: memoryID))
        }

        let data: JSONValue = .object([
            "matches": .array(rows),
            "strict_rerank": Self.evidence(output.outcome),
        ])
        return AriaV2Envelope.success(
            tool: AriaV2TranscriptRecallRequest.toolName,
            effect: .read,
            data: data,
            meta: ["completeness": .string("incomplete")],
            compactText: "Strict transcript recall returned \(rows.count) matches.")
    }

    private func unavailable(
        outcome: StrictTranscriptRerankOutcome? = nil
    ) -> JSONValue {
        var recovery: [String: JSONValue] = [
            "required_operation": .string(AriaV2TranscriptRecallRequest.toolName),
        ]
        if let outcome {
            recovery["strict_rerank"] = Self.evidence(outcome)
        }
        return AriaV2Envelope.refusal(
            tool: AriaV2TranscriptRecallRequest.toolName,
            error: .init(
                code: "rerank_unavailable",
                message: "Strict transcript reranking is unavailable for this request.",
                retryable: true,
                recovery: .object(recovery)))
    }

    private static func match(_ match: PreciseMatch, memoryID: UUID) -> JSONValue {
        .object([
            "memory_id": .string(AriaV2ArgumentDecoder.canonicalUUID(memoryID)),
            "room": .string(match.room),
            "excerpt": .string(AriaV2Envelope.compactText(match.content)),
            "score": .double(match.score),
            "fetch": .object([
                "tool": .string("moot_memory_get"),
                "arguments": .object([
                    "memory_id": .string(AriaV2ArgumentDecoder.canonicalUUID(memoryID)),
                ]),
            ]),
        ])
    }

    private static func evidence(_ outcome: StrictTranscriptRerankOutcome) -> JSONValue {
        var evidence: [String: JSONValue] = [
            "status": .string(outcome.status.rawValue),
            "policy_version": .string(outcome.policyVersion),
            "fresh_head_candidates": .integer(Int64(outcome.freshHeadCandidates)),
            "scored_head_candidates": .integer(Int64(outcome.scoredHeadCandidates)),
            "freshness_verified": .bool(outcome.freshnessVerified),
        ]
        if let reason = outcome.reason { evidence["reason"] = .string(reason.rawValue) }
        if let modelID = outcome.encoderModelID { evidence["encoder_model_id"] = .string(modelID) }
        if let modelVersion = outcome.encoderModelVersion { evidence["encoder_model_version"] = .string(modelVersion) }
        if let queryDimension = outcome.queryDimension { evidence["query_dimension"] = .integer(Int64(queryDimension)) }
        if let profile = outcome.classifierProfileID { evidence["classifier_profile"] = .string(profile) }
        if let revision = outcome.classifierModelRevision { evidence["classifier_model_revision"] = .string(revision) }
        if let pool = outcome.validatedPoolLimit { evidence["pool"] = .integer(Int64(pool)) }
        if let head = outcome.validatedHeadLimit { evidence["head"] = .integer(Int64(head)) }
        if let spans = outcome.validatedSpansLimit { evidence["spans"] = .integer(Int64(spans)) }
        if let rrfK = outcome.validatedRRFK { evidence["rrf_k"] = .integer(Int64(rrfK)) }
        if let servingGeneration = outcome.servingGeneration {
            evidence["serving_generation"] = .integer(servingGeneration)
        }
        return .object(evidence)
    }
}
