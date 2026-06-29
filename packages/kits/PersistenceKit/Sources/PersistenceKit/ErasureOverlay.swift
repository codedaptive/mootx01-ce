// ErasureOverlay.swift
//
// Two-phase fail-closed global erasure overlay (ADR-017 §17).
//
// Every read (present and as-of) passes through this overlay.
// Phase 1: select rows by temporal filter (standard query).
// Phase 2: for each row, check the erasure ledger. If erased,
// null the content fields. If the ledger check fails (storage
// error), drop the row entirely — fail-closed.
//
// PersistenceKit does not know which column is "content" or how
// lineage ids relate to drawer ids. Upper kits supply these
// via ErasureOverlayConfig.

import Foundation
import SubstrateTypes

// MARK: - Configuration

/// Configuration for the erasure overlay. Upper kits supply this
/// so PersistenceKit can apply erasure without knowing entity semantics.
public struct ErasureOverlayConfig: Sendable {
    /// Extract the erasure-ledger key from a result row. Returns nil
    /// if this row type is not subject to erasure (the row passes
    /// through unmodified).
    public let extractErasureId: @Sendable (StorageRow) -> String?

    /// Column names whose values are nulled when the row is erased.
    /// Skeleton columns (id, hlc, timestamps) are preserved; content
    /// columns (verbatim, body, etc.) are nulled.
    public let contentColumns: [String]

    public init(
        extractErasureId: @escaping @Sendable (StorageRow) -> String?,
        contentColumns: [String]
    ) {
        self.extractErasureId = extractErasureId
        self.contentColumns = contentColumns
    }
}

// MARK: - Overlay

/// Applies the two-phase erasure overlay to query results.
///
/// This is a post-processing filter, not a query-path modification.
/// It calls the standard RowStore query, then filters results through
/// the erasure ledger. This avoids circular dependency on the gated
/// as-of surface.
public enum ErasureOverlay {

    /// Apply the erasure overlay to a set of rows.
    ///
    /// For each row:
    /// - Extract the erasure id via config. If nil, the row passes through.
    /// - Check the erasure ledger. If the id is erased, null content columns.
    /// - If the ledger check throws, the row is DROPPED (fail-closed).
    ///
    /// - Parameters:
    ///   - rows: The query result rows to filter.
    ///   - config: Erasure overlay configuration from the upper kit.
    ///   - rowStore: The row store for ledger lookups.
    /// - Returns: Filtered rows with erased content nulled or dropped.
    public static func apply(
        rows: [StorageRow],
        config: ErasureOverlayConfig,
        rowStore: any RowStore
    ) async -> [StorageRow] {
        var result: [StorageRow] = []
        for row in rows {
            guard let erasureId = config.extractErasureId(row) else {
                // Row type not subject to erasure — pass through.
                result.append(row)
                continue
            }

            do {
                let erased = try await ErasureLedgerOps.isErased(
                    rowStore: rowStore,
                    drawerId: erasureId
                )
                if erased {
                    result.append(nullContentColumns(row: row, columns: config.contentColumns))
                } else {
                    result.append(row)
                }
            } catch {
                // Fail-closed: ledger check failed, drop the row entirely.
                continue
            }
        }
        return result
    }

    /// Null the specified content columns in a row, preserving skeleton.
    static func nullContentColumns(row: StorageRow, columns: [String]) -> StorageRow {
        var values = row.values
        for col in columns {
            if values[col] != nil {
                values[col] = .null
            }
        }
        return StorageRow(values: values)
    }
}
