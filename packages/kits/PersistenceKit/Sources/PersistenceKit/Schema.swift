// Schema.swift
//
// Schema declaration per DECISION_STORAGEKIT_DESIGN §3 (Q1).
// Typed Swift structs. No result builder. Kits declare their
// schema once; PersistenceKit emits backend-native DDL.

import Foundation

public struct SchemaDeclaration: Sendable {
    public let kitID: String
    public let version: Int
    public let tables: [TableDeclaration]
    public let indices: [IndexDeclaration]
    public let migrations: [Migration]

    public init(
        kitID: String,
        version: Int,
        tables: [TableDeclaration],
        indices: [IndexDeclaration] = [],
        migrations: [Migration] = []
    ) {
        self.kitID = kitID
        self.version = version
        self.tables = tables
        self.indices = indices
        self.migrations = migrations
    }
}

public struct TableDeclaration: Sendable {
    public let name: String
    public let columns: [ColumnDeclaration]
    public let primaryKey: [String]
    public let uniqueConstraints: [[String]]
    /// Computed columns whose value is derived from an expression
    /// over other columns in the same row. SQLite and PostgreSQL
    /// emit native STORED generated columns; InMemory materializes
    /// them on every row write. Index a generated column with an
    /// ordinary IndexDeclaration that names it.
    public let generatedColumns: [GeneratedColumn]
    /// When true, the table rejects UPDATE and DELETE. SQLite emits
    /// a BEFORE UPDATE / BEFORE DELETE trigger pair that aborts;
    /// PostgreSQL attaches a BEFORE UPDATE OR DELETE trigger that
    /// raises; InMemory rejects in RowStore.update / delete with
    /// StorageError.appendOnlyViolation. INSERT remains allowed.
    public let appendOnly: Bool

    public init(
        name: String,
        columns: [ColumnDeclaration],
        primaryKey: [String],
        uniqueConstraints: [[String]] = [],
        generatedColumns: [GeneratedColumn] = [],
        appendOnly: Bool = false
    ) {
        self.name = name
        self.columns = columns
        self.primaryKey = primaryKey
        self.uniqueConstraints = uniqueConstraints
        self.generatedColumns = generatedColumns
        self.appendOnly = appendOnly
    }
}

public struct ColumnDeclaration: Sendable {
    public let name: String
    public let type: ColumnType
    public let nullable: Bool
    public let defaultValue: TypedValue?

    public init(
        name: String,
        type: ColumnType,
        nullable: Bool = false,
        defaultValue: TypedValue? = nil
    ) {
        self.name = name
        self.type = type
        self.nullable = nullable
        self.defaultValue = defaultValue
    }
}

public struct IndexDeclaration: Sendable {
    public let name: String
    public let table: String
    public let columns: [String]
    public let unique: Bool

    public init(name: String, table: String, columns: [String], unique: Bool = false) {
        self.name = name
        self.table = table
        self.columns = columns
        self.unique = unique
    }
}

public struct Migration: Sendable {
    public let fromVersion: Int
    public let toVersion: Int
    public let operations: [SchemaOperation]

    public init(fromVersion: Int, toVersion: Int, operations: [SchemaOperation]) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.operations = operations
    }
}

public enum SchemaOperation: Sendable {
    case createTable(TableDeclaration)
    case dropTable(name: String)
    case addColumn(table: String, column: ColumnDeclaration)
    case dropColumn(table: String, columnName: String)
    case renameColumn(table: String, from: String, to: String)
    case addIndex(IndexDeclaration)
    case dropIndex(name: String)
    case custom(sqlite: String?, postgresql: String?)  // Per-backend SQL escape hatch
}

// MARK: - Convenience constructors

public extension ColumnDeclaration {
    static func uuid(_ name: String, nullable: Bool = false) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .uuid, nullable: nullable)
    }

    static func bitmap(_ name: String, nullable: Bool = false, default: Int64 = 0) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .bitmap, nullable: nullable, defaultValue: .bitmap(`default`))
    }

    static func text(_ name: String, nullable: Bool = false) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .text, nullable: nullable)
    }

    static func timestamp(_ name: String, nullable: Bool = false) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .timestamp, nullable: nullable)
    }

    static func int(_ name: String, nullable: Bool = false) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .int, nullable: nullable)
    }

    static func float(_ name: String, nullable: Bool = false) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .float, nullable: nullable)
    }

    static func bool(_ name: String, nullable: Bool = false) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .bool, nullable: nullable)
    }

    static func blob(_ name: String, nullable: Bool = false) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .blob, nullable: nullable)
    }

    static func json(_ name: String, nullable: Bool = false) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .json, nullable: nullable)
    }

    static func hlc(_ name: String, nullable: Bool = false) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .hlc, nullable: nullable)
    }

    static func fingerprint(_ name: String, nullable: Bool = false) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .fingerprint, nullable: nullable)
    }
}
