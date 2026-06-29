// SnapshotRegistry.swift
//
// Snapshot registry and attestation primitives (ADR-017 §15).
//
// A snapshot is a registry row recording WHEN (an HLC), plus
// attestation rows recording WHAT the Merkle roots were at that HLC.
// The registry is a PersistenceKit primitive: it knows nothing about
// wings, drawers, or estates. Upper kits supply the subject_kind
// and subject_id semantics.

import Foundation
import SubstrateTypes

// MARK: - Types

/// Opaque identifier for a snapshot. String-typed for cross-backend
/// portability (SQLite TEXT PK, PostgreSQL TEXT PK, InMemory dict key).
public struct SnapshotId: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Mint a new snapshot id from a UUID.
    public static func mint() -> SnapshotId {
        SnapshotId(UUID().uuidString)
    }

    public var description: String { rawValue }
}

/// A row in the `snapshot_registry` table.
public struct SnapshotRecord: Sendable, Equatable {
    public let snapshotId: SnapshotId
    public let hlc: HLC
    public let label: String?
    public let createdAt: Date

    public init(snapshotId: SnapshotId, hlc: HLC, label: String?, createdAt: Date) {
        self.snapshotId = snapshotId
        self.hlc = hlc
        self.label = label
        self.createdAt = createdAt
    }
}

/// A row in the `snapshot_attestations` table.
public struct SnapshotAttestation: Sendable, Equatable {
    public let snapshotId: SnapshotId
    public let subjectKind: String
    public let subjectId: String
    public let merkleRoot: String
    /// HMAC key version if this attestation is commitment-bearing (§17).
    public let keyVersion: Int64?

    public init(
        snapshotId: SnapshotId,
        subjectKind: String,
        subjectId: String,
        merkleRoot: String,
        keyVersion: Int64? = nil
    ) {
        self.snapshotId = snapshotId
        self.subjectKind = subjectKind
        self.subjectId = subjectId
        self.merkleRoot = merkleRoot
        self.keyVersion = keyVersion
    }
}

// MARK: - Schema declarations

/// Table name constants for snapshot tables.
public enum SnapshotTables {
    public static let registry = "snapshot_registry"
    public static let attestations = "snapshot_attestations"
}

/// Schema declarations for snapshot registry and attestations tables.
/// Kits include these in their SchemaDeclaration.tables array.
public enum SnapshotSchema {
    /// `snapshot_registry` table: (snapshot_id TEXT PK, hlc HLC NOT NULL,
    /// label TEXT NULLABLE, created_at TIMESTAMP NOT NULL).
    public static let registryTable = TableDeclaration(
        name: SnapshotTables.registry,
        columns: [
            .text("snapshot_id"),
            .hlc("hlc"),
            .text("label", nullable: true),
            .timestamp("created_at"),
        ],
        primaryKey: ["snapshot_id"]
    )

    /// `snapshot_attestations` table: (snapshot_id TEXT NOT NULL FK,
    /// subject_kind TEXT NOT NULL, subject_id TEXT NOT NULL,
    /// merkle_root TEXT NOT NULL, key_version INT NULLABLE,
    /// PK(snapshot_id, subject_kind, subject_id)).
    public static let attestationsTable = TableDeclaration(
        name: SnapshotTables.attestations,
        columns: [
            .text("snapshot_id"),
            .text("subject_kind"),
            .text("subject_id"),
            .text("merkle_root"),
            .int("key_version", nullable: true),
        ],
        primaryKey: ["snapshot_id", "subject_kind", "subject_id"]
    )
}

// MARK: - CRUD operations

/// Snapshot registry operations on a RowStore.
///
/// These are free functions rather than protocol extensions so they
/// compose with any RowStore-conforming backend without requiring
/// the backend to know about snapshots.
public enum SnapshotRegistryOps {

    /// Create a new snapshot: mint a SnapshotId, record the current HLC,
    /// and write attestation rows for each supplied root.
    ///
    /// - Parameters:
    ///   - rowStore: The backend's row store.
    ///   - hlc: The HLC at which the snapshot is taken.
    ///   - label: Optional human-readable label.
    ///   - createdAt: The wall-clock creation time.
    ///   - attestations: Per-subject Merkle roots to attest.
    /// - Returns: The created `SnapshotRecord`.
    public static func createSnapshot(
        rowStore: any RowStore,
        hlc: HLC,
        label: String?,
        createdAt: Date,
        attestations: [SnapshotAttestation]
    ) async throws -> SnapshotRecord {
        let id = SnapshotId.mint()
        _ = try await rowStore.insert(
            table: SnapshotTables.registry,
            values: [
                "snapshot_id": .text(id.rawValue),
                "hlc": .hlc(hlc),
                "label": label.map { .text($0) } ?? .null,
                "created_at": .timestamp(createdAt),
            ]
        )
        for att in attestations {
            let attWithId = SnapshotAttestation(
                snapshotId: id,
                subjectKind: att.subjectKind,
                subjectId: att.subjectId,
                merkleRoot: att.merkleRoot,
                keyVersion: att.keyVersion
            )
            try await insertAttestation(rowStore: rowStore, attestation: attWithId)
        }
        return SnapshotRecord(snapshotId: id, hlc: hlc, label: label, createdAt: createdAt)
    }

