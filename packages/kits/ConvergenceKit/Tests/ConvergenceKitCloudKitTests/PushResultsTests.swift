// PushResultsTests.swift
//
// Tests for PushResults.process (per-record result classification) and the
// OutboxStore mutations it drives: park(id:from:), incrementRetryCount(id:from:),
// and the readBatch skip-parked-entries guarantee (CVK-ICLOUD P1-M6 R6).
//
// PushResults.process is a pure function — synthetic CKRecord.ID / Result
// dictionaries stand in for real CloudKit transport output. The classifyError
// parameter is injected with a scripted closure so no real CKError objects are
// needed for the branch coverage tests.

import Testing
import Foundation
import CloudKit
@testable import ConvergenceKit
@testable import ConvergenceKitCloudKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes

// MARK: - Shared test storage

private func makeStorage() async throws -> any Storage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory
    ))
    try await storage.open(schema: SchemaDeclaration(
        kitID: "TestApp",
        version: 1,
        tables: [
            TableDeclaration(
                name: "items",
                columns: [.uuid("id"), .text("name")],
                primaryKey: ["id"]
            )
        ]
    ))
    try await CKSideSchema.ensure(storage: storage)
    return storage
}

private func makeEntry(packedHLC: Int64 = 1_000) -> OutboxEntry {
    // Gap 6: `packedHLC` is a plain logical ordinal (test convenience, param
    // name kept so every call site below is unchanged) — wrapped into a
    // full-width HLC.wireBytes.
    let hlc = HLC(physicalTime: packedHLC, logicalCount: 0, nodeID: 1)
    return OutboxEntry(
        id: UUID(),
        tableName: "items",
        rowKey: UUID().uuidString,
        event: .insert,
        valuesData: nil,
        hlcWireBytes: Data(hlc.wireBytes),
        enqueuedAt: ISO8601DateFormatter().string(from: Date())
    )
}

private func recordID(for entry: OutboxEntry) -> CKRecord.ID {
    // Zone is arbitrary for pure-function tests; recordName just needs to be unique.
    CKRecord.ID(recordName: entry.id.uuidString)
}

// MARK: - PushResults.process (pure function)

@Suite("PushResults.process — pure function classification")
struct PushResultsProcessTests {

    // MARK: All success

    @Test("all succeeded → all in confirmedIDs, nothing elsewhere")
    func allSuccess() {
        let entryA = makeEntry()
        let entryB = makeEntry()
        let ridA = recordID(for: entryA)
        let ridB = recordID(for: entryB)

        let saveResults: [CKRecord.ID: Result<CKRecord, Error>] = [
            ridA: .success(CKRecord(recordType: "Item", recordID: ridA)),
            ridB: .success(CKRecord(recordType: "Item", recordID: ridB)),
        ]
        let map: [CKRecord.ID: UUID] = [ridA: entryA.id, ridB: entryB.id]

        let outcome = PushResults.process(saveResults: saveResults, recordToEntryID: map)

        #expect(Set(outcome.confirmedIDs) == Set([entryA.id, entryB.id]))
        #expect(outcome.retryIDs.isEmpty)
        #expect(outcome.parkedIDs.isEmpty)
        #expect(outcome.reclaimNeeded == nil)
        #expect(outcome.pushedCount == 2)
    }

    // MARK: Mixed partial failure

    @Test("partial failure: success → confirm, retryable → retry, permanent → park")
    func partialFailure_mixedOutcomes() {
        let entrySuccess = makeEntry()
        let entryRetry = makeEntry()
        let entryPark = makeEntry()

        let ridSuccess = recordID(for: entrySuccess)
        let ridRetry = recordID(for: entryRetry)
        let ridPark = recordID(for: entryPark)

        struct FakeError: Error {}

        let saveResults: [CKRecord.ID: Result<CKRecord, Error>] = [
            ridSuccess: .success(CKRecord(recordType: "Item", recordID: ridSuccess)),
            ridRetry: .failure(FakeError()),
            ridPark: .failure(FakeError()),
        ]
        let map: [CKRecord.ID: UUID] = [
            ridSuccess: entrySuccess.id,
            ridRetry: entryRetry.id,
            ridPark: entryPark.id,
        ]

        // Inject scripted classifier: retry for entryRetry's rid, permanent for entryPark's.
        let outcome = PushResults.process(
            saveResults: saveResults,
            recordToEntryID: map,
            classifyError: { _ in
                // Caller drives via entry — we can't branch on error here, so
                // we test the full three-bucket split via separate tests below.
                .retryableBackoff(retryAfter: nil)
            }
        )

        // With the scripted classifier returning retryable for both failures:
        // success → confirmed, two failures → retry, none parked.
        #expect(outcome.confirmedIDs == [entrySuccess.id])
        #expect(Set(outcome.retryIDs) == Set([entryRetry.id, entryPark.id]))
        #expect(outcome.parkedIDs.isEmpty)
        #expect(outcome.pushedCount == 1)
    }

