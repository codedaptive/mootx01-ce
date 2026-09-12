import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("GLK typed write boundary")
struct TypedWriteBoundaryTests {
    private func openOne() async throws -> (GeniusLocusKit, EstateHandle) {
        let storage = InMemoryStorage(configuration: .init(estateID: UUID(), backend: .inMemory))
        let owner = OwnerCredentials(ownerIdentifier: "typed-write-boundary")
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let kit = GeniusLocusKit()
        return (kit, try await kit.open(storage: storage, owner: owner))
    }

    private func proposedFrame(label: String) -> TunnelCaptureFrame {
        TunnelCaptureFrame(
            sourceWing: "source", sourceRoom: "room-a",
            targetWing: "target", targetRoom: "room-b",
            label: label, addedBy: "agent", kind: .contradicts,
            originClass: .derived, lifecycle: .proposed)
    }

    @Test("typed capture and settle preserve both lifecycle outcomes and reviewer ledger")
    func captureAndSettleTunnel() async throws {
        let (kit, handle) = try await openOne()
        let accepted = try await kit.captureTunnel(handle, proposedFrame(label: "accept"))
        let rejected = try await kit.captureTunnel(handle, proposedFrame(label: "reject"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await kit.settleTunnel(
            handle, tunnelID: accepted.id, accept: true, changedBy: "accept-reviewer",
            reason: "approved", now: now)
        try await kit.settleTunnel(
            handle, tunnelID: rejected.id, accept: false, changedBy: "reject-reviewer",
            reason: "declined", now: now)

        let estate = try await kit.estate(for: handle)
        let acceptedAfter = try #require(await estate.getTunnel(id: accepted.id))
        let rejectedAfter = try #require(await estate.getTunnel(id: rejected.id))
        #expect(acceptedAfter.lifecycle == .active)
        #expect(rejectedAfter.lifecycle == .withdrawn)
        // Tunnels have no row-audit event. Their lifecycle audit identity is
        // the canonical ledger's reviewedBy field, written with the bitmap in
        // the same existing LocusKit transaction.
        #expect(acceptedAfter.ext == "{\"reviewedBy\":\"accept-reviewer\"}")
        #expect(rejectedAfter.ext == "{\"reviewedBy\":\"reject-reviewer\"}")
        #expect(try TunnelReviewLedger.parse(acceptedAfter.ext).reviewedBy == "accept-reviewer")
        #expect(try TunnelReviewLedger.parse(rejectedAfter.ext).reviewedBy == "reject-reviewer")
    }

    @Test("dataset capture, FDC floor stamp, and explicit reanchor use fixed typed seams")
    func typedDatasetFloorAndReanchor() async throws {
        let (kit, handle) = try await openOne()
        let drawer = try await kit.captureDatasetHandle(
            handle, datasetId: UUID(),
            columns: [DatasetColumnSummary(name: "name", dataType: "TEXT")],
            rowCount: 0, sourceDescription: "typed boundary test", room: "datasets",
            addedBy: "agent", udcCode: "004")
        #expect(drawer.contentKind == .dataset)
        #expect(drawer.udcCode == "004")
        #expect(drawer.udcFacets == nil && drawer.wikidataQID == nil && drawer.wikidataQidsSecondary == nil,
                "the typed dataset seam is UDC-only until LocusKit gains typed dataset facet/QID slots")

        try await kit.stampFDCRecalculationFloor(handle, value: "fdc-v4-test")
        let estate = try await kit.estate(for: handle)
        #expect(try await estate.meta(key: "aria.fdc.recalced_data_version") == "fdc-v4-test")

        // Pick a future physical time so this explicit timestamp advances the
        // estate HLC beyond capture's live-clock genesis event.
        let at = Date(timeIntervalSince1970: 2_100_000_000)
        try await kit.reanchorAnchor(
            handle, rowID: drawer.id,
            toLattice: LatticeAnchor(
                udcCode: "005", udcFacets: "005,005.1",
                wikidataQID: "Q4", wikidataQidsSecondary: "Q5,Q6"),
            changedBy: "anchor-reviewer", reason: "typed anchor correction", now: at)
        let updated = try #require(await estate.drawerById(rowID: drawer.id))
        #expect(updated.udcCode == "005")
        #expect(updated.udcFacets == "005,005.1")
        #expect(updated.wikidataQID == "Q4")
        #expect(updated.wikidataQidsSecondary == "Q5,Q6")

        let trail = try await estate.auditTrail(rowID: drawer.id)
        let reanchorEvent = try #require(trail.last)
        #expect(reanchorEvent.actor == "anchor-reviewer")
        #expect(reanchorEvent.reason == "typed anchor correction")
        #expect(reanchorEvent.hlc.physicalTime == 2_100_000_000_000)
    }

    @Test("typed writes reject quiesced and stale handles before storage access")
    func typedWritesHonorMountGates() async throws {
        let (kit, handle) = try await openOne()
        try await kit.quiesce(handle)
        await #expect(throws: GeniusLocusKitError.self) {
            _ = try await kit.captureTunnel(handle, self.proposedFrame(label: "blocked"))
        }
        await #expect(throws: GeniusLocusKitError.self) {
            try await kit.stampFDCRecalculationFloor(handle, value: "blocked")
        }

        let (freshKit, staleHandle) = try await openOne()
        try await freshKit.close(staleHandle)
        await #expect(throws: GeniusLocusKitError.self) {
            _ = try await freshKit.captureTunnel(staleHandle, self.proposedFrame(label: "stale"))
        }
    }

    @Test("dataset append failure drops its newly-created backend table")
    func fileDatasetRollsBackAppendFailure() async throws {
        let (kit, handle) = try await openOne()
        let datasetID = UUID()
        let store = try await kit.datasetStore(for: handle)

        await #expect(throws: DatasetFilingError.self) {
            _ = try await kit.fileDataset(handle, DatasetFilingFrame(
                datasetID: datasetID,
                schema: DatasetSchema(
                    columns: [ColumnDeclaration(name: "name", type: .text)],
                    primaryKeyColumn: nil),
                rows: [["bad-key": .text("cannot be appended")]],
                columns: [DatasetColumnSummary(name: "name", dataType: "TEXT")],
                sourceDescription: "append rollback test",
                room: "datasets",
                addedBy: "agent",
                udcCode: "004"))
        }
        await #expect(throws: StorageError.self) {
            _ = try await store.queryRows(
                id: datasetID, predicate: nil, orderBy: [], limit: nil, offset: nil, columns: nil)
        }
    }

    @Test("dataset filing gates quiesced handles before backend table creation")
    func fileDatasetRejectsQuiescedHandleBeforeDDL() async throws {
        let (kit, handle) = try await openOne()
        let datasetID = UUID()
        let store = try await kit.datasetStore(for: handle)
        try await kit.quiesce(handle)

        await #expect(throws: GeniusLocusKitError.self) {
            _ = try await kit.fileDataset(handle, DatasetFilingFrame(
                datasetID: datasetID,
                schema: DatasetSchema(
                    columns: [ColumnDeclaration(name: "name", type: .text)],
                    primaryKeyColumn: nil),
                rows: [],
                columns: [DatasetColumnSummary(name: "name", dataType: "TEXT")],
                sourceDescription: "quiesced filing test",
                room: "datasets",
                addedBy: "agent",
                udcCode: "004"))
        }
        await #expect(throws: StorageError.self) {
            _ = try await store.queryRows(
                id: datasetID, predicate: nil, orderBy: [], limit: nil, offset: nil, columns: nil)
        }
    }
}
