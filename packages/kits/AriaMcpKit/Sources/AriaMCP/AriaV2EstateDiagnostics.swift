import AriaMCPWire
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import SubstrateTypes

/// The context that binds every v2 estate diagnostic to one caller, session,
/// clock, and selected estate.  The service does not borrow mutable dispatcher
/// state and never treats a caller-supplied estate as an authorization grant.
public struct AriaV2EstateDiagnosticsContext: Sendable {
    public let estateID: UUID
    public let estateName: String
    public let callerID: String
    public let serverIdentity: String
    public let sessionID: String
    public let buildSerial: String
    public let now: @Sendable () -> Date
    public let accessGate: any AriaV2EstateDiagnosticsAccessGate

    public init(
        estateID: UUID,
        estateName: String,
        callerID: String,
        serverIdentity: String,
        sessionID: String,
        buildSerial: String,
        now: @escaping @Sendable () -> Date = { Date() },
        accessGate: any AriaV2EstateDiagnosticsAccessGate = AriaV2AllowEstateDiagnosticsAccess()
    ) {
        self.estateID = estateID
        self.estateName = estateName
        self.callerID = callerID
        self.serverIdentity = serverIdentity
        self.sessionID = sessionID
        self.buildSerial = buildSerial
        self.now = now
        self.accessGate = accessGate
    }
}

public enum AriaV2EstateDiagnosticOperation: String, Sendable, Equatable {
    case estatePing = "moot_estate_ping"
    case estateStatus = "moot_estate_status"
    case estateMap = "moot_estate_map"
    case drainStatus = "moot_drain_status"
    case rebuildStatus = "moot_rebuild_status"
    case timingReport = "moot_timing_report"
}

/// Admission remains outside data collection.  A host can bind this to the
/// selected caller/session policy without exposing a legacy text runner.
public protocol AriaV2EstateDiagnosticsAccessGate: Sendable {
    func admit(
        _ operation: AriaV2EstateDiagnosticOperation,
        context: AriaV2EstateDiagnosticsContext
    ) async -> AriaV2OperationalRefusal?
}

public struct AriaV2AllowEstateDiagnosticsAccess: AriaV2EstateDiagnosticsAccessGate {
    public init() {}

    public func admit(
        _ operation: AriaV2EstateDiagnosticOperation,
        context: AriaV2EstateDiagnosticsContext
    ) async -> AriaV2OperationalRefusal? {
        _ = operation
        _ = context
        return nil
    }
}

/// The shared request shape frozen in the Mission 02 fixture.  These tools
/// accept only an optional selected-estate UUID; timing windows are owned by
/// the provider, not silently inherited from the legacy `since_ms` runner.
public struct AriaV2EstateDiagnosticsRequest: Sendable, Equatable {
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["estate_id"])
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2EstatePingData: Sendable, Equatable {
    public let estateID: UUID
    public let estateName: String
    public let state: String
    public let buildSerial: String
}

public struct AriaV2EstateStatusData: Sendable, Equatable {
    public let estateID: UUID
    public let estateName: String
    public let memoryCount: Int
    public let factCount: Int
    public let drains: [AriaV2DrainStatusEntry]
}

public struct AriaV2EstateMapRoom: Sendable, Equatable {
    public let name: String
    public let memoryCount: Int
}

public struct AriaV2EstateMapWing: Sendable, Equatable {
    public let name: String
    public let rooms: [AriaV2EstateMapRoom]
}

public struct AriaV2EstateMapData: Sendable, Equatable {
    public let estateID: UUID
    public let wings: [AriaV2EstateMapWing]
}

public struct AriaV2DrainStatusEntry: Sendable, Equatable {
    public let name: String
    public let state: String
    public let pending: Int
}

public struct AriaV2DrainStatusData: Sendable, Equatable {
    public let drains: [AriaV2DrainStatusEntry]
}

public struct AriaV2RebuildStatusData: Sendable, Equatable {
    public let state: String
}

public struct AriaV2TimingReportData: Sendable, Equatable {
    public let sinceMilliseconds: Int64
    public let watermarkMilliseconds: Int64
    public let truncated: Bool
}

public enum AriaV2EstatePingResult: Sendable, Equatable {
    case mounted(AriaV2EstatePingData)
    case refusal(AriaV2OperationalRefusal)
}

