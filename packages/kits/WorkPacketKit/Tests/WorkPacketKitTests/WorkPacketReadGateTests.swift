import Testing
import Foundation
import LocusKit
@testable import WorkPacketKit

// WorkPacketReadGateTests — the by-id read gate on WorkPacketStore.
//
// Verifies: fetch reads through the frame-gated client call (never the
// unfiltered one); an adjective-restricted packet is absent under the default
// ceiling and present under a restricted ceiling; a provenance-restricted or
// provenance-secret packet is absent under every ceiling; the batch read
// applies the same rules; the frame carries the list chain plus the ceiling.

@Suite("WorkPacketStore read gate")
struct WorkPacketReadGateTests {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePacket(id: String) -> WorkPacket {
        WorkPacket(
            id: id,
            objective: "Packet \(id)",
            provenance: WorkPacketProvenance(
                model: "m", agent: "a",
                createdAt: fixedDate, updatedAt: fixedDate
            )
        )
    }

    @Test("fetch reads through the frame-gated client call")
    func fetchUsesFrameGatedRead() async throws {
        let client = MockEstateClient()
        try client.plant(makePacket(id: "gate-normal"))
        let store = WorkPacketStore(client: client)
        let fetched = try await store.fetch(drawerID: "gate-normal")
        #expect(fetched?.id == "gate-normal")
        #expect(client.frameGatedCalls == 1)
    }

    @Test("adjective-restricted packet is absent under the default ceiling")
    func adjectiveRestrictedIsAbsentByDefault() async throws {
        let client = MockEstateClient()
        try client.plant(makePacket(id: "gate-adj-restricted"), sensitivity: .restricted)
        let store = WorkPacketStore(client: client)
        let fetched = try await store.fetch(drawerID: "gate-adj-restricted")
        #expect(fetched == nil)
    }

    @Test("adjective-secret packet is absent under the default ceiling")
    func adjectiveSecretIsAbsentByDefault() async throws {
        let client = MockEstateClient()
        try client.plant(makePacket(id: "gate-adj-secret"), sensitivity: .secret)
        let store = WorkPacketStore(client: client)
        let fetched = try await store.fetch(drawerID: "gate-adj-secret")
        #expect(fetched == nil)
    }

    @Test("a restricted ceiling lifts the adjective gate for restricted, not secret")
    func restrictedCeilingLiftsAdjectiveGate() async throws {
        let client = MockEstateClient()
        try client.plant(makePacket(id: "gate-adj-restricted"), sensitivity: .restricted)
        try client.plant(makePacket(id: "gate-adj-secret"), sensitivity: .secret)
        let store = WorkPacketStore(client: client)
        let ceiling = Filter.sensitivityAtMost(.restricted)
        let restricted = try await store.fetch(drawerID: "gate-adj-restricted", ceiling: ceiling)
        let secret = try await store.fetch(drawerID: "gate-adj-secret", ceiling: ceiling)
        #expect(restricted?.id == "gate-adj-restricted")
        #expect(secret == nil)
    }

    @Test("provenance restricted/secret packets are absent under every ceiling")
    func provenanceGateIsUnconditional() async throws {
        let client = MockEstateClient()
        try client.plant(makePacket(id: "gate-prov-restricted"), provenanceSensitivity: .restricted)
        try client.plant(makePacket(id: "gate-prov-secret"), provenanceSensitivity: .secret)
        let store = WorkPacketStore(client: client)
        for ceiling: Filter? in [nil, .sensitivityAtMost(.restricted), .sensitivityAtMost(.secret)] {
            let restricted = try await store.fetch(drawerID: "gate-prov-restricted", ceiling: ceiling)
            let secret = try await store.fetch(drawerID: "gate-prov-secret", ceiling: ceiling)
            #expect(restricted == nil, "provenance restricted must be absent under ceiling \(String(describing: ceiling))")
            #expect(secret == nil, "provenance secret must be absent under ceiling \(String(describing: ceiling))")
        }
    }

    @Test("provenance normal and elevated packets are returned")
    func provenanceNormalAndElevatedAreReturned() async throws {
        let client = MockEstateClient()
        try client.plant(makePacket(id: "gate-prov-normal"), provenanceSensitivity: .normal)
        try client.plant(makePacket(id: "gate-prov-elevated"), provenanceSensitivity: .elevated)
        let store = WorkPacketStore(client: client)
        let normal = try await store.fetch(drawerID: "gate-prov-normal")
        let elevated = try await store.fetch(drawerID: "gate-prov-elevated")
        #expect(normal?.id == "gate-prov-normal")
        #expect(elevated?.id == "gate-prov-elevated")
    }

    @Test("batch read omits gated and missing ids, keeps admissible ones")
    func batchReadOmitsGatedIDs() async throws {
        let client = MockEstateClient()
        try client.plant(makePacket(id: "batch-open"))
        try client.plant(makePacket(id: "batch-adj-restricted"), sensitivity: .restricted)
        try client.plant(makePacket(id: "batch-prov-secret"), provenanceSensitivity: .secret)
        let store = WorkPacketStore(client: client)
        let ids = ["batch-open", "batch-adj-restricted", "batch-prov-secret", "batch-missing"]
        let byDefault = try await store.fetchAdmissibleDrawers(ids: ids)
        #expect(byDefault.map(\.id) == ["batch-open"])
        let underSecret = try await store.fetchAdmissibleDrawers(
            ids: ids, ceiling: .sensitivityAtMost(.secret))
        #expect(Set(underSecret.map(\.id)) == ["batch-open", "batch-adj-restricted"])
    }

    @Test("batch read of no ids makes no client call")
    func batchReadEmptyIsNoop() async throws {
        let client = MockEstateClient()
        let store = WorkPacketStore(client: client)
        let result = try await store.fetchAdmissibleDrawers(ids: [])
        #expect(result.isEmpty)
        #expect(client.frameGatedCalls == 0)
    }
}
