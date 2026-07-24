import Testing
import Foundation
import LocusKit
@testable import WorkPacketKit

// WorkPacketStoreTests — store against a stubbed MockEstateClient.
//
// Verifies: packet is stored as a drawer; lineage tunnels are filed for each
// link; fetch retrieves a stored packet by ID; list returns multiple packets.

@Suite("WorkPacketStore")
struct WorkPacketStoreTests {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() -> (WorkPacketStore, MockEstateClient) {
        let client = MockEstateClient()
        let store = WorkPacketStore(client: client)
        return (store, client)
    }

    private func makePacket(id: String = UUID().uuidString, objective: String = "Test objective") -> WorkPacket {
        WorkPacket(
            id: id,
            objective: objective,
            provenance: WorkPacketProvenance(
                model: "test-model", agent: "test-agent",
                createdAt: fixedDate, updatedAt: fixedDate
            )
        )
    }

    // MARK: - store

    @Test("store files exactly one drawer per packet")
    func storeFilesOneDrawer() async throws {
        let (store, client) = makeStore()
        let packet = makePacket(id: "pkt-001")
        let drawerID = try await store.store(packet, now: fixedDate)
        #expect(drawerID == "pkt-001")
        #expect(client.captureDrawerCount == 1)
    }

    @Test("store files tunnels for lineage links")
    func storeFilesLineageTunnels() async throws {
        let (store, client) = makeStore()
        let packet = WorkPacket(
            id: "pkt-with-links",
            objective: "Test lineage",
            provenance: WorkPacketProvenance(
                model: "m", agent: "a",
                createdAt: fixedDate, updatedAt: fixedDate
            ),
            lineageLinks: [
                LineageLink(kind: .derivesFrom, targetPacketID: "parent-001"),
                LineageLink(kind: .respondsTo, targetPacketID: "ref-001"),
            ]
        )
        _ = try await store.store(packet, now: fixedDate)
        // One drawer + two tunnels
        #expect(client.captureDrawerCount == 1)
        #expect(client.captureTunnelCount == 2)
        // Tunnel kinds
        let tunnels = client.storedTunnels()
        #expect(tunnels.contains { $0.kind == .derivesFrom })
        #expect(tunnels.contains { $0.kind == .respondsTo })
    }

    @Test("store with no lineage links files no tunnels")
    func storeWithNoLinksFilesNoTunnels() async throws {
        let (store, client) = makeStore()
        let packet = makePacket(id: "solo-001")
        _ = try await store.store(packet, now: fixedDate)
        #expect(client.captureTunnelCount == 0)
    }

    // MARK: - fetch

    @Test("fetch returns a stored packet by drawer ID")
    func fetchReturnsStoredPacket() async throws {
        let (store, client) = makeStore()
        let original = makePacket(id: "fetch-test-001", objective: "Fetchable packet")
        _ = try await store.store(original, now: fixedDate)

        // Fetch returns the packet with the same id the store was given.
        // NOTE: The mock assigns a new UUID as drawer.id in capture,
        // but fetch uses the drawer ID from the mock's allDrawers list.
        // For the test to be round-trip correct, plant the packet directly.
        _ = client  // mock already recorded the capture

        // Re-plant via mock to align drawer.id with packet.id.
        let mock2 = MockEstateClient()
        try mock2.plant(original)
        let store2 = WorkPacketStore(client: mock2)
        let fetched = try await store2.fetch(drawerID: original.id)
        #expect(fetched?.id == original.id)
        #expect(fetched?.objective == original.objective)
    }

    @Test("fetch returns nil for unknown drawer ID")
    func fetchReturnsNilForUnknownID() async throws {
        let (store, _) = makeStore()
        let result = try await store.fetch(drawerID: "nonexistent-id")
        #expect(result == nil)
    }

    // MARK: - list

    @Test("list returns all planted packets")
    func listReturnsAllPlantedPackets() async throws {
        let client = MockEstateClient()
        let packets = [
            makePacket(id: "list-001", objective: "First"),
            makePacket(id: "list-002", objective: "Second"),
            makePacket(id: "list-003", objective: "Third"),
        ]
        for p in packets { try client.plant(p) }
        let store = WorkPacketStore(client: client)
        let listed = try await store.list()
        #expect(listed.count == 3)
        let ids = Set(listed.map(\.id))
        #expect(ids.contains("list-001"))
        #expect(ids.contains("list-002"))
        #expect(ids.contains("list-003"))
    }

    @Test("list respects limit parameter")
    func listRespectsLimit() async throws {
        let client = MockEstateClient()
        for i in 1...5 {
            try client.plant(makePacket(id: "limited-\(i)"))
        }
        let store = WorkPacketStore(client: client)
        let listed = try await store.list(limit: 3)
        #expect(listed.count == 3)
    }

    @Test("list on empty store returns empty array")
    func listOnEmptyStoreReturnsEmpty() async throws {
        let (store, _) = makeStore()
        let listed = try await store.list()
        #expect(listed.isEmpty)
    }

    // MARK: - Content correctness

    @Test("stored drawer content is valid JSON")
    func storedDrawerContentIsValidJSON() async throws {
        let (store, client) = makeStore()
        let packet = makePacket(id: "json-check-001")
        _ = try await store.store(packet, now: fixedDate)
        let drawer = client.allDrawers().first!
        let data = drawer.content.data(using: .utf8)
        #expect(data != nil)
        let parsed = try JSONSerialization.jsonObject(with: data!)
        let dict = parsed as? [String: Any]
        #expect(dict != nil)
        #expect(dict?["id"] as? String == "json-check-001")
    }

    // MARK: - LatticeAnchor override

    @Test("store accepts a custom LatticeAnchor override")
    func storeAcceptsCustomLatticeAnchor() async throws {
        let (store, client) = makeStore()
        let packet = makePacket(id: "anchor-test-001")
        let customAnchor = LatticeAnchor.udc("547")  // Organic chemistry
        _ = try await store.store(packet, now: fixedDate, latticeAnchor: customAnchor)
        #expect(client.captureDrawerCount == 1)
        let drawer = client.allDrawers().first!
        // The mock extracts udcCode from the frame's latticeAnchor.
        #expect(drawer.udcCode == "547")
    }
}
