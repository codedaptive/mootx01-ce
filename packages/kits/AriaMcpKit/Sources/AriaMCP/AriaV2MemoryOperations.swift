import Foundation
import GeniusLocusKit
import LocusKit
import AriaMCPWire

/// The v2 memory-operation context is deliberately explicit.  ARIA owns the
/// caller identity, clock, sensitivity ceiling, and usage ledger; the estate
/// backend owns durable capture and retrieval.  This keeps the v2 surface from
/// borrowing mutable state from `ToolDispatcher` or reparsing a legacy reply.
public struct AriaV2MemoryOperationContext: Sendable {
    public let estateID: UUID
    public let callerID: String
    public let serverIdentity: String
    public let now: @Sendable () -> Date
    public let maximumSensitivity: AdjectiveSensitivity
    public let recallOrigin: RecallOrigin
    public let usageLedger: any AriaV2MemoryUsageLedger

    public init(
        estateID: UUID,
        callerID: String,
        serverIdentity: String,
        now: @escaping @Sendable () -> Date = { Date() },
        maximumSensitivity: AdjectiveSensitivity = .elevated,
        recallOrigin: RecallOrigin = .external,
        usageLedger: any AriaV2MemoryUsageLedger = AriaV2NoopMemoryUsageLedger()
    ) {
        self.estateID = estateID
        self.callerID = callerID
        self.serverIdentity = serverIdentity
        self.now = now
        self.maximumSensitivity = maximumSensitivity
        self.recallOrigin = recallOrigin
        self.usageLedger = usageLedger
    }
}

/// This is the only session-state seam needed by the three memory operations.
/// A production implementation can attach the existing recall usage ledger;
/// tests can prove the same calls without constructing a dispatcher.
public protocol AriaV2MemoryUsageLedger: Sendable {
    func recordSurfaced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async
    func recordDereferenced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async
}

public struct AriaV2NoopMemoryUsageLedger: AriaV2MemoryUsageLedger {
    public init() {}
    public func recordSurfaced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async {}
    public func recordDereferenced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async {}
}

public enum AriaV2MemoryDepth: String, Sendable, Equatable, CaseIterable {
    case subject
    case distilled
    case full
}

public enum AriaV2MemorySensitivity: String, Sendable, Equatable, CaseIterable {
    case normal
    case elevated
    case restricted
    case secret

    var locusValue: AdjectiveSensitivity {
        switch self {
        case .normal: .normal
        case .elevated: .elevated
        case .restricted: .restricted
        case .secret: .secret
        }
    }
}

public enum AriaV2MemoryExportability: String, Sendable, Equatable, CaseIterable {
    case `private`
    case `public`

    var locusValue: AdjectiveExportability {
        switch self {
        case .private: .private_
        case .public: .public_
        }
    }
}

public enum AriaV2MemoryKind: String, Sendable, Equatable, CaseIterable {
    case prose
    case code
    case transcript
    case list
    case structuredJSON = "structured_json"
    case imageCaption = "image_caption"

    var locusValue: ContentKind {
        switch self {
        case .prose: .prose
        case .code: .code
        case .transcript: .transcript
        case .list: .list
        case .structuredJSON: .structuredJSON
        case .imageCaption: .imageCaption
        }
    }
}

