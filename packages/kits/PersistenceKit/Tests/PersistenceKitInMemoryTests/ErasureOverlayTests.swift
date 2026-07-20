// ErasureOverlayTests.swift
//
// Tests for the two-phase fail-closed global erasure overlay
//. Part 4 of mission NT-P3.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

struct ErasureOverlayTests {

    func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
    }

    /// Schema with a content table and the erasure ledger.
    func overlaySchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "ErasureOverlayTestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "drawers",
                    columns: [
                        .text("drawer_id"),
                        .text("verbatim"),
                        .text("body", nullable: true),
                        .hlc("created_hlc"),
                    ],
                    primaryKey: ["drawer_id"]
                ),
                ErasureLedgerSchema.ledgerTable,
            ]
        )
    }

    /// Standard overlay config: extract drawer_id, null verbatim + body.
    func testConfig() -> ErasureOverlayConfig {
        ErasureOverlayConfig(
            extractErasureId: { row in
                if case .text(let id) = row["drawer_id"] { return id }
                return nil
            },
            contentColumns: ["verbatim", "body"]
        )
    }

    @Test func nonErasedRowPassesThrough() async throws {
        let storage = makeStorage()
        try await storage.open(schema: overlaySchema())

        // Insert a drawer row (not in erasure ledger).
        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: [
                "drawer_id": .text("d1"),
                "verbatim": .text("hello world"),
                "body": .text("full body"),
                "created_hlc": .hlc(HLC(physicalTime: 1_000, logicalCount: 1, nodeID: 0)),
            ]
        )

        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: nil,
            orderBy: [],
            limit: nil,
            offset: nil
        )

        let filtered = await ErasureOverlay.apply(
            rows: rows,
            config: testConfig(),
            rowStore: storage.rowStore
        )

        #expect(filtered.count == 1)
        #expect(filtered[0]["verbatim"] == .text("hello world"))
        #expect(filtered[0]["body"] == .text("full body"))
    }

    @Test func erasedRowHasContentNulled() async throws {
        let storage = makeStorage()
        try await storage.open(schema: overlaySchema())

        // Insert a drawer row.
        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: [
                "drawer_id": .text("d2"),
                "verbatim": .text("secret content"),
                "body": .text("secret body"),
                "created_hlc": .hlc(HLC(physicalTime: 2_000, logicalCount: 1, nodeID: 0)),
            ]
        )

        // Mark d2 as erased.
        try await ErasureLedgerOps.recordErasure(
            rowStore: storage.rowStore,
            drawerId: "d2",
            erasedHlc: HLC(physicalTime: 3_000, logicalCount: 1, nodeID: 0)
        )

        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: nil,
            orderBy: [],
            limit: nil,
            offset: nil
        )

        let filtered = await ErasureOverlay.apply(
            rows: rows,
            config: testConfig(),
            rowStore: storage.rowStore
        )

        #expect(filtered.count == 1)
        // Content columns nulled.
        #expect(filtered[0]["verbatim"] == .null)
        #expect(filtered[0]["body"] == .null)
        // Skeleton preserved.
        #expect(filtered[0]["drawer_id"] == .text("d2"))
    }

    @Test func mixedErasedAndNonErased() async throws {
        let storage = makeStorage()
        try await storage.open(schema: overlaySchema())

        // Insert two drawers.
        for id in ["keep", "erase"] {
            _ = try await storage.rowStore.insert(
                table: "drawers",
                values: [
                    "drawer_id": .text(id),
                    "verbatim": .text("content-\(id)"),
                    "body": .null,
                    "created_hlc": .hlc(HLC(physicalTime: 1_000, logicalCount: 1, nodeID: 0)),
                ]
            )
        }

        // Erase one.
        try await ErasureLedgerOps.recordErasure(
            rowStore: storage.rowStore,
            drawerId: "erase",
            erasedHlc: HLC(physicalTime: 2_000, logicalCount: 1, nodeID: 0)
        )

        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: nil,
            orderBy: [],
            limit: nil,
            offset: nil
        )

        let filtered = await ErasureOverlay.apply(
            rows: rows,
            config: testConfig(),
            rowStore: storage.rowStore
        )

        #expect(filtered.count == 2)

        let kept = filtered.first { $0["drawer_id"] == .text("keep") }!
        #expect(kept["verbatim"] == .text("content-keep"))

        let erased = filtered.first { $0["drawer_id"] == .text("erase") }!
        #expect(erased["verbatim"] == .null)
    }

    @Test func failClosedDropsRowOnLedgerError() async throws {
        // Use a storage WITHOUT the erasure ledger table to simulate
        // a ledger-check failure (query on missing table throws).
        let storage = makeStorage()
        let noLedgerSchema = SchemaDeclaration(
            kitID: "NoLedgerKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "drawers",
                    columns: [
                        .text("drawer_id"),
                        .text("verbatim"),
                    ],
                    primaryKey: ["drawer_id"]
                ),
            ]
        )
        try await storage.open(schema: noLedgerSchema)

        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: [
                "drawer_id": .text("d-fail"),
                "verbatim": .text("should be dropped"),
            ]
        )

        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: nil,
            orderBy: [],
            limit: nil,
            offset: nil
        )
        #expect(rows.count == 1)

        // Apply overlay — ledger table doesn't exist, so isErased
        // throws, and the row must be DROPPED (fail-closed).
        let filtered = await ErasureOverlay.apply(
            rows: rows,
            config: testConfig(),
            rowStore: storage.rowStore
        )

        #expect(filtered.isEmpty)
    }

    @Test func rowWithNilErasureIdPassesThrough() async throws {
        let storage = makeStorage()
        try await storage.open(schema: overlaySchema())

        // Insert a row.
        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: [
                "drawer_id": .text("d-normal"),
                "verbatim": .text("safe"),
                "body": .null,
                "created_hlc": .hlc(HLC(physicalTime: 1_000, logicalCount: 1, nodeID: 0)),
            ]
        )

        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: nil,
            orderBy: [],
            limit: nil,
            offset: nil
        )

        // Config that returns nil for all rows (not subject to erasure).
        let skipConfig = ErasureOverlayConfig(
            extractErasureId: { _ in nil },
            contentColumns: ["verbatim"]
        )

        let filtered = await ErasureOverlay.apply(
            rows: rows,
            config: skipConfig,
            rowStore: storage.rowStore
        )

        #expect(filtered.count == 1)
        #expect(filtered[0]["verbatim"] == .text("safe"))
    }
}