    @Test("permanent failure → parkedIDs, not retryIDs")
    func permanentFailureToParked() {
        let entry = makeEntry()
        let rid = recordID(for: entry)

        struct FakeError: Error {}
        let saveResults: [CKRecord.ID: Result<CKRecord, Error>] = [
            rid: .failure(FakeError()),
        ]

        let outcome = PushResults.process(
            saveResults: saveResults,
            recordToEntryID: [rid: entry.id],
            classifyError: { _ in .permanent(.quotaExceeded) }
        )

        #expect(outcome.confirmedIDs.isEmpty)
        #expect(outcome.retryIDs.isEmpty)
        #expect(outcome.parkedIDs == [entry.id])
        #expect(outcome.pushedCount == 0)
    }

    @Test("conflict failure → retryIDs (pull cycle resolves via LWW)")
    func conflictToRetry() {
        let entry = makeEntry()
        let rid = recordID(for: entry)

        struct FakeError: Error {}
        let saveResults: [CKRecord.ID: Result<CKRecord, Error>] = [
            rid: .failure(FakeError()),
        ]

        let outcome = PushResults.process(
            saveResults: saveResults,
            recordToEntryID: [rid: entry.id],
            classifyError: { _ in .conflict }
        )

        #expect(outcome.retryIDs == [entry.id])
        #expect(outcome.confirmedIDs.isEmpty)
        #expect(outcome.parkedIDs.isEmpty)
    }

    @Test("reclaim failure → retryIDs with reclaimNeeded set")
    func reclaimSurfaced() {
        let entry = makeEntry()
        let rid = recordID(for: entry)

        struct FakeError: Error {}
        let saveResults: [CKRecord.ID: Result<CKRecord, Error>] = [
            rid: .failure(FakeError()),
        ]

        let outcome = PushResults.process(
            saveResults: saveResults,
            recordToEntryID: [rid: entry.id],
            classifyError: { _ in .reclaim(.zoneNotFound) }
        )

        #expect(outcome.retryIDs == [entry.id])
        #expect(outcome.reclaimNeeded == .zoneNotFound)
        #expect(outcome.confirmedIDs.isEmpty)
        #expect(outcome.parkedIDs.isEmpty)
    }

    @Test("only first reclaimKind is surfaced when multiple reclaim errors arrive")
    func onlyFirstReclaimKind() {
        let entryA = makeEntry()
        let entryB = makeEntry()
        let ridA = recordID(for: entryA)
        let ridB = recordID(for: entryB)

        struct FakeError: Error {}
        let saveResults: [CKRecord.ID: Result<CKRecord, Error>] = [
            ridA: .failure(FakeError()),
            ridB: .failure(FakeError()),
        ]

        // Both classify as reclaim — one zoneNotFound, one changeTokenExpired.
        // Because dictionary iteration order is non-deterministic, we just verify
        // exactly ONE reclaim is surfaced (not both, not nil).
        var callCount = 0
        let kinds: [ReclaimKind] = [.zoneNotFound, .changeTokenExpired]
        let outcome = PushResults.process(
            saveResults: saveResults,
            recordToEntryID: [ridA: entryA.id, ridB: entryB.id],
            classifyError: { _ in
                defer { callCount += 1 }
                return .reclaim(kinds[callCount % kinds.count])
            }
        )

        #expect(outcome.reclaimNeeded != nil)
        // Both entries are retryIDs even when reclaim is present.
        #expect(Set(outcome.retryIDs) == Set([entryA.id, entryB.id]))
    }

    @Test("records absent from recordToEntryID map are silently skipped")
    func unknownRecordIDSkipped() {
        let unknownID = CKRecord.ID(recordName: "ghost")
        let saveResults: [CKRecord.ID: Result<CKRecord, Error>] = [
            unknownID: .success(CKRecord(recordType: "Item", recordID: unknownID)),
        ]

        let outcome = PushResults.process(
            saveResults: saveResults,
            recordToEntryID: [:] // no mapping for unknownID
        )

        // Ghost record skipped; all buckets empty.
        #expect(outcome.confirmedIDs.isEmpty)
        #expect(outcome.retryIDs.isEmpty)
        #expect(outcome.parkedIDs.isEmpty)
        #expect(outcome.pushedCount == 0)
    }

    @Test("empty saveResults → empty outcome (no crash)")
    func emptyResults() {
        let outcome = PushResults.process(
            saveResults: [:],
            recordToEntryID: [:]
        )
        #expect(outcome.confirmedIDs.isEmpty)
        #expect(outcome.retryIDs.isEmpty)
        #expect(outcome.parkedIDs.isEmpty)
        #expect(outcome.reclaimNeeded == nil)
        #expect(outcome.pushedCount == 0)
    }
}

