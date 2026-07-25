// PacketsPaneTests.swift
//
// Part 2 verify: exportability filter test — non-exportable packets are
// absent from the PacketsEngine read API; exportable packets appear.
//
// Tests PacketsEngine directly via MockPacketsClient (no HTTP stack). This
// is an in-process unit test of the filter gate that is the content-safety
// boundary for the /api/packets* surface.
//
// The exportability invariant (comment in PacketsHandlers.swift):
//   Only LocusKit drawers marked .public_ appear on any /api/packets* surface.
//   .private_ drawers (adjectiveBitmap == 0, the LocusKit default) are silently
//   excluded at the RecallFrame filter layer.

import Testing
import Foundation
import WorkPacketKit
import LocusKit
@testable import MootManager

// MARK: - Fixture helpers

private func makePacketContent(
    id: String = UUID().uuidString,
    objective: String = "test objective"
) -> String {
    let packet = WorkPacket(
        id: id,
        objective: objective,
        provenance: WorkPacketProvenance(
            model: "test-model",
            agent: "test-agent",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return String(data: try! encoder.encode(packet), encoding: .utf8)!
}

// MARK: - PacketsPaneTests

@Suite struct PacketsPaneTests {

    @Test("Empty mock — list returns pending=false and empty packet list")
    func emptyMockReturnsEmptyList() async throws {
        let mock = MockPacketsClient()
        let engine = PacketsEngine(client: mock)
        let payload = try await engine.list()
        #expect(payload.pending == false)
        #expect(payload.packets.isEmpty)
    }

    @Test("Non-exportable packet (adjectiveBitmap=0) is absent from list")
    func nonExportableAbsentFromList() async throws {
        let mock = MockPacketsClient()
        let id = UUID().uuidString
        mock.plant(id: id, content: makePacketContent(id: id), exportable: false)

        let engine = PacketsEngine(client: mock)
        let payload = try await engine.list()
        #expect(payload.packets.isEmpty, "non-exportable packet must not appear in list")
    }

    @Test("Exportable packet (.public_) appears in list")
    func exportableAppearsInList() async throws {
        let mock = MockPacketsClient()
        let id = UUID().uuidString
        let content = makePacketContent(id: id, objective: "export me")
        let drawer = mock.plant(id: id, content: content, exportable: true)

        let engine = PacketsEngine(client: mock)
        let payload = try await engine.list()
        #expect(payload.packets.count == 1, "expected exactly one packet")
        #expect(payload.packets.first?.drawerID == drawer.id)
        #expect(payload.packets.first?.objective == "export me")
    }

    @Test("Mixed — only exportable packet appears, non-exportable absent")
    func mixedOnlyExportableShown() async throws {
        let mock = MockPacketsClient()
        let privID = UUID().uuidString
        let pubID = UUID().uuidString
        mock.plant(id: privID, content: makePacketContent(id: privID, objective: "private"),
                   exportable: false)
        mock.plant(id: pubID, content: makePacketContent(id: pubID, objective: "public"),
                   exportable: true)

        let engine = PacketsEngine(client: mock)
        let payload = try await engine.list()
        #expect(payload.packets.count == 1)
        #expect(payload.packets.first?.drawerID == pubID)
        #expect(payload.packets.first?.objective == "public")
    }

    @Test("fetch with non-exportable drawer ID returns nil (no bypass)")
    func fetchNonExportableReturnsNil() async throws {
        let mock = MockPacketsClient()
        let id = UUID().uuidString
        mock.plant(id: id, content: makePacketContent(id: id), exportable: false)

        let engine = PacketsEngine(client: mock)
        let detail = try await engine.fetch(drawerID: id)
        #expect(detail == nil, "non-exportable drawer must not be accessible via direct ID fetch")
    }

    @Test("fetch with exportable drawer ID returns PacketDetailPayload")
    func fetchExportableReturnsDetail() async throws {
        let mock = MockPacketsClient()
        let id = UUID().uuidString
        let content = makePacketContent(id: id, objective: "detail test")
        let drawer = mock.plant(id: id, content: content, exportable: true)

        let engine = PacketsEngine(client: mock)
        let detail = try await engine.fetch(drawerID: drawer.id)
        let d = try #require(detail)
        #expect(d.drawerID == drawer.id)
        #expect(d.objective == "detail test")
        #expect(d.agent == "test-agent")
        #expect(d.model == "test-model")
    }

    @Test("lineage with non-exportable drawer returns nil")
    func lineageNonExportableReturnsNil() async throws {
        let mock = MockPacketsClient()
        let id = UUID().uuidString
        mock.plant(id: id, content: makePacketContent(id: id), exportable: false)

        let engine = PacketsEngine(client: mock)
        let result = try await engine.lineage(drawerID: id)
        #expect(result == nil)
    }

    @Test("lineage with exportable drawer returns PacketLineagePayload")
    func lineageExportableReturnsPayload() async throws {
        let mock = MockPacketsClient()
        let antecedentID = UUID().uuidString
        let id = UUID().uuidString

        // Build a packet with one lineage link.
        let packet = WorkPacket(
            id: id,
            objective: "lineage test",
            provenance: WorkPacketProvenance(
                model: "m",
                agent: "a",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            lineageLinks: [LineageLink(kind: .derivesFrom, targetPacketID: antecedentID)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let content = String(data: try encoder.encode(packet), encoding: .utf8)!

        let drawer = mock.plant(id: id, content: content, exportable: true)
        let engine = PacketsEngine(client: mock)
        let result = try await engine.lineage(drawerID: drawer.id)
        let r = try #require(result)
        #expect(r.drawerID == drawer.id)
        #expect(r.links.count == 1)
        #expect(r.links.first?.kind == "derivesFrom")
        #expect(r.links.first?.targetPacketID == antecedentID)
    }
}
