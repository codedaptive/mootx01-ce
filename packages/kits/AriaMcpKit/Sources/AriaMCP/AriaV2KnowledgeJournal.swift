import AriaMCPWire
import Foundation
import GeniusLocusKit
import LocusKit

/// The unadvertised Mission 02 knowledge and journal operation vocabulary.
/// These operations are deliberately independent of `ToolDispatcher`: the
/// backend exchanges typed values with LocusKit and the service owns the v2
/// envelope projection.
public enum AriaV2KnowledgeJournalOperation: String, Sendable, Equatable {
    case connectionSearch = "moot_connection_search"
    case connectionMap = "moot_connection_map"
    case fileFact = "moot_file_fact"
    case factSearch = "moot_fact_search"
    case retireFact = "moot_retire_fact"
    case factTimeline = "moot_fact_timeline"
    case writeJournal = "moot_write_journal"
    case readJournal = "moot_read_journal"
}

/// Hosts bind admission to their caller/session authorization context before
/// any lower read or write occurs. A caller-supplied estate UUID is never an
/// authorization grant.
public protocol AriaV2KnowledgeJournalAccessGate: Sendable {
    func admit(
        _ operation: AriaV2KnowledgeJournalOperation,
        context: AriaV2MemoryOperationContext
    ) async -> AriaV2OperationalRefusal?
}

public struct AriaV2AllowKnowledgeJournalAccess: AriaV2KnowledgeJournalAccessGate {
    public init() {}

    public func admit(
        _ operation: AriaV2KnowledgeJournalOperation,
        context: AriaV2MemoryOperationContext
    ) async -> AriaV2OperationalRefusal? {
        _ = operation
        _ = context
        return nil
    }
}

public enum AriaV2ConnectionDirection: String, Sendable, Equatable {
    case outgoing
    case incoming
    case both
}

public struct AriaV2ConnectionSearchRequest: Sendable, Equatable {
    public static let defaultLimit = 50
    public static let maximumLimit = 500

