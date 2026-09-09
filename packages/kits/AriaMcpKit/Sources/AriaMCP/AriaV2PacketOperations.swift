import AriaMCPWire
import Foundation
import GeniusLocusKit
import LocusKit
import WorkPacketKit

public struct AriaV2PacketFileRequest: Sendable, Equatable {
    public static let toolName = "moot_file_packet"

    public let objective: String
    public let model: String
    public let agent: String
    public let sources: [WorkPacketSource]
    public let claims: [WorkPacketClaim]
    public let uncertainties: [String]
    public let nextSteps: [String]
    public let lineageLinks: [LineageLink]
    public let wing: String?
    public let sensitivity: AdjectiveSensitivity?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: [
            "objective", "model", "agent", "sources", "claims", "uncertainties",
            "next_steps", "lineage_links", "wing", "sensitivity", "estate_id",
        ])
        objective = try Self.nonEmpty(decoder.requireString("objective"), path: "objective")
        model = try Self.nonEmpty(decoder.requireString("model"), path: "model")
        agent = try Self.nonEmpty(decoder.requireString("agent"), path: "agent")
        sources = try Self.sources(decoder.arguments["sources"])
        claims = try Self.claims(decoder.arguments["claims"])
        uncertainties = try Self.stringArray(decoder.arguments["uncertainties"], path: "uncertainties")
        nextSteps = try Self.stringArray(decoder.arguments["next_steps"], path: "next_steps")
        lineageLinks = try Self.links(decoder.arguments["lineage_links"])
        if let rawWing = try decoder.optionalString("wing") {
            wing = try Self.nonEmpty(rawWing, path: "wing")
        } else {
            wing = nil
        }
        if let rawSensitivity = try decoder.optionalString("sensitivity") {
            sensitivity = try Self.sensitivity(rawSensitivity)
        } else {
            sensitivity = nil
        }
        estateID = try decoder.optionalUUID("estate_id")
    }

    fileprivate static func nonEmpty(_ value: String, path: String) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AriaV2InvalidArgument(path: path, message: "Argument '\(path)' must not be empty.").jsonRPCError
        }
        return value
    }

    private static func stringArray(_ value: JSONValue?, path: String) throws -> [String] {
        guard let value else { return [] }
        guard let array = value.arrayValue else {
            throw AriaV2InvalidArgument(path: path, message: "Argument '\(path)' must be an array.").jsonRPCError
        }
        return try array.enumerated().map { index, item in
            guard let string = item.stringValue else {
                throw AriaV2InvalidArgument(path: "\(path)[\(index)]", message: "Array entries must be strings.").jsonRPCError
            }
            return try nonEmpty(string, path: "\(path)[\(index)]")
        }
    }

    private static func sources(_ value: JSONValue?) throws -> [WorkPacketSource] {
        guard let value else { return [] }
        guard let array = value.arrayValue else {
            throw AriaV2InvalidArgument(path: "sources", message: "Argument 'sources' must be an array.").jsonRPCError
        }
        return try array.enumerated().map { index, item in
            let decoder = try AriaV2ArgumentDecoder(item, allowedKeys: ["description", "kind", "uri"])
            let description = try nonEmpty(decoder.requireString("description"), path: "sources[\(index)].description")
            let kind = try decoder.optionalString("kind") ?? "drawer"
            return WorkPacketSource(
                description: description,
                uri: try decoder.optionalString("uri"),
                kind: try nonEmpty(kind, path: "sources[\(index)].kind"))
        }
    }

    private static func claims(_ value: JSONValue?) throws -> [WorkPacketClaim] {
        guard let value else { return [] }
        guard let array = value.arrayValue else {
            throw AriaV2InvalidArgument(path: "claims", message: "Argument 'claims' must be an array.").jsonRPCError
        }
        return try array.enumerated().map { index, item in
            let decoder = try AriaV2ArgumentDecoder(item, allowedKeys: ["statement", "confidence", "supportingSourceIDs"])
            let statement = try nonEmpty(decoder.requireString("statement"), path: "claims[\(index)].statement")
            let confidence: Double
            if let value = decoder.arguments["confidence"] {
                switch value {
                case .integer(let integer): confidence = Double(integer)
                case .double(let double): confidence = double
                default:
                    throw AriaV2InvalidArgument(path: "claims[\(index)].confidence", message: "Argument 'confidence' must be a number.").jsonRPCError
                }
            } else {
                confidence = 1.0
            }
            guard confidence.isFinite, (0.0...1.0).contains(confidence) else {
                throw AriaV2InvalidArgument(path: "claims[\(index)].confidence", message: "Argument 'confidence' must be between 0 and 1.").jsonRPCError
            }
            let supporting = try stringArray(decoder.arguments["supportingSourceIDs"], path: "claims[\(index)].supportingSourceIDs")
            return WorkPacketClaim(statement: statement, confidence: confidence, supportingSourceIDs: supporting)
        }
    }

    private static func links(_ value: JSONValue?) throws -> [LineageLink] {
        guard let value else { return [] }
        guard let array = value.arrayValue else {
            throw AriaV2InvalidArgument(path: "lineage_links", message: "Argument 'lineage_links' must be an array.").jsonRPCError
        }
        return try array.enumerated().map { index, item in
            let decoder = try AriaV2ArgumentDecoder(item, allowedKeys: ["kind", "targetPacketID"])
            guard let kind = LineageLinkKind(rawValue: try decoder.requireString("kind")) else {
                throw AriaV2InvalidArgument(path: "lineage_links[\(index)].kind", message: "Argument 'kind' must be derivesFrom or respondsTo.").jsonRPCError
            }
            let target = try decoder.requireUUID("targetPacketID")
            // Swift estate storage preserves Foundation's uppercase UUID spelling.
            // Keep that internal representation so frame-gated reads can resolve
            // the target, then canonicalize every public v2 projection below.
            return LineageLink(kind: kind, targetPacketID: target.uuidString)
        }
    }

    private static func sensitivity(_ raw: String) throws -> AdjectiveSensitivity {
        switch raw {
        case "normal": return .normal
        case "elevated": return .elevated
        case "restricted": return .restricted
        case "secret": return .secret
        default:
            throw AriaV2InvalidArgument(path: "sensitivity", message: "Unknown sensitivity: \(raw).").jsonRPCError
        }
    }
}