/// Injection seam for the lower estate APIs.  Each method returns an
/// operation-specific value, so ARIA never reparses a legacy tool response.
public protocol AriaV2EstateDiagnosticsProvider: Sendable {
    func ping(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2EstatePingResult
    func status(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2EstateStatusData
    func map(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2EstateMapData
    func drains(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2DrainStatusData
    func rebuild(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2RebuildStatusData
    func timing(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2TimingReportData
}

/// Direct adapter for the public GeniusLocusKit and NeuronKit read APIs.
/// It deliberately does not call `ToolDispatcher` or inspect rendered text.
public struct AriaV2GeniusLocusEstateDiagnosticsProvider: AriaV2EstateDiagnosticsProvider {
    public static let timingWindowMaxEvents = 262_144

    private let kit: GeniusLocusKit
    private let handle: EstateHandle

    public init(kit: GeniusLocusKit, handle: EstateHandle) {
        self.kit = kit
        self.handle = handle
    }

    public func ping(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2EstatePingResult {
        try validate(context)
        switch await kit.mountState(for: handle) {
        case .mounted:
            return .mounted(AriaV2EstatePingData(
                estateID: handle.estateUUID,
                estateName: handle.estateName,
                state: "mounted",
                buildSerial: context.buildSerial))
        case .quiesced, .draining:
            return .refusal(.init(
                code: "estate_unavailable",
                message: "The selected estate is quiesced and not accepting new work.",
                retryable: false))
        case .unmounted, .none:
            return .refusal(.init(
                code: "estate_unavailable",
                message: "The selected estate is not mounted; re-open or re-provision it.",
                retryable: true))
        }
    }

    public func status(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2EstateStatusData {
        try validate(context)
        let estate = try await kit.estate(for: handle)
        let drawers = try await estate.allDrawers()
        let visible = drawers.filter { $0.tombstonedAt == nil && $0.adjectiveSensitivity.isBulkExportable }
        let active = visible.filter {
            let stateRaw = UInt8($0.adjectiveBitmap & 0x3F)
            return RowState.cluster(ofRawState: stateRaw) == .some(.a)
        }
        let facts = try await kit.recallKGFacts(handle)
        let drains = try await typedDrains()
        return AriaV2EstateStatusData(
            estateID: handle.estateUUID,
            estateName: handle.estateName,
            memoryCount: active.count,
            factCount: facts.count,
            drains: drains)
    }

    public func map(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2EstateMapData {
        try validate(context)
        let estate = try await kit.estate(for: handle)
        let drawers = try await estate.allDrawers().filter {
            $0.tombstonedAt == nil && $0.adjectiveSensitivity.isBulkExportable
        }
        let names = try await estate.resolveNodeNames(parentNodeIds: drawers.map(\.parentNodeId))
        var counts: [String: [String: Int]] = [:]
        for drawer in drawers {
            let location = names[drawer.parentNodeId]
            let wing = location?.wing ?? ""
            let room = location?.room ?? ""
            counts[wing, default: [:]][room, default: 0] += 1
        }
        let wings = counts.keys.sorted().map { wing in
            AriaV2EstateMapWing(
                name: wing,
                rooms: (counts[wing] ?? [:]).keys.sorted().map { room in
                    AriaV2EstateMapRoom(name: room, memoryCount: counts[wing]?[room] ?? 0)
                })
        }
        return AriaV2EstateMapData(estateID: handle.estateUUID, wings: wings)
    }

    public func drains(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2DrainStatusData {
        try validate(context)
        return AriaV2DrainStatusData(drains: try await typedDrains())
    }

    public func rebuild(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2RebuildStatusData {
        try validate(context)
        return AriaV2RebuildStatusData(state: await kit.derivedRebuildActive(for: handle) ? "running" : "idle")
    }

    public func timing(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2TimingReportData {
        try validate(context)
        let (events, truncated) = try await timingEvents()
        let derivation = deriveTimings(events: events, sinceExclusiveMs: 0)
        return AriaV2TimingReportData(
            sinceMilliseconds: 0,
            watermarkMilliseconds: derivation.watermarkMs,
            truncated: truncated)
    }

    private func validate(_ context: AriaV2EstateDiagnosticsContext) throws {
        guard context.estateID == handle.estateUUID else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "The selected estate is not available to this diagnostics provider.")
        }
    }

    private func timingEvents() async throws -> ([TimingAuditEvent], Bool) {
        var events: [TimingAuditEvent] = []
        var cursor: HLC?
        var truncated = false
        let pageSize = 4_096
        while events.count < Self.timingWindowMaxEvents {
            let page = try await kit.auditEvents(handle, after: cursor, limit: pageSize)
            let remaining = Self.timingWindowMaxEvents - events.count
            events.append(contentsOf: page.prefix(remaining).map {
                TimingAuditEvent(
                    verb: $0.verb,
                    physicalTimeMs: $0.hlc.physicalTime,
                    rowID: $0.rowId,
                    reason: $0.reason)
            })
            if page.count > remaining {
                truncated = true
                break
            }
            guard page.count == pageSize, let last = page.last else { break }
            cursor = last.hlc
        }
        if events.count == Self.timingWindowMaxEvents { truncated = true }
        return (events, truncated)
    }

    private func typedDrains() async throws -> [AriaV2DrainStatusEntry] {
        let statuses = try await kit.drainStatuses(handle)
        return statuses.map {
            AriaV2DrainStatusEntry(
                name: $0.name,
                state: $0.isDraining ? "draining" : "idle",
                pending: $0.pending)
        }
    }
}

/// Strict, typed v2 estate diagnostics.  The selected registry/transport
/// owner wires this service later; this file owns no catalog or dispatch path.
public struct AriaV2EstateDiagnostics: Sendable {
    private let provider: any AriaV2EstateDiagnosticsProvider
    private let context: AriaV2EstateDiagnosticsContext

    public init(
        provider: any AriaV2EstateDiagnosticsProvider,
        context: AriaV2EstateDiagnosticsContext
    ) {
        self.provider = provider
        self.context = context
    }

    public func ping(arguments: JSONValue) async throws -> JSONValue {
        let request = try AriaV2EstateDiagnosticsRequest(arguments: arguments)
        try validate(request)
        if let refusal = await context.accessGate.admit(.estatePing, context: context) {
            return AriaV2Envelope.refusal(tool: AriaV2EstateDiagnosticOperation.estatePing.rawValue, error: refusal)
        }
        switch try await provider.ping(context: context) {
        case .mounted(let data):
            return success(.estatePing, data: data.json)
        case .refusal(let refusal):
            return AriaV2Envelope.refusal(tool: AriaV2EstateDiagnosticOperation.estatePing.rawValue, error: refusal)
        }
    }

    public func status(arguments: JSONValue) async throws -> JSONValue {
        try await execute(.estateStatus, arguments: arguments) {
            try await self.provider.status(context: self.context).json
        }
    }

    public func map(arguments: JSONValue) async throws -> JSONValue {
        try await execute(.estateMap, arguments: arguments) {
            try await self.provider.map(context: self.context).json
        }
    }

    public func drainStatus(arguments: JSONValue) async throws -> JSONValue {
        try await execute(.drainStatus, arguments: arguments) {
            try await self.provider.drains(context: self.context).json
        }
    }

    public func rebuildStatus(arguments: JSONValue) async throws -> JSONValue {
        try await execute(.rebuildStatus, arguments: arguments) {
            try await self.provider.rebuild(context: self.context).json
        }
    }

    public func timingReport(arguments: JSONValue) async throws -> JSONValue {
        try await execute(.timingReport, arguments: arguments) {
            try await self.provider.timing(context: self.context).json
        }
    }

    private func execute(
        _ operation: AriaV2EstateDiagnosticOperation,
        arguments: JSONValue,
        body: () async throws -> JSONValue
    ) async throws -> JSONValue {
        let request = try AriaV2EstateDiagnosticsRequest(arguments: arguments)
        try validate(request)
        if let refusal = await context.accessGate.admit(operation, context: context) {
            return AriaV2Envelope.refusal(tool: operation.rawValue, error: refusal)
        }
        return success(operation, data: try await body())
    }

    private func validate(_ request: AriaV2EstateDiagnosticsRequest) throws {
        guard request.estateID == nil || request.estateID == context.estateID else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "The requested estate is not available to this caller.")
        }
    }

    private func success(_ operation: AriaV2EstateDiagnosticOperation, data: JSONValue) -> JSONValue {
        return AriaV2Envelope.success(
            tool: operation.rawValue,
            effect: .read,
            data: data,
            meta: [
                "completeness": .string("incomplete"),
                "server_identity": .string(context.serverIdentity),
                "session_id": .string(context.sessionID),
                "observed_at": .string(Self.timestamp(context.now())),
            ],
            compactText: "\(operation.rawValue) completed for estate \(context.estateID.uuidString.lowercased()).")
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private extension AriaV2EstatePingData {
    var json: JSONValue {
        .object([
            "estate_id": .string(estateID.uuidString.lowercased()),
            "estate_name": .string(estateName),
            "state": .string(state),
            "build_serial": .string(buildSerial),
        ])
    }
}

private extension AriaV2EstateStatusData {
    var json: JSONValue {
        .object([
            "estate_id": .string(estateID.uuidString.lowercased()),
            "estate_name": .string(estateName),
            "memory_count": .integer(Int64(memoryCount)),
            "fact_count": .integer(Int64(factCount)),
            "drains": .array(drains.map { $0.json }),
        ])
    }
}

private extension AriaV2EstateMapData {
    var json: JSONValue {
        .object([
            "estate_id": .string(estateID.uuidString.lowercased()),
            "wings": .array(wings.map { wing in
                .object([
                    "name": .string(wing.name),
                    "rooms": .array(wing.rooms.map {
                        .object(["name": .string($0.name), "memory_count": .integer(Int64($0.memoryCount))])
                    }),
                ])
            }),
        ])
    }
}

private extension AriaV2DrainStatusData {
    var json: JSONValue {
        .object([
            "drains": .array(drains.map { $0.json }),
        ])
    }
}

private extension AriaV2RebuildStatusData {
    var json: JSONValue {
        .object([
            "state": .string(state),
        ])
    }
}

private extension AriaV2DrainStatusEntry {
    var json: JSONValue {
        .object([
            "name": .string(name),
            "state": .string(state),
            "pending": .integer(Int64(pending)),
        ])
    }
}

private extension AriaV2TimingReportData {
    var json: JSONValue {
        .object([
            "since_ms": .integer(sinceMilliseconds),
            "watermark_ms": .integer(watermarkMilliseconds),
            "truncated": .bool(truncated),
        ])
    }
}
