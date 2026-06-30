// PostgreSQLPredicateCompiler.swift
//
// StoragePredicate → parameterized SQL with positional bindings.
// PostgreSQL uses $1, $2, ... parameter syntax.
//
// Column-name validation (SECFIX-WS2-PK F7): every predicate case that
// interpolates a column name into SQL calls `validatePSQLIdentifier` from
// `PostgreSQLIdentifierValidator.swift` before building the fragment. The
// `compile` entry point is now `throws` so callers propagate rejection.

import Foundation
import PersistenceKit

struct CompiledPostgreSQLPredicate {
    let sql: String
    let bindings: [TypedValue]
}

enum PostgreSQLPredicateCompiler {

    /// Compile `predicate` to a parameterized PostgreSQL WHERE clause.
    ///
    /// Throws `StorageError.invalidIdentifier` if any column name in the
    /// predicate tree contains characters outside `[A-Za-z_][A-Za-z0-9_]*`.
    /// All bindings are safe (bound values, never interpolated); only column
    /// identifiers are validated here (SECFIX-WS2-PK F7).
    static func compile(_ predicate: StoragePredicate) throws -> CompiledPostgreSQLPredicate {
        var bindings: [TypedValue] = []
        let sql = try render(predicate, bindings: &bindings)
        return CompiledPostgreSQLPredicate(sql: sql, bindings: bindings)
    }

    // render is now `throws` so identifier-validation errors propagate up.
    private static func render(_ p: StoragePredicate, bindings: inout [TypedValue]) throws -> String {
        switch p {
        case .and(let preds):
            if preds.isEmpty { return "TRUE" }
            return "(" + (try preds.map { try render($0, bindings: &bindings) }.joined(separator: " AND ")) + ")"
        case .or(let preds):
            if preds.isEmpty { return "FALSE" }
            return "(" + (try preds.map { try render($0, bindings: &bindings) }.joined(separator: " OR ")) + ")"
        case .not(let inner):
            return "(NOT \(try render(inner, bindings: &bindings)))"
        case .isTrue: return "TRUE"
        case .isFalse: return "FALSE"
        case .eq(let c, let v):
            try validatePSQLIdentifier(c.name)
            bindings.append(v)
            return "\"\(c.name)\" = $\(bindings.count)"
        case .neq(let c, let v):
            try validatePSQLIdentifier(c.name)
            bindings.append(v)
            return "\"\(c.name)\" <> $\(bindings.count)"
        case .lt(let c, let v):
            try validatePSQLIdentifier(c.name)
            bindings.append(v)
            return "\"\(c.name)\" < $\(bindings.count)"
        case .lte(let c, let v):
            try validatePSQLIdentifier(c.name)
            bindings.append(v)
            return "\"\(c.name)\" <= $\(bindings.count)"
        case .gt(let c, let v):
            try validatePSQLIdentifier(c.name)
            bindings.append(v)
            return "\"\(c.name)\" > $\(bindings.count)"
        case .gte(let c, let v):
            try validatePSQLIdentifier(c.name)
            bindings.append(v)
            return "\"\(c.name)\" >= $\(bindings.count)"
        case .isNull(let c):
            try validatePSQLIdentifier(c.name)
            return "\"\(c.name)\" IS NULL"
        case .isNotNull(let c):
            try validatePSQLIdentifier(c.name)
            return "\"\(c.name)\" IS NOT NULL"
        case .in(let c, let values):
            try validatePSQLIdentifier(c.name)
            if values.isEmpty { return "FALSE" }
            var placeholders: [String] = []
            for v in values {
                bindings.append(v)
                placeholders.append("$\(bindings.count)")
            }
            return "\"\(c.name)\" IN (\(placeholders.joined(separator: ", ")))"
        case .like(let c, let pattern):
            try validatePSQLIdentifier(c.name)
            bindings.append(.text(pattern))
            return "\"\(c.name)\" LIKE $\(bindings.count)"
        case .bitmaskAll(let c, let mask):
            try validatePSQLIdentifier(c.name)
            bindings.append(.int(mask))
            bindings.append(.int(mask))
            return "(\"\(c.name)\" & $\(bindings.count - 1)) = $\(bindings.count)"
        case .bitmaskAny(let c, let mask):
            try validatePSQLIdentifier(c.name)
            bindings.append(.int(mask))
            return "(\"\(c.name)\" & $\(bindings.count)) <> 0"
        case .bitmaskNone(let c, let mask):
            try validatePSQLIdentifier(c.name)
            bindings.append(.int(mask))
            return "(\"\(c.name)\" & $\(bindings.count)) = 0"
        case .bitwiseEq(let c, let expected, let mask):
            try validatePSQLIdentifier(c.name)
            bindings.append(.int(mask))
            bindings.append(.int(expected))
            return "(\"\(c.name)\" & $\(bindings.count - 1)) = $\(bindings.count)"
        }
    }
}
