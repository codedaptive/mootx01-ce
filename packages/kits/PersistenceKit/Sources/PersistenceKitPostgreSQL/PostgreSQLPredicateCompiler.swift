// PostgreSQLPredicateCompiler.swift
//
// StoragePredicate → parameterized SQL with positional bindings.
// PostgreSQL uses $1, $2, ... parameter syntax.

import Foundation
import PersistenceKit

struct CompiledPostgreSQLPredicate {
    let sql: String
    let bindings: [TypedValue]
}

enum PostgreSQLPredicateCompiler {

    static func compile(_ predicate: StoragePredicate) -> CompiledPostgreSQLPredicate {
        var bindings: [TypedValue] = []
        let sql = render(predicate, bindings: &bindings)
        return CompiledPostgreSQLPredicate(sql: sql, bindings: bindings)
    }

    private static func render(_ p: StoragePredicate, bindings: inout [TypedValue]) -> String {
        switch p {
        case .and(let preds):
            if preds.isEmpty { return "TRUE" }
            return "(" + preds.map { render($0, bindings: &bindings) }.joined(separator: " AND ") + ")"
        case .or(let preds):
            if preds.isEmpty { return "FALSE" }
            return "(" + preds.map { render($0, bindings: &bindings) }.joined(separator: " OR ") + ")"
        case .not(let inner):
            return "(NOT \(render(inner, bindings: &bindings)))"
        case .isTrue: return "TRUE"
        case .isFalse: return "FALSE"
        case .eq(let c, let v):
            bindings.append(v)
            return "\"\(c.name)\" = $\(bindings.count)"
        case .neq(let c, let v):
            bindings.append(v)
            return "\"\(c.name)\" <> $\(bindings.count)"
        case .lt(let c, let v):
            bindings.append(v)
            return "\"\(c.name)\" < $\(bindings.count)"
        case .lte(let c, let v):
            bindings.append(v)
            return "\"\(c.name)\" <= $\(bindings.count)"
        case .gt(let c, let v):
            bindings.append(v)
            return "\"\(c.name)\" > $\(bindings.count)"
        case .gte(let c, let v):
            bindings.append(v)
            return "\"\(c.name)\" >= $\(bindings.count)"
        case .isNull(let c):
            return "\"\(c.name)\" IS NULL"
        case .isNotNull(let c):
            return "\"\(c.name)\" IS NOT NULL"
        case .in(let c, let values):
            if values.isEmpty { return "FALSE" }
            var placeholders: [String] = []
            for v in values {
                bindings.append(v)
                placeholders.append("$\(bindings.count)")
            }
            return "\"\(c.name)\" IN (\(placeholders.joined(separator: ", ")))"
        case .like(let c, let pattern):
            bindings.append(.text(pattern))
            return "\"\(c.name)\" LIKE $\(bindings.count)"
        case .bitmaskAll(let c, let mask):
            bindings.append(.int(mask))
            bindings.append(.int(mask))
            return "(\"\(c.name)\" & $\(bindings.count - 1)) = $\(bindings.count)"
        case .bitmaskAny(let c, let mask):
            bindings.append(.int(mask))
            return "(\"\(c.name)\" & $\(bindings.count)) <> 0"
        case .bitmaskNone(let c, let mask):
            bindings.append(.int(mask))
            return "(\"\(c.name)\" & $\(bindings.count)) = 0"
        case .bitwiseEq(let c, let expected, let mask):
            bindings.append(.int(mask))
            bindings.append(.int(expected))
            return "(\"\(c.name)\" & $\(bindings.count - 1)) = $\(bindings.count)"
        }
    }
}