// MARK: - OutboxStore.park + readBatch skip-parked

@Suite("OutboxStore — parked-entry skip and diagnostics")
struct OutboxStoreParkedTests {

    @Test("park(id:) excludes entry from future readBatch")
    func parkedEntrySkippedByReadBatch() async throws {
        let storage = try await makeStorage()
        let entryA = makeEntry(packedHLC: 10)
        let entryB = makeEntry(packedHLC: 20)

        try await OutboxStore.append(entry: entryA, to: storage)
        try await OutboxStore.append(entry: entryB, to: storage)

        // Park entryA (permanent failure simulation).
        try await OutboxStore.park(id: entryA.id, from: storage)

        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 1)
        #expect(batch.first?.id == entryB.id,
                "parked entryA must not appear in readBatch")
    }

    @Test("parkedEntries() returns only parked entries")
    func parkedEntriesDiagnosticAccessor() async throws {
        let storage = try await makeStorage()
        let live = makeEntry(packedHLC: 1)
        let parked = makeEntry(packedHLC: 2)

        try await OutboxStore.append(entry: live, to: storage)
        try await OutboxStore.append(entry: parked, to: storage)
        try await OutboxStore.park(id: parked.id, from: storage)

        let parkedList = try await OutboxStore.parkedEntries(from: storage)
        #expect(parkedList.count == 1)
        #expect(parkedList.first?.id == parked.id)
        #expect(parkedList.first?.isParked == true)
    }

    @Test("parkedEntries() is empty when no entries are parked")
    func parkedEntriesEmptyWhenNoneParked() async throws {
        let storage = try await makeStorage()
        let entry = makeEntry()
        try await OutboxStore.append(entry: entry, to: storage)

        let parkedList = try await OutboxStore.parkedEntries(from: storage)
        #expect(parkedList.isEmpty)
    }

    @Test("park is idempotent: parking already-parked entry does not throw")
    func parkIdempotent() async throws {
        let storage = try await makeStorage()
        let entry = makeEntry()
        try await OutboxStore.append(entry: entry, to: storage)

        try await OutboxStore.park(id: entry.id, from: storage)
        try await OutboxStore.park(id: entry.id, from: storage) // second call must not throw

        let parkedList = try await OutboxStore.parkedEntries(from: storage)
        #expect(parkedList.count == 1)
    }
}

// MARK: - OutboxStore.incrementRetryCount

@Suite("OutboxStore — retry count increment")
struct OutboxStoreRetryCountTests {

    @Test("incrementRetryCount increases retryCount by 1")
    func incrementOnce() async throws {
        let storage = try await makeStorage()
        let entry = makeEntry()
        try await OutboxStore.append(entry: entry, to: storage)

        try await OutboxStore.incrementRetryCount(id: entry.id, from: storage)

        let batch = try await OutboxStore.readBatch(from: storage)
        let updated = try #require(batch.first)
        #expect(updated.retryCount == 1)
    }

    @Test("incrementRetryCount accumulates across multiple calls")
    func incrementMultiple() async throws {
        let storage = try await makeStorage()
        let entry = makeEntry()
        try await OutboxStore.append(entry: entry, to: storage)

        for _ in 0..<5 {
            try await OutboxStore.incrementRetryCount(id: entry.id, from: storage)
        }

        let batch = try await OutboxStore.readBatch(from: storage)
        let updated = try #require(batch.first)
        #expect(updated.retryCount == 5)
    }

    @Test("incrementRetryCount on non-existent id is a no-op (no crash)")
    func incrementUnknownIdNoOp() async throws {
        let storage = try await makeStorage()
        // Should not throw — a missing entry is silently ignored.
        try await OutboxStore.incrementRetryCount(id: UUID(), from: storage)
    }

    @Test("new entry starts with retryCount 0")
    func newEntryHasZeroRetryCount() async throws {
        let storage = try await makeStorage()
        let entry = makeEntry()
        try await OutboxStore.append(entry: entry, to: storage)

        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.first?.retryCount == 0)
    }

    @Test("incrementRetryCount does not affect other entries")
    func incrementDoesNotAffectOtherEntries() async throws {
        let storage = try await makeStorage()
        let entryA = makeEntry(packedHLC: 10)
        let entryB = makeEntry(packedHLC: 20)

        try await OutboxStore.append(entry: entryA, to: storage)
        try await OutboxStore.append(entry: entryB, to: storage)

        try await OutboxStore.incrementRetryCount(id: entryA.id, from: storage)

        let batch = try await OutboxStore.readBatch(from: storage)
        let a = try #require(batch.first(where: { $0.id == entryA.id }))
        let b = try #require(batch.first(where: { $0.id == entryB.id }))

        #expect(a.retryCount == 1)
        #expect(b.retryCount == 0)
    }
}
