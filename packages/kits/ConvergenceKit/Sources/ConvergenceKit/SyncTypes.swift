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
    /// (v1.2-draft) Per-column HLC last-writer-wins. Each column in the
    /// incoming record is applied only when its HLC is >= the locally
    /// stored per-column HLC. Column HLCs are wire-carried (never derived
    /// by the receiver — A7 binding). Tombstone HLC must be >= ALL local
    /// column HLCs for the delete to win (edit-beats-delete rule).
    /// See B-8 in CONVERGENCEKIT_SPEC.md and FieldLWW/ for implementation.
    case fieldLevelLWW
}

/// Declaration of a single synced table within a manifest.
public struct SyncedTable: Sendable, Codable {
    public let name: String
    public let direction: SyncDirection
    public let primaryKeyColumn: String
    public let conflictPolicy: ConflictPolicy
    /// (v1.2-draft) Columns excluded from sync. These are locally recomputed
    /// on every device (scores, caches, derived values). Excluding them prevents
    /// sync storms: when an observer fires on a local compute update, the excluded
    /// columns are stripped from the outbox entry before it is persisted, so no
    /// outbound traffic is generated for data the receiver immediately recomputes.
    ///
    /// Exclusion semantics only — not inclusion: every column NOT in this set is
    /// synced. An inclusion list is a later additive change; it would require a
    /// schema-level registry of all sync-eligible columns that is not available
    /// at the ConvergenceKit layer.
    ///
    /// JSON contract: "excludedColumns" key; omitted from the wire when empty
    /// so existing serialised manifests decode without error (backward compatible).
    /// Rust twin: `excluded_columns: HashSet<String>` with serde default empty.
    public let excludedColumns: Set<String>

    /// Explicit CodingKeys documenting the cross-port JSON contract.
    /// Rust serde renames match these exact strings.
    private enum CodingKeys: String, CodingKey {
        case name, direction, primaryKeyColumn, conflictPolicy, excludedColumns
    }

    public init(
        name: String,
        direction: SyncDirection = .bidirectional,
        primaryKeyColumn: String,
        conflictPolicy: ConflictPolicy = .lastWriterWinsByHLC,
        excludedColumns: Set<String> = []
    ) {
        self.name = name
        self.direction = direction
        self.primaryKeyColumn = primaryKeyColumn
        self.conflictPolicy = conflictPolicy
        self.excludedColumns = excludedColumns
    }

    /// Custom decode: `excludedColumns` is optional in JSON so existing
    /// serialised manifests (without the key) decode with an empty set.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        direction = try c.decode(SyncDirection.self, forKey: .direction)
        primaryKeyColumn = try c.decode(String.self, forKey: .primaryKeyColumn)
        conflictPolicy = try c.decode(ConflictPolicy.self, forKey: .conflictPolicy)
        excludedColumns = try c.decodeIfPresent(Set<String>.self, forKey: .excludedColumns) ?? []
    }

    /// Custom encode: omit `excludedColumns` when empty to keep the wire
    /// representation compact and compatible with older receivers.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(direction, forKey: .direction)
        try c.encode(primaryKeyColumn, forKey: .primaryKeyColumn)
        try c.encode(conflictPolicy, forKey: .conflictPolicy)
        if !excludedColumns.isEmpty {
            try c.encode(excludedColumns, forKey: .excludedColumns)
        }
    }
}

/// Declarative configuration for a sync session. The consumer
/// declares which PersistenceKit tables sync to which zone with
/// which conflict policies.
///
/// ## Not Codable
///
/// `SyncManifest` is NOT `Codable`. The `postApplyIntegrityHook` closure
/// cannot be serialised, so the whole struct cannot synthesise `Codable`
/// conformance. `SyncManifest` is a local configuration object — it is
/// passed to `SyncEngine.enable(manifest:storage:)` and is never transmitted
/// over the wire. Only `SyncRecord` is the wire format.
///
/// Code that previously JSON-encoded a `SyncManifest` for cross-port
/// conformance testing should instead encode the `SyncedTable` array directly,
/// or test the `SyncRecord` wire format (which remains `Codable`).
public struct SyncManifest: Sendable {
    public let kitID: String
    public let schemaVersion: Int
    public let zoneIdentifier: String
    public let tables: [SyncedTable]