public struct AriaV2FileMemoryRequest: Sendable, Equatable {
    public let content: String
    public let subject: String
    public let location: String
    public let wing: String?
    public let sensitivity: AriaV2MemorySensitivity
    public let exportability: AriaV2MemoryExportability
    public let kind: AriaV2MemoryKind
    public let eventTime: Date?
    public let impatient: Bool
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: [
            "content", "subject", "location", "wing", "sensitivity", "exportability",
            "kind", "event_time", "impatient", "estate_id",
        ])
        content = try Self.nonEmpty(decoder.requireString("content"), path: "content")
        subject = try Self.subject(decoder.requireString("subject"))
        location = try Self.nonEmpty(decoder.requireString("location"), path: "location")
        wing = try decoder.optionalString("wing")
        sensitivity = try Self.enumValue(
            try decoder.optionalString("sensitivity") ?? AriaV2MemorySensitivity.normal.rawValue,
            path: "sensitivity", type: AriaV2MemorySensitivity.self)
        exportability = try Self.enumValue(
            try decoder.optionalString("exportability") ?? AriaV2MemoryExportability.private.rawValue,
            path: "exportability", type: AriaV2MemoryExportability.self)
        kind = try Self.enumValue(
            try decoder.optionalString("kind") ?? AriaV2MemoryKind.prose.rawValue,
            path: "kind", type: AriaV2MemoryKind.self)
        eventTime = try Self.date(try decoder.optionalString("event_time"), path: "event_time")
        impatient = try decoder.optionalBoolean("impatient") ?? false
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2MemorySearchRequest: Sendable, Equatable {
    public static let defaultLimit = 20
    public static let maximumLimit = 500

    public let query: String?
    public let near: UUID?
    public let limit: Int
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: [
            "query", "near", "limit", "filter", "wing", "media_type", "explain", "door",
            "scoring", "ordering", "frontier_k", "answer", "estate_id",
        ])
        let selected = try decoder.requireExactlyOne(of: ["query", "near"])
        if selected == "query" {
            query = try AriaV2FileMemoryRequest.nonEmpty(try decoder.requireString("query"), path: "query")
            near = nil
        } else {
            query = nil
            near = try decoder.requireUUID("near")
        }
        if let rawLimit = try decoder.optionalInteger("limit") {
            guard rawLimit >= 1, rawLimit <= Int64(Self.maximumLimit) else {
                throw AriaV2FileMemoryRequest.invalid(path: "limit", message: "Argument 'limit' must be between 1 and \(Self.maximumLimit).")
            }
            limit = Int(rawLimit)
        } else {
            limit = Self.defaultLimit
        }
        // The remaining source-faithful keys are intentionally not guessed at
        // this foundation boundary.  They remain declared by the registry but
        // require their own typed filter/scoring adapters before becoming live.
        for key in ["filter", "wing", "media_type", "explain", "door", "scoring", "ordering", "frontier_k", "answer"] {
            guard !decoder.has(key) else {
                throw AriaV2FileMemoryRequest.invalid(path: key, message: "Argument '\(key)' is not available in the incomplete v2 memory service.")
            }
        }
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2MemoryGetRequest: Sendable, Equatable {
    public static let maximumIDs = 50

    public let memoryIDs: [UUID]
    public let depth: AriaV2MemoryDepth
    public let estateID: UUID?

    public init(memoryIDs: [UUID], depth: AriaV2MemoryDepth, estateID: UUID?) {
        self.memoryIDs = memoryIDs
        self.depth = depth
        self.estateID = estateID
    }

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["memory_id", "memory_ids", "depth", "estate_id"])
        let selected = try decoder.requireExactlyOne(of: ["memory_id", "memory_ids"])
        if selected == "memory_id" {
            memoryIDs = [try decoder.requireUUID("memory_id")]
        } else {
            guard let values = decoder.arguments["memory_ids"]?.arrayValue, !values.isEmpty else {
                throw AriaV2FileMemoryRequest.invalid(path: "memory_ids", message: "Argument 'memory_ids' must be a non-empty UUID array.")
            }
            guard values.count <= Self.maximumIDs else {
                throw AriaV2FileMemoryRequest.invalid(path: "memory_ids", message: "Argument 'memory_ids' may contain at most \(Self.maximumIDs) UUIDs.")
            }
            memoryIDs = try values.enumerated().map { index, value in
                guard let raw = value.stringValue, let id = UUID(uuidString: raw) else {
                    throw AriaV2FileMemoryRequest.invalid(path: "memory_ids[\(index)]", message: "Argument 'memory_ids[\(index)]' must be a UUID.")
                }
                return id
            }
            guard Set(memoryIDs).count == memoryIDs.count else {
                throw AriaV2FileMemoryRequest.invalid(path: "memory_ids", message: "Argument 'memory_ids' must not contain duplicates.")
            }
        }
        depth = try AriaV2FileMemoryRequest.enumValue(
            try decoder.optionalString("depth") ?? AriaV2MemoryDepth.full.rawValue,
            path: "depth", type: AriaV2MemoryDepth.self)
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2MemoryRecord: Sendable, Equatable {
    public let memoryID: UUID
    public let subject: String?
    public let content: String
    public let wing: String
    public let room: String
    public let filedAt: Date
    public let eventTime: Date
    public let state: String
    public let trust: String
    public let sensitivity: String
    public let exportability: String
    public let confirmation: String
    public let lineageID: UUID
    public let provenance: String?
    public let context: String?
    public let isAuthorized: Bool

    public init(memoryID: UUID, subject: String? = nil, content: String = "", wing: String = "", room: String = "", filedAt: Date, eventTime: Date, state: String = "active", trust: String = "verbatim", sensitivity: String = "normal", exportability: String = "private", confirmation: String = "unconfirmed", lineageID: UUID, provenance: String? = nil, context: String? = nil, isAuthorized: Bool = true) {
        self.memoryID = memoryID
        self.subject = subject
        self.content = content
        self.wing = wing
        self.room = room
        self.filedAt = filedAt
        self.eventTime = eventTime
        self.state = state
        self.trust = trust
        self.sensitivity = sensitivity
        self.exportability = exportability
        self.confirmation = confirmation
        self.lineageID = lineageID
        self.provenance = provenance
        self.context = context
        self.isAuthorized = isAuthorized
    }
}

