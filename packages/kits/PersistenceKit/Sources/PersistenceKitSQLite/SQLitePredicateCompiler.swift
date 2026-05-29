// SQLitePredicateCompiler.swift
//
// Compile StoragePredicate trees to SQLite WHERE clauses with
// parameter binding.

import Foundation
import PersistenceKit

struct CompiledPredicate {
    let sql: String
    let bindings: [TypedValue]
}

enum SQLitePredicateCompiler {

    static func compile(_ predicate: StoragePredicate) -> CompiledPredicate {
        var bindings: [TypedValue] = []
        let sql = render(predicate, bindings: &bindings)
        return CompiledPredicate(sql: sql, bindings: bindings)
    }

    private static func render(_ predicate: StoragePredicate, bindings: inout [TypedValue]) -> String {
        switch predicate {
        case .isTrue: return "1=1"
        case .isFalse: return "1=0"
        case .and(let preds):
            if preds.isEmpty { return "1=1" }
            let parts = preds.map { render($0, bindings: &bindings) }
            return "(" + parts.joined(separator: " AND ") + ")"
        case .or(let preds):
            if preds.isEmpty { return "1=0" }
            let parts = preds.map { render($0, bindings: &bindings) }
            return "(" + parts.joined(separator: " OR ") + ")"
        case .not(let p):
            return "NOT (" + render(p, bindings: &bindings) + ")"
        case .eq(let col, let v):
            bindings.append(v)
            return "\"\(col.name)\" = ?"
        case .neq(let col, let v):
            bindings.append(v)
            return "\"\(col.name)\" != ?"
        case .lt(let col, let v):
            bindings.append(v)
            return "\"\(col.name)\" < ?"
        case .lte(let col, let v):
            bindings.append(v)
            return "\"\(col.name)\" <= ?"
        case .gt(let col, let v):
            bindings.append(v)
            return "\"\(col.name)\" > ?"
        case .gte(let col, let v):
            bindings.append(v)
            return "\"\(col.name)\" >= ?"
        case .isNull(let col):
            return "\"\(col.name)\" IS NULL"
        case .isNotNull(let col):
            return "\"\(col.name)\" IS NOT NULL"
        case .in(let col, let values):
            if values.isEmpty { return "1=0" }
            let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
            bindings.append(contentsOf: values)
            return "\"\(col.name)\" IN (\(placeholders))"
        case .like(let col, let pattern):
            bindings.append(.text(pattern))
            return "\"\(col.name)\" LIKE ?"
        case .bitmaskAll(let col, let mask):
            bindings.append(.int(mask))
            bindings.append(.int(mask))
            return "(\"\(col.name)\" & ?) = ?"
        case .bitmaskAny(let col, let mask):
            bindings.append(.int(mask))
            return "(\"\(col.name)\" & ?) != 0"
        case .bitmaskNone(let col, let mask):
            bindings.append(.int(mask))
            return "(\"\(col.name)\" & ?) = 0"
        case .bitwiseEq(let col, let expected, let mask):
            bindings.append(.int(mask))
            bindings.append(.int(expected))
            return "(\"\(col.name)\" & ?) = ?"
        }
    }
}
