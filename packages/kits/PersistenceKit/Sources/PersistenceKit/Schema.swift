// Schema.swift
//
// Schema declaration per the PersistenceKit storage surface (Q1).
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
    /// default) pass through writes unmodified (node-tree integrity / NT-P2).
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
///. Columns tagged with a role participate in the
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
    /// as-of temporal filtering.
    static func createdHlc(_ name: String) -> ColumnDeclaration {
        ColumnDeclaration(name: name, type: .hlc, nullable: false, role: .createdHlc)
    }

    /// HLC column tagged as the row-tombstone timestamp for
    /// as-of temporal filtering. Nullable by
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

// MARK: - Ladder shape

/// One column a migration ladder adds: the check target of a schema repair.
public struct LadderColumn: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let table: String
    public let column: String

    public init(table: String, column: String) {
        self.table = table
        self.column = column
    }

    public var description: String { "\(table).\(column)" }
}

extension SchemaDeclaration {
    /// True when `stored` is a version this ladder cannot move: nonzero, no
    /// hop starts at it, and at least one hop starts below it. Such a
    /// version sits inside the ladder's range with no entry — a pre-release
    /// LocusKit estate at 11–18, for example. Replaying the hops above it
    /// and stamping the declared version would mark the estate current with
    /// every skipped hop's objects missing, so a runner must refuse instead.
    ///
    /// A stored version below every hop is not a hole: the base CREATE
    /// carried those versions and the ladder replays on top of it, which is
    /// how every kit whose ladder starts above 1 has always opened. A
    /// ladder with no hops never has a hole.
    public func ladderHasHole(atStoredVersion stored: Int) -> Bool {
        guard stored > 0, stored < version, !migrations.isEmpty else { return false }
        if migrations.contains(where: { $0.fromVersion == stored }) { return false }
        return migrations.contains(where: { $0.fromVersion < stored })
    }

    /// The hops that start at or above `fromVersion`, in ladder order: the
    /// set a repair replays.
    public func ladderHops(fromVersion: Int) -> [Migration] {
        migrations
            .filter { $0.fromVersion >= fromVersion }
            .sorted(by: { $0.fromVersion < $1.fromVersion })
    }

    /// Every column the hops from `fromVersion` up add. A storage backend
    /// probes these to tell a stamped-but-incomplete estate from a healthy
    /// one; the ledger row alone cannot.
    public func ladderColumns(fromVersion: Int) -> [LadderColumn] {
        var seen: Set<LadderColumn> = []
        var ordered: [LadderColumn] = []
        for hop in ladderHops(fromVersion: fromVersion) {
            for op in hop.operations {
                if case .addColumn(let table, let column) = op {
                    let ref = LadderColumn(table: table, column: column.name)
                    if seen.insert(ref).inserted { ordered.append(ref) }
                }
            }
        }
        return ordered
    }

    /// The refusal a runner throws for a hole, worded for the person who
    /// sees it: which kit, which version, and that a newer or older build
    /// is the only thing that moves it.
    public func ladderHoleError(atStoredVersion stored: Int) -> StorageError {
        .migrationFailed(
            version: stored,
            reason: "kit \(kitID) declares no migration from stored schema version \(stored); "
                + "opening would stamp version \(version) without the skipped objects. "
                + "This estate needs a build whose ladder starts at \(stored)."
        )
    }
}
