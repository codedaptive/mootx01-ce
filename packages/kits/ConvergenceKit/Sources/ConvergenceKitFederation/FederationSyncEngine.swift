// FederationSyncEngine.swift
//
// Substrate-native CRDT exchange per paper section 9.
//
// At v1.0 the engine provides:
// - Per-estate Ed25519 identity
// - In-process peer registry (paired peers exchange SignedEnvelope
//   messages through a shared Relay; the stored peer reference is
//   used for pairing registration, not direct message exchange)
// - Audit-event-style replication via SyncRecord wire format
// - Last-writer-wins-by-HLC and append-only conflict policies
//
// Wire transport for cross-machine federation (HTTPS-relay,
// peer-to-peer, IPFS) is a v1.x decision. In-process pairing is
// enough to exercise the protocol and the cross-perimeter math
// in tests.

import Foundation
import Crypto
import ConvergenceKit
import PersistenceKit
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
import SubstrateTypes
import os

private let logger = Logger(subsystem: "com.mootx01.synckit.federation", category: "Engine")

public final class FederationSyncEngine: SyncEngine, Sendable {
    let stateActor: FederationStateActor

    public init() {
        self.stateActor = FederationStateActor()
    }

    public func enable(manifest: SyncManifest, storage: any Storage) async throws {
        try await stateActor.enable(manifest: manifest, storage: storage)
    }

    public func disable() async throws {
        await stateActor.disable()
    }

    public func push() async throws -> SyncReceipt {
        try await stateActor.push()
    }

    public func pull() async throws -> SyncReceipt {
        try await stateActor.pull()
    }

