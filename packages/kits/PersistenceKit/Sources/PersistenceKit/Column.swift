// Column.swift
//
// Column reference: (table, name) pair used in predicates and
// queries. Comparable for stable ordering in test fixtures.

import Foundation
import SubstrateTypes

public struct Column: Sendable, Hashable, Comparable {
    public let table: String
    public let name: String

    public init(table: String, name: String) {
        self.table = table
        self.name = name
    }

    public static func < (lhs: Column, rhs: Column) -> Bool {
        if lhs.table != rhs.table { return lhs.table < rhs.table }
        return lhs.name < rhs.name
    }
}

public enum ColumnType: String, Sendable, Hashable, Codable {
    case uuid
    case bitmap        // Int64 with bitwise semantics
    case text
    case timestamp
    case float         // Double precision
    case int           // Int64
    case bool
    case blob
    case json
    case hlc           // HLC stored as packed UInt64
    case fingerprint   // 32-byte blob
}
