import AriaMCPWire
import CryptoKit
import Foundation
import PersistenceKit

/// Strict Mission 02 request shape used by the selected v2 surface.
public struct AriaV2MemoryListRequest: Sendable, Equatable {
    public static let toolName = "moot_memory_list"
    public static let defaultLimit = 200
    public static let maximumLimit = 200

    public let wing: String
    public let room: String?
    public let filter: String?
    public let limit: Int
    public let cursor: String?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: [
            "wing", "room", "filter", "limit", "cursor", "estate_id",
        ])
        wing = try Self.nonEmpty(try decoder.requireString("wing"), path: "wing")
        if let rawRoom = try decoder.optionalString("room") {
            room = rawRoom.isEmpty ? nil : rawRoom
        } else {
            room = nil
        }
        switch try decoder.optionalString("filter") {
        case nil:
            filter = nil
        case "missing_subject":
            filter = "missing_subject"
        case .some:
            throw AriaV2InvalidArgument(
                path: "filter",
                message: "Argument 'filter' must be 'missing_subject' when supplied.",
                allowed: ["missing_subject"],
                correction: "use 'missing_subject' as the filter value"
            ).jsonRPCError
        }
        if let rawLimit = try decoder.optionalInteger("limit") {
            guard rawLimit >= 1, rawLimit <= Int64(Self.maximumLimit) else {
                throw AriaV2InvalidArgument(
                    path: "limit",
                    message: "Argument 'limit' must be between 1 and \(Self.maximumLimit).").jsonRPCError
            }
            limit = Int(rawLimit)
        } else {
            limit = Self.defaultLimit
        }
        if let rawCursor = try decoder.optionalString("cursor") {
            cursor = try Self.nonEmpty(rawCursor, path: "cursor")
        } else {
            cursor = nil
        }
        estateID = try decoder.optionalUUID("estate_id")
    }

    private static func nonEmpty(_ value: String, path: String) throws -> String {
        guard !value.isEmpty else {
            throw AriaV2InvalidArgument(
                path: path,
                message: "Argument '\(path)' must not be empty.").jsonRPCError
        }
        return value
    }
}

/// The caller/policy binding that a cursor may never cross.
public struct AriaV2MemoryListAuthorization: Sendable, Equatable {
    public let callerID: String
    public let contextID: String
    public let policyVersion: String

    public init(callerID: String, contextID: String, policyVersion: String) {
        self.callerID = callerID
        self.contextID = contextID
        self.policyVersion = policyVersion
    }
}

/// A fully decoded, authorized row from one immutable persistence snapshot.
/// `projection` is the exact public row payload excluding `memory_id`; its
/// values participate in the revision identity so a projection change cannot
/// silently retain a continuation cursor.
public struct AriaV2MemoryListRow: Sendable, Equatable {
    public let memoryID: UUID
    public let ancestryIDs: [UUID]
    public let ancestryNames: [String]
    public let eligibilityState: String
    public let visibilityState: String
    public let projection: [String: JSONValue]

    public init(
        memoryID: UUID,
        ancestryIDs: [UUID],
        ancestryNames: [String],
        eligibilityState: String,
        visibilityState: String,
        projection: [String: JSONValue]
    ) {
        self.memoryID = memoryID
        self.ancestryIDs = ancestryIDs
        self.ancestryNames = ancestryNames
        self.eligibilityState = eligibilityState
        self.visibilityState = visibilityState
        self.projection = projection
    }
}

/// The post-decode result of a bounded `Storage.captureInventorySnapshot`.
/// The provider must capture drawers and nodes atomically, strictly decode
/// relevant rows/ancestry, recheck access, apply the fixed bulk-export
/// authorization ceiling, apply the requested scope, and return the complete
/// authorized current state. It must never omit a corrupt relevant row or
/// return a partial inventory.
public struct AriaV2MemoryListSnapshot: Sendable, Equatable {
    public let estateID: UUID
    public let authorizationGeneration: String
    public let rows: [AriaV2MemoryListRow]

    public init(estateID: UUID, authorizationGeneration: String, rows: [AriaV2MemoryListRow]) {
        self.estateID = estateID
        self.authorizationGeneration = authorizationGeneration
        self.rows = rows
    }
}