    /// List all snapshots, ordered by HLC ascending.
    public static func listSnapshots(rowStore: any RowStore) async throws -> [SnapshotRecord] {
        let rows = try await rowStore.query(
            table: SnapshotTables.registry,
            where: nil,
            orderBy: [OrderClause(
                column: Column(table: SnapshotTables.registry, name: "hlc"),
                direction: .ascending
            )],
            limit: nil,
            offset: nil
        )
        return rows.compactMap { decodeSnapshotRecord($0) }
    }

    /// Delete a snapshot and its attestations. Returns true if the
    /// snapshot existed (and was deleted).
    public static func deleteSnapshot(
        rowStore: any RowStore,
        snapshotId: SnapshotId
    ) async throws -> Bool {
        // Delete attestations first (child rows).
        _ = try await rowStore.delete(
            table: SnapshotTables.attestations,
            where: .eq(
                Column(table: SnapshotTables.attestations, name: "snapshot_id"),
                .text(snapshotId.rawValue)
            )
        )
        // Delete registry row.
        let deleted = try await rowStore.delete(
            table: SnapshotTables.registry,
            where: .eq(
                Column(table: SnapshotTables.registry, name: "snapshot_id"),
                .text(snapshotId.rawValue)
            )
        )
        return deleted > 0
    }

    /// Read attestations for a given snapshot.
    public static func attestations(
        rowStore: any RowStore,
        snapshotId: SnapshotId
    ) async throws -> [SnapshotAttestation] {
        let rows = try await rowStore.query(
            table: SnapshotTables.attestations,
            where: .eq(
                Column(table: SnapshotTables.attestations, name: "snapshot_id"),
                .text(snapshotId.rawValue)
            ),
            orderBy: [
                OrderClause(
                    column: Column(table: SnapshotTables.attestations, name: "subject_kind"),
                    direction: .ascending
                ),
                OrderClause(
                    column: Column(table: SnapshotTables.attestations, name: "subject_id"),
                    direction: .ascending
                ),
            ],
            limit: nil,
            offset: nil
        )
        return rows.compactMap { decodeAttestation($0) }
    }

    // MARK: - Internal helpers

    static func insertAttestation(
        rowStore: any RowStore,
        attestation: SnapshotAttestation
    ) async throws {
        _ = try await rowStore.insert(
            table: SnapshotTables.attestations,
            values: [
                "snapshot_id": .text(attestation.snapshotId.rawValue),
                "subject_kind": .text(attestation.subjectKind),
                "subject_id": .text(attestation.subjectId),
                "merkle_root": .text(attestation.merkleRoot),
                "key_version": attestation.keyVersion.map { .int($0) } ?? .null,
            ]
        )
    }

    static func decodeSnapshotRecord(_ row: StorageRow) -> SnapshotRecord? {
        guard case .text(let id) = row["snapshot_id"],
              case .hlc(let hlc) = row["hlc"],
              case .timestamp(let createdAt) = row["created_at"]
        else { return nil }

        let label: String?
        if case .text(let l) = row["label"] {
            label = l
        } else {
            label = nil
        }

        return SnapshotRecord(
            snapshotId: SnapshotId(id),
            hlc: hlc,
            label: label,
            createdAt: createdAt
        )
    }

    static func decodeAttestation(_ row: StorageRow) -> SnapshotAttestation? {
        guard case .text(let sid) = row["snapshot_id"],
              case .text(let kind) = row["subject_kind"],
              case .text(let subId) = row["subject_id"],
              case .text(let root) = row["merkle_root"]
        else { return nil }

        let keyVersion: Int64?
        if case .int(let kv) = row["key_version"] {
            keyVersion = kv
        } else {
            keyVersion = nil
        }

        return SnapshotAttestation(
            snapshotId: SnapshotId(sid),
            subjectKind: kind,
            subjectId: subId,
            merkleRoot: root,
            keyVersion: keyVersion
        )
    }
}