    /// (v1.2-draft) Optional callback invoked once per pull batch AFTER all
    /// inbound records have been applied. Use it to restore cross-row or
    /// cross-table structural invariants that row-grain conflict policies
    /// cannot maintain (Playground Rule 3, R3).
    ///
    /// **Invocation contract (CVK-ICLOUD P2-M3):**
    /// - Called once per pull cycle, after ALL records in the batch apply.
    /// - NOT called when the batch applied zero records (empty-batch rule).
    /// - A throw is logged and counted as ONE additional conflict in the
    ///   `SyncReceipt`; it does NOT abort the pull cycle.
    /// - Writes made through `AppliedBatch.storage` use the non-sync-tagged
    ///   paths (`upsert`, `insert`, `delete`), so they carry `origin == .local`
    ///   and flow into the outbox — hook-originated repairs ship to peers on
    ///   the next push cycle (Kong Q2 adjudication: hook-writes-must-ship).
    ///
    /// **Atomicity caveat:** PersistenceKit exposes no batch-transaction API.
    /// The hook runs after the batch applies but NOT inside a containing
    /// transaction. Design hooks to be idempotent (safe to re-run).
    ///
    /// Not `Codable` — closures cannot be serialised; set at construction only.
    public var postApplyIntegrityHook: (@Sendable (AppliedBatch) async throws -> Void)?

    public init(
        kitID: String,
        schemaVersion: Int,
        zoneIdentifier: String,
        tables: [SyncedTable],
        postApplyIntegrityHook: (@Sendable (AppliedBatch) async throws -> Void)? = nil
    ) {
        self.kitID = kitID
        self.schemaVersion = schemaVersion
        self.zoneIdentifier = zoneIdentifier
        self.tables = tables
        self.postApplyIntegrityHook = postApplyIntegrityHook
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
    /// Records held in the schema-skew queue (R9, CVK-ICLOUD P3-M4).
    ///
    /// Emitted during pull when inbound records have a schemaVersion GREATER
    /// than the local manifest version (the sender is on a newer schema).
    /// Also emitted from enable() when records still-held in the queue have
    /// a schemaVersion that is still newer than the now-enabled manifest.
    ///
    /// `count` is the number of records currently held — zero is not emitted.
    /// The held records are replayed automatically on the next enable() after
    /// the consumer updates its manifest's schemaVersion to match.
    ///
    /// Rust twin: `RecordsHeldForMigration { count: usize }`.
    case recordsHeldForMigration(count: Int)
    /// A CloudKit silent-push notification arrived for this engine's zone
    /// and the engine responded by nudging the poll scheduler.
    ///
    /// Emitted by `CloudKitSyncEngine.handleRemoteNotification(userInfo:)`
    /// BEFORE the nudge fires, so observers can distinguish a push-accelerated
    /// pull from a cadence-scheduled pull.
    ///
    /// This case is CloudKit-only. The None and Federation backends never emit it.
    /// Spec: CONVERGENCEKIT_SPEC.md § 5 B-3 (event stream).
    case remoteWakeReceived
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

    // ── N2 slot-registry errors (v1.2-draft) ──────────────────────────────
    // CloudKit-only. Vocabulary is mirrored in the Rust SyncError enum for
    // cross-port parity even though the CloudKit backend is Swift-only (N4).
    // Reference: DECISION_CONVERGENCEKIT_CONCURRENT_MULTIDEVICE_2026-07-16 §N2

    /// This device's (slot, epoch) pair has been superseded: the slot was
    /// evicted and its epoch bumped while this device was inactive.
    ///
    /// Recovery: the engine re-claims a fresh slot, re-mints pending outbox
    /// HLCs under the new nodeID, then resumes the pull cycle. No inbound
    /// records are applied until re-enrollment is complete — applying records
    /// with the old (colliding) nodeID would produce LWW ties that different
    /// replicas resolve differently.
    ///
    /// Signature matches CONVERGENCEKIT_INTERFACE.md §4 (v1.2-draft stub).
    case reenrollRequired(slot: Int, staleEpoch: Int, currentEpoch: Int)

    /// All 15 assignable node-ID slots (1–15) are occupied by recently-active
    /// devices. No records are applied. The engine retries after a backoff
    /// period; the error is surfaced to the caller loud (not silently dropped)
    /// because the real ceiling is 15 concurrent machines and hitting it is
    /// an operational signal that warrants attention.
    ///
    /// Signature matches CONVERGENCEKIT_INTERFACE.md §4 (v1.2-draft stub).
    case slotExhausted(activeCount: Int)
}
