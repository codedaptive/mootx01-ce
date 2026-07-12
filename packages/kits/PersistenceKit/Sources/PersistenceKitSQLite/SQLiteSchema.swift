// SQLiteSchema.swift
//
// Translates PersistenceKit SchemaDeclaration types into SQLite DDL.
// Owns the migrations bookkeeping table.

import Foundation
import PersistenceKit

enum SQLiteSchema {

    /// Map PersistenceKit ColumnType to SQLite native type.
    static func nativeType(_ type: ColumnType) -> String {
        switch type {
        case .uuid:        return "TEXT"        // UUID stored as canonical string
        case .bitmap:      return "INTEGER"
        case .text:        return "TEXT"
        case .timestamp:   return "TEXT"        // ISO-8601 UTC
        case .float:       return "REAL"
        case .int:         return "INTEGER"
        case .bool:        return "INTEGER"     // 0/1
        case .blob:        return "BLOB"
        case .json:        return "BLOB"
        case .hlc:         return "INTEGER"     // packed UInt64 as signed
        case .fingerprint: return "BLOB"        // 32 bytes
        }
    }

    /// Emit CREATE TABLE statement.
    static func createTable(_ decl: TableDeclaration) -> String {
        var parts: [String] = []
        for col in decl.columns {
            var line = "\"\(col.name)\" \(nativeType(col.type))"
            if !col.nullable { line += " NOT NULL" }
            if let dv = col.defaultValue {
                line += " DEFAULT \(literalSQL(dv))"
            }
            parts.append(line)
        }
        // Generated columns. Always STORED for cross-backend parity
        // with PostgreSQL (which has no VIRTUAL form). Indexable by
        // an ordinary CREATE INDEX naming the column.
        for gen in decl.generatedColumns {
            let line = "\"\(gen.name)\" \(nativeType(gen.type)) "
                + "GENERATED ALWAYS AS (\(gen.expression.renderSQL())) STORED"
            parts.append(line)
        }
        if !decl.primaryKey.isEmpty {
            let cols = decl.primaryKey.map { "\"\($0)\"" }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(cols))")
        }
        for unique in decl.uniqueConstraints {
            let cols = unique.map { "\"\($0)\"" }.joined(separator: ", ")
            parts.append("UNIQUE (\(cols))")
        }
        return "CREATE TABLE IF NOT EXISTS \"\(decl.name)\" (\n  " + parts.joined(separator: ",\n  ") + "\n)"
    }

    static func createIndex(_ decl: IndexDeclaration) -> String {
        let unique = decl.unique ? "UNIQUE " : ""
        let cols = decl.columns.map { "\"\($0)\"" }.joined(separator: ", ")
        return "CREATE \(unique)INDEX IF NOT EXISTS \"\(decl.name)\" ON \"\(decl.table)\" (\(cols))"
    }

    /// Emit the BEFORE UPDATE / BEFORE DELETE trigger pair that
    /// makes a table append-only. Each trigger aborts the statement
    /// with a descriptive message. Returns an empty array for
    /// tables that are not append-only.
    static func appendOnlyTriggers(_ decl: TableDeclaration) -> [String] {
        guard decl.appendOnly else { return [] }
        let t = decl.name
        let updateTrigger = """
        CREATE TRIGGER IF NOT EXISTS "trg_\(t)_no_update"
        BEFORE UPDATE ON "\(t)"
        BEGIN SELECT RAISE(ABORT, 'table \(t) is append-only'); END
        """
        let deleteTrigger = """
        CREATE TRIGGER IF NOT EXISTS "trg_\(t)_no_delete"
        BEFORE DELETE ON "\(t)"
        BEGIN SELECT RAISE(ABORT, 'table \(t) is append-only'); END
        """
        return [updateTrigger, deleteTrigger]
    }

    /// Render a TypedValue as a SQLite literal (for DEFAULT clauses).
    /// Only handles trivial cases; complex defaults use NULL.
    static func literalSQL(_ v: TypedValue) -> String {
        switch v {
        case .null: return "NULL"
        case .bool(let b): return b ? "1" : "0"
        case .int(let i): return String(i)
        case .bitmap(let i): return String(i)
        case .float(let d): return String(d)
        case .text(let s): return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
        case .uuid(let u): return "'\(u.uuidString)'"
        case .timestamp(let d): return "'\(ISO8601.string(from: d))'"
        case .hlc(let h): return String(Int64(bitPattern: h.packed))
        default: return "NULL"
        }
    }

    // MARK: - PersistenceKit-internal tables

    static let migrationsTableSQL = """
    CREATE TABLE IF NOT EXISTS "_storagekit_migrations" (
      "kit_id" TEXT NOT NULL,
      "version" INTEGER NOT NULL,
      "applied_at" TEXT NOT NULL,
      PRIMARY KEY ("kit_id")
    )
    """

    /// Internal audit log table (single source of truth for audit
    /// events). Schema:
    ///   event_id TEXT PK
    ///   hlc INTEGER PK
    ///   estate_uuid TEXT
    ///   row_id TEXT (indexed)
    ///   verb TEXT
    ///   before_adj INTEGER NULL
    ///   before_op  INTEGER NULL
    ///   before_pv  INTEGER NULL
    ///   after_adj  INTEGER
    ///   after_op   INTEGER
    ///   after_pv   INTEGER
    ///   before_udc INTEGER NULL
    ///   before_qid INTEGER NULL
    ///   after_udc  INTEGER
    ///   after_qid  INTEGER
    ///   actor      TEXT
    ///   reason     TEXT NULL   — caller-supplied reason for the mutation;
    ///                            NULL when no reason was provided
    static let auditTableSQL = """
    CREATE TABLE IF NOT EXISTS "_storagekit_audit" (
      "event_id" TEXT NOT NULL,
      "hlc" INTEGER NOT NULL,
      "estate_uuid" TEXT NOT NULL,
      "row_id" TEXT NOT NULL,
      "verb" TEXT NOT NULL,
      "before_adj" INTEGER,
      "before_op" INTEGER,
      "before_pv" INTEGER,
      "after_adj" INTEGER NOT NULL,
      "after_op" INTEGER NOT NULL,
      "after_pv" INTEGER NOT NULL,
      "before_udc" INTEGER,
      "before_qid" INTEGER,
      "after_udc" INTEGER NOT NULL,
      "after_qid" INTEGER NOT NULL,
      "actor" TEXT NOT NULL,
      "reason" TEXT,
      "physical_time" INTEGER NOT NULL DEFAULT 0,
      "logical_count" INTEGER NOT NULL DEFAULT 0,
      "node_id" INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY ("event_id", "hlc")
    )
    """

    // Audit ordering indexes are on the full-precision HLC columns
    // (physical_time, logical_count, node_id) — the chronological key every
    // audit read orders by. The packed `hlc` column is NOT an ordering key:
    // its field layout (node in the top byte, logical above physical) does
    // not preserve HLC order (HLC_PACKED_ORDER_UNSOUND finding); it remains
    // only as the PK dedup component. The old packed-column indexes are
    // dropped at open (no query uses them).
    static let auditIndexSQL = """
    CREATE INDEX IF NOT EXISTS "_storagekit_audit_row_chrono" ON "_storagekit_audit" ("row_id", "physical_time", "logical_count", "node_id")
    """

    static let auditHLCIndexSQL = """
    CREATE INDEX IF NOT EXISTS "_storagekit_audit_chrono" ON "_storagekit_audit" ("physical_time", "logical_count", "node_id")
    """

    static let auditDropPackedIndexesSQL = [
        "DROP INDEX IF EXISTS \"_storagekit_audit_row_hlc\"",
        "DROP INDEX IF EXISTS \"_storagekit_audit_hlc\"",
    ]

    /// One-time backfill for estates whose audit rows predate the
    /// full-precision HLC columns: reconstruct the three columns from the
    /// packed value so the chronological ORDER BY covers old rows. The
    /// packed form truncates physicalTime to 40 bits and nodeID to its low
    /// byte, so backfilled values carry exactly what `HLC(packed:)` would
    /// recover — the best available for pre-migration rows. Idempotent: a
    /// row whose columns are already populated fails the WHERE guard, and
    /// re-deriving a legitimately-zero physical_time row from its packed
    /// value writes back identical values. SQLite `>>` sign-extends
    /// negative integers; the `& 0xFFFF` / `& 0xFF` masks make the shifts
    /// layout-exact regardless of sign.
    static let auditBackfillFullHLCSQL = """
    UPDATE "_storagekit_audit"
    SET "physical_time" = ("hlc" & 0xFFFFFFFFFF),
        "logical_count" = (("hlc" >> 40) & 0xFFFF),
        "node_id" = CASE WHEN (("hlc" >> 56) & 0xFF) >= 128
                         THEN (("hlc" >> 56) & 0xFF) - 256
                         ELSE (("hlc" >> 56) & 0xFF) END
    WHERE "physical_time" = 0 AND "hlc" != 0
    """

    /// Blob storage table.
    static let blobTableSQL = """
    CREATE TABLE IF NOT EXISTS "_storagekit_blobs" (
      "key" TEXT PRIMARY KEY NOT NULL,
      "bytes" BLOB NOT NULL
    )
    """
}
