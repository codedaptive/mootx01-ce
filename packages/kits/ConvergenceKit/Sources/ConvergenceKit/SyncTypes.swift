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
    /// Per-column HLC last-writer-wins. Each column in the
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
    /// Columns excluded from sync. These are locally recomputed
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

/// Wire representation used for HLC fields (row-level `moot_sync_hlc`,
/// tombstone HLC, and `TypedValue.hlc` columns) when encoding or decoding
/// CKRecord data in a zone managed by `CKRecordMapping`.
///
/// This is a **local CloudKit encoding directive** — it lives in the manifest
/// and is never transmitted on the wire inside a CKRecord. The canonical
/// HLC wire format for federation and JSON (`PackedHLC` / `SyncValueBox.hlc`)
/// is always full-width and is unaffected by this declaration.
///
/// WHY a dedicated declaration rather than inferring from `schemaVersion`:
/// Generic schemaVersion 2 and 3 callers already exist in the test suite
/// (e.g. `FederationTombstoneRetentionTests` uses schemaVersion 2 and
/// `ProjectionTests` uses schemaVersion 3, both with legacyPacked zones).
/// Coupling representation to schemaVersion would silently break those
/// callers; the opt-in must be explicit per the binding decision (A1).
public enum HLCWireRepresentation: String, Sendable {
    /// Default. Row-level `moot_sync_hlc`, tombstone HLC, and
    /// `TypedValue.hlc` columns are encoded as a packed `Int64` via
    /// `NSNumber`. Layout: 48-bit `physicalTime` | 12-bit `logicalCount`
    /// | 4-bit `nodeID`. Byte-identical to all existing zones.
    ///
    /// Limitation: `logicalCount` values above 4095 (12-bit cap) and
    /// `physicalTime` bits above 47 are silently truncated. This was
    /// acceptable for the original zones; Fulcrum's new v2 zone adopts
    /// `.fullWidthV2` to fix this gap.
    case legacyPacked

    /// Explicit opt-in for Fulcrum's v2 zone. Row-level `moot_sync_hlc`,
    /// tombstone HLC, and `TypedValue.hlc` columns are encoded as
    /// `Data(HLC.wireBytes)` — exactly 16 bytes (8 bytes `physicalTime`
    /// LE + 4 bytes `logicalCount` LE + 4 bytes `nodeID` LE). Fully
    /// lossless: no component is truncated regardless of magnitude.
    ///
    /// Strict decode: `CKRecordMapping.decode(_:representation:)` fails
    /// closed (`SyncError.decodingFailure`) on any deviation — packed
    /// `NSNumber` where `Data` is expected, wrong-length `Data`, malformed
    /// wire bytes, or a column HLC in one representation while the
    /// row-level HLC is in the other (mixed-representation record).
    case fullWidthV2
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

    /// Columns to route through `CKRecord.encryptedValues` (CloudKit only).
    /// Key: table name matching an entry in `tables`. Value: set of column names
    /// to encrypt. Empty default → every existing caller's behavior is byte-identical.
    /// Not wire-carried: this is a local CloudKit encoding directive, never transmitted
    /// in a SyncRecord. Columns in the `moot_sync_` namespace and tables starting
    /// with `_ck_` are rejected by `validateEncryptedColumns()`. Registry columns
    /// stay plaintext.
    public let encryptedContentColumns: [String: Set<String>]

    /// HLC wire representation for this zone's CKRecord data (CloudKit only).
    ///
    /// Controls how `CKRecordMapping` encodes and decodes the row-level
    /// `moot_sync_hlc` field, tombstone HLC, and `TypedValue.hlc` columns.
    ///
    /// Default is `.legacyPacked` — every existing manifest and caller
    /// keeps byte-identical behavior without any code change. Fulcrum's
    /// new v2 zone opts in to `.fullWidthV2` for lossless HLC transport.
    ///
    /// Not wire-carried: this is a local CloudKit encoding directive that
    /// stays in the manifest. `SyncRecord` / federation wire format is
    /// always full-width (`PackedHLC`) and is unaffected by this field.
    public let hlcWireRepresentation: HLCWireRepresentation

    /// Optional callback invoked once per pull batch AFTER all
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