/// Injection seam for the lower persistence/LocusKit snapshot interpreter.
/// ARIA intentionally does not reconstruct drawers from raw storage rows.
public protocol AriaV2MemoryListSnapshotProvider: Sendable {
    func immutableAuthorizedSnapshot(
        estateID: UUID,
        wing: String,
        room: String?,
        filter: String?,
        authorization: AriaV2MemoryListAuthorization
    ) async throws -> AriaV2MemoryListSnapshot
}

public enum AriaV2MemoryListCursorError: Error, Sendable, Equatable {
    case expired
    case mismatch
    case stale
    case retainedStateLimit
}

/// Opaque temporary cursor references. The session never retains row bodies or
/// a prior snapshot: every continuation receives a new complete state from the
/// injected provider and revalidates its cryptographic revision first.
public actor AriaV2MemoryListCursorSession {
    public static let absoluteTTL: TimeInterval = 10 * 60
    public static let maximumPerAuthorizationContext = 32
    public static let maximumServerReferences = 256
    public static let maximumRetainedBytes = 16 * 1024 * 1024

    struct Scope: Sendable, Equatable {
        let estateID: UUID
        let wing: String
        let room: String?
        let filter: String?
        let order = "uuid_bytes_ascending"
    }

    private struct Entry: Sendable {
        let scope: Scope
        let authorization: AriaV2MemoryListAuthorization
        let revision: String
        let lastMemoryID: UUID
        let expiresAt: Date
        var lastAccessedAt: Date

        var byteCount: Int {
            128
                + scope.wing.utf8.count
                + (scope.room?.utf8.count ?? 0)
                + (scope.filter?.utf8.count ?? 0)
                + authorization.callerID.utf8.count
                + authorization.contextID.utf8.count
                + authorization.policyVersion.utf8.count
                + revision.utf8.count
        }
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    func resume(
        cursor: String,
        scope: Scope,
        authorization: AriaV2MemoryListAuthorization,
        revision: String,
        now: Date
    ) throws -> UUID {
        evictExpired(now: now)
        guard var entry = entries[cursor] else { throw AriaV2MemoryListCursorError.expired }
        guard entry.scope == scope, entry.authorization == authorization else {
            throw AriaV2MemoryListCursorError.mismatch
        }
        guard entry.revision == revision else { throw AriaV2MemoryListCursorError.stale }
        entry.lastAccessedAt = now
        entries[cursor] = entry
        return entry.lastMemoryID
    }

    func retain(
        scope: Scope,
        authorization: AriaV2MemoryListAuthorization,
        revision: String,
        lastMemoryID: UUID,
        now: Date
    ) throws -> String {
        evictExpired(now: now)
        let token = UUID().uuidString.lowercased()
        let entry = Entry(
            scope: scope,
            authorization: authorization,
            revision: revision,
            lastMemoryID: lastMemoryID,
            expiresAt: now.addingTimeInterval(Self.absoluteTTL),
            lastAccessedAt: now)
        guard entry.byteCount <= Self.maximumRetainedBytes else {
            throw AriaV2MemoryListCursorError.retainedStateLimit
        }
        evictForContextIfNeeded(authorization: authorization)
        evictForServerIfNeeded()
        evictForBytesIfNeeded(adding: entry.byteCount)
        guard entries.count < Self.maximumServerReferences,
              entries.values.filter({ $0.authorization == authorization }).count < Self.maximumPerAuthorizationContext,
              retainedByteCount + entry.byteCount <= Self.maximumRetainedBytes else {
            throw AriaV2MemoryListCursorError.retainedStateLimit
        }
        entries[token] = entry
        return token
    }

    public func retainedReferenceCount() -> Int { entries.count }

    private var retainedByteCount: Int { entries.values.reduce(0) { $0 + $1.byteCount } }

    private func evictExpired(now: Date) {
        entries = entries.filter { now < $0.value.expiresAt }
    }

    private func evictForContextIfNeeded(authorization: AriaV2MemoryListAuthorization) {
        while entries.values.filter({ $0.authorization == authorization }).count >= Self.maximumPerAuthorizationContext,
              let token = leastRecentlyUsedToken(where: { $0.authorization == authorization }) {
            entries[token] = nil
        }
    }

    private func evictForServerIfNeeded() {
        while entries.count >= Self.maximumServerReferences,
              let token = leastRecentlyUsedToken(where: { _ in true }) {
            entries[token] = nil
        }
    }

    private func evictForBytesIfNeeded(adding byteCount: Int) {
        while retainedByteCount + byteCount > Self.maximumRetainedBytes,
              let token = leastRecentlyUsedToken(where: { _ in true }) {
            entries[token] = nil
        }
    }

    private func leastRecentlyUsedToken(where predicate: (Entry) -> Bool) -> String? {
        entries
            .filter { predicate($0.value) }
            .min { lhs, rhs in
                if lhs.value.lastAccessedAt == rhs.value.lastAccessedAt { return lhs.key < rhs.key }
                return lhs.value.lastAccessedAt < rhs.value.lastAccessedAt
            }?
            .key
    }
}

/// Typed list service. It is intentionally unadvertised until a lower-kit
/// immutable snapshot interpreter is wired at the selected v2 surface.
public struct AriaV2MemoryListService: Sendable {
    public let provider: any AriaV2MemoryListSnapshotProvider
    public let cursorSession: AriaV2MemoryListCursorSession
    public let defaultEstateID: UUID
    public let authorization: AriaV2MemoryListAuthorization
    public let now: @Sendable () -> Date

    public init(
        provider: any AriaV2MemoryListSnapshotProvider,
        cursorSession: AriaV2MemoryListCursorSession,
        defaultEstateID: UUID,
        authorization: AriaV2MemoryListAuthorization,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.cursorSession = cursorSession
        self.defaultEstateID = defaultEstateID
        self.authorization = authorization
        self.now = now
    }

    public func list(arguments: JSONValue) async throws -> JSONValue {
        try await list(AriaV2MemoryListRequest(arguments: arguments))
    }

    public func list(_ request: AriaV2MemoryListRequest) async throws -> JSONValue {
        let estateID = request.estateID ?? defaultEstateID
        let scope = AriaV2MemoryListCursorSession.Scope(
            estateID: estateID, wing: request.wing, room: request.room, filter: request.filter)
        let snapshot: AriaV2MemoryListSnapshot
        do {
            snapshot = try await provider.immutableAuthorizedSnapshot(
                estateID: estateID, wing: request.wing, room: request.room,
                filter: request.filter, authorization: authorization)
        } catch let error as InventorySnapshotError {
            return inventoryTooLarge(error)
        } catch {
            return refusal(code: "inventory_unavailable", message: "The complete authorized memory inventory is unavailable.", retryable: true)
        }
        guard snapshot.estateID == estateID else {
            return refusal(code: "inventory_unavailable", message: "The complete authorized memory inventory is unavailable.", retryable: true)
        }

        let rows = snapshot.rows.sorted { Self.uuidBytes($0.memoryID).lexicographicallyPrecedes(Self.uuidBytes($1.memoryID)) }
        guard Set(rows.map(\.memoryID)).count == rows.count else {
            return refusal(code: "inventory_unavailable", message: "The complete authorized memory inventory is unavailable.", retryable: true)
        }
        let revision = Self.revision(scope: scope, authorization: authorization, snapshot: snapshot, rows: rows)
        let current = now()
        let start: Int
        if let cursor = request.cursor {
            do {
                let lastID = try await cursorSession.resume(
                    cursor: cursor, scope: scope, authorization: authorization,
                    revision: revision, now: current)
                guard let index = rows.firstIndex(where: { $0.memoryID == lastID }) else {
                    return refusal(code: "cursor_stale", message: "The memory list changed; restart enumeration.", retryable: true)
                }
                start = index + 1
            } catch let error as AriaV2MemoryListCursorError {
                return cursorRefusal(error)
            }
        } else {
            start = 0
        }

        let end = min(start + request.limit, rows.count)
        let page = Array(rows[start..<end])
        let hasMore = end < rows.count
        var data: [String: JSONValue] = [
            "memories": .array(page.map(Self.project)),
            "has_more": .bool(hasMore),
            "revision": .string(revision),
        ]
        if hasMore, let last = page.last {
            do {
                data["next_cursor"] = .string(try await cursorSession.retain(
                    scope: scope, authorization: authorization, revision: revision,
                    lastMemoryID: last.memoryID, now: current))
            } catch let error as AriaV2MemoryListCursorError {
                return cursorRefusal(error)
            }
        }
        return AriaV2Envelope.success(
            tool: AriaV2MemoryListRequest.toolName,
            effect: .read,
            data: .object(data),
            meta: ["completeness": .string("incomplete")],
            compactText: "Enumerated \(page.count) authorized memories from a complete current inventory.")
    }

    private func cursorRefusal(_ error: AriaV2MemoryListCursorError) -> JSONValue {
        switch error {
        case .expired:
            return refusal(code: "cursor_expired", message: "The memory-list cursor expired; restart enumeration.", retryable: true)
        case .mismatch:
            return refusal(code: "cursor_mismatch", message: "The cursor does not match this memory-list scope or authorization context; restart enumeration.", retryable: true)
        case .stale:
            return refusal(code: "cursor_stale", message: "The memory list changed; restart enumeration.", retryable: true)
        case .retainedStateLimit:
            return refusal(code: "cursor_unavailable", message: "A memory-list cursor could not be retained; restart enumeration.", retryable: true)
        }
    }

    private func inventoryTooLarge(_ error: InventorySnapshotError) -> JSONValue {
        _ = error
        return refusal(code: "inventory_too_large", message: "The complete authorized memory inventory exceeds the snapshot limit.", retryable: true)
    }

    private func refusal(code: String, message: String, retryable: Bool) -> JSONValue {
        AriaV2Envelope.refusal(
            tool: AriaV2MemoryListRequest.toolName,
            error: .init(code: code, message: message, retryable: retryable,
                         recovery: .object(["action": .string("restart")])) )
    }

    private static func project(_ row: AriaV2MemoryListRow) -> JSONValue {
        var value = row.projection
        value["memory_id"] = .string(AriaV2ArgumentDecoder.canonicalUUID(row.memoryID))
        return .object(value)
    }

    private static func revision(
        scope: AriaV2MemoryListCursorSession.Scope,
        authorization: AriaV2MemoryListAuthorization,
        snapshot: AriaV2MemoryListSnapshot,
        rows: [AriaV2MemoryListRow]
    ) -> String {
        let material: JSONValue = .object([
            "authorization": .object([
                "authorization_generation": .string(snapshot.authorizationGeneration),
                "caller_binding": .string(authorization.callerID),
                "context_id": .string(authorization.contextID),
                "policy_version": .string(authorization.policyVersion),
            ]),
            "estate_id": .string(AriaV2ArgumentDecoder.canonicalUUID(scope.estateID)),
            "revision_version": .string("moot_memory_list_revision_v1"),
            "rows": .array(rows.map { row in
                .object([
                    "ancestry_ids": .array(row.ancestryIDs.map { .string(AriaV2ArgumentDecoder.canonicalUUID($0)) }),
                    "ancestry_names": .array(row.ancestryNames.map(JSONValue.string)),
                    "eligibility": .string(row.eligibilityState),
                    "memory_id": .string(AriaV2ArgumentDecoder.canonicalUUID(row.memoryID)),
                    "projection": .object(row.projection),
                    "visibility": .string(row.visibilityState),
                ])
            }),
            "scope": .object([
                "filter": scope.filter.map(JSONValue.string) ?? .null,
                "order": .string(scope.order),
                "room": scope.room.map(JSONValue.string) ?? .null,
                "wing": .string(scope.wing),
            ]),
            "total": .integer(Int64(rows.count)),
        ])
        let canonical = Self.canonicalJSON(material)
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalJSON(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value):
            let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        case .array(let values): return "[\(values.map(canonicalJSON).joined(separator: ","))]"
        case .object(let values):
            return "{\(values.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }).map { "\(canonicalJSON(.string($0))):\(canonicalJSON(values[$0]!))" }.joined(separator: ","))}"
        }
    }

    private static func uuidBytes(_ uuid: UUID) -> [UInt8] {
        let value = uuid.uuid
        return [value.0, value.1, value.2, value.3, value.4, value.5, value.6, value.7,
                value.8, value.9, value.10, value.11, value.12, value.13, value.14, value.15]
    }
}
