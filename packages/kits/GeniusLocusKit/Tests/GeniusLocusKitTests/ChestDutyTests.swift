// ChestDutyTests.swift — the chest re-bin duty and the per-container
// incremental anomaly sweep (ADR-026, spec § CHESTS). Twin of
// chest_duty_parity.rs.
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import GeniusLocusKit

@Suite("Chest duties (ADR-026): re-bin at capacity, incremental container sweep")
struct ChestDutyTests {
    private static let wing = "Agentic Memory"
    private static let room = "chest-duty"

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "chest-duty-tests-\(UUID().uuidString)")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Chest Duty Test Estate", kind: .glk, zoomWindowLow: 1, zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork", syncMode: .none)
        let handle = try await kit.provision(storage: storage, owner: owner, params: params,
                                             embeddingModels: [.deterministic])
        return (kit, handle)
    }

    private func frame(_ content: String, room: String = ChestDutyTests.room) -> CaptureFrame {
        CaptureFrame(content: content, channel: .typed, room: room, latticeAnchor: LatticeAnchor.udc("000"),
                     addedBy: "chest-duty-tests", embeddingModelID: "minilm-v6")
    }

    @Test("a room at capacity owes one re-bin; the sweep then scores its chests incrementally and agrees with a whole rescore")
    func rebinAtCapacityThenIncrementalSweep() async throws {
        let (kit, handle) = try await openEstate()
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let estate = try await kit.estate(for: handle)
        _ = try await estate.captureBatch((0..<500).map {
            frame("Project Falcon status note \($0): the deploy target is the staging cluster and Maria owns the rollout checklist.")
        })

        // 500 drawers sit on the room itself: at capacity, one re-bin owed
        // (the provisioned estate's other rooms are small); the sweep skips a
        // container at capacity, so nothing in this room is owed a scoring yet.
        func inRoom(_ owed: [AnomalyContainer]) -> Set<String> {
            Set(owed.filter { $0.room == Self.room }.map { $0.nodeId.lowercased() })
        }
        #expect(try await kit.chestRebinOwedRooms(handle).map(\.room) == [Self.room])
        #expect(inRoom(try await kit.anomalySweepOwedContainers(handle, now: t0)).isEmpty)
        #expect(try await kit.runChestRebinBatch(handle, limit: 1, now: t0) == 1)
        #expect(try await kit.dutyDebt(.chestRebin, in: handle, now: t0) == 0)
        let chests = try await estate.chests(in: Self.wing, room: Self.room)
        #expect(chests.map(\.count) == [250, 250])

        // Every chest is owed a first scoring; one batch pays every owed container.
        let owed = try await kit.anomalySweepOwedContainers(handle, now: t0)
        #expect(inRoom(owed) == Set(chests.map { $0.chestNodeId.lowercased() }))
        #expect(try await kit.runAnomalySweepBatch(handle, limit: owed.count, now: t0) == owed.count)
        #expect(try await kit.dutyDebt(.anomalySweep, in: handle, now: t0) == 0)
        #expect(try await estate.drawersIn(wing: Self.wing, room: Self.room).filter(\.isAnomalous).isEmpty,
                "a uniform cohort has no outlier")

        // One outlier capture owes exactly its chest; the incremental pass
        // flags it, and a whole rescore changes nothing more.
        let outlier = try await kit.capture(handle, frame(
            "Banana pudding recipe: vanilla wafers layered with custard and sliced bananas. Refrigerate overnight."))
        let owedAfter = try await kit.anomalySweepOwedContainers(handle, now: t0.addingTimeInterval(1))
        #expect(owedAfter.map { $0.nodeId.lowercased() } == [outlier.parentNodeId.lowercased()])
        #expect(chests.contains { $0.chestNodeId.lowercased() == outlier.parentNodeId.lowercased() }, "the capture landed in a chest")
        #expect(try await kit.runAnomalySweepBatch(handle, limit: 8, now: t0.addingTimeInterval(1)) == 1)
        let flagged = try await estate.drawersIn(wing: Self.wing, room: Self.room).filter(\.isAnomalous).map(\.id)
        #expect(flagged == [outlier.id])
        #expect(try await kit.anomalyFlagSweep(handle: handle, now: t0.addingTimeInterval(2)) == 0,
                "the incremental sums and a whole rescore agree on every flag")

        // Moving the outlier to another room owes the chest it left and the
        // container it joined; scoring both clears the flag it no longer earns.
        // The destination is seeded first: the owed list walks the rooms the
        // container-fingerprint store knows, and a room is known once
        // something was captured into it.
        _ = try await kit.capture(handle, frame("seed for the destination room", room: "elsewhere"))
        _ = try await kit.runAnomalySweepBatch(handle, limit: 8, now: t0.addingTimeInterval(2))
        try await kit.reanchor(handle, ReanchorFrame(rowID: outlier.id, toRoom: "elsewhere"))
        let moved = try await estate.getDrawers(ids: [outlier.id])[0]
        let owedMove = Set(try await kit.anomalySweepOwedContainers(handle, now: t0.addingTimeInterval(3)).map { $0.nodeId.lowercased() })
        #expect(owedMove == Set([outlier.parentNodeId.lowercased(), moved.parentNodeId.lowercased()]))
        #expect(try await kit.runAnomalySweepBatch(handle, limit: 8, now: t0.addingTimeInterval(3)) == 2)
        #expect(try await estate.getDrawers(ids: [outlier.id])[0].isAnomalous == false,
                "alone in its new room, the drawer is not an outlier")
        #expect(try await kit.dutyDebt(.anomalySweep, in: handle, now: t0.addingTimeInterval(3)) == 0)
    }
}
