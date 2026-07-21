// DatabaseInventory.swift
//
// Deterministic table inventory + content folds (GLK shared-content 1.1, P0).
//
// The shared-content migration must be able to prove, before and after any
// destructive step, exactly which rows exist and that PROTECTED state
// (drawers, audit/history, relationships, unrelated/shared vectors) is
// byte-identical to its pre-migration baseline. This helper captures that
// baseline: per-table row counts plus an order-independent deterministic
// fold over canonically-encoded rows.
//
// The fold is FNV-1a 64 per row over a canonical row encoding, combined
// with wrapping addition so enumeration order cannot affect the digest.
// It is an integrity DIAGNOSTIC (detects accidental mutation in migration
// and characterization tests), not a cryptographic attestation; the
// Merkle/content-hash lanes remain the attestation surface.
//
// Cross-port: mirrors Rust `database_inventory.rs`. The canonical value
// encoding is defined to be byte-identical across ports:
//
//   null        n
//   bool        b:0 | b:1
//   int         i:<decimal>
//   bitmap      m:<decimal>
//   float       f:<16-hex IEEE-754 bit pattern>   (bit pattern, never text)
//   text        t:<utf8-byte-len>:<utf8 bytes>
//   blob        x:<len>:<lowercase hex>
//   uuid        u:<lowercase hyphenated>
//   timestamp   s:<epoch-milliseconds, rounded>
//   json        j:<byte-len>:<bytes>
//   hlc         h:<packed u64 decimal>
//   fingerprint p:<4 × 16-hex-digit blocks, block0..block3>
//   array       a:[<elements comma-joined>]
//
// Row encoding: columns sorted by name, each rendered as
// `<name>=<encoded value>` joined by `\u{1F}` (unit separator).

import Foundation
import SubstrateTypes

/// Inventory of one table: its live row count and deterministic content fold.
public struct TableInventory: Sendable, Equatable {
    public let table: String
    public let rowCount: Int
    /// Order-independent FNV-1a 64 fold over canonical row encodings,
    /// lowercase hex. Two captures are equal iff the table holds the
    /// same multiset of rows (up to FNV collision odds).
    public let contentFold: String

    public init(table: String, rowCount: Int, contentFold: String) {
        self.table = table
        self.rowCount = rowCount
        self.contentFold = contentFold
    }
}

/// Captures deterministic inventories of storage tables.
public enum DatabaseInventory {

    /// Capture the inventory of every table named in `tables`, in name order.
    ///
    /// Missing tables throw the backend's table-not-found error — callers
    /// enumerating a declared schema should only pass declared tables.
    ///
    /// - Parameters:
    ///   - storage: the storage to inventory.
    ///   - tables: table names to capture.
    ///   - excludingColumns: per-table column names to EXCLUDE from the fold
    ///     (e.g. a nondeterministic `created_at` audit stamp). Excluded
    ///     columns still count toward row presence via the row count.
    public static func capture(
        storage: any Storage,
        tables: [String],
        excludingColumns: [String: Set<String>] = [:]
    ) async throws -> [TableInventory] {
        var out: [TableInventory] = []
        out.reserveCapacity(tables.count)
        for table in tables.sorted() {
            let rows = try await storage.rowStore.query(
                table: table, where: nil, orderBy: [], limit: nil, offset: nil)
            let excluded = excludingColumns[table] ?? []
            var combined: UInt64 = 0
            for row in rows {
                let encoded = canonicalRowEncoding(row, excluding: excluded)
                let rowHash = SchemaLayoutFNV.fold(
                    bytes: Array(encoded.utf8), into: SchemaLayoutFNV.offsetBasis)
                combined = combined &+ rowHash
            }
            out.append(TableInventory(
                table: table,
                rowCount: rows.count,
                contentFold: String(format: "%016llx", combined)))
        }
        return out
    }

    /// Canonical, cross-port-stable encoding of one row.
    /// Columns sorted by name; excluded columns omitted.
    public static func canonicalRowEncoding(
        _ row: StorageRow,
        excluding excluded: Set<String> = []
    ) -> String {
        row.values
            .filter { !excluded.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(canonicalValueEncoding($0.value))" }
            .joined(separator: "\u{1F}")
    }

    /// Canonical, cross-port-stable encoding of one TypedValue.
    /// See the file header for the format table.
    public static func canonicalValueEncoding(_ value: TypedValue) -> String {
        switch value {
        case .null:
            return "n"
        case .bool(let b):
            return "b:\(b ? 1 : 0)"
        case .int(let i):
            return "i:\(i)"
        case .bitmap(let i):
            return "m:\(i)"
        case .float(let d):
            // IEEE-754 bit pattern — float TEXT rendering is not stable
            // across ports; the bit pattern is (f64 wire discipline).
            return "f:" + String(format: "%016llx", d.bitPattern)
        case .text(let t):
            return "t:\(t.utf8.count):\(t)"
        case .blob(let data):
            return "x:\(data.count):" + data.map { String(format: "%02x", $0) }.joined()
        case .uuid(let u):
            return "u:\(u.uuidString.lowercased())"
        case .timestamp(let date):
            // Epoch milliseconds, rounded — matches the Rust
            // `TypedValue::Timestamp(i64)` millisecond representation.
            return "s:\(Int64((date.timeIntervalSince1970 * 1000).rounded()))"
        case .json(let data):
            return "j:\(data.count):" + (String(data: data, encoding: .utf8)
                ?? data.map { String(format: "%02x", $0) }.joined())
        case .hlc(let hlc):
            return "h:\(hlc.packed)"
        case .fingerprint(let fp):
            // Four big-endian 64-bit blocks as 16-hex-digit groups — the
            // block layout both ports share (`Fingerprint256.words`).
            return "p:" + fp.words.map { String(format: "%016llx", $0) }.joined()
        case .array(let elements):
            return "a:[" + elements.map(canonicalValueEncoding).joined(separator: ",") + "]"
        }
    }
}
