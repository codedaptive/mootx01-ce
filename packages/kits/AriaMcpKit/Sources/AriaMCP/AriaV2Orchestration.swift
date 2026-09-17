import AriaMCPWire
import Foundation

/// The four small selected-v2 orchestration operations.  This is deliberately
/// unregistered: the selected catalog and transport own admission and wiring.
/// Its lower seam carries typed values, never a v1 runner result or rendered
/// text that would need parsing.
public enum AriaV2OrchestrationOperation: String, Sendable, Equatable {
    case synthesize = "moot_synthesize"
    case runMigration = "moot_migration_run"
    case confirmMigration = "moot_migration_confirm"
    case federatedSearch = "moot_federated_recall"

    var effect: AriaV2OperationEffect {
        self == .confirmMigration ? .write : .read
    }
}

public struct AriaV2OrchestrationContext: Sendable {
    public let estateID: UUID
    public let serverIdentity: String
    public let sessionID: String
    public let now: @Sendable () -> Date

    public init(
        estateID: UUID,
        serverIdentity: String,
        sessionID: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.estateID = estateID
        self.serverIdentity = serverIdentity
        self.sessionID = sessionID
        self.now = now
    }
}

public struct AriaV2SynthesizeRequest: Sendable, Equatable {
    public let query: String?
    public let filter: String?
    public let limit: Int?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(
            arguments, allowedKeys: ["query", "filter", "limit", "estate_id"])
        query = try decoder.optionalString("query")
        filter = try decoder.optionalString("filter")
        if let value = try decoder.optionalInteger("limit") {
            guard value >= 1, value <= Int64(Int.max) else { throw Self.invalidLimit }
            limit = Int(value)
        } else {
            limit = nil
        }
        estateID = try decoder.optionalUUID("estate_id")
    }

    fileprivate static var invalidLimit: JSONRPCError {
        AriaV2InvalidArgument(
            path: "limit", message: "Argument 'limit' must be an integer of at least 1.",
            correction: "Provide a positive integer limit.").jsonRPCError
    }
}

public struct AriaV2MigrationEntry: Sendable, Equatable {
    public let id: String
    public let content: String
    public let tags: [String]

    init(value: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(value, allowedKeys: ["id", "content", "tags"])
        id = try decoder.requireString("id")
        content = try decoder.requireString("content")
        guard let rawTags = decoder.arguments["tags"] else { tags = []; return }
        guard let values = rawTags.arrayValue else {
            throw AriaV2InvalidArgument(path: "entries.tags", message: "Argument 'tags' must be an array of strings.").jsonRPCError
        }
        tags = try values.enumerated().map { index, value in
            guard let tag = value.stringValue else {
                throw AriaV2InvalidArgument(path: "entries.tags[\(index)]", message: "Each tag must be a string.").jsonRPCError
            }
            return tag
        }
    }
}

public struct AriaV2MigrationPlan: Sendable, Equatable {
    public let name: String
    public let room: String
    public let latticeCode: String
    public let embeddingModelID: String
    public let sensitivity: String?

    init(value: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(value, allowedKeys: [
            "name", "room", "latticeCode", "embeddingModelID", "sensitivity",
        ])
        name = try decoder.requireString("name")
        room = try decoder.requireString("room")
        latticeCode = try decoder.requireString("latticeCode")
        embeddingModelID = try decoder.requireString("embeddingModelID")
        sensitivity = try decoder.optionalString("sensitivity")
    }
}