public struct AriaV2PacketGetRequest: Sendable, Equatable {
    public static let toolName = "moot_packet_get"
    public let drawerID: UUID
    public let wing: String?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["drawer_id", "wing", "estate_id"])
        drawerID = try decoder.requireUUID("drawer_id")
        if let rawWing = try decoder.optionalString("wing") {
            wing = try AriaV2PacketFileRequest.nonEmpty(rawWing, path: "wing")
        } else {
            wing = nil
        }
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2PacketListRequest: Sendable, Equatable {
    public static let toolName = "moot_packet_list"
    public let limit: Int
    public let wing: String?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["limit", "wing", "estate_id"])
        if let raw = try decoder.optionalInteger("limit") {
            guard raw >= 1, raw <= 100 else {
                throw AriaV2InvalidArgument(path: "limit", message: "Argument 'limit' must be between 1 and 100.").jsonRPCError
            }
            limit = Int(raw)
        } else {
            limit = 20
        }
        if let rawWing = try decoder.optionalString("wing") {
            wing = try AriaV2PacketFileRequest.nonEmpty(rawWing, path: "wing")
        } else {
            wing = nil
        }
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2PacketLineageRequest: Sendable, Equatable {
    public static let toolName = "moot_packet_lineage"
    public let drawerID: UUID
    public let maxDepth: Int
    public let wing: String?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["drawer_id", "max_depth", "wing", "estate_id"])
        drawerID = try decoder.requireUUID("drawer_id")
        if let raw = try decoder.optionalInteger("max_depth") {
            guard raw >= 1, raw <= 50 else {
                throw AriaV2InvalidArgument(path: "max_depth", message: "Argument 'max_depth' must be between 1 and 50.").jsonRPCError
            }
            maxDepth = Int(raw)
        } else {
            maxDepth = 10
        }
        if let rawWing = try decoder.optionalString("wing") {
            wing = try AriaV2PacketFileRequest.nonEmpty(rawWing, path: "wing")
        } else {
            wing = nil
        }
        estateID = try decoder.optionalUUID("estate_id")
    }
}

