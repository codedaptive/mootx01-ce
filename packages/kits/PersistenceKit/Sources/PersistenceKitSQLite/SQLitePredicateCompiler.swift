// SQLitePredicateCompiler.swift
//
// Compile StoragePredicate trees to SQLite WHERE clauses with
// parameter binding.
//
// Column-name validation (SECFIX-WS2-PK F7): every predicate case that
// interpolates a column name into SQL calls `validateSQLIdentifier` from
// `SQLiteIdentifierValidator.swift` before building the fragment. The
// `compile` entry point is now `throws` so callers propagate rejection.

import Foundation
import PersistenceKit

struct CompiledPredicate {
    let sql: String
    let bindings: [TypedValue]
}

enum SQLitePredicateCompiler {

    /// Compile `predicate` to a parameterized SQLite WHERE clause.
    ///
    /// Throws `StorageError.invalidIdentifier` if any column name in the
    /// predicate tree contains characters outside `[A-Za-z_][A-Za-z0-9_]*`.
    /// All bindings are safe (bound values, never interpolated); only column
    /// identifiers are validated here (SECFIX-WS2-PK F7).
    static func compile(_ predicate: StoragePredicate) throws -> CompiledPredicate {
        var bindings: [TypedValue] = []
        let sql = try render(predicate, bindings: &bindings)
        return CompiledPredicate(sql: sql, bindings: bindings)
    }

    // render is now `throws` so identifier-validation errors propagate up.
    private static func render(_ predicate: StoragePredicate, bindings: inout [TypedValue]) throws -> String {
        switch predicate {
        case .isTrue: return "1=1"
        case .isFalse: return "1=0"
        case .and(let preds):
            if preds.isEmpty { return "1=1" }
            let parts = try preds.map { try render($0, bindings: &bindings) }
            return "(" + parts.joined(separator: " AND ") + ")"
        case .or(let preds):
            if preds.isEmpty { return "1=0" }
            let parts = try preds.map { try render($0, bindings: &bindings) }
            return "(" + parts.joined(separator: " OR ") + ")"
        case .not(let p):
            return "NOT (" + (try render(p, bindings: &bindings)) + ")"
        case .eq(let col, let v):
            try validateSQLIdentifier(col.name)
            bindings.append(v)
            return "\"\(col.name)\" = ?"
        case .neq(let col, let v):
            try validateSQLIdentifier(col.name)
            bindings.append(v)
            return "\"\(col.name)\" != ?"
        case .lt(let col, let v):
            try validateSQLIdentifier(col.name)
            bindings.append(v)
            return "\"\(col.name)\" < ?"
        case .lte(let col, let v):
            try validateSQLIdentifier(col.name)
            bindings.append(v)
            return "\"\(col.name)\" <= ?"
        case .gt(let col, let v):
            try validateSQLIdentifier(col.name)
            bindings.append(v)
            return "\"\(col.name)\" > ?"
        case .gte(let col, let v):
            try validateSQLIdentifier(col.name)
            bindings.append(v)
            return "\"\(col.name)\" >= ?"
        case .isNull(let col):
            try validateSQLIdentifier(col.name)
            return "\"\(col.name)\" IS NULL"
        case .isNotNull(let col):
            try validateSQLIdentifier(col.name)
            return "\"\(col.name)\" IS NOT NULL"
        case .in(let col, let values):
            try validateSQLIdentifier(col.name)
            if values.isEmpty { return "1=0" }
            let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
            bindings.append(contentsOf: values)
            return "\"\(col.name)\" IN (\(placeholders))"
        case .like(let col, let pattern):
            try validateSQLIdentifier(col.name)
            bindings.append(.text(pattern))
            return "\"\(col.name)\" LIKE ?"
        case .bitmaskAll(let col, let mask):
            try validateSQLIdentifier(col.name)
            bindings.append(.int(mask))
            bindings.append(.int(mask))
            return "(\"\(col.name)\" & ?) = ?"
        case .bitmaskAny(let col, let mask):
            try validateSQLIdentifier(col.name)
            bindings.append(.int(mask))
            return "(\"\(col.name)\" & ?) != 0"
        case .bitmaskNone(let col, let mask):
            try validateSQLIdentifier(col.name)
            bindings.append(.int(mask))
            return "(\"\(col.name)\" & ?) = 0"
        case .bitwiseEq(let col, let expected, let mask):
            try validateSQLIdentifier(col.name)
            bindings.append(.int(mask))
            bindings.append(.int(expected))
            return "(\"\(col.name)\" & ?) = ?"
        }
    }
}