public struct AriaV2RunMigrationRequest: Sendable, Equatable {
    public let corpusName: String
    public let entries: [AriaV2MigrationEntry]
    public let plans: [AriaV2MigrationPlan]
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(
            arguments, allowedKeys: ["corpusName", "entries", "plans", "estate_id"])
        corpusName = try decoder.requireString("corpusName")
        guard let rawEntries = decoder.arguments["entries"]?.arrayValue else {
            throw AriaV2InvalidArgument(path: "entries", message: "Argument 'entries' must be an array.").jsonRPCError
        }
        guard let rawPlans = decoder.arguments["plans"]?.arrayValue else {
            throw AriaV2InvalidArgument(path: "plans", message: "Argument 'plans' must be an array.").jsonRPCError
        }
        entries = try rawEntries.map(AriaV2MigrationEntry.init(value:))
        plans = try rawPlans.map(AriaV2MigrationPlan.init(value:))
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2ConfirmMigrationRequest: Sendable, Equatable {
    public let winnerBranchID: UUID
    public let discardBranchIDs: [UUID]
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(
            arguments, allowedKeys: ["winner_branch_id", "discard_branch_ids", "estate_id"])
        winnerBranchID = try decoder.requireUUID("winner_branch_id")
        if let raw = decoder.arguments["discard_branch_ids"] {
            guard let values = raw.arrayValue else {
                throw AriaV2InvalidArgument(path: "discard_branch_ids", message: "Argument 'discard_branch_ids' must be an array of UUIDs.").jsonRPCError
            }
            discardBranchIDs = try values.enumerated().map { index, value in
                guard let string = value.stringValue, let id = UUID(uuidString: string) else {
                    throw AriaV2InvalidArgument(path: "discard_branch_ids[\(index)]", message: "Each discard branch id must be a UUID.").jsonRPCError
                }
                return id
            }
        } else {
            discardBranchIDs = []
        }
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2FederatedSearchRequest: Sendable, Equatable {
    public let requesterEstateID: UUID?
    public let filter: String?
    public let limit: Int?
    public let ordering: String?
    public let hydrationLevel: String?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: [
            "requester_estate_id", "filter", "limit", "ordering", "hydration_level",
        ])
        requesterEstateID = try decoder.optionalUUID("requester_estate_id")
        filter = try decoder.optionalString("filter")
        ordering = try decoder.optionalString("ordering")
        hydrationLevel = try decoder.optionalString("hydration_level")
        if let value = try decoder.optionalInteger("limit") {
            guard value >= 1, value <= Int64(Int.max) else { throw AriaV2SynthesizeRequest.invalidLimit }
            limit = Int(value)
        } else {
            limit = nil
        }
    }
}

public struct AriaV2CompactMemory: Sendable, Equatable {
    public let memoryID: UUID
    public let subject: String?
    public let score: Double?
    public let provenance: String?
    public let context: String?
    public let excerpt: String?

    public init(
        memoryID: UUID, subject: String? = nil, score: Double? = nil,
        provenance: String? = nil, context: String? = nil, excerpt: String? = nil
    ) {
        self.memoryID = memoryID; self.subject = subject; self.score = score
        self.provenance = provenance; self.context = context; self.excerpt = excerpt
    }
}

public struct AriaV2SynthesisData: Sendable, Equatable {
    public let summary: String
    public let cues: [String]?
    public let results: [AriaV2CompactMemory]
}

public struct AriaV2BenchmarkReport: Sendable, Equatable {
    public let branchID: UUID
    public let queryCount: Int
    public let recallOverlap: Double
    public let recallPrecision: Double
    public let meanReciprocalRank: Double
    public let notFoundInBranch: [String]
    public let newInBranch: [String]
    public let evaluatedAt: String
}

public struct AriaV2MigrationRanking: Sendable, Equatable {
    public let branchID: UUID
    public let planName: String
    public let combinedScore: Double
    public let recallOverlap: Double
    public let meanReciprocalRank: Double
}

public struct AriaV2DisqualifiedMigration: Sendable, Equatable {
    public let branchID: UUID
    public let planName: String
    public let lostConcepts: [String]
}

public struct AriaV2MigrationData: Sendable, Equatable {
    public let reports: [AriaV2BenchmarkReport]
    public let winnerBranchID: UUID?
    public let winnerPlanName: String?
    public let rankings: [AriaV2MigrationRanking]
    public let disqualified: [AriaV2DisqualifiedMigration]
}

public enum AriaV2DiscardOutcomeStatus: String, Sendable, Equatable {
    case discarded, alreadyDiscarded = "already_discarded", winnerSkipped = "winner_skipped", unknown, failed
}

public struct AriaV2DiscardOutcome: Sendable, Equatable {
    public let branchID: UUID
    public let status: AriaV2DiscardOutcomeStatus
}

/// This is a lower-engine receipt.  The service retains only its verified
/// cleanup projection; it never substitutes requested branch ids for it.
public struct AriaV2MigrationConfirmationData: Sendable, Equatable {
    public let promotedBranchID: UUID
    public let discardedBranchIDs: [UUID]
    public let discardOutcomes: [AriaV2DiscardOutcome]
}

public struct AriaV2FederatedSearchData: Sendable, Equatable {
    public let sourceEstateID: UUID
    public let requesterEstateID: UUID
    public let grantID: UUID
    public let results: [AriaV2CompactMemory]
}