    /// Optional must-succeed boundary invoked after inbound rows and the
    /// non-fatal integrity hook have run, but before the CloudKit change cursor
    /// and successful-pull state are committed.
    ///
    /// Use this when accepting a transport batch requires a second durable,
    /// semantic operation. A throw aborts the pull cycle before cursor
    /// advancement, so the same CloudKit changes are offered again on the next
    /// pull. The callback is not invoked for an empty batch.
    ///
    /// The barrier guards both inbound routes. It runs on the pull path over
    /// the pulled batch, and on the schema-skew replay path in `enable()` over
    /// the records replayed from `_ck_pending_skew`. On replay a throw retains
    /// the queue entries and fails `enable()`, so the same held records are
    /// offered to the barrier again on the next `enable()`.
    ///
    /// The row writes have already happened and are not rolled back. Callers
    /// must therefore make this callback idempotent. This differs deliberately
    /// from `postApplyIntegrityHook`, whose failures remain non-fatal conflicts.
    ///
    /// CloudKit-only execution directive; not wire-carried or `Codable`.
    public var postApplyCommitBarrier: (@Sendable (AppliedBatch) async throws -> Void)?

    public init(
        kitID: String,
        schemaVersion: Int,
        zoneIdentifier: String,
        tables: [SyncedTable],
        encryptedContentColumns: [String: Set<String>] = [:],
        // Default is legacyPacked so every existing manifest and caller
        // stays byte/behavior-identical without any code change. Opt in
        // to fullWidthV2 only for zones explicitly designed for lossless
        // HLC transport (Fulcrum v2 zone). The parameter must be set at
        // construction; it is not inferred from schemaVersion because
        // generic schemaVersion-2/3 callers already exist with legacyPacked
        // zones (see HLCWireRepresentation doc for details).
        hlcWireRepresentation: HLCWireRepresentation = .legacyPacked,
        postApplyIntegrityHook: (@Sendable (AppliedBatch) async throws -> Void)? = nil,
        postApplyCommitBarrier: (@Sendable (AppliedBatch) async throws -> Void)? = nil
    ) {
        self.kitID = kitID
        self.schemaVersion = schemaVersion
        self.zoneIdentifier = zoneIdentifier
        self.tables = tables
        self.encryptedContentColumns = encryptedContentColumns
        self.hlcWireRepresentation = hlcWireRepresentation
        self.postApplyIntegrityHook = postApplyIntegrityHook
        self.postApplyCommitBarrier = postApplyCommitBarrier
    }

    /// Validate `encryptedContentColumns` entries before use.
    /// Rejects ConvergenceKit wire-metadata columns and `_ck_*`
    /// tables (registry tables that must stay plaintext per the mission spec).
    /// Phase-2 engine wiring will call this from CloudKitSyncEngine.enable(); tests call it directly.
    public func validateEncryptedColumns() throws {
        for (table, columns) in encryptedContentColumns {
            if table.hasPrefix("_ck_") {
                throw SyncError.encodingFailure(
                    detail: "encryptedContentColumns: '\(table)' is a registry table (_ck_*) and must stay plaintext"
                )
            }
            for column in columns {
                if SyncMetadataField.isReserved(column) {
                    throw SyncError.encodingFailure(
                        detail: "encryptedContentColumns: column '\(column)' in '\(table)' is a reserved sync-metadata field"
                    )
                }
            }
        }
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

    // ── N2 slot-registry errors ─────────────────────────────────────────────
    // CloudKit-only. Vocabulary is mirrored in the Rust SyncError enum for
    // cross-port parity even though the CloudKit backend is Swift-only (N4).
    // Slot and fence epoch identify the writer across concurrent devices.

    /// This device's (slot, epoch) pair has been superseded: the slot was
    /// evicted and its epoch bumped while this device was inactive.
    ///
    /// Recovery: the engine re-claims a fresh slot, re-mints pending outbox
    /// HLCs under the new nodeID, then resumes the pull cycle. No inbound
    /// records are applied until re-enrollment is complete — applying records
    /// with the old (colliding) nodeID would produce LWW ties that different
    /// replicas resolve differently.
    ///
    /// Signature matches CONVERGENCEKIT_INTERFACE.md §4.
    case reenrollRequired(slot: Int, staleEpoch: Int, currentEpoch: Int)

    /// All 15 assignable node-ID slots (1–15) are occupied by recently-active
    /// devices. No records are applied. The engine retries after a backoff
    /// period; the error is surfaced to the caller loud (not silently dropped)
    /// because the real ceiling is 15 concurrent machines and hitting it is
    /// an operational signal that warrants attention.
    ///
    /// Signature matches CONVERGENCEKIT_INTERFACE.md §4.
    case slotExhausted(activeCount: Int)
}
