import AriaMCPWire
import CognitionKit
import Foundation
import GeniusLocusKit
import LocusKit

/// The small v2 contract for the paraphrase door: nearest drawers by
/// whole-record LSA vector for a free-text question. Lane selection and
/// nearest-first ordering belong to the lower recipe; this boundary accepts
/// only the public inputs.
public struct AriaV2SimilarRecallRequest: Sendable, Equatable {
    public static let toolName = "moot_recall_similar"

    /// Smallest and largest accepted `limit`; the default applies when the
    /// caller omits it. Mirrored in the catalog schema and the Rust twin.
    public static let minimumLimit: Int64 = 1
    public static let maximumLimit: Int64 = 50
    public static let defaultLimit: Int64 = 10

    public let query: String
    public let limit: Int
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(
            arguments, allowedKeys: ["query", "limit", "estate_id"])
        let rawQuery = try decoder.requireString("query")
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw AriaV2InvalidArgument(
                path: "query",
                message: "Argument 'query' must not be empty.").jsonRPCError
        }
        // The lane embeds the caller's original query bytes. Trimming is
        // validation only, matching the Rust twin.
        query = rawQuery
        let requestedLimit = try decoder.optionalInteger("limit") ?? Self.defaultLimit
        guard (Self.minimumLimit...Self.maximumLimit).contains(requestedLimit) else {
            throw AriaV2InvalidArgument(
                path: "limit",
                message: "Argument 'limit' must be between \(Self.minimumLimit) and \(Self.maximumLimit).").jsonRPCError
        }
        limit = Int(requestedLimit)
        estateID = try decoder.optionalUUID("estate_id")
    }
}

/// Typed-only seam around the CognitionKit recipe. It exchanges the recipe's
/// output rather than a rendered tool response, so the v2 boundary cannot
/// accept a generic-recall fallback in place of the similarity lane.
public protocol AriaV2SimilarRecallBackend: Sendable {
    func recall(
        _ request: AriaV2SimilarRecallRequest,
        context: AriaV2MemoryOperationContext
    ) async throws -> SimilarRecall.Output
}

/// Production binding to the similar-recall recipe. The recipe probes the
/// estate's registered corpus lane; an estate without one returns no matches.
public struct AriaV2GeniusLocusSimilarRecallBackend: AriaV2SimilarRecallBackend {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle

    public init(kit: GeniusLocusKit, handle: EstateHandle) {
        self.kit = kit
        self.handle = handle
    }

    public func recall(
        _ request: AriaV2SimilarRecallRequest,
        context: AriaV2MemoryOperationContext
    ) async throws -> SimilarRecall.Output {
        guard request.estateID == nil || request.estateID == context.estateID,
              context.estateID == handle.estateUUID else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "The requested estate is not available to this caller.")
        }
        let output = try await SimilarRecall().run(
            input: .init(
                query: request.query,
                limit: request.limit,
                filter: .sensitivityAtMost(context.maximumSensitivity)),
            estate: handle,
            kit: kit)
        try await AriaV2Withheld.recall(kit: kit, handle: handle, frame: .init(
            filterChain: [.sensitivityAtMost(context.maximumSensitivity)],
            hydrationLevel: .full, limit: 50, ordering: .byCaptureTimeDesc))
        return output
    }
}

/// Projects the similar-recall recipe's typed result into the v2 MCP
/// envelope. A recipe failure is operationally unavailable, never a generic
/// result with a different ordering or membership.
public struct AriaV2SimilarRecallService: Sendable {
    public let backend: any AriaV2SimilarRecallBackend
    public let context: AriaV2MemoryOperationContext

    public init(
        backend: any AriaV2SimilarRecallBackend,
        context: AriaV2MemoryOperationContext
    ) {
        self.backend = backend
        self.context = context
    }

    public func recall(arguments: JSONValue) async throws -> JSONValue {
        try await recall(AriaV2SimilarRecallRequest(arguments: arguments))
    }

    public func recall(_ request: AriaV2SimilarRecallRequest) async throws -> JSONValue {
        let output: SimilarRecall.Output
        do {
            output = try await backend.recall(request, context: context)
        } catch let error as JSONRPCError {
            throw error
        } catch {
            return unavailable()
        }

        var rows: [JSONValue] = []
        rows.reserveCapacity(output.matches.count)
        for match in output.matches {
            guard let memoryID = UUID(uuidString: match.id), match.score.isFinite else {
                return unavailable()
            }
            rows.append(Self.match(match, memoryID: memoryID))
        }

        return AriaV2Envelope.success(
            tool: AriaV2SimilarRecallRequest.toolName,
            effect: .read,
            data: .object(["matches": .array(rows)]),
            meta: ["completeness": .string("incomplete")],
            compactText: "Similar recall returned \(rows.count) matches.")
    }

    private func unavailable() -> JSONValue {
        AriaV2Envelope.refusal(
            tool: AriaV2SimilarRecallRequest.toolName,
            error: .init(
                code: "lane_unavailable",
                message: "The whole-record similarity lane is unavailable for this request.",
                retryable: true,
                recovery: .object([
                    "required_operation": .string(AriaV2SimilarRecallRequest.toolName),
                ])))
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
}
