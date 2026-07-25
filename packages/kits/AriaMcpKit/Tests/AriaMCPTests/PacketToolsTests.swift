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

    /// Parse a "  key: value" line from a multi-line response body.
    private func extractValue(key: String, from body: String) -> String? {
        let prefix = "\(key): "
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
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

    @Test func filePacketGetRoundTrip() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-rtrip"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fileArgs: JSONValue = .object([
            "objective": .string("Verify the round-trip serialisation of work packets."),
            "model":     .string("claude-sonnet-4-6"),
            "agent":     .string("PacketToolsTests"),
            "sources": .array([
                .object([
                    "description": .string("AriaMcpKit source tree"),
                    "kind":        .string("file"),
                    "uri":         .string("packages/kits/AriaMcpKit"),
                ])
            ]),
            "claims": .array([
                .object([
                    "statement":  .string("WorkPacket round-trips through the estate."),
                    "confidence": .double(0.95),
                ])
            ]),
            "uncertainties": .array([.string("Edge behaviour under concurrent writers.")]),
            "next_steps":    .array([.string("Expand to concurrent-write test.")]),
        ])

        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_packet",
            arguments: fileArgs)
        let fileBody = try text(fileResult)

        #expect(fileBody.hasPrefix("packet_filed:"),
            "moot_file_packet must return packet_filed: header; got: \(fileBody)")
        #expect(fileBody.contains("sources: 1"))
        #expect(fileBody.contains("claims: 1"))
        #expect(fileBody.contains("uncertainties: 1"))
        #expect(fileBody.contains("next_steps: 1"))

        let drawerID = try #require(extractValue(key: "drawer_id", from: fileBody),
            "packet_filed response must include drawer_id:")
        #expect(!drawerID.isEmpty)

        // Retrieve the packet and confirm objective survives the round-trip.
        let getResult = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(drawerID)]))
        let getBody = try text(getResult)

        #expect(getBody.hasPrefix("packet:"),
            "moot_packet_get must return packet: header; got: \(getBody)")
        #expect(getBody.contains("drawer_id: \(drawerID)"))
        #expect(getBody.contains("Verify the round-trip serialisation of work packets."))
        #expect(getBody.contains("claude-sonnet-4-6"))
        #expect(getBody.contains("PacketToolsTests"))
    }

    // MARK: - moot_packet_list

    @Test func listPacketsContainsFiledPacket() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-list"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File a packet.
        let fileArgs: JSONValue = .object([
            "objective": .string("List-test objective."),
            "model":     .string("test-model"),
            "agent":     .string("test-agent"),
        ])
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_packet",
            arguments: fileArgs)
        #expect(!isError(fileResult), "moot_file_packet must not return isError")

        // List should include the packet.
        let listResult = try await dispatcher.dispatch(
            name: "moot_packet_list",
            arguments: .object([:]))
        let listBody = try text(listResult)

        #expect(listBody.hasPrefix("packets:"),
            "moot_packet_list must return packets: header; got: \(listBody)")
        #expect(listBody.contains("List-test objective."),
            "Listed packets must include the filed packet's objective")
        #expect(listBody.contains("total: 1"))
    }

    // MARK: - moot_packet_lineage

    @Test func packetLineageTwoNodeChain() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-lineage"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File ancestor packet.
        let ancestorResult = try await dispatcher.dispatch(
            name: "moot_file_packet",
            arguments: .object([
                "objective": .string("Ancestor packet."),
                "model":     .string("m1"),
                "agent":     .string("a1"),
            ]))
        let ancestorBody = try text(ancestorResult)
        let ancestorDrawerID = try #require(
            extractValue(key: "drawer_id", from: ancestorBody))

        // File descendant packet that derives from the ancestor.
        let descendantResult = try await dispatcher.dispatch(
            name: "moot_file_packet",
            arguments: .object([
                "objective": .string("Descendant packet."),
                "model":     .string("m2"),
                "agent":     .string("a2"),
                "lineage_links": .array([
                    .object([
                        "kind":          .string("derivesFrom"),
                        "targetPacketID": .string(ancestorDrawerID),
                    ])
                ]),
            ]))
        let descendantBody = try text(descendantResult)
        let descendantDrawerID = try #require(
            extractValue(key: "drawer_id", from: descendantBody))

        // Trace lineage from descendant — should return ancestor.
        let lineageResult = try await dispatcher.dispatch(
            name: "moot_packet_lineage",
            arguments: .object(["drawer_id": .string(descendantDrawerID)]))
        let lineageBody = try text(lineageResult)

        #expect(lineageBody.hasPrefix("lineage:"),
            "moot_packet_lineage must return lineage: header; got: \(lineageBody)")
        #expect(lineageBody.contains(ancestorDrawerID),
            "Lineage trace must include the ancestor drawer ID")
        #expect(lineageBody.contains("count: 1"))
    }

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
}