/// A typed estate seam. It only exchanges request and record values; no JSON
/// runner, text renderer, or legacy dispatch result crosses it.
public protocol AriaV2MemoryBackend: Sendable {
    func file(_ request: AriaV2FileMemoryRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2MemoryRecord
    func search(_ request: AriaV2MemorySearchRequest, context: AriaV2MemoryOperationContext) async throws -> [(record: AriaV2MemoryRecord, score: Double)]
    func get(_ request: AriaV2MemoryGetRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2MemoryRecord]
}

/// Direct typed adapter for the current GeniusLocusKit/Estate APIs.  It is
/// optional at construction time because tests and host composition cannot
/// manufacture public EstateHandle values; those callers inject the protocol
/// seam above instead.
public struct AriaV2GeniusLocusMemoryBackend: AriaV2MemoryBackend {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle

    public init(kit: GeniusLocusKit, handle: EstateHandle) {
        self.kit = kit
        self.handle = handle
    }

    public func file(_ request: AriaV2FileMemoryRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2MemoryRecord {
        try validateEstate(request.estateID, context: context)
        let frame = CaptureFrame(
            content: request.content,
            channel: .actuator,
            room: request.location,
            latticeAnchor: LatticeAnchor(udcCode: "000", udcFacets: nil, wikidataQID: nil, wikidataQidsSecondary: nil),
            addedBy: context.serverIdentity,
            embeddingModelID: "default",
            sensitivity: request.sensitivity.locusValue,
            kind: request.kind.locusValue,
            provenanceChannel: .mcpAgent,
            sourceType: .imported,
            eventTime: request.eventTime,
            exportability: request.exportability.locusValue,
            wing: request.wing ?? LocusKit.defaultWingName,
            subject: request.subject
        )
        let drawer = try await kit.capture(handle, frame, mode: request.impatient ? .impatient : .regular)
        return try await record(for: drawer, authorized: true)
    }

    public func search(_ request: AriaV2MemorySearchRequest, context: AriaV2MemoryOperationContext) async throws -> [(record: AriaV2MemoryRecord, score: Double)] {
        try validateEstate(request.estateID, context: context)
        let query: String
        if let requestQuery = request.query {
            query = requestQuery
        } else if let near = request.near {
            let source = try await get(AriaV2MemoryGetRequest(memoryIDs: [near], depth: .full, estateID: request.estateID), context: context)
            guard let anchor = source.first else { return [] }
            query = anchor.content
        } else {
            return []
        }
        let frame = RecallFrame(
            filterChain: [.sensitivityAtMost(context.maximumSensitivity)], hydrationLevel: .full, limit: request.limit)
        let result = try await kit.recall(handle, GLKRecallRequest(
            frame: frame, mode: .unionBest, scoring: .matrixAware, limit: request.limit,
            fallback: .allowDegraded, queryText: query, origin: context.recallOrigin,
            door: "memory_search", subSpanScoring: .off))
        var records: [(record: AriaV2MemoryRecord, score: Double)] = []
        for hit in result.hits {
            guard let drawer = hit.drawer else { continue }
            records.append((try await record(for: drawer, authorized: Self.provenanceVisible(drawer.provenance)), Double(hit.score.final)))
        }
        return records
    }

    public func get(_ request: AriaV2MemoryGetRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2MemoryRecord] {
        try validateEstate(request.estateID, context: context)
        let estate = try await kit.estate(for: handle)
        // Swift-authored drawers use UUID.uuidString while Rust-authored
        // portable estates use canonical lowercase. Public v2 references are
        // lowercase, so look up both valid storage spellings without changing
        // the typed UUID identity or exposing which spelling exists.
        let ids = request.memoryIDs.flatMap(AriaV2ArgumentDecoder.storageIdentitySpellings)
        let frame = RecallFrame(filterChain: [.sensitivityAtMost(context.maximumSensitivity)], hydrationLevel: .full)
        let loaded = try await estate.getDrawers(ids: ids, matchingFrame: frame, hydrationLevel: .full)
        var records: [AriaV2MemoryRecord] = []
        for drawer in loaded.admissible {
            records.append(try await record(for: drawer, authorized: Self.provenanceVisible(drawer.provenance)))
        }
        return records
    }

    private func validateEstate(_ requested: UUID?, context: AriaV2MemoryOperationContext) throws {
        guard requested == nil || requested == context.estateID, context.estateID == handle.estateUUID else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "The requested estate is not available to this caller.")
        }
    }

