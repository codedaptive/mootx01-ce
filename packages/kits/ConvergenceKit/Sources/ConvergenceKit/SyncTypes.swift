// SyncTypes.swift
//
// Core enums and value types for ConvergenceKit.

import Foundation
import SubstrateTypes
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import PersistenceKit

/// Direction of replication per synced table.
public enum SyncDirection: String, Sendable, Codable {
    case bidirectional
    case pushOnly
    case pullOnly
}

/// Conflict resolution policy applied at the receive boundary.
public enum ConflictPolicy: String, Sendable, Codable {
    /// Default. HLC on the incoming record vs HLC on the local row wins.
    case lastWriterWinsByHLC
    /// (eventID, hlc) compound key makes duplicate appends idempotent.
    /// Used for the audit log.
    case appendOnly
    /// Receiver discards remote changes on conflict.
    case localWins
    /// Receiver overwrites local on conflict.
    case remoteWins
}

/// Declaration of a single synced table within a manifest.
public struct SyncedTable: Sendable, Codable {
    public let name: String
    public let direction: SyncDirection
    public let primaryKeyColumn: String
    public let conflictPolicy: ConflictPolicy

    /// Explicit CodingKeys documenting the cross-port JSON contract.
    /// Rust serde renames match these exact strings.
    private enum CodingKeys: String, CodingKey {
        case name, direction, primaryKeyColumn, conflictPolicy
    }

    public init(
        name: String,
        direction: SyncDirection = .bidirectional,
        primaryKeyColumn: String,
        conflictPolicy: ConflictPolicy = .lastWriterWinsByHLC
    ) {
        self.name = name
        self.direction = direction
        self.primaryKeyColumn = primaryKeyColumn
        self.conflictPolicy = conflictPolicy
    }
}

/// Declarative configuration for a sync session. The consumer
/// declares which PersistenceKit tables sync to which zone with
/// which conflict policies.
public struct SyncManifest: Sendable, Codable {
    public let kitID: String
    public let schemaVersion: Int
    public let zoneIdentifier: String
    public let tables: [SyncedTable]

    /// Explicit CodingKeys documenting the cross-port JSON contract.
    /// Rust serde renames match these exact strings.
    private enum CodingKeys: String, CodingKey {
        case kitID, schemaVersion, zoneIdentifier, tables
    }

    public init(
        kitID: String,
        schemaVersion: Int,
        zoneIdentifier: String,
        tables: [SyncedTable]
    ) {
        self.kitID = kitID
        self.schemaVersion = schemaVersion
        self.zoneIdentifier = zoneIdentifier
        self.tables = tables
    }

    public func table(named name: String) -> SyncedTable? {
        tables.first { $0.name == name }
    }
}

/// Result summary for one push or pull cycle.
public struct SyncReceipt: Sendable {
    public let pushed: Int
    public let pulled: Int
    public let conflicts: Int
    public let timestamp: Date

    public init(pushed: Int, pulled: Int, conflicts: Int, timestamp: Date = Date()) {
        self.pushed = pushed
        self.pulled = pulled
        self.conflicts = conflicts
        self.timestamp = timestamp
    }

    public static let empty = SyncReceipt(pushed: 0, pulled: 0, conflicts: 0)
}

/// Events emitted by `SyncEngine.subscribe()`.
public enum SyncEvent: Sendable {
    case remoteChangesApplied(count: Int)
    case pushCompleted(receipt: SyncReceipt)
    case peerConnected(identity: String)
    case peerDisconnected(identity: String, reason: String)
    case error(SyncError)
}

/// Coarse state for UI bindings.
public enum SyncState: Sendable {
    case disabled
    case enabled(zone: String, lastPushAt: Date?, lastPullAt: Date?)
    case syncing(direction: SyncDirection)
    case error(SyncError, retryAt: Date?)
}

/// Errors surfaced by ConvergenceKit operations.
public enum SyncError: Error, Sendable, Equatable {
    case notEnabled
    case alreadyEnabled
    case schemaMismatch(expected: Int, received: Int)
    case kitMismatch(expected: String, received: String)
    case transportFailure(detail: String)
    case decodingFailure(detail: String)
    case encodingFailure(detail: String)
    case peerUnreachable(identity: String)
    case authenticationFailed(detail: String)
    case unsupportedTable(name: String)
    /// A remote record's `recordName` could not be parsed as a UUID.
    /// Fabricating a fresh UUID from a corrupt `recordName` would create a
    /// phantom local row that desynchronises on every subsequent sync round.
    /// The record is quarantined: the pull loop counts it as a conflict,
    /// logs it, and continues to the next record rather than aborting the batch.
    case corruptRemoteIdentity(recordName: String)
}