/// Typed direct-engine boundary. Production adapters bind these methods to
/// GroundedSynthesis, MigrationBenchmark, and GeniusLocusKit federated recall;
/// no method accepts or returns a legacy transport payload.
public protocol AriaV2OrchestrationProvider: Sendable {
    func synthesize(_ request: AriaV2SynthesizeRequest, context: AriaV2OrchestrationContext) async throws -> AriaV2SynthesisData
    func runMigration(_ request: AriaV2RunMigrationRequest, context: AriaV2OrchestrationContext) async throws -> AriaV2MigrationData
    func confirmMigration(_ request: AriaV2ConfirmMigrationRequest, context: AriaV2OrchestrationContext) async throws -> AriaV2MigrationConfirmationData
    func federatedSearch(_ request: AriaV2FederatedSearchRequest, context: AriaV2OrchestrationContext) async throws -> AriaV2FederatedSearchData
}

public struct AriaV2Orchestration: Sendable {
    private let provider: any AriaV2OrchestrationProvider
    private let context: AriaV2OrchestrationContext

    public init(provider: any AriaV2OrchestrationProvider, context: AriaV2OrchestrationContext) {
        self.provider = provider; self.context = context
    }

    public func synthesize(arguments: JSONValue) async throws -> JSONValue {
        try await synthesize(AriaV2SynthesizeRequest(arguments: arguments))
    }

    public func synthesize(_ request: AriaV2SynthesizeRequest) async throws -> JSONValue {
        try validate(request.estateID)
        return response(.synthesize, data: try await provider.synthesize(request, context: context).json)
    }

    /// Evaluation intentionally stops after producing candidates.  It never
    /// calls confirmation; promotion requires a separate explicit tool call.
    public func runMigration(arguments: JSONValue) async throws -> JSONValue {
        try await runMigration(try AriaV2RunMigrationRequest(arguments: arguments))
    }

    public func runMigration(_ request: AriaV2RunMigrationRequest) async throws -> JSONValue {
        try validate(request.estateID)
        let data: AriaV2MigrationData
        do {
            data = try await provider.runMigration(request, context: context)
        } catch let error as JSONRPCError {
            throw error
        } catch {
            return orchestrationUnavailable(.runMigration)
        }
        return response(.runMigration, data: data.json)
    }

    public func confirmMigration(arguments: JSONValue) async throws -> JSONValue {
        try await confirmMigration(try AriaV2ConfirmMigrationRequest(arguments: arguments))
    }

    public func confirmMigration(_ request: AriaV2ConfirmMigrationRequest) async throws -> JSONValue {
        try validate(request.estateID)
        let data: AriaV2MigrationConfirmationData
        do {
            data = try await provider.confirmMigration(request, context: context)
        } catch let error as JSONRPCError {
            throw error
        } catch {
            return orchestrationUnavailable(.confirmMigration)
        }
        return response(.confirmMigration, data: try data.verifiedJSON())
    }

    public func federatedSearch(arguments: JSONValue) async throws -> JSONValue {
        try await federatedSearch(try AriaV2FederatedSearchRequest(arguments: arguments))
    }

    public func federatedSearch(_ request: AriaV2FederatedSearchRequest) async throws -> JSONValue {
        if let requester = request.requesterEstateID, requester != context.estateID {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "The requested estate is not available to this caller.")
        }
        let data: AriaV2FederatedSearchData
        do {
            data = try await provider.federatedSearch(request, context: context)
        } catch let error as JSONRPCError {
            throw error
        } catch {
            return orchestrationUnavailable(.federatedSearch)
        }
        return response(.federatedSearch, data: data.json)
    }

    /// A lower failure on a typed orchestration operation is the operational
    /// refusal `orchestration_unavailable`: an empty migration plan, an
    /// unknown or terminal branch, or a federated recall with no authorized
    /// peer all answer with this one code and fixed message, which is what the
    /// Rust port's `render_orchestration` (surface.rs) emits for the same
    /// situations. The lower's own error description never reaches the wire,
    /// so the caller cannot read estate structure out of a refusal. A thrown
    /// `JSONRPCError` is a syntax fault the caller can fix and is rethrown for
    /// the dispatcher to answer as `invalid_argument`. `retryable` is true
    /// because the same call can succeed once the estate changes (a peer is
    /// granted, a plan is supplied), matching the Rust value.
    private func orchestrationUnavailable(_ operation: AriaV2OrchestrationOperation) -> JSONValue {
        AriaV2Envelope.refusal(tool: operation.rawValue, error: .init(
            code: "orchestration_unavailable",
            message: "The selected typed orchestration operation is unavailable.",
            retryable: true))
    }

    private func validate(_ estateID: UUID?) throws {
        guard estateID == nil || estateID == context.estateID else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "The requested estate is not available to this caller.")
        }
    }

    private func response(_ operation: AriaV2OrchestrationOperation, data: JSONValue) -> JSONValue {
        AriaV2Envelope.success(
            tool: operation.rawValue, effect: operation.effect, data: data,
            meta: [
                "completeness": .string("incomplete"),
                "server_identity": .string(context.serverIdentity),
                "session_id": .string(context.sessionID),
                "observed_at": .string(ISO8601DateFormatter().string(from: context.now())),
            ],
            compactText: "\(operation.rawValue) completed for selected estate \(context.estateID.uuidString.lowercased()).")
    }
}