    private func record(for drawer: Drawer, authorized: Bool) async throws -> AriaV2MemoryRecord {
        let names = try await kit.resolveNodeNames(handle, parentNodeIds: [drawer.parentNodeId])
        let location = names[drawer.parentNodeId] ?? (wing: "", room: "")
        guard let memoryID = UUID(uuidString: drawer.id) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "The estate returned a non-UUID memory identifier.")
        }
        return AriaV2MemoryRecord(
            memoryID: memoryID,
            subject: drawer.subject, content: drawer.content, wing: location.wing, room: location.room,
            filedAt: drawer.filedAt, eventTime: drawer.eventTime, state: String(describing: drawer.state),
            trust: String(describing: drawer.trust), sensitivity: String(describing: drawer.adjectiveSensitivity),
            exportability: String(describing: drawer.exportability), confirmation: String(describing: drawer.confirmation),
            lineageID: drawer.lineageID, provenance: String(describing: drawer.sourceType), isAuthorized: authorized)
    }

    static func provenanceVisible(_ provenance: Int64) -> Bool {
        let raw = (provenance >> 30) & 0x3f
        return raw == Int64(Sensitivity.normal.rawValue)
            || raw == Int64(Sensitivity.elevated.rawValue)
    }
}

public struct AriaV2MemoryOperations: Sendable {
    public let backend: any AriaV2MemoryBackend
    public let context: AriaV2MemoryOperationContext

    public init(backend: any AriaV2MemoryBackend, context: AriaV2MemoryOperationContext) {
        self.backend = backend
        self.context = context
    }

    public func file(arguments: JSONValue) async throws -> JSONValue {
        try await file(AriaV2FileMemoryRequest(arguments: arguments))
    }

    public func file(_ request: AriaV2FileMemoryRequest) async throws -> JSONValue {
        let record = try await backend.file(request, context: context)
        let data: JSONValue = .object([
            "memory_id": .string(Self.id(record.memoryID)),
            "placement": .object(["wing": .string(record.wing), "room": .string(record.room)]),
            "fetch": Self.fetch(record.memoryID),
        ])
        return AriaV2Envelope.success(tool: "moot_file_memory", effect: .write, data: data, meta: Self.meta(), compactText: "Filed memory \(Self.id(record.memoryID)).")
    }

    public func search(arguments: JSONValue) async throws -> JSONValue {
        try await search(AriaV2MemorySearchRequest(arguments: arguments))
    }

    public func search(_ request: AriaV2MemorySearchRequest) async throws -> JSONValue {
        let matches = try await backend.search(request, context: context)
        // Lower recall may return a broader candidate pool than the public
        // request limit. Authorization happens first, then the selected v2
        // boundary enforces the caller-visible ceiling.
        let visible = Array(matches.lazy.filter { $0.record.isAuthorized }.prefix(request.limit))
        await context.usageLedger.recordSurfaced(visible.map { $0.record.memoryID }, estateID: context.estateID, callerID: context.callerID, at: context.now())
        let data: JSONValue = .object(["results": .array(visible.map { Self.compact($0.record, score: $0.score) })])
        return AriaV2Envelope.success(tool: "moot_memory_search", effect: .read, data: data, meta: Self.meta(), compactText: "Found \(visible.count) authorized memories.")
    }

