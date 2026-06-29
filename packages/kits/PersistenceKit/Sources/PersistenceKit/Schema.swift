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
    /// When true, the hash-on-write hook computes a ContentHash for
    /// every insert, update, and upsert on this table's rows. The
    /// hash is supplied by a `ContentHashProvider` callback injected
    /// into `HashingRowStore`; PersistenceKit does not import
    /// SubstrateLib or SubstrateKernel. Non-hashable tables (the
    /// default) pass through writes unmodified (ADR-017 §16 / NT-P2).
    public let hashable: Bool

    public init(
        name: String,
        columns: [ColumnDeclaration],
        primaryKey: [String],
        uniqueConstraints: [[String]] = [],
        generatedColumns: [GeneratedColumn] = [],
        appendOnly: Bool = false,
        hashable: Bool = false
    ) {
        self.name = name
        self.columns = columns
        self.primaryKey = primaryKey
        self.uniqueConstraints = uniqueConstraints
        self.generatedColumns = generatedColumns
        self.appendOnly = appendOnly
        self.hashable = hashable
    }
}

/// Semantic role of a column within the as-of temporal filter
/// (ADR-017 §15). Columns tagged with a role participate in the
/// temporal validity window: `created_hlc <= T AND
/// (tombstoned_hlc IS NULL OR tombstoned_hlc > T)`.
/// Kits declare roles at schema time; PersistenceKit uses them to
/// push the filter into the engine without knowing kit-specific
/// column names.
public enum ColumnRole: String, Sendable, Equatable {
    /// The HLC at which the row became valid.
    case createdHlc
    /// The HLC at which the row was superseded or deleted. Nullable
    /// by convention — a nil tombstone means "still live."
    case tombstonedHlc
}

public struct ColumnDeclaration: Sendable {
    public let name: String
    public let type: ColumnType
    public let nullable: Bool
    public let defaultValue: TypedValue?
    /// Semantic role for temporal filtering. nil means the column
    /// has no special role in the as-of filter.
    public let role: ColumnRole?

    public init(
        name: String,
        type: ColumnType,
        nullable: Bool = false,
        defaultValue: TypedValue? = nil,
        role: ColumnRole? = nil
    ) {
        self.name = name
        self.type = type
        self.nullable = nullable
        self.defaultValue = defaultValue
        self.role = role
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

    /// HLC column tagged as the row-creation timestamp for
    /// as-of temporal filtering (ADR-017 §15).
    static func createdHlc(_ name: String) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .hlc, nullable: false, role: .createdHlc)
    }

    /// HLC column tagged as the row-tombstone timestamp for
    /// as-of temporal filtering (ADR-017 §15). Nullable by
    /// convention — a nil tombstone means "still live."
    static func tombstonedHlc(_ name: String) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .hlc, nullable: true, role: .tombstonedHlc)
    }

    static func fingerprint(_ name: String, nullable: Bool = false) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .fingerprint, nullable: nullable)
    }
}

// MARK: - Temporal validity helpers

public extension TableDeclaration {
    /// Returns the column name tagged with `.createdHlc` role, if any.
    var createdHlcColumn: String? {
        columns.first(where: { $0.role == .createdHlc })?.name
    }

    /// Returns the column name tagged with `.tombstonedHlc` role, if any.
    var tombstonedHlcColumn: String? {
        columns.first(where: { $0.role == .tombstonedHlc })?.name
    }

    /// True when the table declares both temporal validity columns
    /// and can participate in as-of filtering.
    var supportsAsOfFilter: Bool {
        createdHlcColumn != nil
    }
}