    public let memoryID: UUID
    public let relationship: String?
    public let direction: AriaV2ConnectionDirection
    public let limit: Int
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: [
            "memory_id", "relationship", "direction", "limit", "estate_id",
        ])
        memoryID = try decoder.requireUUID("memory_id")
        relationship = try AriaV2KnowledgeJournalRequest.optionalNonEmpty(decoder.optionalString("relationship"), path: "relationship")
        direction = try AriaV2KnowledgeJournalRequest.direction(decoder.optionalString("direction"))
        limit = try AriaV2KnowledgeJournalRequest.limit(
            decoder.optionalInteger("limit"), defaultValue: Self.defaultLimit, maximum: Self.maximumLimit, path: "limit")
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2ConnectionMapRequest: Sendable, Equatable {
    public static let defaultDepth = 1
    public static let maximumDepth = 50
    public static let defaultLimit = 50
    public static let maximumLimit = 500

    public let memoryID: UUID
    public let depth: Int
    public let limit: Int
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["memory_id", "depth", "limit", "estate_id"])
        memoryID = try decoder.requireUUID("memory_id")
        depth = try AriaV2KnowledgeJournalRequest.limit(
            decoder.optionalInteger("depth"), defaultValue: Self.defaultDepth, maximum: Self.maximumDepth, path: "depth")
        limit = try AriaV2KnowledgeJournalRequest.limit(
            decoder.optionalInteger("limit"), defaultValue: Self.defaultLimit, maximum: Self.maximumLimit, path: "limit")
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2FileFactRequest: Sendable, Equatable {
    public let subject: String
    public let predicate: String
    public let object: String
    public let sourceMemoryID: UUID?
    public let eventTime: Date?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: [
            "subject", "predicate", "object", "source_memory_id", "event_time", "estate_id",
        ])
        subject = try AriaV2KnowledgeJournalRequest.subject(decoder.requireString("subject"))
        predicate = try AriaV2KnowledgeJournalRequest.nonEmpty(decoder.requireString("predicate"), path: "predicate")
        object = try AriaV2KnowledgeJournalRequest.nonEmpty(decoder.requireString("object"), path: "object")
        sourceMemoryID = try decoder.optionalUUID("source_memory_id")
        eventTime = try AriaV2KnowledgeJournalRequest.date(decoder.optionalString("event_time"), path: "event_time")
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2FactSearchRequest: Sendable, Equatable {
    public static let defaultLimit = 100
    public static let maximumLimit = 500

    public let query: String?
    public let subject: String?
    public let predicate: String?
    public let object: String?
    public let limit: Int
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: [
            "query", "subject", "predicate", "object", "limit", "estate_id",
        ])
        query = try AriaV2KnowledgeJournalRequest.optionalNonEmpty(decoder.optionalString("query"), path: "query")
        subject = try AriaV2KnowledgeJournalRequest.optionalNonEmpty(decoder.optionalString("subject"), path: "subject")
        predicate = try AriaV2KnowledgeJournalRequest.optionalNonEmpty(decoder.optionalString("predicate"), path: "predicate")
        object = try AriaV2KnowledgeJournalRequest.optionalNonEmpty(decoder.optionalString("object"), path: "object")
        limit = try AriaV2KnowledgeJournalRequest.limit(
            decoder.optionalInteger("limit"), defaultValue: Self.defaultLimit, maximum: Self.maximumLimit, path: "limit")
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2RetireFactRequest: Sendable, Equatable {
    public let factID: UUID
    public let reason: String?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["fact_id", "reason", "estate_id"])
        factID = try decoder.requireUUID("fact_id")
        // optionalNonEmpty checks for empty string only; no length cap applies to reason.
        reason = try AriaV2KnowledgeJournalRequest.optionalNonEmpty(decoder.optionalString("reason"), path: "reason")
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2FactTimelineRequest: Sendable, Equatable {
    public static let defaultLimit = 200
    public static let maximumLimit = 500

    public let subject: String
    public let predicate: String?
    public let limit: Int
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["subject", "predicate", "limit", "estate_id"])
        subject = try AriaV2KnowledgeJournalRequest.nonEmpty(decoder.requireString("subject"), path: "subject")
        predicate = try AriaV2KnowledgeJournalRequest.optionalNonEmpty(decoder.optionalString("predicate"), path: "predicate")
        limit = try AriaV2KnowledgeJournalRequest.limit(
            decoder.optionalInteger("limit"), defaultValue: Self.defaultLimit, maximum: Self.maximumLimit, path: "limit")
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2WriteJournalRequest: Sendable, Equatable {
    public let content: String
    public let entryTime: Date?
    public let tags: String?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["content", "entry_time", "tags", "estate_id"])
        content = try AriaV2KnowledgeJournalRequest.nonEmpty(decoder.requireString("content"), path: "content")
        entryTime = try AriaV2KnowledgeJournalRequest.date(decoder.optionalString("entry_time"), path: "entry_time")
        tags = try AriaV2KnowledgeJournalRequest.optionalNonEmpty(decoder.optionalString("tags"), path: "tags")
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2ReadJournalRequest: Sendable, Equatable {
    public static let defaultLimit = 10
    public static let maximumLimit = 500

    public let limit: Int
    public let before: Date?
    public let after: Date?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["limit", "before", "after", "estate_id"])
        limit = try AriaV2KnowledgeJournalRequest.limit(
            decoder.optionalInteger("limit"), defaultValue: Self.defaultLimit, maximum: Self.maximumLimit, path: "limit")
        before = try AriaV2KnowledgeJournalRequest.date(decoder.optionalString("before"), path: "before")
        after = try AriaV2KnowledgeJournalRequest.date(decoder.optionalString("after"), path: "after")
        guard before == nil || after == nil || after! < before! else {
            throw AriaV2KnowledgeJournalRequest.invalid(path: "after", message: "Argument 'after' must be earlier than 'before'.")
        }
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2KnowledgeTunnel: Sendable, Equatable {
    public let tunnelID: UUID
    public let fromID: UUID?
    public let toID: UUID?
    public let kind: String
    /// Where this edge sits on the review ladder: `active`, `proposed`,
    /// `superseded` or `withdrawn`.
    ///
    /// Without it a caller cannot tell a user-confirmed link from an
    /// unreviewed machine inference — the dreaming daemon and the
    /// contradiction hunt both file `.proposed` edges on a timer, and an AI
    /// reading connections would otherwise treat a guess as an established
    /// fact.
    public let lifecycle: String
}

