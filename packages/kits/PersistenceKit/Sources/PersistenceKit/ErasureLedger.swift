// ErasureLedger.swift
//
// Grow-only erasure ledger (ADR-017 §17).
//
// Records THAT a drawer was erased, never the content. The table
// is append-only: once a drawer_id is in the ledger, it stays.
// GC-pinned and replicated like other skeleton rows.

import Foundation
import SubstrateTypes

// MARK: - Types

/// A row in the `erasure_ledger` table.
public struct ErasureLedgerEntry: Sendable, Equatable {
    public let drawerId: String
    public let erasedHlc: HLC

    public init(drawerId: String, erasedHlc: HLC) {
        self.drawerId = drawerId
        self.erasedHlc = erasedHlc
    }
}

// MARK: - Schema

/// Table name constant.
public enum ErasureLedgerTables {
    public static let ledger = "erasure_ledger"
}

/// Schema declaration for the erasure ledger. Append-only: UPDATE
/// and DELETE throw `StorageError.appendOnlyViolation`.
public enum ErasureLedgerSchema {
    public static let ledgerTable = TableDeclaration(
        name: ErasureLedgerTables.ledger,
        columns: [
            .text("drawer_id"),
            .hlc("erased_hlc"),
        ],
        primaryKey: ["drawer_id"],
        appendOnly: true
    )
}

// MARK: - Operations

/// Erasure ledger operations on a RowStore.
public enum ErasureLedgerOps {

    /// Record an erasure. Throws `StorageError.duplicateKey` if the
    /// drawer_id is already in the ledger — each drawer is erased once.
    public static func recordErasure(
        rowStore: any RowStore,
        drawerId: String,
        erasedHlc: HLC
    ) async throws {
        _ = try await rowStore.insert(
            table: ErasureLedgerTables.ledger,
            values: [
                "drawer_id": .text(drawerId),
                "erased_hlc": .hlc(erasedHlc),
            ]
        )
    }

    /// Point lookup: is this drawer_id in the erasure ledger?
    public static func isErased(
        rowStore: any RowStore,
        drawerId: String
    ) async throws -> Bool {
        let rows = try await rowStore.query(
            table: ErasureLedgerTables.ledger,
            where: .eq(
                Column(table: ErasureLedgerTables.ledger, name: "drawer_id"),
                .text(drawerId)
            ),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        return !rows.isEmpty
    }

    /// Retrieve the erasure entry for a drawer_id, if it exists.
    public static func lookupErasure(
        rowStore: any RowStore,
        drawerId: String
    ) async throws -> ErasureLedgerEntry? {
        let rows = try await rowStore.query(
            table: ErasureLedgerTables.ledger,
            where: .eq(
                Column(table: ErasureLedgerTables.ledger, name: "drawer_id"),
                .text(drawerId)
            ),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first else { return nil }
        return decodeEntry(row)
    }

    // MARK: - Internal

    static func decodeEntry(_ row: StorageRow) -> ErasureLedgerEntry? {
        guard case .text(let id) = row["drawer_id"],
              case .hlc(let hlc) = row["erased_hlc"]
        else { return nil }
        return ErasureLedgerEntry(drawerId: id, erasedHlc: hlc)
    }
}