    public func subscribe() -> AsyncStream<SyncEvent> {
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let task = Task { await stateActor.attachSubscriber(continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public var state: SyncState {
        get async { await stateActor.currentState }
    }

    /// Pair with a peer. Both sides exchange public keys plus a
    /// shared hyperplane family spec. After pairing, push/pull
    /// routes JSON-encoded SyncRecord batches inside SignedEnvelope
    /// messages through the peer's relay inbox.
    ///
    /// For v1.0 pairing is in-process: both peers share a
    /// FederationRelay instance.
    public func pair(with peer: FederationSyncEngine, via relay: any Relay, family: HyperplaneFamilySpec) async throws {
        try await stateActor.pair(with: peer.stateActor, via: relay, family: family)
    }

    public var identity: LocalIdentity {
        get async { stateActor.localIdentity }
    }
}

// MARK: - PayloadKind

/// Discriminator for the opaque payload carried by `SignedEnvelope`.
/// The single-byte tag is embedded in the canonical signing bytes so the
/// receiver knows how to decode the payload without ambiguity.
///
/// Variants are assigned stable byte values; never reuse a value.
/// `syncRecordBatch` (0x01) is the only v1.0 variant. `fieldWriteEventBatch`
/// (0x02) is reserved for the next-gen write-path payload (C1 extension point).
public enum PayloadKind: UInt8, Sendable, Codable, Hashable {
    /// A JSON-encoded array of `SyncRecord` values. The only v1.0 payload.
    case syncRecordBatch = 0x01
    // fieldWriteEventBatch = 0x02  — reserved; add when FieldWriteEvent
    // wire format lands. Do not assign 0x02 to anything else.
}

// MARK: - Canonical signing bytes

/// Build the canonical deterministic byte sequence that `SignedEnvelope.signature`
/// covers.
///
/// Layout (all integers little-endian):
///   sender_public_key (32 bytes, Ed25519 pubkey raw)
///   payload_kind      (1 byte: PayloadKind raw value)
///   payload_len       (4 bytes: LE uint32 count of payload bytes)
///   payload           (payload_len bytes: opaque batch bytes)
///   hlc.physicalTime  (8 bytes: LE int64)
///   hlc.logicalCount  (4 bytes: LE int32)
///   hlc.nodeID        (4 bytes: LE int32)
///
/// This encoding is byte-identical to the Rust `envelope_signing_bytes` in
/// `federation.rs`. The signature must verify cross-port.
///
/// - Parameters:
///   - senderPublicKey: 32-byte Ed25519 public key.
///   - payloadKind: Discriminator for the payload's meaning.
///   - payload: Opaque batch bytes (e.g. JSON-encoded `[SyncRecord]`).
///   - hlc: Batch-level HLC timestamp packed into three integer fields.
/// - Returns: The canonical bytes to sign or verify.
public func envelopeSigningBytes(
    senderPublicKey: Data,
    payloadKind: PayloadKind,
    payload: Data,
    hlc: PackedHLC
) -> Data {
    var out = Data()
    out.reserveCapacity(32 + 1 + 4 + payload.count + 8 + 4 + 4)

    // 32-byte public key
    out.append(contentsOf: senderPublicKey)

    // 1-byte payload kind discriminator
    out.append(payloadKind.rawValue)

    // 4-byte LE length prefix for payload
    var payloadLen = UInt32(payload.count).littleEndian
    withUnsafeBytes(of: &payloadLen) { out.append(contentsOf: $0) }

    // Payload bytes
    out.append(payload)

    // HLC: 8-byte LE physicalTime, 4-byte LE logicalCount, 4-byte LE nodeID
    var pt = hlc.physicalTime.littleEndian
    withUnsafeBytes(of: &pt) { out.append(contentsOf: $0) }
    var lc = hlc.logicalCount.littleEndian
    withUnsafeBytes(of: &lc) { out.append(contentsOf: $0) }
    var ni = hlc.nodeID.littleEndian
    withUnsafeBytes(of: &ni) { out.append(contentsOf: $0) }

    return out
}

// MARK: - SignedEnvelope

/// The authenticated wire envelope for federated sync.
///
/// Carries an opaque batch payload (discriminated by `payloadKind`) signed with
/// the sender's Ed25519 key. The signature covers deterministic canonical bytes
/// produced by `envelopeSigningBytes(...)`, not raw JSON — closing the
/// relabel/replay seam and ensuring cross-port byte-identical verification.
///
/// `payloadKind` is a C1 extension point: v1.0 only knows `syncRecordBatch`;
/// `fieldWriteEventBatch` is reserved for the next-gen write-path payload.
/// A receiver that encounters an unknown `payloadKind` should reject the
/// envelope as a conflict rather than crash.
public struct SignedEnvelope: Sendable, Codable {
    /// 32-byte Ed25519 public key of the sender.
    public let senderPublicKey: Data
    /// Discriminator for the opaque payload's type.
    public let payloadKind: PayloadKind
    /// Opaque canonical bytes for the batch (e.g. JSON-encoded `[SyncRecord]`
    /// when `payloadKind == .syncRecordBatch`).
    public let payload: Data
    /// Ed25519 signature over `envelopeSigningBytes(senderPublicKey:payloadKind:payload:hlc:)`.
    /// Not over raw payload bytes — this closes the relabel/replay seam.
    public let signature: Data
    /// Batch-level HLC timestamp. Strictly ordered after the records it carries
    /// (the sender advances the clock once more after minting record HLCs).
    public let hlc: PackedHLC

    public init(
        senderPublicKey: Data,
        payloadKind: PayloadKind,
        payload: Data,
        signature: Data,
        hlc: PackedHLC
    ) {
        self.senderPublicKey = senderPublicKey
        self.payloadKind = payloadKind
        self.payload = payload
        self.signature = signature
        self.hlc = hlc
    }
}

// MARK: - Relay protocol

/// Transport abstraction for federated sync. Swapping the implementation
/// swaps the transport without touching the engine; the in-process
/// `FederationRelay` below serves local peering and tests, and a hosted
/// HTTPS/gRPC relay (a third-party SyncServer) is a drop-in conformer —
/// this protocol is that extension point.
public protocol Relay: Sendable {
    /// Deliver a signed envelope to a recipient's inbox.
    func send(to recipient: Data, message: SignedEnvelope)
    /// Drain (and clear) the recipient's pending inbound envelopes.
    func drain(for recipient: Data) -> [SignedEnvelope]
}

/// Shared in-process relay used by paired engines for v1.0 (the
/// local/test `Relay`). In production a hosted relay conforms instead.
public final class FederationRelay: Relay, @unchecked Sendable {
    private let lock = NSLock()
    private var inboxes: [Data: [SignedEnvelope]] = [:]  // keyed by recipient public key

    public init() {}

    public func send(to recipient: Data, message: SignedEnvelope) {
        lock.lock()
        defer { lock.unlock() }
        inboxes[recipient, default: []].append(message)
    }

    public func drain(for recipient: Data) -> [SignedEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        let msgs = inboxes[recipient] ?? []
        inboxes[recipient] = []
        return msgs
    }
}

// MARK: - FederationStateActor

actor FederationStateActor {
    let localIdentity = LocalIdentity()
    var manifest: SyncManifest?
    var storage: (any Storage)?
    var isEnabled: Bool = false
    var lastPushAt: Date?
    var lastPullAt: Date?
    var observerTasks: [Task<Void, Never>] = []
    var pendingOutbound: [TableChange] = []
    var subscribers: [AsyncStream<SyncEvent>.Continuation] = []
    var peers: [PairedPeer] = []
    var hlcGenerator = HLCGenerator(nodeID: Int32.random(in: 1...0x0F))

    struct PairedPeer {
        let publicKey: Data
        weak var actor: FederationStateActor?
        let relay: any Relay
        let family: HyperplaneFamilySpec
    }

    func enable(manifest: SyncManifest, storage: any Storage) async throws {
        if isEnabled { throw SyncError.alreadyEnabled }
        self.manifest = manifest
        self.storage = storage
        // Ensure the _fed_sync_meta side table exists before any pull.
        // Mirrors the CloudKit engine's ensureSyncMetaTable call in enable() so
        // the LWW side-table path is available from the first apply (A6 unification).
        try await Self.ensureFedSyncMetaTable(storage: storage)
        for table in manifest.tables where table.direction != .pullOnly {
            let stream = storage.observer.observe(table: table.name, events: [.insert, .update, .delete])
            let task = Task { [weak self] in
                for await change in stream {
                    await self?.recordOutbound(change)
                }
            }
            observerTasks.append(task)
        }
        isEnabled = true
    }

    func disable() async {
        isEnabled = false
        // Cancel each observer task, then await its completion so write
        // capture is deterministically stopped before disable returns —
        // no late write can land in the outbox across the disable boundary.
        // This mirrors the Rust port joining its observer worker threads in
        // `stop_observers`. Cancelling without awaiting would leave a race
        // window where a buffered change is still processed after disable.
        let tasks = observerTasks
        observerTasks.removeAll()
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        for sub in subscribers { sub.finish() }
        subscribers.removeAll()
        pendingOutbound.removeAll()
        peers.removeAll()
        manifest = nil
        storage = nil
    }

    func recordOutbound(_ change: TableChange) {
        pendingOutbound.append(change)
    }

    func attachSubscriber(_ continuation: AsyncStream<SyncEvent>.Continuation) {
        subscribers.append(continuation)
    }

    private func emit(_ event: SyncEvent) {
        for s in subscribers { s.yield(event) }
    }

    var currentState: SyncState {
        if let m = manifest, isEnabled {
            return .enabled(zone: m.zoneIdentifier, lastPushAt: lastPushAt, lastPullAt: lastPullAt)
        }
        return .disabled
    }

    func pair(with peerActor: FederationStateActor, via relay: any Relay, family: HyperplaneFamilySpec) async throws {
        let peerPubKey = peerActor.localIdentity.publicKey
        peers.append(PairedPeer(publicKey: peerPubKey, actor: peerActor, relay: relay, family: family))
        // Symmetric: register ourselves on the peer too.
        await peerActor.acceptPeering(publicKey: localIdentity.publicKey, relay: relay, family: family)
        emit(.peerConnected(identity: peerPubKey.base64EncodedString()))
    }

    func acceptPeering(publicKey: Data, relay: any Relay, family: HyperplaneFamilySpec) {
        peers.append(PairedPeer(publicKey: publicKey, actor: nil, relay: relay, family: family))
        emit(.peerConnected(identity: publicKey.base64EncodedString()))
    }

    func push() async throws -> SyncReceipt {
        guard isEnabled, let manifest else { throw SyncError.notEnabled }
        if peers.isEmpty {
            return SyncReceipt.empty
        }

        // Build SyncRecords from pendingOutbound.
        var records: [SyncRecord] = []
        let pending = pendingOutbound
        pendingOutbound.removeAll()
        for change in pending {
            guard let syncedTable = manifest.table(named: change.table) else { continue }
            guard syncedTable.direction != .pullOnly else { continue }
            guard let rowKey = change.rowKey else { continue }
            // Prefer the HLC that already ordered the change. If the
            // observation carried none, mint a monotonic one through
            // the generator. Use send(now:), not currentTime():
            // currentTime() is a read-only snapshot that does not
            // advance the clock, so two HLC-less changes in the same
            // batch would collide on an identical timestamp. send()
            // advances the logical counter and takes the clock as a
            // parameter, keeping the engine deterministic.
            let hlc = change.hlc ?? hlcGenerator.send(now: nowMillis())
            let eventKind = SyncEventKind(from: change.event)
            // Tombstone flag: set syncDeleted = true for delete events so the
            // receiver knows to apply the tombstone path (LWW gate + side-table
            // HLC persistence) rather than a normal upsert. Matches the A6
            // unification contract and the Rust wire format (C-8 parity).
            let syncDeleted: Bool? = eventKind == .delete ? true : nil
            let record = SyncRecord(
                table: change.table,
                event: eventKind,
                rowKey: rowKey,
                values: change.values.map { SyncValueMap($0) },
                hlc: PackedHLC(hlc),
                schemaVersion: manifest.schemaVersion,
                kitID: manifest.kitID,
                syncDeleted: syncDeleted
            )
            records.append(record)
        }

        if records.isEmpty {
            return SyncReceipt.empty
        }

        // Encode the batch to opaque bytes. SyncRecord has a conformance-gated
        // wire format (JSON via Codable / serde_json). The envelope's canonical
        // signing bytes wrap this payload with a length prefix so the boundary
        // is unambiguous when computing the signature.
        let payloadBytes: Data
        do {
            payloadBytes = try JSONEncoder().encode(records)
        } catch {
            throw SyncError.encodingFailure(detail: "encode SyncRecords: \(error)")
        }

        // Batch-level HLC: advance the clock once more. Records that already
        // carried change.hlc are not incorporated into the generator before this
        // mint, so strict ordering after every record HLC is not guaranteed.
        let batchHLC = PackedHLC(hlcGenerator.send(now: nowMillis()))

        // Build canonical signing bytes and sign with sender's Ed25519 key.
        // The signature covers (senderPublicKey || payloadKind || payload_len
        // || payload || hlc) — not raw JSON — closing the relabel/replay seam.
        let signingBytes = envelopeSigningBytes(
            senderPublicKey: localIdentity.publicKey,
            payloadKind: .syncRecordBatch,
            payload: payloadBytes,
            hlc: batchHLC
        )
        let signature: Data
        do {
            signature = try localIdentity.sign(signingBytes)
        } catch {
            throw SyncError.encodingFailure(detail: "sign envelope: \(error)")
        }

        let envelope = SignedEnvelope(
            senderPublicKey: localIdentity.publicKey,
            payloadKind: .syncRecordBatch,
            payload: payloadBytes,
            signature: signature,
            hlc: batchHLC
        )

        var pushedCount = 0
        for peer in peers {
            peer.relay.send(to: peer.publicKey, message: envelope)
            pushedCount += records.count
        }

        lastPushAt = Date()
        let receipt = SyncReceipt(pushed: pushedCount, pulled: 0, conflicts: 0)
        emit(.pushCompleted(receipt: receipt))
        return receipt
    }

    func pull() async throws -> SyncReceipt {
        guard isEnabled, let manifest, let storage else { throw SyncError.notEnabled }
        var appliedCount = 0
        var conflicts = 0

        for peer in peers {
            let envelopes = peer.relay.drain(for: localIdentity.publicKey)
            for envelope in envelopes {
                // Only accept envelopes from explicitly paired peers. A valid
                // signature alone does not prove pairing authorization
                // (ADR-013): an attacker could craft a self-signed envelope
                // and inject records without completing the pairing handshake.
                // This check enforces the authorization boundary before any
                // further processing. Mirrors Rust federation.rs pull().
                guard envelope.senderPublicKey == peer.publicKey else {
                    conflicts += 1
                    logger.error("envelope from unpaired sender \(envelope.senderPublicKey.base64EncodedString()) rejected")
                    continue
                }

                // Reject unknown payload kinds to avoid misinterpreting future
                // payload types. Known: .syncRecordBatch. Unknown kinds are
                // counted as conflicts and logged; no crash.
                guard envelope.payloadKind == .syncRecordBatch else {
                    conflicts += 1
                    logger.error("unknown payload kind \(envelope.payloadKind.rawValue) from \(envelope.senderPublicKey.base64EncodedString())")
                    continue
                }

                // Verify signature over canonical bytes (not raw payload).
                // The sender signed envelopeSigningBytes(...); we reproduce
                // the same bytes here for verification.
                let signingBytes = envelopeSigningBytes(
                    senderPublicKey: envelope.senderPublicKey,
                    payloadKind: envelope.payloadKind,
                    payload: envelope.payload,
                    hlc: envelope.hlc
                )
                guard FederationSignature.verify(
                    envelope.signature,
                    of: signingBytes,
                    by: envelope.senderPublicKey
                ) else {
                    conflicts += 1
                    logger.error("signature verification failed from \(envelope.senderPublicKey.base64EncodedString())")
                    continue
                }

                // Decode the batch from the opaque payload.
                let records: [SyncRecord]
                do {
                    records = try JSONDecoder().decode([SyncRecord].self, from: envelope.payload)
                } catch {
                    conflicts += 1
                    continue
                }

                for record in records {
                    do {
                        guard record.kitID == manifest.kitID else {
                            throw SyncError.kitMismatch(expected: manifest.kitID, received: record.kitID)
                        }
                        guard record.schemaVersion == manifest.schemaVersion else {
                            throw SyncError.schemaMismatch(expected: manifest.schemaVersion, received: record.schemaVersion)
                        }
                        guard let syncedTable = manifest.table(named: record.table) else {
                            throw SyncError.unsupportedTable(name: record.table)
                        }
                        guard syncedTable.direction != .pushOnly else { continue }

                        try await applyInbound(record, syncedTable: syncedTable, storage: storage)
                        appliedCount += 1
                    } catch {
                        conflicts += 1
                    }
                }
            }
        }

        lastPullAt = Date()
        let receipt = SyncReceipt(pushed: 0, pulled: appliedCount, conflicts: conflicts)
        if appliedCount > 0 {
            emit(.remoteChangesApplied(count: appliedCount))
        }
        return receipt
    }

    /// Apply one inbound SyncRecord to local storage.
    ///
    /// A6 UNIFICATION: the sync HLC is now stored in `_fed_sync_meta` (a per-engine
    /// side table) rather than in the application row's `_syncHLC` column. This
    /// matches the CloudKit engine's `_ck_sync_meta` pattern and fixes the tombstone
    /// HLC loss: when a row is deleted the side-table entry survives, blocking stale
    /// resurrections for subsequent inserts with older HLCs.
    ///
    /// The body dispatches on `record.syncDeleted` (tombstone) first, then on
    /// event kind × conflict policy for normal (non-tombstone) records. Each arm
    /// is a short operation — upsert, insert-if-absent, delete, or early-return.
    ///
    /// Internal (not private) so the LWW force-tests can call it directly
    /// via @testable import without going through the full push/pull stack.
    func applyInbound(
        _ record: SyncRecord,
        syncedTable: SyncedTable,
        storage: any Storage
    ) async throws {
        // Tombstone path: applies via LWW gate and persists delete HLC in
        // _fed_sync_meta after hard-delete (A6 adjudication).
        let isTombstone = record.syncDeleted == true || record.event == .delete
        if isTombstone {
            let predicate: StoragePredicate = .eq(
                Column(table: record.table, name: syncedTable.primaryKeyColumn),
                .uuid(record.rowKey)
            )
            switch syncedTable.conflictPolicy {
            case .appendOnly:
                // Append-only tables are write-once; silently reject remote deletes.
                return
            case .localWins:
                // Local state is authoritative; silently reject remote deletes.
                return
            case .remoteWins:
                // Remote delete wins unconditionally; hard-delete the row.
                _ = try? await storage.rowStore.delete(table: record.table, where: predicate)
            case .lastWriterWinsByHLC:
                // HLC gate: stale delete (incoming HLC < side-table HLC) must not
                // remove a newer local row (D2 fix). Side table persists the HLC
                // after delete so stale resurrections are also blocked (A6).
                let localHLC = try await readFedSyncHLC(
                    storage: storage, table: record.table, primaryKey: record.rowKey)
                if let localHLC, record.hlc.asHLC < localHLC {
                    return // stale delete — local row is newer
                }
                _ = try? await storage.rowStore.delete(table: record.table, where: predicate)
                // A6: persist tombstone HLC in side table after hard-delete.
                // WHY: without this, a stale insert arriving after the delete would
                // find localHLC = nil and be accepted, resurrecting the deleted row.
                try await writeFedTombstoneHLC(
                    storage: storage, table: record.table,
                    primaryKey: record.rowKey, hlc: record.hlc.asHLC,
                    schemaVersion: record.schemaVersion, kitID: record.kitID)
            }
            return
        }

        // Normal (non-tombstone) insert/update path.
        let values = record.values?.asTypedValues ?? [:]
        switch syncedTable.conflictPolicy {
        case .appendOnly:
            _ = try await storage.rowStore.upsert(
                table: record.table,
                values: values,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )

        case .lastWriterWinsByHLC:
            // A6: read HLC from _fed_sync_meta side table, not from the row.
            // The side table entry exists even after a delete (tombstone HLC),
            // so a stale resurrect for a previously-deleted row is also gated.
            let localHLC = try await readFedSyncHLC(
                storage: storage, table: record.table, primaryKey: record.rowKey)
            if let localHLC, record.hlc.asHLC < localHLC {
                return // local is newer (or tombstone is newer) — skip remote
            }
            // Apply the row WITHOUT embedding _syncHLC in the row values.
            // A6: HLC lives in _fed_sync_meta, not in the application row.
            _ = try await storage.rowStore.upsert(
                table: record.table,
                values: values,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )
            // Persist HLC in side table (is_deleted = 0, live row).
            try await writeFedSyncHLC(
                storage: storage, table: record.table,
                primaryKey: record.rowKey, hlc: record.hlc.asHLC,
                schemaVersion: record.schemaVersion, kitID: record.kitID)

        case .remoteWins:
            _ = try await storage.rowStore.upsert(
                table: record.table,
                values: values,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )

        case .localWins:
            let existing = try? await storage.rowStore.count(
                table: record.table,
                where: .eq(Column(table: record.table, name: syncedTable.primaryKeyColumn), .uuid(record.rowKey))
            )
            if (existing ?? 0) == 0 {
                _ = try await storage.rowStore.insert(table: record.table, values: values)
            }
        }
    }

    // MARK: - _fed_sync_meta side table (A6 unification)

    /// Side table name for Federation. Mirrors `_ck_sync_meta` in the CloudKit
    /// engine — both backends use a side table to persist sync HLCs so the HLC
    /// survives hard-deletes and provides the stale-resurrect guard (A6).
    private static let fedSyncMetaTable = "_fed_sync_meta"

    /// Create the `_fed_sync_meta` side table if it does not exist.
    ///
    /// Must be called from `enable()` before any `applyInbound`. Mirrors
    /// `CloudKitStateActor.ensureSyncMetaTable`. Marked `internal` (not private)
    /// so tests that call `applyInbound` directly can call this in their setup.
    static func ensureFedSyncMetaTable(storage: any Storage) async throws {
        let schema = SchemaDeclaration(
            kitID: "ConvergenceKitFederation",
            version: 1,
            tables: [
                TableDeclaration(
                    name: fedSyncMetaTable,
                    columns: [
                        ColumnDeclaration(name: "table_name", type: .text, nullable: false),
                        ColumnDeclaration(name: "primary_key", type: .text, nullable: false),
                        ColumnDeclaration(name: "sync_hlc", type: .int, nullable: false,
                                          defaultValue: .int(0)),
                        ColumnDeclaration(name: "schema_version", type: .int, nullable: false,
                                          defaultValue: .int(0)),
                        ColumnDeclaration(name: "kit_id", type: .text, nullable: false,
                                          defaultValue: .text("")),
                        // is_deleted: 1 for tombstone entries (delete HLC that outlives
                        // the row). Used by GC to identify entries eligible for compaction
                        // after SyncTombstone.gcRetentionSeconds.
                        ColumnDeclaration(name: "is_deleted", type: .int, nullable: false,
                                          defaultValue: .int(0)),
                    ],
                    primaryKey: ["table_name", "primary_key"]
                ),
            ],
            indices: []
        )
        // migrate(to:) is ADDITIVE — creates missing tables/columns without clobbering
        // the application schema. This matches the CloudKit engine's pattern.
        try await storage.migrate(to: schema)
    }

    /// Read the persisted sync HLC from `_fed_sync_meta` for a given row.
    /// Returns the HLC regardless of `is_deleted` — tombstone HLCs compare
    /// identically to live-row HLCs in the LWW gate.
    private func readFedSyncHLC(
        storage: any Storage, table: String, primaryKey: UUID
    ) async throws -> HLC? {
        let rows = try await storage.rowStore.query(
            table: Self.fedSyncMetaTable,
            where: .and([
                .eq(Column(table: Self.fedSyncMetaTable, name: "table_name"), .text(table)),
                .eq(Column(table: Self.fedSyncMetaTable, name: "primary_key"), .text(primaryKey.uuidString))
            ])
        )
        guard let row = rows.first,
              case .int(let packed) = row["sync_hlc"] else { return nil }
        return HLC(packed: UInt64(bitPattern: packed))
    }

    /// Persist the sync HLC in `_fed_sync_meta` after a successful upsert.
    /// Sets `is_deleted = 0` (live row, not a tombstone).
    private func writeFedSyncHLC(
        storage: any Storage, table: String, primaryKey: UUID,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        _ = try await storage.rowStore.upsert(
            table: Self.fedSyncMetaTable,
            values: [
                "table_name": .text(table),
                "primary_key": .text(primaryKey.uuidString),
                "sync_hlc": .int(Int64(bitPattern: hlc.packed)),
                "schema_version": .int(Int64(schemaVersion)),
                "kit_id": .text(kitID),
                "is_deleted": .int(0)
            ],
            conflictColumns: ["table_name", "primary_key"]
        )
    }

    /// Persist the delete HLC in `_fed_sync_meta` after a hard-delete (A6).
    /// Sets `is_deleted = 1` to mark this as a tombstone entry for GC purposes.
    private func writeFedTombstoneHLC(
        storage: any Storage, table: String, primaryKey: UUID,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        _ = try await storage.rowStore.upsert(
            table: Self.fedSyncMetaTable,
            values: [
                "table_name": .text(table),
                "primary_key": .text(primaryKey.uuidString),
                "sync_hlc": .int(Int64(bitPattern: hlc.packed)),
                "schema_version": .int(Int64(schemaVersion)),
                "kit_id": .text(kitID),
                "is_deleted": .int(1)
            ],
            conflictColumns: ["table_name", "primary_key"]
        )
    }

    /// Current wall-clock in milliseconds, passed explicitly into
    /// the HLC generator. Note: the engine also reads Date() when
    /// assigning lastPushAt and lastPullAt on receipts.
    private func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
