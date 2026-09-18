// StalePushAfterDeleteTests.swift
//
// Two devices, one shared cloud. Device B edits a record while offline.
// Device A deletes the same record later and pushes the tombstone. B comes
// back and pushes. The rule is last-changed-wins by the clock: A's delete is
// the last change, so it must stand everywhere, and B's older edit must
// never reach the cloud.
//
// Without pull-before-push the cloud took B's old edit: CloudKit merges a
// changed-keys save without comparing clocks, and the live record's explicit
// `moot_sync_deleted = 0` replaced the tombstone marker. The record came
// back to life for any device that pulled fresh, while A kept it deleted —
// permanent divergence. With the fix, B's push pulls first, the tombstone
// wins B's LWW gate, B's queued edit is cancelled as beaten, and B sends
// nothing for that row.

import Testing
import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
import SubstrateTypes
@testable import ConvergenceKitCloudKit

@Suite("Stale push after delete — pull before push, last change wins")
struct StalePushAfterDeleteTests {

    /// Delete a row locally (non-sync origin) and wait for the outbox entry.
    private func deleteLocal(fixture: TwoEstateFixture, engine: CloudKitSyncEngine,
                             storage: any Storage, id: UUID) async throws {
        let before = try await OutboxStore.readBatch(from: storage).count
        _ = try await storage.rowStore.delete(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(id)))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            await Task.yield()
            if try await OutboxStore.readBatch(from: storage).count > before { return }
        }
        throw FixtureError.outboxTimeoutAfterWrite(table: "items")
    }

    /// The record as the cloud holds it right now: nil when absent, otherwise
    /// whether it is a tombstone.
    private func cloudIsTombstone(fixture: TwoEstateFixture, id: UUID) async throws -> Bool? {
        let zone = CKRecordZone.ID(zoneName: TwoEstateFixture.manifest.zoneIdentifier,
                                   ownerName: CKCurrentUserDefaultName)
        let changes = try await fixture.cloud.fetchZoneChanges(inZoneWith: zone, since: nil)
        let recordID = CKRecordMapping.recordID(rowKey: id, zone: zone)
        guard let record = changes.modifiedRecords.first(where: { $0.recordID == recordID }) else { return nil }
        return (record[SyncTombstone.deletedFieldKey] as? NSNumber)?.intValue == 1
    }

    @Test("B's offline edit, then A's delete: B's push pulls first, the delete stands, nothing stale is sent")
    func offlineEditLosesToLaterDelete() async throws {
        let fixture = try await TwoEstateFixture.make()
        let id = UUID()

        // Both devices hold the row.
        try await fixture.writeA(row: ["id": .uuid(id), "note": .text("v1"), "flags": .bitmap(0)])
        _ = try await fixture.engineA.push()
        _ = try await fixture.engineB.pull()
        #expect(try await fixture.queryB(id: id) != nil, "B holds the row after the first pull")

        // B edits the row and stays offline: the edit sits in B's outbox.
        try await fixture.writeB(row: ["id": .uuid(id), "note": .text("v2 from B, older"), "flags": .bitmap(0)])
        #expect(try await fixture.outboxCountB() == 1)

        // A deletes the row later (clock moved well past B's edit) and pushes.
        await fixture.engineA.stateActor.advanceClock(by: 60_000)
        try await deleteLocal(fixture: fixture, engine: fixture.engineA, storage: fixture.storageA, id: id)
        _ = try await fixture.engineA.push()
        #expect(try await cloudIsTombstone(fixture: fixture, id: id) == true, "the cloud holds A's tombstone")

        // B comes back and pushes. The push pulls first: A's delete is the last
        // change, so it wins on B, B's queued edit is cancelled, and B sends
        // nothing for the row.
        let receipt = try await fixture.engineB.push()
        #expect(receipt.pushed == 0, "B pushed nothing: its only queued write had already lost")
        #expect(try await fixture.outboxCountB() == 0, "B's beaten edit is gone from its outbox")
        #expect(try await fixture.queryB(id: id) == nil, "the row is deleted on B")
        #expect(try await cloudIsTombstone(fixture: fixture, id: id) == true,
                "the cloud still holds the tombstone; the older edit did not revive the row")

        // A sees no change either way.
        _ = try await fixture.engineA.pull()
        #expect(try await fixture.queryA(id: id) == nil, "the row stays deleted on A")
    }

    @Test("A's delete, then B's LATER edit: the edit is the last change and revives the row everywhere")
    func laterEditBeatsEarlierDelete() async throws {
        let fixture = try await TwoEstateFixture.make()
        let id = UUID()

        try await fixture.writeA(row: ["id": .uuid(id), "note": .text("v1"), "flags": .bitmap(0)])
        _ = try await fixture.engineA.push()
        _ = try await fixture.engineB.pull()

        // A deletes and pushes the tombstone.
        try await deleteLocal(fixture: fixture, engine: fixture.engineA, storage: fixture.storageA, id: id)
        _ = try await fixture.engineA.push()

        // B edits later, without having pulled the delete, then pushes.
        await fixture.engineB.stateActor.advanceClock(by: 60_000)
        try await fixture.writeB(row: ["id": .uuid(id), "note": .text("v2 from B, newer"), "flags": .bitmap(0)])
        let receipt = try await fixture.engineB.push()
        #expect(receipt.pushed == 1, "B's edit is newer than the delete and goes out")
        #expect(try await cloudIsTombstone(fixture: fixture, id: id) == false, "the cloud record is live again")

        // A pulls and gets the row back: the last change wins.
        _ = try await fixture.engineA.pull()
        let onA = try await fixture.queryA(id: id)
        #expect(onA?["note"] == .text("v2 from B, newer"), "A holds B's newer edit")
    }
}