private extension AriaV2CompactMemory {
    var json: JSONValue {
        var object: [String: JSONValue] = [
            "memory_id": .string(AriaV2ArgumentDecoder.canonicalUUID(memoryID)),
            "fetch": .object(["tool": .string("moot_memory_get"), "arguments": .object(["memory_id": .string(AriaV2ArgumentDecoder.canonicalUUID(memoryID))])]),
        ]
        if let subject { object["subject"] = .string(subject) }
        if let score { object["score"] = .double(score) }
        if let provenance { object["provenance"] = .string(provenance) }
        if let context { object["context"] = .string(context) }
        if let excerpt { object["excerpt"] = .string(AriaV2Envelope.compactText(excerpt)) }
        return .object(object)
    }
}

private extension AriaV2SynthesisData {
    var json: JSONValue {
        var object: [String: JSONValue] = ["summary": .string(summary), "results": .array(results.map(\.json))]
        if let cues { object["cues"] = .array(cues.map(JSONValue.string)) }
        return .object(object)
    }
}

private extension AriaV2MigrationData {
    var json: JSONValue {
        var object: [String: JSONValue] = [
            "reports": .array(reports.map { report in .object([
                "branch_id": .string(AriaV2ArgumentDecoder.canonicalUUID(report.branchID)), "query_count": .integer(Int64(report.queryCount)),
                "recall_overlap": .double(report.recallOverlap), "recall_precision": .double(report.recallPrecision),
                "mean_reciprocal_rank": .double(report.meanReciprocalRank), "not_found_in_branch": .array(report.notFoundInBranch.map(JSONValue.string)),
                "new_in_branch": .array(report.newInBranch.map(JSONValue.string)), "evaluated_at": .string(report.evaluatedAt),
            ]) }),
            "rankings": .array(rankings.map { ranking in .object([
                "branch_id": .string(AriaV2ArgumentDecoder.canonicalUUID(ranking.branchID)), "plan_name": .string(ranking.planName),
                "combined_score": .double(ranking.combinedScore), "recall_overlap": .double(ranking.recallOverlap),
                "mean_reciprocal_rank": .double(ranking.meanReciprocalRank),
            ]) }),
            "disqualified": .array(disqualified.map { row in .object([
                "branch_id": .string(AriaV2ArgumentDecoder.canonicalUUID(row.branchID)), "plan_name": .string(row.planName),
                "lost_concepts": .array(row.lostConcepts.map(JSONValue.string)),
            ]) }),
        ]
        if let winnerBranchID { object["winner_branch_id"] = .string(AriaV2ArgumentDecoder.canonicalUUID(winnerBranchID)) }
        if let winnerPlanName { object["winner_plan_name"] = .string(winnerPlanName) }
        return .object(object)
    }
}

private extension AriaV2MigrationConfirmationData {
    func verifiedJSON() throws -> JSONValue {
        let verified = discardOutcomes.compactMap { outcome -> UUID? in
            switch outcome.status { case .discarded, .alreadyDiscarded: return outcome.branchID; default: return nil }
        }
        guard Set(discardedBranchIDs) == Set(verified) else {
            throw JSONRPCError(code: JSONRPCErrorCode.internalError, message: "Migration cleanup receipt did not contain verified discarded branch ids.")
        }
        return .object([
            "status": .string("promoted"),
            "promoted_branch_id": .string(AriaV2ArgumentDecoder.canonicalUUID(promotedBranchID)),
            "discarded_branch_ids": .array(discardedBranchIDs.map { .string(AriaV2ArgumentDecoder.canonicalUUID($0)) }),
            "discard_outcomes": .array(discardOutcomes.map { .object([
                "branch_id": .string(AriaV2ArgumentDecoder.canonicalUUID($0.branchID)), "status": .string($0.status.rawValue),
            ]) }),
        ])
    }
}

private extension AriaV2FederatedSearchData {
    var json: JSONValue {
        .object([
            "source_estate_id": .string(AriaV2ArgumentDecoder.canonicalUUID(sourceEstateID)),
            "requester_estate_id": .string(AriaV2ArgumentDecoder.canonicalUUID(requesterEstateID)),
            "grant_id": .string(AriaV2ArgumentDecoder.canonicalUUID(grantID)),
            "results": .array(results.map(\.json)),
        ])
    }
}
