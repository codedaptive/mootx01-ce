// SyncMetaStore.swift
//
// _ck_sync_meta side table management for CloudKitStateActor.
// Provides ensure/read/write operations for the HLC-keyed row
// metadata used by the lastWriterWinsByHLC conflict policy (#12).

import Foundation
import ConvergenceKit
import PersistenceKit
import SubstrateTypes

// MARK: - Sync metadata side table (#12)

extension CloudKitStateActor {

    /// Side table name. Owned by ConvergenceKit, not by the application schema.
    private static let syncMetaTable = "_ck_sync_meta"

    /// Ensure the side table exists. Must be called before any pull.
    /// Uses SchemaDeclaration + migrate so the table is created via the
    /// standard PersistenceKit schema path (works on all backends).
    static func ensureSyncMetaTable(storage: any Storage) async throws {
        let schema = SchemaDeclaration(
            kitID: "ConvergenceKitCloudKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: syncMetaTable,
                    columns: [
                        ColumnDeclaration(name: "table_name", type: .text, nullable: false),
                        ColumnDeclaration(name: "primary_key", type: .text, nullable: false),
                        ColumnDeclaration(name: "sync_hlc", type: .int, nullable: false,
                                          defaultValue: .int(0)),
                        ColumnDeclaration(name: "schema_version", type: .int, nullable: false,
                                          defaultValue: .int(0)),
                        ColumnDeclaration(name: "kit_id", type: .text, nullable: false,
                                          defaultValue: .text("")),
                    ],
                    primaryKey: ["table_name", "primary_key"]
                ),
            ],
            indices: []
        )
        // migrate(to:) is ADDITIVE — it creates missing tables without
        // replacing the backend's active schema declaration. open(schema:)
        // would clobber the application schema, breaking all row operations.
        try await storage.migrate(to: schema)
    }

    /// Read the persisted sync HLC for a specific row.
    func readSyncHLC(
        storage: any Storage, table: String, primaryKey: UUID, pkColumn: String
    ) async throws -> HLC? {
        let rows = try await storage.rowStore.query(
            table: Self.syncMetaTable,
            where: .and([
                .eq(Column(table: Self.syncMetaTable, name: "table_name"), .text(table)),
                .eq(Column(table: Self.syncMetaTable, name: "primary_key"), .text(primaryKey.uuidString))
            ])
        )
        guard let row = rows.first,
              case .int(let packed) = row["sync_hlc"] else { return nil }
        return HLC(packed: UInt64(bitPattern: packed))
    }

    /// Persist the sync HLC for a specific row after a successful upsert.
    func writeSyncHLC(
        storage: any Storage, table: String, primaryKey: UUID, pkColumn: String,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        _ = try await storage.rowStore.upsert(
            table: Self.syncMetaTable,
            values: [
                "table_name": .text(table),
                "primary_key": .text(primaryKey.uuidString),
                "sync_hlc": .int(Int64(bitPattern: hlc.packed)),
                "schema_version": .int(Int64(schemaVersion)),
                "kit_id": .text(kitID)
            ],
            conflictColumns: ["table_name", "primary_key"]
        )
    }
}
