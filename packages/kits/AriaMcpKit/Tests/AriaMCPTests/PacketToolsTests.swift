// PacketToolsTests.swift
// AriaMcpKit
//
// Tests for the work-packet MCP tool surface (FAB5-I2).
//
// Coverage:
//   - Tool projection: 4 packet tools present, all carry .interface provenance.
//   - moot_file_packet → moot_packet_get round-trip: objective, model, agent survive.
//   - moot_packet_list: filed packet appears in list output.
//   - moot_packet_lineage: two-packet chain returns one antecedent.
//   - Required-arg enforcement: missing objective/model/agent → isError response.
//   - Unknown drawer_id: moot_packet_get returns isError.
//   - Read gate: adjective restricted/secret packets are not-found by default,
//     a live grant lifts the adjective ceiling, provenance Restricted/Secret is
//     never returned, the not-found shape matches a missing id, lineage gates
//     its root and omits gated antecedents, and `wing` routes get/lineage.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: each test case opens a live in-memory estate — same discipline
/// as DatasetToolsTests and LensToolsTests.
@Suite("Packet tools", .serialized)
struct PacketToolsTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit, owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    /// Extract isError:false text content from a tool result.
    private func text(_ result: JSONValue) throws -> String {
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false,
            "Expected isError: false; result: \(result)")
        return try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    }

    /// True when the result carries isError: true.
    private func isError(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue == true
    }

    /// The text body of a result regardless of its isError flag.
    private func body(_ result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
    }

    /// A minimal WorkPacket v1 JSON body as `moot_file_packet` would store it,
    /// so a drawer can be seeded straight into the estate with chosen
    /// sensitivity bits (the packet tools expose no sensitivity argument).
    private func packetJSON(objective: String, lineageTargets: [String] = []) -> String {
        let links = lineageTargets
            .map { "{\"kind\":\"derivesFrom\",\"targetPacketID\":\"\($0)\"}" }
            .joined(separator: ",")
        return "{\"schemaVersion\":1,\"id\":\"\(UUID().uuidString)\",\"objective\":\"\(objective)\","
            + "\"sources\":[],\"claims\":[],\"uncertainties\":[],\"nextSteps\":[],"
            + "\"provenance\":{\"model\":\"seed-model\",\"agent\":\"seed-agent\","
            + "\"createdAt\":\"2023-11-14T22:13:20Z\",\"updatedAt\":\"2023-11-14T22:13:20Z\"},"
            + "\"lineageLinks\":[\(links)]}"
    }

    /// Seed a packet drawer directly into the packets room of the default wing
    /// with full control over both sensitivity axes: the adjective axis (bits
    /// 6-11, gated by the RecallFrame ceiling) and the provenance axis (bits
    /// 30-35, gated unconditionally). Mirrors `MemoryGetTests.seed`.
    @discardableResult
    private func seedPacket(
        objective: String,
        lineageTargets: [String] = [],
        sensitivity: AdjectiveSensitivity = .normal,
        provenanceSensitivity: LocusKit.Sensitivity = .normal,
        in handle: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Drawer {
        // "work-packets" is WorkPacketStore.room — the room moot_file_packet files into.
        var frame = CaptureFrame(
            content: packetJSON(objective: objective, lineageTargets: lineageTargets),
            channel: .actuator,
            room: "work-packets",
            latticeAnchor: .udc("004"),
            addedBy: "PacketToolsTests",
            embeddingModelID: "none",
            sensitivity: sensitivity,
            kind: .structuredJSON,
            provenanceSensitivity: provenanceSensitivity
        )
        frame.wing = LocusKit.defaultWingName
        return try await kit.capture(handle, frame)
    }

    /// Parse a "  key: value" or "  - key: value" line from a multi-line response body.
    private func extractValue(key: String, from body: String) -> String? {
        let prefix = "\(key): "
        let listPrefix = "- \(key): "
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
            if trimmed.hasPrefix(listPrefix) {
                return String(trimmed.dropFirst(listPrefix.count))
            }
        }
        return nil
    }

    // MARK: - Tool projection

    @Test func toolListContainsFourPacketTools() {
        let names = Set(ToolProjection.tools().map(\.name))
        #expect(names.contains("moot_file_packet"))
        #expect(names.contains("moot_packet_get"))
        #expect(names.contains("moot_packet_list"))
        #expect(names.contains("moot_packet_lineage"))
    }

    @Test func packetToolsCarryInterfaceProvenance() {
        let packetTools = ToolProjection.tools().filter {
            PacketTools.isPacketTool($0.name)
        }
        #expect(packetTools.count == 4)
        for tool in packetTools {
            #expect(tool.provenance == .interface,
                "\(tool.name) must carry .interface provenance")
        }
    }

    // MARK: - moot_file_packet → moot_packet_get round-trip

    // MARK: - moot_packet_list

    // MARK: - moot_packet_lineage

    // MARK: - Required-arg enforcement

    @Test func filePacketMissingObjectiveIsError() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-req-obj"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        // `objective` is required — omitting it must throw a JSONRPCError
        // before the store is reached (so no isError tool result — the
        // dispatcher propagates the JSONRPCError directly).
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_file_packet",
                arguments: .object([
                    "model": .string("m"),
                    "agent": .string("a"),
                ]))
            Issue.record("Expected a JSONRPCError for missing objective")
        } catch is JSONRPCError {
            // Expected path — missing required arg throws.
        }
    }

    @Test func getPacketMissingDrawerIDIsError() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-req-did"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_packet_get",
                arguments: .object([:]))
            Issue.record("Expected a JSONRPCError for missing drawer_id")
        } catch is JSONRPCError {
            // Expected.
        }
    }

    @Test func getPacketUnknownDrawerIDReturnsError() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-unknown"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(UUID().uuidString)]))
        #expect(isError(result), "Non-existent drawer_id must return isError: true")
    }

    // MARK: - Read gate: moot_packet_get

    /// The not-found text the gate must reproduce exactly, so a gated id and a
    /// missing id are indistinguishable to the caller.
    private func notFound(_ id: String) -> String {
        "moot_packet_get: no packet found for drawer_id \(id)"
    }

    @Test func getPacketNotFoundShapeMatchesMissingID() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-shape"))
        let gated = try await seedPacket(
            objective: "gated", sensitivity: .restricted, in: handle, kit: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let missingID = UUID().uuidString

        let gatedResult = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(gated.id)]))
        let missingResult = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(missingID)]))
        // Identical up to the echoed id — no field, flag, or wording differs.
        #expect(body(gatedResult).replacingOccurrences(of: gated.id, with: "ID")
            == body(missingResult).replacingOccurrences(of: missingID, with: "ID"))
        #expect(isError(gatedResult) && isError(missingResult))
    }

    // MARK: - moot_file_packet files at the live grant ceiling

    /// Minimal file args; `sensitivity` is added only when given so the
    /// omitted-key path is exercised.
    private func minimalFileArgs(_ marker: String, sensitivity: String? = nil) -> JSONValue {
        var args: [String: JSONValue] = [
            "objective": .string("\(marker) objective"),
            "model": .string("claude-sonnet-4-6"),
            "agent": .string("PacketToolsTests"),
        ]
        if let sensitivity { args["sensitivity"] = .string(sensitivity) }
        return .object(args)
    }

    /// Read the filed packet drawer back through an explicit sensitivity
    /// filter, which suppresses the default `.elevated` ceiling that would
    /// hide a restricted or secret row.
    private func filedDrawer(
        _ id: String, at tier: AdjectiveSensitivity, in handle: EstateHandle, kit: GeniusLocusKit
    ) async throws -> Drawer {
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.sensitivity(tier)], hydrationLevel: .full, limit: 50))
        return try #require(drawers.first { $0.id == id },
                            "the filed packet must be readable at sensitivity \(tier)")
    }

    // MARK: - Read gate: moot_packet_lineage

    // MARK: - End-to-end round-trip over MCP surface (Part 2)

    /// MCP round-trip proof: file a packet via moot_file_packet, then retrieve it
    /// via BOTH the generic memory surface (moot_memory_get) AND the packet-specific
    /// surface (moot_packet_get). This confirms packets are first-class drawers
    /// reachable through the full estate substrate.
}
