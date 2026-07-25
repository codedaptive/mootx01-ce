// ErasureLedgerTests.swift
//
// Tests for the erasure ledger.
// Part 3 of mission NT-P3.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

struct ErasureLedgerTests {

    func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
    }

    func ledgerSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "ErasureLedgerTestKit",
            version: 1,
            tables: [
                ErasureLedgerSchema.ledgerTable,
            ]
        )
    }

    @Test func recordAndLookupErasure() async throws {
        let storage = makeStorage()
        try await storage.open(schema: ledgerSchema())

        let hlc = HLC(physicalTime: 5_000, logicalCount: 1, nodeID: 0)

        try await ErasureLedgerOps.recordErasure(
            rowStore: storage.rowStore,
            drawerId: "drawer-42",
            erasedHlc: hlc
        )

        let entry = try await ErasureLedgerOps.lookupErasure(
            rowStore: storage.rowStore,
            drawerId: "drawer-42"
        )
        #expect(entry != nil)
        #expect(entry?.drawerId == "drawer-42")
        #expect(entry?.erasedHlc == hlc)
    }

    @Test func isErasedReturnsTrueForRecordedId() async throws {
        let storage = makeStorage()
        try await storage.open(schema: ledgerSchema())

        try await ErasureLedgerOps.recordErasure(
            rowStore: storage.rowStore,
            drawerId: "erased-1",
            erasedHlc: HLC(physicalTime: 1_000, logicalCount: 1, nodeID: 0)
        )

        let result = try await ErasureLedgerOps.isErased(
            rowStore: storage.rowStore,
            drawerId: "erased-1"
        )
        #expect(result == true)
    }

    @Test func isErasedReturnsFalseForUnrecordedId() async throws {
        let storage = makeStorage()
        try await storage.open(schema: ledgerSchema())

        let result = try await ErasureLedgerOps.isErased(
            rowStore: storage.rowStore,
            drawerId: "never-erased"
        )
        #expect(result == false)
    }

    @Test func lookupNonexistentReturnsNil() async throws {
        let storage = makeStorage()
        try await storage.open(schema: ledgerSchema())

        let entry = try await ErasureLedgerOps.lookupErasure(
            rowStore: storage.rowStore,
            drawerId: "ghost"
        )
        #expect(entry == nil)
    }

    @Test func updateRejectedOnAppendOnlyTable() async throws {
        let storage = makeStorage()
        try await storage.open(schema: ledgerSchema())

        try await ErasureLedgerOps.recordErasure(
            rowStore: storage.rowStore,
            drawerId: "d1",
            erasedHlc: HLC(physicalTime: 1_000, logicalCount: 1, nodeID: 0)
        )

        // Attempting to update should throw appendOnlyViolation.
        await #expect(throws: StorageError.self) {
            _ = try await storage.rowStore.update(
                table: ErasureLedgerTables.ledger,
                values: ["erased_hlc": .hlc(HLC(physicalTime: 9_999, logicalCount: 1, nodeID: 0))],
                where: .eq(
                    Column(table: ErasureLedgerTables.ledger, name: "drawer_id"),
                    .text("d1")
                )
            )
        }
    }

    @Test func deleteRejectedOnAppendOnlyTable() async throws {
        let storage = makeStorage()
        try await storage.open(schema: ledgerSchema())

        try await ErasureLedgerOps.recordErasure(
            rowStore: storage.rowStore,
            drawerId: "d2",
            erasedHlc: HLC(physicalTime: 2_000, logicalCount: 1, nodeID: 0)
        )

        // Attempting to delete should throw appendOnlyViolation.
        await #expect(throws: StorageError.self) {
            _ = try await storage.rowStore.delete(
                table: ErasureLedgerTables.ledger,
                where: .eq(
                    Column(table: ErasureLedgerTables.ledger, name: "drawer_id"),
                    .text("d2")
                )
            )
        }
    }

    @Test func multipleErasuresCoexist() async throws {
        let storage = makeStorage()
        try await storage.open(schema: ledgerSchema())

        for i in 1...5 {
            try await ErasureLedgerOps.recordErasure(
                rowStore: storage.rowStore,
                drawerId: "drawer-\(i)",
                erasedHlc: HLC(physicalTime: Int64(i * 1000), logicalCount: 1, nodeID: 0)
            )
        }

        // All five should be findable.
        for i in 1...5 {
            let found = try await ErasureLedgerOps.isErased(
                rowStore: storage.rowStore,
                drawerId: "drawer-\(i)"
            )
            #expect(found == true)
        }

        // Non-existent still returns false.
        let notFound = try await ErasureLedgerOps.isErased(
            rowStore: storage.rowStore,
            drawerId: "drawer-99"
        )
        #expect(notFound == false)
    }
}
