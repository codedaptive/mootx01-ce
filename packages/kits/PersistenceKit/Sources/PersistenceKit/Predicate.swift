// StoragePredicate.swift
//
// StoragePredicate tree per DECISION_STORAGEKIT_DESIGN §4 (Q2).
// Closed enum, three operator families: logical, comparison, bitmap.
// BitmapEvaluator compiles Filter → StoragePredicate; backend compiles
// StoragePredicate → backend-native SQL. PersistenceKit treats predicates
// as opaque except for compilation.

import Foundation

public indirect enum StoragePredicate: Sendable {
    // Logical
    case and([StoragePredicate])
    case or([StoragePredicate])
    case not(StoragePredicate)
    case isTrue
    case isFalse

    // Comparison
    case eq(Column, TypedValue)
    case neq(Column, TypedValue)
    case lt(Column, TypedValue)
    case lte(Column, TypedValue)
    case gt(Column, TypedValue)
    case gte(Column, TypedValue)
    case isNull(Column)
    case isNotNull(Column)
    case `in`(Column, [TypedValue])
    case like(Column, String)

    // Bitmap (Int64 columns only)
    case bitmaskAll(Column, mask: Int64)
    case bitmaskAny(Column, mask: Int64)
    case bitmaskNone(Column, mask: Int64)
    case bitwiseEq(Column, expected: Int64, mask: Int64)
}

public extension StoragePredicate {
    /// Convenience: combine predicates with AND, short-circuiting
    /// trivial cases.
    static func all(_ predicates: [StoragePredicate]) -> StoragePredicate {
        let filtered = predicates.filter {
            if case .isTrue = $0 { return false }
            return true
        }
        if filtered.isEmpty { return .isTrue }
        if filtered.count == 1 { return filtered[0] }
        if filtered.contains(where: { if case .isFalse = $0 { return true }; return false }) {
            return .isFalse
        }
        return .and(filtered)
    }

    /// Convenience: combine predicates with OR.
    static func any(_ predicates: [StoragePredicate]) -> StoragePredicate {
        let filtered = predicates.filter {
            if case .isFalse = $0 { return false }
            return true
        }
        if filtered.isEmpty { return .isFalse }
        if filtered.count == 1 { return filtered[0] }
        if filtered.contains(where: { if case .isTrue = $0 { return true }; return false }) {
            return .isTrue
        }
        return .or(filtered)
    }
}

public enum OrderDirection: Sendable {
    case ascending
    case descending
}

public struct OrderClause: Sendable {
    public let column: Column
    public let direction: OrderDirection

    public init(column: Column, direction: OrderDirection = .ascending) {
        self.column = column
        self.direction = direction
    }
}
