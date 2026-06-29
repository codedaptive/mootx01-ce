// PostgreSQLSchema.swift
//
// Schema declaration → PostgreSQL DDL emission.

import Foundation
import PersistenceKit

enum PostgreSQLSchemaEmitter {

    static func createTableSQL(_ table: TableDeclaration) -> String {
        var cols: [String] = []
        for c in table.columns {
            cols.append(columnSQL(c))
        }
        // Generated columns. PostgreSQL only supports STORED, which
        // matches the cross-backend contract.
        for gen in table.generatedColumns {
            // renderSQL emits an integer expression (booleans as 0/1, shared
            // with InMemory/SQLite). A .bool generated column maps to PG
            // BOOLEAN, which won't accept an integer default — cast it.
            let expr = gen.type == .bool
                ? "(\(gen.expression.renderSQL()))::boolean"
                : gen.expression.renderSQL()
            cols.append("\"\(gen.name)\" \(typeSQL(gen.type)) "
                + "GENERATED ALWAYS AS (\(expr)) STORED")
        }
        if !table.primaryKey.isEmpty {
            let pk = table.primaryKey.map { "\"\($0)\"" }.joined(separator: ", ")
            cols.append("PRIMARY KEY (\(pk))")
        }
        for uc in table.uniqueConstraints {
            let cs = uc.map { "\"\($0)\"" }.joined(separator: ", ")
            cols.append("UNIQUE (\(cs))")
        }
        return "CREATE TABLE IF NOT EXISTS \"\(table.name)\" (\n  " + cols.joined(separator: ",\n  ") + "\n)"
    }

    static func columnSQL(_ c: ColumnDeclaration) -> String {
        var parts: [String] = ["\"\(c.name)\"", typeSQL(c.type)]
        if !c.nullable { parts.append("NOT NULL") }
        if let dv = c.defaultValue {
            parts.append("DEFAULT \(literalSQL(dv))")
        }
        return parts.joined(separator: " ")
    }

    static func typeSQL(_ t: ColumnType) -> String {
        switch t {
        case .uuid: return "UUID"
        case .bitmap, .int: return "BIGINT"
        case .text: return "TEXT"
        case .timestamp: return "TIMESTAMPTZ"
        case .float: return "DOUBLE PRECISION"
        case .bool: return "BOOLEAN"
        case .blob: return "BYTEA"
        case .json: return "JSONB"
        case .hlc: return "BIGINT"  // packed
        case .fingerprint: return "BYTEA"
        }
    }

    static func literalSQL(_ v: TypedValue) -> String {
        switch v {
        case .null: return "NULL"
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .int(let i), .bitmap(let i): return String(i)
        case .float(let f): return String(f)
        case .text(let s): return "'\(s.replacingOccurrences(of: "'", with: "''"))'"
        default: return "NULL"
        }
    }

    static func createIndexSQL(_ idx: IndexDeclaration) -> String {
        let unique = idx.unique ? "UNIQUE " : ""
        let cols = idx.columns.map { "\"\($0)\"" }.joined(separator: ", ")
        return "CREATE \(unique)INDEX IF NOT EXISTS \"\(idx.name)\" ON \"\(idx.table)\" (\(cols))"
    }

    /// Shared trigger function that raises on any attempted
    /// mutation. CREATE OR REPLACE makes this idempotent across
    /// repeated schema opens. One function serves every append-only
    /// table; TG_TABLE_NAME names the offending table at runtime.
    static let appendOnlyFunctionSQL = """
    CREATE OR REPLACE FUNCTION "_storagekit_reject_mutation"()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'table % is append-only', TG_TABLE_NAME;
    END;
    $$ LANGUAGE plpgsql
    """

    /// Per-table BEFORE UPDATE OR DELETE trigger statements that
    /// make a table append-only. PostgreSQL has no
    /// CREATE TRIGGER IF NOT EXISTS, so each trigger is dropped
    /// first for idempotence. Returns an empty array for tables
    /// that are not append-only.
    static func appendOnlyTriggerStatements(_ table: TableDeclaration) -> [String] {
        guard table.appendOnly else { return [] }
        let t = table.name
        let name = "trg_\(t)_append_only"
        return [
            "DROP TRIGGER IF EXISTS \"\(name)\" ON \"\(t)\"",
            """
            CREATE TRIGGER "\(name)"
            BEFORE UPDATE OR DELETE ON "\(t)"
            FOR EACH ROW EXECUTE FUNCTION "_storagekit_reject_mutation"()
            """
        ]
    }

    static func dropTableSQL(_ name: String) -> String {
        "DROP TABLE IF EXISTS \"\(name)\""
    }

    static func dropIndexSQL(_ name: String) -> String {
        "DROP INDEX IF EXISTS \"\(name)\""
    }

    static func addColumnSQL(table: String, column: ColumnDeclaration) -> String {
        // IF NOT EXISTS makes the operation idempotent (mirrors CREATE TABLE IF
        // NOT EXISTS): the fresh-DB path creates every table at the latest schema
        // before replaying migrations from version 0, so an addColumn migration
        // may target a column that already exists. PostgreSQL supports the guard
        // natively; SQLite/InMemory probe the existing columns instead.
        "ALTER TABLE \"\(table)\" ADD COLUMN IF NOT EXISTS \(columnSQL(column))"
    }

    static func dropColumnSQL(table: String, columnName: String) -> String {
        "ALTER TABLE \"\(table)\" DROP COLUMN \"\(columnName)\""
    }

    static func renameColumnSQL(table: String, from: String, to: String) -> String {
        "ALTER TABLE \"\(table)\" RENAME COLUMN \"\(from)\" TO \"\(to)\""
    }
}
