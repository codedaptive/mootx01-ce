// FailClosedPreReadTests.swift
//
// Proves the fail-closed pre-read behavior in GLK expunge and retireKGFact.
//
// Each verb performs a query against storage before its main operation:
// expunge queries "drawers", retireKGFact queries "kg_facts". A thrown read
// error must surface as VerbError.underlyingEstateFailure (fail-closed) —
// not silently treated as an absent-row/absent-fact condition. Nothing
// previously tested the thrown-error branch because the in-memory backend
// never throws; FaultingStorage provides the seam.
//
// P1 — expunge: arm fault on "drawers" → call expunge → error must contain
//      the fault marker, not the absent-row marker → disarm → drawer survives.
//
// P2 — retireKGFact: arm fault on "kg_facts" → call retireKGFact → error
//      must contain the fault marker, not the absent-fact marker → disarm →
//      fact survives active.

import Testing
import Foundation
import LocusKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitTestSupport
@testable import GeniusLocusKit

@Suite("Fail-closed pre-read — storage faults surface as estate failures")
struct FailClosedPreReadTests {

    /// Fixed timestamp shared across tests — 2026-01-01T00:00:00Z.
    private var testNow: Date { Date(timeIntervalSince1970: 1_735_689_600) }

    // MARK: - P1: expunge pre-read fault closes fail

    /// A storage fault thrown during expunge's pre-read of the "drawers" table
    /// must propagate as VerbError.underlyingEstateFailure (fail-closed). The
    /// error must carry the injected fault marker and must NOT resemble the
    /// absent-row error path (which carries "drawer not found"). After disarming
    /// the fault the drawer must survive non-tombstoned.
    @Test
    func expungePreReadStorageFaultClosesFail() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fail-closed-expunge")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)

        // Wire the faulting wrapper targeting the "drawers" table. The cell starts
        // disarmed so the estate-open and seed writes pass through unchanged.
        let cell = FaultCell(table: "drawers")
        let faulting = FaultingStorage(wrapping: storage, cell: cell)
        let handle = try await kit.open(storage: faulting, owner: owner)

        // Seed a drawer while the fault is disarmed.
        let frame = CaptureFrame(
            content: "drawer seeded for fail-closed pre-read test",
            channel: .typed,
            room: "fail-closed-tests",
            latticeAnchor: .udc("000"),
            addedBy: "fail-closed-pre-read-tests",
            embeddingModelID: "test-model-v1"
        )
        let drawer = try await kit.capture(handle, frame)

        // Arm the fault: the pre-read query in expunge hits "drawers" and fails.
        cell.arm(StorageError.backendUnavailable(reason: "INJECTED_FAULT"))

        var thrownError: Error?
        do {
            _ = try await kit.expunge(
                handle,
                ExpungeFrame(rowID: drawer.id, reason: "fault-test", confirmation: true)
            )
        } catch {
            thrownError = error
        }

        // Disarm before any further storage access.
        cell.disarm()

        let err = try #require(thrownError, "expunge must throw when the pre-read faults")
        let desc = String(describing: err)

        // The fault marker must be present — this distinguishes the storage-fault
        // path from the absent-row path.
        #expect(
            desc.contains("INJECTED_FAULT"),
            "error must carry the injected fault marker; got: \(desc)"
        )
        // The absent-row marker must be absent — the two paths are distinguishable.
        #expect(
            !desc.contains("drawer not found"),
            "storage fault must not be misreported as an absent-row condition; got: \(desc)"
        )

        // The drawer must survive non-tombstoned: the expunge did not complete.
        let estate = try await kit.estate(for: handle)
        let rowAfter = try await estate.allDrawers().first { $0.id == drawer.id }
        #expect(rowAfter != nil, "drawer must survive the failed expunge")
        #expect(
            rowAfter?.state != .tombstoned,
            "drawer state must remain non-tombstoned; got \(String(describing: rowAfter?.state))"
        )
    }

    // MARK: - P2: retireKGFact pre-read fault closes fail

    /// A storage fault thrown during retireKGFact's pre-read of the "kg_facts"
    /// table must propagate as VerbError.underlyingEstateFailure (fail-closed).
    /// The error must carry the injected fault marker and must NOT resemble the
    /// absent-fact error path (which carries "kgFact not found"). After disarming
    /// the fault the fact must survive active.
    @Test
    func retireKGFactPreReadStorageFaultClosesFail() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-fail-closed-retire-kg")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)

        // Wire the faulting wrapper targeting the "kg_facts" table. The cell starts
        // disarmed so the estate-open, seed writes, and KGFact capture pass through.
        let cell = FaultCell(table: "kg_facts")
        let faulting = FaultingStorage(wrapping: storage, cell: cell)
        let handle = try await kit.open(storage: faulting, owner: owner)

        // Seed a source drawer (disarmed — passes through).
        let drawerFrame = CaptureFrame(
            content: "drawer for KGFact retire fault test",
            channel: .typed,
            room: "fail-closed-tests",
            latticeAnchor: .udc("000"),
            addedBy: "fail-closed-pre-read-tests",
            embeddingModelID: "test-model-v1"
        )
        let drawer = try await kit.capture(handle, drawerFrame)

        // Seed a KGFact while the fault is disarmed.
        let fact = try await kit.captureKGFact(
            handle,
            subject: "TestSubject",
            predicate: "hasProperty",
            object: "TestValue",
            sourceDrawerID: drawer.id,
            now: testNow
        )

        // Arm the fault: the pre-read query in retireKGFact hits "kg_facts" and fails.
        cell.arm(StorageError.backendUnavailable(reason: "INJECTED_FAULT"))

        var thrownError: Error?
        do {
            try await kit.retireKGFact(
                handle,
                rowID: fact.id,
                changedBy: "fail-closed-pre-read-tests",
                now: testNow
            )
        } catch {
            thrownError = error
        }

        // Disarm before any further storage access.
        cell.disarm()

        let err = try #require(thrownError, "retireKGFact must throw when the pre-read faults")
        let desc = String(describing: err)

        // The fault marker must be present.
        #expect(
            desc.contains("INJECTED_FAULT"),
            "error must carry the injected fault marker; got: \(desc)"
        )
        // The absent-fact marker must be absent.
        #expect(
            !desc.contains("kgFact not found"),
            "storage fault must not be misreported as an absent-fact condition; got: \(desc)"
        )

        // The fact must survive active: retireKGFact did not complete.
        let estate = try await kit.estate(for: handle)
        let allFacts = try await estate.allKGFactsIncludingRetired()
        let factAfter = allFacts.first { $0.id == fact.id }
        #expect(factAfter != nil, "KGFact must survive the failed retireKGFact")
        #expect(
            factAfter?.state == .active,
            "KGFact state must remain .active; got \(String(describing: factAfter?.state))"
        )
    }
}