/// Direct v2 adapter over WorkPacketKit. WorkPacketStore owns capture fidelity:
/// actuator provenance, the work-packets room, UDC 004, addedBy WorkPacketKit,
/// embedding model none, structuredJSON, event time, sensitivity, and
/// best-effort lineage tunnel filing all remain in the lower kit.
public struct AriaV2PacketOperations: Sendable {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle
    public let context: AriaV2MemoryOperationContext
    public let grantCeiling: AdjectiveSensitivity?

    public init(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        context: AriaV2MemoryOperationContext,
        grantCeiling: AdjectiveSensitivity?
    ) {
        self.kit = kit
        self.handle = handle
        self.context = context
        self.grantCeiling = grantCeiling
    }

    public func file(_ request: AriaV2PacketFileRequest) async throws -> JSONValue {
        try validateEstate(request.estateID)
        let sensitivity: AdjectiveSensitivity
        if let requested = request.sensitivity {
            if let grantCeiling, requested.rawValue < grantCeiling.rawValue {
                return refusal(
                    tool: AriaV2PacketFileRequest.toolName,
                    code: "sensitivity_below_ceiling",
                    message: ToolDispatcher.sensitivityBelowCeilingMessage(requested: requested, ceiling: grantCeiling))
            }
            sensitivity = requested
        } else {
            sensitivity = grantCeiling ?? .normal
        }

        let now = context.now()
        let packet = WorkPacket(
            id: UUID().uuidString.lowercased(),
            objective: request.objective,
            sources: request.sources,
            claims: request.claims,
            uncertainties: request.uncertainties,
            nextSteps: request.nextSteps,
            provenance: .init(model: request.model, agent: request.agent, createdAt: now, updatedAt: now),
            lineageLinks: request.lineageLinks)
        let store = try await store(wing: request.wing)
        let drawerID = try await store.store(packet, now: now, sensitivity: sensitivity)
        guard let drawerUUID = UUID(uuidString: drawerID) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "The estate returned a non-UUID packet drawer identifier.")
        }
        let data: JSONValue = .object([
            "drawer_id": .string(Self.id(drawerUUID)),
            "packet_id": .string(Self.id(UUID(uuidString: packet.id)!)),
            "schema_version": .integer(Int64(packet.schemaVersion)),
            "objective": .string(packet.objective),
            "sources": .integer(Int64(packet.sources.count)),
            "claims": .integer(Int64(packet.claims.count)),
            "uncertainties": .integer(Int64(packet.uncertainties.count)),
            "next_steps": .integer(Int64(packet.nextSteps.count)),
            "lineage_links": .integer(Int64(packet.lineageLinks.count)),
            "sensitivity": .string(ToolDispatcher.sensitivityArgumentName(sensitivity)),
        ])
        return success(tool: AriaV2PacketFileRequest.toolName, effect: .write, data: data, text: "Filed work packet \(Self.id(drawerUUID)).")
    }

    public func get(_ request: AriaV2PacketGetRequest) async throws -> JSONValue {
        try validateEstate(request.estateID)
        guard let packetStore = try await storeForRead(drawerID: request.drawerID, wing: request.wing) else {
            return notFound(tool: AriaV2PacketGetRequest.toolName)
        }
        var packet: WorkPacket?
        for drawerID in AriaV2ArgumentDecoder.storageIdentitySpellings(request.drawerID) where packet == nil {
            packet = try await fetchPacket(packetStore, drawerID: drawerID)
        }
        guard let packet else { return notFound(tool: AriaV2PacketGetRequest.toolName) }
        return success(tool: AriaV2PacketGetRequest.toolName, effect: .read, data: .object([
            "packet": Self.packet(packet, drawerID: request.drawerID),
        ]), text: "Fetched authorized work packet \(Self.id(request.drawerID)).")
    }

    public func list(_ request: AriaV2PacketListRequest) async throws -> JSONValue {
        try validateEstate(request.estateID)
        let client = try await client()
        // Resolve the v2 packet scope after loading so Rust's lowercase node
        // IDs can use the bounded physical-spelling node lookup. Legacy name
        // filters retain their typed UUID behavior.
        let frame = RecallFrame(
            filterChain: [.currentlyBelieve, .sensitivityAtMost(context.maximumSensitivity)],
            hydrationLevel: .full, ordering: .byCaptureTimeDesc)
        let drawers = try await client.listDrawers(frame)
        let nodeNames = try await kit.resolveNodeNames(
            handle, parentNodeIds: Array(Set(drawers.map(\.parentNodeId))),
            preservePhysicalUUIDSpellings: true)
        let wing = request.wing ?? LocusKit.defaultWingName
        let decoder = WorkPacketStore.portableJSONDecoder()
        let packets = drawers.filter { drawer in
            let rawSensitivity = (drawer.provenance >> 30) & 0x3f
            guard rawSensitivity == 0 || rawSensitivity == 16,
                  let names = nodeNames[drawer.parentNodeId] else { return false }
            return names.wing == wing && names.room == WorkPacketStore.room
        }.compactMap { drawer -> JSONValue? in
            guard let drawerID = UUID(uuidString: drawer.id),
                  let data = drawer.content.data(using: .utf8),
                  let packet = try? decoder.decode(WorkPacket.self, from: data) else { return nil }
            return Self.compactPacket(packet, drawerID: drawerID)
        }
        let limited = Array(packets.prefix(request.limit))
        return success(tool: AriaV2PacketListRequest.toolName, effect: .read, data: .object([
            "packets": .array(limited), "total": .integer(Int64(limited.count)),
        ]), text: "Listed \(limited.count) authorized work packets.")
    }

    public func lineage(_ request: AriaV2PacketLineageRequest) async throws -> JSONValue {
        try validateEstate(request.estateID)
        guard let packetStore = try await storeForRead(drawerID: request.drawerID, wing: request.wing) else {
            return notFound(tool: AriaV2PacketLineageRequest.toolName)
        }
        var storedDrawerID: String?
        for drawerID in AriaV2ArgumentDecoder.storageIdentitySpellings(request.drawerID) where storedDrawerID == nil {
            if try await fetchPacket(packetStore, drawerID: drawerID) != nil {
                storedDrawerID = drawerID
            }
        }
        guard let storedDrawerID else {
            return notFound(tool: AriaV2PacketLineageRequest.toolName)
        }
        let estateClient = try await client()
        let graph = LineageGraph(client: estateClient)
        let traced = try await graph.trace(from: storedDrawerID, maxDepth: request.maxDepth)
        let admissibleDrawers = try await packetStore.fetchAdmissibleDrawers(
            ids: traced, ceiling: .sensitivityAtMost(context.maximumSensitivity))
        let admissible = Set(admissibleDrawers.compactMap { UUID(uuidString: $0.id) })
        let antecedents = traced.compactMap(UUID.init(uuidString:)).filter { admissible.contains($0) }
        return success(tool: AriaV2PacketLineageRequest.toolName, effect: .read, data: .object([
            "root": .string(Self.id(request.drawerID)),
            "antecedents": .array(antecedents.map { .string(Self.id($0)) }),
            "count": .integer(Int64(antecedents.count)),
        ]), text: "Traced \(antecedents.count) authorized packet antecedents.")
    }

    private func validateEstate(_ requested: UUID?) throws {
        guard requested == nil || requested == context.estateID,
              context.estateID == handle.estateUUID else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "The requested estate is not available to this caller.")
        }
    }

    private func client() async throws -> EstateAdapter { EstateAdapter(try await kit.estate(for: handle)) }

    private func storeForRead(drawerID: UUID, wing: String?) async throws -> WorkPacketStore? {
        if let wing { return try await store(wing: wing) }
        let estateClient = try await client()
        let frame = RecallFrame(filterChain: [
            .currentlyBelieve, .inRoom(WorkPacketStore.room),
            .sensitivityAtMost(context.maximumSensitivity),
        ], hydrationLevel: .full)
        let drawers = try await estateClient.getDrawers(
            ids: AriaV2ArgumentDecoder.storageIdentitySpellings(drawerID), matchingFrame: frame,
            preservePhysicalUUIDSpellings: true)
        guard let drawer = drawers.first(where: {
            let rawSensitivity = ($0.provenance >> 30) & 0x3f
            return rawSensitivity == 0 || rawSensitivity == 16
        }) else { return nil }
        let names = try await kit.resolveNodeNames(
            handle, parentNodeIds: [drawer.parentNodeId],
            preservePhysicalUUIDSpellings: true)
        guard let actualWing = names[drawer.parentNodeId]?.wing, !actualWing.isEmpty else { return nil }
        return try await store(wing: actualWing)
    }

    private func store(wing: String?) async throws -> WorkPacketStore {
        WorkPacketStore(
            client: try await client(), wing: wing ?? LocusKit.defaultWingName,
            allowsFractionalSeconds: true, preservePhysicalUUIDSpellings: true)
    }

    /// A malformed stored packet is unavailable on the typed v2 boundary.
    /// It must not become an existence oracle distinct from an absent or
    /// privacy-gated drawer; operational read failures still propagate.
    private func fetchPacket(_ store: WorkPacketStore, drawerID: String) async throws -> WorkPacket? {
        do {
            return try await store.fetch(
                drawerID: drawerID, ceiling: .sensitivityAtMost(context.maximumSensitivity))
        } catch is DecodingError {
            return nil
        }
    }

    private func success(tool: String, effect: AriaV2OperationEffect, data: JSONValue, text: String) -> JSONValue {
        AriaV2Envelope.success(tool: tool, effect: effect, data: data, meta: ["completeness": .string("incomplete")], compactText: text)
    }

    private func refusal(tool: String, code: String, message: String) -> JSONValue {
        AriaV2Envelope.refusal(tool: tool, error: .init(code: code, message: message, retryable: false))
    }

    private func notFound(tool: String) -> JSONValue {
        refusal(tool: tool, code: "packet_not_found", message: "No authorized work packet matched the requested drawer ID.")
    }

    private static func id(_ value: UUID) -> String { AriaV2ArgumentDecoder.canonicalUUID(value) }

    private static func packet(_ packet: WorkPacket, drawerID: UUID) -> JSONValue {
        .object([
            "drawer_id": .string(id(drawerID)),
            "packet_id": .string(canonicalPacketID(packet.id)),
            "schema_version": .integer(Int64(packet.schemaVersion)),
            "future_schema": .bool(packet.schemaVersion > WorkPacket.currentSchemaVersion),
            "objective": .string(packet.objective),
            "sources": .array(packet.sources.map(source)),
            "claims": .array(packet.claims.map(claim)),
            "uncertainties": .array(packet.uncertainties.map(JSONValue.string)),
            "next_steps": .array(packet.nextSteps.map(JSONValue.string)),
            "provenance": .object([
                "model": .string(packet.provenance.model),
                "agent": .string(packet.provenance.agent),
                "created_at": .string(iso8601(packet.provenance.createdAt)),
                "updated_at": .string(iso8601(packet.provenance.updatedAt)),
            ]),
            "lineage_links": .array(packet.lineageLinks.map(link)),
        ])
    }

    private static func compactPacket(_ packet: WorkPacket, drawerID: UUID) -> JSONValue {
        .object([
            "drawer_id": .string(id(drawerID)),
            "packet_id": .string(canonicalPacketID(packet.id)),
            "objective": .string(packet.objective),
            "model": .string(packet.provenance.model),
            "agent": .string(packet.provenance.agent),
            "lineage_count": .integer(Int64(packet.lineageLinks.count)),
        ])
    }

    private static func source(_ source: WorkPacketSource) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(canonicalPacketID(source.id)),
            "description": .string(source.description),
            "kind": .string(source.kind),
        ]
        if let uri = source.uri { value["uri"] = .string(uri) }
        return .object(value)
    }

    private static func claim(_ claim: WorkPacketClaim) -> JSONValue {
        .object([
            "id": .string(canonicalPacketID(claim.id)),
            "statement": .string(claim.statement),
            "confidence": .double(claim.confidence),
            "supporting_source_ids": .array(claim.supportingSourceIDs.map { .string(canonicalPacketID($0)) }),
        ])
    }

    private static func link(_ link: LineageLink) -> JSONValue {
        .object([
            "kind": .string(link.kind.rawValue),
            "target_packet_id": .string(canonicalPacketID(link.targetPacketID)),
        ])
    }

    private static func canonicalPacketID(_ raw: String) -> String {
        UUID(uuidString: raw).map(id) ?? raw
    }

    private static func iso8601(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