public struct AriaV2KnowledgeFact: Sendable, Equatable {
    public let factID: UUID
    public let subject: String
    public let predicate: String
    public let object: String
    /// Source-less facts are valid LocusKit records. The frozen output schema
    /// currently requires a UUID, so callers must retain this distinction until
    /// that schema is reconciled instead of minting a sentinel UUID.
    public let sourceMemoryID: UUID?
    public let eventTime: Date
    public let state: String
}

public struct AriaV2KnowledgeJournalEntry: Sendable, Equatable {
    public let agentName: String
    public let entry: String
    public let writtenAt: Date
}

/// A lower authority can reject an unavailable source without distinguishing a
/// missing drawer from one outside the caller's sensitivity ceiling.
public enum AriaV2KnowledgeJournalBackendFailure: Error, Sendable {
    case refusal(AriaV2OperationalRefusal)
}

/// Typed lower authority for the whole family. No legacy text or JSON result
/// crosses this boundary; a production provider calls public GLK/Estate APIs.
public protocol AriaV2KnowledgeJournalBackend: Sendable {
    func connectionSearch(_ request: AriaV2ConnectionSearchRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeTunnel]
    func connectionMap(_ request: AriaV2ConnectionMapRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeTunnel]
    func fileFact(_ request: AriaV2FileFactRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2KnowledgeFact
    func factSearch(_ request: AriaV2FactSearchRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeFact]
    /// Fixed-provider-only exact selectors. The selected v2 request remains
    /// selector-free; this requirement lets the concrete first-party backend
    /// receive the private contract values through an existential service.
    func factSearch(_ request: AriaV2FactSearchRequest, context: AriaV2MemoryOperationContext, sourceIDExact: String?, subjectExact: String?) async throws -> [AriaV2KnowledgeFact]
    func retireFact(_ request: AriaV2RetireFactRequest, context: AriaV2MemoryOperationContext) async throws
    func factTimeline(_ request: AriaV2FactTimelineRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeFact]
    func writeJournal(_ request: AriaV2WriteJournalRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2KnowledgeJournalEntry
    func readJournal(_ request: AriaV2ReadJournalRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeJournalEntry]
}

extension AriaV2KnowledgeJournalBackend {
    /// The selected-public grammar has no exact selectors. The authenticated
    /// provider supplies them through its fixed contract, while test doubles
    /// and public adapters retain the ordinary fact-search implementation.
    func factSearch(
        _ request: AriaV2FactSearchRequest,
        context: AriaV2MemoryOperationContext,
        sourceIDExact: String?,
        subjectExact: String?
    ) async throws -> [AriaV2KnowledgeFact] {
        _ = (sourceIDExact, subjectExact)
        return try await factSearch(request, context: context)
    }
}

/// Direct provider over the public GeniusLocusKit and LocusKit surfaces.
public struct AriaV2GeniusLocusKnowledgeJournalBackend: AriaV2KnowledgeJournalBackend {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle

    public init(kit: GeniusLocusKit, handle: EstateHandle) {
        self.kit = kit
        self.handle = handle
    }

    public func connectionSearch(_ request: AriaV2ConnectionSearchRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeTunnel] {
        try validateEstate(request.estateID, context: context)
        var candidates: [Tunnel] = []
        for id in AriaV2ArgumentDecoder.storageIdentitySpellings(request.memoryID) {
            if request.direction == .outgoing || request.direction == .both {
                candidates += try await kit.activeTunnels(in: handle, from: id)
            }
            if request.direction == .incoming || request.direction == .both {
                candidates += try await kit.activeTunnels(in: handle, to: id)
            }
        }
        let filtered = candidates.filter { tunnel in
            request.relationship == nil || tunnel.label == request.relationship
        }
        return try await visibleTunnels(filtered, ceiling: context.maximumSensitivity, limit: request.limit)
    }

    public func connectionMap(_ request: AriaV2ConnectionMapRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeTunnel] {
        try validateEstate(request.estateID, context: context)
        var frontier = Set(AriaV2ArgumentDecoder.storageIdentitySpellings(request.memoryID))
        var visited = frontier
        var collected: [Tunnel] = []
        for _ in 0..<request.depth where !frontier.isEmpty && collected.count < request.limit {
            var next = Set<String>()
            for id in frontier.sorted() {
                collected += try await kit.activeTunnels(in: handle, from: id)
                collected += try await kit.activeTunnels(in: handle, to: id)
            }
            let visible = try await visibleTunnels(collected, ceiling: context.maximumSensitivity, limit: request.limit)
            for tunnel in visible {
                if let fromID = tunnel.fromID { next.insert(fromID.uuidString) }
                if let toID = tunnel.toID { next.insert(toID.uuidString) }
            }
            frontier = next.subtracting(visited)
            visited.formUnion(frontier)
        }
        return try await visibleTunnels(collected, ceiling: context.maximumSensitivity, limit: request.limit)
    }

    public func fileFact(_ request: AriaV2FileFactRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2KnowledgeFact {
        try validateEstate(request.estateID, context: context)
        var storedSourceID = ""
        if let sourceMemoryID = request.sourceMemoryID {
            let source = try await kit.getDrawers(in: handle, 
                ids: AriaV2ArgumentDecoder.storageIdentitySpellings(sourceMemoryID),
                hydrationLevel: .structured)
            guard let admitted = source.first(where: {
                UUID(uuidString: $0.id) == sourceMemoryID &&
                    $0.adjectiveSensitivity.rawValue <= context.maximumSensitivity.rawValue
            }) else {
                throw AriaV2KnowledgeJournalBackendFailure.refusal(.init(
                    code: "source_unavailable",
                    message: "The supplied source memory is not available to this caller.",
                    retryable: false))
            }
            storedSourceID = admitted.id
        }
        let fact = try await kit.captureKGFact(
            handle,
            subject: request.subject,
            predicate: request.predicate,
            object: request.object,
            sourceDrawerID: storedSourceID,
            addedBy: context.serverIdentity,
            now: request.eventTime ?? context.now())
        return try factProjection(fact)
    }

    public func factSearch(_ request: AriaV2FactSearchRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeFact] {
        try await factSearch(request, context: context, sourceIDExact: nil, subjectExact: nil)
    }

    public func factSearch(
        _ request: AriaV2FactSearchRequest,
        context: AriaV2MemoryOperationContext,
        sourceIDExact: String?,
        subjectExact: String?
    ) async throws -> [AriaV2KnowledgeFact] {
        try validateEstate(request.estateID, context: context)
        let facts: [KGFact]
        if sourceIDExact != nil || subjectExact != nil {
            facts = try await kit.kgFacts(in: handle, 
                subjectEq: subjectExact,
                sourceDrawerIDEq: sourceIDExact)
        } else {
            facts = try await kit.recallKGFacts(handle)
        }
        return try (try await visibleFacts(facts, context: context))
            .filter { fact in
                // The provider's source/subject selectors are its own stable
                // 1.1 contract. Keep the SQL equality predicates above for
                // normal stores, then enforce both exact values again at this
                // boundary so a storage implementation cannot broaden a
                // first-party inventory. The selected public v2 grammar never
                // supplies either selector (both are nil there).
                (sourceIDExact == nil || fact.sourceDrawerID == sourceIDExact)
                    && (subjectExact == nil || fact.subject == subjectExact)
                    && Self.matches(fact, query: request.query, subject: request.subject, predicate: request.predicate, object: request.object)
            }
            .prefix(request.limit)
            .map { try factProjection($0) }
    }

    public func retireFact(_ request: AriaV2RetireFactRequest, context: AriaV2MemoryOperationContext) async throws {
        try validateEstate(request.estateID, context: context)
        let facts = try await kit.recallKGFacts(handle)
        let visible = try await visibleFacts(facts, context: context)
        guard let storedID = AriaV2ArgumentDecoder.matchingStorageIdentity(request.factID, among: visible.map(\.id)) else {
            throw AriaV2InvalidArgument(
                code: "fact_unavailable", path: "fact_id",
                message: "The target fact is not available to this caller."
            ).jsonRPCError
        }
        // changedBy comes from serverIdentity (the binary that hosts this dispatcher).
        // reason is forwarded from the caller's request; optionalNonEmpty applies, no length cap.
        try await kit.retireKGFact(handle, rowID: storedID, changedBy: context.serverIdentity, reason: request.reason, now: context.now())
    }

    public func factTimeline(_ request: AriaV2FactTimelineRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeFact] {
        try validateEstate(request.estateID, context: context)
        let facts = try await kit.recallKGFactTimeline(handle, entity: request.subject)
        return try (try await visibleFacts(facts, context: context))
            .filter { $0.subject == request.subject && (request.predicate == nil || $0.predicate == request.predicate) }
            .prefix(request.limit)
            .map { try factProjection($0) }
    }

    public func writeJournal(_ request: AriaV2WriteJournalRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2KnowledgeJournalEntry {
        try validateEstate(request.estateID, context: context)
        let entry = DiaryEntry(
            agentName: "mcp-agent",
            entry: request.content,
            topic: request.tags ?? "mcp-session",
            wing: "agents",
            room: "diary",
            filedAt: request.entryTime ?? context.now(),
            embeddingModelID: "default",
            operationalBitmap: Int64(DiaryActorClass.mcpAgent.rawValue) << 7)
        try await kit.addDiaryEntry(in: handle, entry)
        return .init(agentName: entry.agentName, entry: entry.entry, writtenAt: entry.filedAt)
    }

    public func readJournal(_ request: AriaV2ReadJournalRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2KnowledgeJournalEntry] {
        try validateEstate(request.estateID, context: context)
        return try await kit.readDiaryEntries(in: handle, agentName: "mcp-agent", lastN: request.limit)
            .filter { entry in
                (request.before == nil || entry.filedAt < request.before!) &&
                (request.after == nil || entry.filedAt > request.after!)
            }
            .map { .init(agentName: $0.agentName, entry: $0.entry, writtenAt: $0.filedAt) }
    }

    private func validateEstate(_ requested: UUID?, context: AriaV2MemoryOperationContext) throws {
        guard requested == nil || requested == context.estateID,
              context.estateID == handle.estateUUID else {
            throw AriaV2KnowledgeJournalRequest.invalid(path: "estate_id", message: "The requested estate is not available to this caller.")
        }
    }

    private func visibleTunnels(_ candidates: [Tunnel], ceiling: AdjectiveSensitivity, limit: Int) async throws -> [AriaV2KnowledgeTunnel] {
        let unique = Dictionary(grouping: candidates, by: \.id).values.compactMap(\.first).sorted { $0.id < $1.id }
        let rows = unique.compactMap { tunnel -> (Tunnel, UUID, UUID?, UUID?)? in
            // Connection surfaces report SETTLED edges only. v1 pushed this into
            // SQL via activeTunnelsFrom/activeTunnelsTo; the Rust port filters
            // here. Without it an unreviewed proposal filed by dreaming or the
            // contradiction hunt reads as a confirmed link. Proposals are
            // surfaced deliberately by the contradiction lens, not by this one.
            guard tunnel.lifecycle == .active,
                  tunnel.adjectiveSensitivity.rawValue <= ceiling.rawValue,
                  let tunnelID = UUID(uuidString: tunnel.id) else { return nil }
            let fromID = tunnel.sourceDrawerId.flatMap(UUID.init(uuidString:))
            let toID = tunnel.targetDrawerId.flatMap(UUID.init(uuidString:))
            guard (tunnel.sourceDrawerId == nil || fromID != nil),
                  (tunnel.targetDrawerId == nil || toID != nil) else { return nil }
            return (tunnel, tunnelID, fromID, toID)
        }
        let endpoints = Set(rows.flatMap { [$0.0.sourceDrawerId, $0.0.targetDrawerId].compactMap { $0 } })
        let drawers = try await kit.getDrawers(in: handle, ids: Array(endpoints), hydrationLevel: .structured)
        let visibleIDs = Set(drawers.filter { $0.adjectiveSensitivity.rawValue <= ceiling.rawValue }.map(\.id))
        return rows.filter {
            ($0.0.sourceDrawerId.map(visibleIDs.contains) ?? true) &&
            ($0.0.targetDrawerId.map(visibleIDs.contains) ?? true)
        }.prefix(limit).map { row in
            .init(tunnelID: row.1, fromID: row.2, toID: row.3, kind: row.0.kind.wireString,
                  lifecycle: String(describing: row.0.lifecycle))
        }
    }

    private func visibleFacts(_ facts: [KGFact], context: AriaV2MemoryOperationContext) async throws -> [KGFact] {
        let ceilingFacts = facts.filter {
            $0.adjectiveSensitivity.rawValue <= context.maximumSensitivity.rawValue &&
                (!context.exportableOnly || $0.exportability == .public_)
        }
        let sourceIDs = Set(ceilingFacts.map(\.sourceDrawerID).filter { !$0.isEmpty })
        let drawers = try await kit.getDrawers(in: handle, ids: Array(sourceIDs), hydrationLevel: .structured)
        let visibleSources = Set(drawers.filter {
            $0.adjectiveSensitivity.rawValue <= context.maximumSensitivity.rawValue &&
                (!context.exportableOnly || $0.exportability == .public_)
        }.map(\.id))
        return ceilingFacts.filter { $0.sourceDrawerID.isEmpty || visibleSources.contains($0.sourceDrawerID) }
    }

    private static func matches(_ fact: KGFact, query: String?, subject: String?, predicate: String?, object: String?) -> Bool {
        if let subject, fact.subject != subject { return false }
        if let predicate, fact.predicate != predicate { return false }
        if let object, fact.object != object { return false }
        guard let query else { return true }
        let lower = query.lowercased()
        return fact.subject.lowercased().contains(lower) || fact.predicate.lowercased().contains(lower) || fact.object.lowercased().contains(lower)
    }

    private func factProjection(_ fact: KGFact) throws -> AriaV2KnowledgeFact {
        guard let factID = UUID(uuidString: fact.id) else {
            throw AriaV2KnowledgeJournalRequest.invalid(path: "fact_id", message: "The estate returned a non-UUID fact identifier.")
        }
        return .init(
            factID: factID, subject: fact.subject, predicate: fact.predicate, object: fact.object,
            sourceMemoryID: UUID(uuidString: fact.sourceDrawerID), eventTime: fact.filedAt,
            state: String(describing: fact.state))
    }
}

/// Unadvertised typed service. Wiring it into the catalog/dispatcher remains a
/// separate admission and surface-completeness change.
public struct AriaV2KnowledgeJournalService: Sendable {
    public let backend: any AriaV2KnowledgeJournalBackend
    public let context: AriaV2MemoryOperationContext
    public let accessGate: any AriaV2KnowledgeJournalAccessGate

    public init(
        backend: any AriaV2KnowledgeJournalBackend,
        context: AriaV2MemoryOperationContext,
        accessGate: any AriaV2KnowledgeJournalAccessGate = AriaV2AllowKnowledgeJournalAccess()
    ) {
        self.backend = backend
        self.context = context
        self.accessGate = accessGate
    }

    public func connectionSearch(arguments: JSONValue) async throws -> JSONValue { try await connectionSearch(.init(arguments: arguments)) }
    public func connectionMap(arguments: JSONValue) async throws -> JSONValue { try await connectionMap(.init(arguments: arguments)) }
    public func fileFact(arguments: JSONValue) async throws -> JSONValue { try await fileFact(.init(arguments: arguments)) }
    public func factSearch(arguments: JSONValue) async throws -> JSONValue { try await factSearch(.init(arguments: arguments)) }

    /// Fixed-provider-only selectors that deliberately stay outside the
    /// selected-public fact-search decoder and catalog.
    public func factSearch(
        arguments: JSONValue,
        sourceIDExact: String?,
        subjectExact: String?
    ) async throws -> JSONValue {
        try await factSearch(
            .init(arguments: arguments),
            sourceIDExact: sourceIDExact,
            subjectExact: subjectExact
        )
    }
    public func retireFact(arguments: JSONValue) async throws -> JSONValue { try await retireFact(.init(arguments: arguments)) }
    public func factTimeline(arguments: JSONValue) async throws -> JSONValue { try await factTimeline(.init(arguments: arguments)) }
    public func writeJournal(arguments: JSONValue) async throws -> JSONValue { try await writeJournal(.init(arguments: arguments)) }
    public func readJournal(arguments: JSONValue) async throws -> JSONValue { try await readJournal(.init(arguments: arguments)) }

    public func connectionSearch(_ request: AriaV2ConnectionSearchRequest) async throws -> JSONValue {
        if let refusal = await accessGate.admit(.connectionSearch, context: context) { return Self.refusal(.connectionSearch, refusal) }
        let edges = try await backend.connectionSearch(request, context: context)
        return Self.success(.connectionSearch, effect: .read, data: .object(["edges": .array(edges.map(Self.tunnel))]), text: "Found \(edges.count) authorized connections.")
    }

    public func connectionMap(_ request: AriaV2ConnectionMapRequest) async throws -> JSONValue {
        if let refusal = await accessGate.admit(.connectionMap, context: context) { return Self.refusal(.connectionMap, refusal) }
        let edges = try await backend.connectionMap(request, context: context)
        return Self.success(.connectionMap, effect: .read, data: .object(["edges": .array(edges.map(Self.tunnel))]), text: "Mapped \(edges.count) authorized connections.")
    }

    public func fileFact(_ request: AriaV2FileFactRequest) async throws -> JSONValue {
        if let refusal = await accessGate.admit(.fileFact, context: context) { return Self.refusal(.fileFact, refusal) }
        do {
            return Self.success(.fileFact, effect: .write, data: Self.fact(try await backend.fileFact(request, context: context)), text: "Filed fact.")
        } catch let failure as AriaV2KnowledgeJournalBackendFailure {
            switch failure {
            case .refusal(let refusal): return Self.refusal(.fileFact, refusal)
            }
        }
    }

    public func factSearch(_ request: AriaV2FactSearchRequest) async throws -> JSONValue {
        try await factSearch(request, sourceIDExact: nil, subjectExact: nil)
    }

    public func factSearch(
        _ request: AriaV2FactSearchRequest,
        sourceIDExact: String?,
        subjectExact: String?
    ) async throws -> JSONValue {
        if let refusal = await accessGate.admit(.factSearch, context: context) { return Self.refusal(.factSearch, refusal) }
        let facts = try await backend.factSearch(
            request,
            context: context,
            sourceIDExact: sourceIDExact,
            subjectExact: subjectExact
        )
        return Self.success(.factSearch, effect: .read, data: .object(["facts": .array(facts.map(Self.fact))]), text: "Found \(facts.count) authorized facts.")
    }

    public func retireFact(_ request: AriaV2RetireFactRequest) async throws -> JSONValue {
        if let refusal = await accessGate.admit(.retireFact, context: context) { return Self.refusal(.retireFact, refusal) }
        try await backend.retireFact(request, context: context)
        return Self.success(.retireFact, effect: .write, data: .object(["fact_id": .string(Self.id(request.factID))]), text: "Retired fact \(Self.id(request.factID)).")
    }

    public func factTimeline(_ request: AriaV2FactTimelineRequest) async throws -> JSONValue {
        if let refusal = await accessGate.admit(.factTimeline, context: context) { return Self.refusal(.factTimeline, refusal) }
        let facts = try await backend.factTimeline(request, context: context)
        return Self.success(.factTimeline, effect: .read, data: .object(["facts": .array(facts.map(Self.fact))]), text: "Read \(facts.count) authorized facts.")
    }

    public func writeJournal(_ request: AriaV2WriteJournalRequest) async throws -> JSONValue {
        if let refusal = await accessGate.admit(.writeJournal, context: context) { return Self.refusal(.writeJournal, refusal) }
        return Self.success(.writeJournal, effect: .write, data: Self.journal(try await backend.writeJournal(request, context: context)), text: "Wrote journal entry.")
    }

    public func readJournal(_ request: AriaV2ReadJournalRequest) async throws -> JSONValue {
        if let refusal = await accessGate.admit(.readJournal, context: context) { return Self.refusal(.readJournal, refusal) }
        let entries = try await backend.readJournal(request, context: context)
        return Self.success(.readJournal, effect: .read, data: .object(["entries": .array(entries.map(Self.journal))]), text: "Read \(entries.count) authorized journal entries.")
    }

    private static func success(_ operation: AriaV2KnowledgeJournalOperation, effect: AriaV2OperationEffect, data: JSONValue, text: String) -> JSONValue {
        AriaV2Envelope.success(tool: operation.rawValue, effect: effect, data: data, meta: ["completeness": .string("incomplete")], compactText: text)
    }

    private static func refusal(_ operation: AriaV2KnowledgeJournalOperation, _ error: AriaV2OperationalRefusal) -> JSONValue {
        AriaV2Envelope.refusal(tool: operation.rawValue, error: error)
    }

    private static func tunnel(_ tunnel: AriaV2KnowledgeTunnel) -> JSONValue {
        var value: [String: JSONValue] = [
            "tunnel_id": .string(id(tunnel.tunnelID)), "kind": .string(tunnel.kind),
            // Always emitted: a caller that cannot see the lifecycle cannot
            // tell a confirmed link from an unreviewed machine proposal.
            "lifecycle": .string(tunnel.lifecycle),
        ]
        if let fromID = tunnel.fromID { value["from_id"] = .string(id(fromID)) }
        if let toID = tunnel.toID { value["to_id"] = .string(id(toID)) }
        return .object(value)
    }

    private static func fact(_ fact: AriaV2KnowledgeFact) -> JSONValue {
        var value: [String: JSONValue] = [
            "fact_id": .string(id(fact.factID)), "subject": .string(fact.subject), "predicate": .string(fact.predicate),
            "object": .string(fact.object), "event_time": .string(iso8601(fact.eventTime)), "state": .string(fact.state),
        ]
        if let sourceMemoryID = fact.sourceMemoryID {
            value["source_memory_id"] = .string(id(sourceMemoryID))
        }
        return .object(value)
    }

    private static func journal(_ entry: AriaV2KnowledgeJournalEntry) -> JSONValue {
        .object(["agent_name": .string(entry.agentName), "entry": .string(entry.entry), "written_at": .string(iso8601(entry.writtenAt))])
    }

    private static func id(_ id: UUID) -> String { AriaV2ArgumentDecoder.canonicalUUID(id) }
    private static func iso8601(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

private enum AriaV2KnowledgeJournalRequest {
    static func nonEmpty(_ value: String, path: String) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid(path: path, message: "Argument '\(path)' must not be empty.")
        }
        return value
    }

    static func optionalNonEmpty(_ value: String?, path: String) throws -> String? {
        try value.map { try nonEmpty($0, path: path) }
    }

    static func subject(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= DrawerStore.subjectLengthContract else {
            throw invalid(path: "subject", message: "Argument 'subject' must contain 1–\(DrawerStore.subjectLengthContract) characters.")
        }
        return trimmed
    }

    static func direction(_ value: String?) throws -> AriaV2ConnectionDirection {
        guard let value else { return .both }
        guard let direction = AriaV2ConnectionDirection(rawValue: value) else {
            throw invalid(path: "direction", message: "Argument 'direction' must be outgoing, incoming, or both.")
        }
        return direction
    }

    /// Below one is a SYNTAX ERROR and above the ceiling CLAMPS, which is the
    /// split v1's shared limit funnel used.
    ///
    /// The two halves are not symmetric on purpose. A negative or zero limit
    /// is meaningless and, left alone, reaches SQLite as `LIMIT -1` — every
    /// row — so it must be refused rather than quietly corrected. An
    /// over-large limit is a caller asking for more than the surface will
    /// give, which the ceiling already answers; refusing it instead makes a
    /// caller who asked for 10_000 get nothing rather than 500.
    static func limit(_ value: Int64?, defaultValue: Int, maximum: Int, path: String) throws -> Int {
        guard let value else { return defaultValue }
        guard value >= 1 else {
            throw invalid(path: path, message: "Argument '\(path)' must be at least 1.")
        }
        return Int(min(value, Int64(maximum)))
    }

    static func date(_ value: String?, path: String) throws -> Date? {
        guard let value else { return nil }
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw invalid(path: path, message: "Argument '\(path)' must be an ISO-8601 date-time.")
        }
        return date
    }

    static func invalid(path: String, message: String) -> JSONRPCError {
        AriaV2InvalidArgument(path: path, message: message).jsonRPCError
    }
}