    public func get(arguments: JSONValue) async throws -> JSONValue {
        try await get(AriaV2MemoryGetRequest(arguments: arguments))
    }

    public func get(_ request: AriaV2MemoryGetRequest) async throws -> JSONValue {
        let fetched = try await backend.get(request, context: context)
        let records = fetched.filter(\.isAuthorized)
        guard !records.isEmpty else {
            return AriaV2Envelope.refusal(tool: "moot_memory_get", error: .init(
                code: "memory_not_found", message: "No authorized memory matched the requested reference.", retryable: false))
        }
        await context.usageLedger.recordDereferenced(records.map(\.memoryID), estateID: context.estateID, callerID: context.callerID, at: context.now())
        let data: JSONValue = .object(["memories": .array(records.map { Self.full($0, depth: request.depth) })])
        return AriaV2Envelope.success(tool: "moot_memory_get", effect: .read, data: data, meta: Self.meta(), compactText: "Fetched \(records.count) authorized memories.")
    }

    private static func meta() -> [String: JSONValue] { ["completeness": .string("incomplete")] }
    private static func id(_ id: UUID) -> String { AriaV2ArgumentDecoder.canonicalUUID(id) }
    private static func fetch(_ id: UUID) -> JSONValue { .object(["tool": .string("moot_memory_get"), "arguments": .object(["memory_id": .string(Self.id(id))])]) }

    private static func compact(_ record: AriaV2MemoryRecord, score: Double) -> JSONValue {
        var result: [String: JSONValue] = ["memory_id": .string(id(record.memoryID)), "score": .double(score), "fetch": fetch(record.memoryID)]
        if let subject = record.subject { result["subject"] = .string(AriaV2Envelope.compactText(subject)) }
        if let provenance = record.provenance { result["provenance"] = .string(provenance) }
        if let context = record.context { result["context"] = .string(AriaV2Envelope.compactText(context)) }
        if !record.content.isEmpty { result["excerpt"] = .string(AriaV2Envelope.compactText(record.content)) }
        return .object(result)
    }

    private static func full(_ record: AriaV2MemoryRecord, depth: AriaV2MemoryDepth) -> JSONValue {
        var result: [String: JSONValue] = ["memory_id": .string(id(record.memoryID)), "fetch": fetch(record.memoryID)]
        if let subject = record.subject { result["subject"] = .string(subject) }
        if depth != .subject { result["distilled"] = .string(AriaV2Envelope.compactText(record.content)) }
        if depth == .full {
            result["content"] = .string(record.content)
            result["placement"] = .object(["wing": .string(record.wing), "room": .string(record.room)])
            result["filed_at"] = .string(Self.iso8601(record.filedAt))
            result["event_time"] = .string(Self.iso8601(record.eventTime))
            result["state"] = .string(record.state)
            result["trust"] = .string(record.trust)
            result["sensitivity"] = .string(record.sensitivity)
            result["exportability"] = .string(record.exportability)
            result["confirmation"] = .string(record.confirmation)
            result["lineage_id"] = .string(id(record.lineageID))
        }
        return .object(result)
    }

    private static func iso8601(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

fileprivate extension AriaV2FileMemoryRequest {
    static func nonEmpty(_ value: String, path: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw invalid(path: path, message: "Argument '\(path)' must not be empty.") }
        return trimmed
    }

    static func subject(_ value: String) throws -> String {
        let normalized = try nonEmpty(value, path: "subject")
        guard normalized.count <= DrawerStore.subjectLengthContract else {
            throw invalid(path: "subject", message: "Argument 'subject' must be at most \(DrawerStore.subjectLengthContract) characters.")
        }
        return normalized
    }

    static func date(_ raw: String?, path: String) throws -> Date? {
        guard let raw else { return nil }
        guard let date = ISO8601DateFormatter().date(from: raw) else {
            throw invalid(path: path, message: "Argument '\(path)' must be an ISO-8601 instant.")
        }
        return date
    }

    static func enumValue<T: RawRepresentable>(_ raw: String, path: String, type: T.Type) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: raw) else {
            throw invalid(path: path, message: "Argument '\(path)' has an unsupported value '\(raw)'.")
        }
        return value
    }

    static func invalid(path: String, message: String) -> JSONRPCError {
        AriaV2InvalidArgument(path: path, message: message).jsonRPCError
    }
}
