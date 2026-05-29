// SQLiteDurabilityTail.swift
//
// SQLite durability tail per cookbook § 4.3 and paper § 11.2.
//
// The substrate's audit log lives in a SQLite database file. The
// working set (bit-tensor, fingerprint tensor) is a projection
// of the audit log; if the working set is lost or corrupted, it
// can always be rebuilt by replaying audit events.
//
// SQLite schema (cookbook § 4.3.2):
//
//   CREATE TABLE audit_events (
//       hlc_packed   INTEGER NOT NULL,
//       estate_uuid  BLOB    NOT NULL,
//       row_id       BLOB    NOT NULL,
//       actor        TEXT    NOT NULL,
//       mutation     TEXT    NOT NULL,
//       before_state BLOB,
//       after_state  BLOB    NOT NULL,
//       fingerprint  BLOB    NOT NULL,
//       lattice      TEXT    NOT NULL,
//       PRIMARY KEY (estate_uuid, hlc_packed, row_id)
//   );
//
//   CREATE INDEX audit_by_row ON audit_events (row_id, hlc_packed);
//   CREATE INDEX audit_by_hlc ON audit_events (hlc_packed);
//
// Pragmas for durability:
//   PRAGMA journal_mode = WAL;        (write-ahead log)
//   PRAGMA synchronous  = NORMAL;     (fsync on commit)
//   PRAGMA wal_autocheckpoint = 1000; (truncate WAL every 1000 frames)
//
// Reference implementation: protocol + in-memory backing for the
// conformance gate. Production code wires this to the C SQLite
// library via the system SQLite framework on Apple platforms or
// libsqlite3 on Linux.
//
// Used by:
//   § 4.3 cookbook   SQLite tail definition (this file)
//   § 11.2 paper     Persistence layer
//   § 6 cookbook     Audit log (the data this stores)
//   § 12 cookbook    Federation (audit-log exchange)

import Foundation

public protocol AuditEventStore {
    func append(_ event: SQLiteAuditEvent) throws
    func events(for rowId: RowId,
                upTo hlc: HLC?) throws -> [SQLiteAuditEvent]
    func events(in hlcRange: ClosedRange<HLC>) throws -> [SQLiteAuditEvent]
    func events(forEstate uuid: UUID,
                in hlcRange: ClosedRange<HLC>) throws -> [SQLiteAuditEvent]
    func eventCount() throws -> Int
    func truncate() throws
}

public struct SQLiteAuditEvent: Sendable, Equatable {
    public let hlc: HLC
    public let estateUUID: UUID
    public let rowId: RowId
    public let actor: String
    public let mutation: String
    public let beforeState: Data?
    public let afterState: Data
    public let fingerprint: Fingerprint256
    public let lattice: LatticeAnchor

    public init(hlc: HLC, estateUUID: UUID, rowId: RowId,
                actor: String, mutation: String,
                beforeState: Data?, afterState: Data,
                fingerprint: Fingerprint256, lattice: LatticeAnchor) {
        self.hlc = hlc
        self.estateUUID = estateUUID
        self.rowId = rowId
        self.actor = actor
        self.mutation = mutation
        self.beforeState = beforeState
        self.afterState = afterState
        self.fingerprint = fingerprint
        self.lattice = lattice
    }
}

/// In-memory reference implementation. Production wraps libsqlite3.
public final class InMemoryAuditStore: AuditEventStore {
    private var events: [SQLiteAuditEvent] = []

    public init() {}

    public func append(_ event: SQLiteAuditEvent) throws {
        events.append(event)
    }

    public func events(for rowId: RowId, upTo hlc: HLC?) throws -> [SQLiteAuditEvent] {
        return events
            .filter { $0.rowId == rowId && (hlc == nil || $0.hlc <= hlc!) }
            .sorted { $0.hlc < $1.hlc }
    }

    public func events(in hlcRange: ClosedRange<HLC>) throws -> [SQLiteAuditEvent] {
        return events
            .filter { hlcRange.contains($0.hlc) }
            .sorted { $0.hlc < $1.hlc }
    }

    public func events(forEstate uuid: UUID,
                       in hlcRange: ClosedRange<HLC>) throws -> [SQLiteAuditEvent] {
        return events
            .filter { $0.estateUUID == uuid && hlcRange.contains($0.hlc) }
            .sorted { $0.hlc < $1.hlc }
    }

    public func eventCount() throws -> Int {
        return events.count
    }

    public func truncate() throws {
        events.removeAll()
    }
}

/// Canonical SQL DDL for production schema setup.
public enum SQLiteTailSchema {
    public static let createTable: String = """
        CREATE TABLE IF NOT EXISTS audit_events (
            hlc_packed    INTEGER NOT NULL,
            estate_uuid   BLOB    NOT NULL,
            row_id        BLOB    NOT NULL,
            actor         TEXT    NOT NULL,
            mutation      TEXT    NOT NULL,
            before_state  BLOB,
            after_state   BLOB    NOT NULL,
            fingerprint   BLOB    NOT NULL,
            lattice       TEXT    NOT NULL,
            PRIMARY KEY (estate_uuid, hlc_packed, row_id)
        );
        """

    public static let createIndexByRow: String = """
        CREATE INDEX IF NOT EXISTS audit_by_row
            ON audit_events (row_id, hlc_packed);
        """

    public static let createIndexByHLC: String = """
        CREATE INDEX IF NOT EXISTS audit_by_hlc
            ON audit_events (hlc_packed);
        """

    public static let pragmas: [String] = [
        "PRAGMA journal_mode = WAL;",
        "PRAGMA synchronous = NORMAL;",
        "PRAGMA wal_autocheckpoint = 1000;",
    ]

    public static let insertEvent: String = """
        INSERT INTO audit_events
            (hlc_packed, estate_uuid, row_id, actor, mutation,
             before_state, after_state, fingerprint, lattice)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

    public static let selectByRow: String = """
        SELECT hlc_packed, estate_uuid, row_id, actor, mutation,
               before_state, after_state, fingerprint, lattice
        FROM audit_events
        WHERE row_id = ? AND hlc_packed <= ?
        ORDER BY hlc_packed ASC;
        """

    public static let selectByHLCRange: String = """
        SELECT hlc_packed, estate_uuid, row_id, actor, mutation,
               before_state, after_state, fingerprint, lattice
        FROM audit_events
        WHERE hlc_packed BETWEEN ? AND ?
        ORDER BY hlc_packed ASC;
        """
}
