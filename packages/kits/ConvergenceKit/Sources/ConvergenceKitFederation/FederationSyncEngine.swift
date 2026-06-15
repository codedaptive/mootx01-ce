// FederationSyncEngine.swift
//
// Substrate-native CRDT exchange per paper section 9.
//
// At v1.0 the engine provides:
// - Per-estate Ed25519 identity
// - In-process peer registry (paired peers exchange messages
//   directly through shared state)
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
    /// will route audit-event-style messages through the peer.
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
            let record = SyncRecord(
                table: change.table,
                event: SyncEventKind(from: change.event),
                rowKey: rowKey,
                values: change.values.map { SyncValueMap($0) },
                hlc: PackedHLC(hlc),
                schemaVersion: manifest.schemaVersion,
                kitID: manifest.kitID
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

        // Batch-level HLC: advance the clock once more so the envelope timestamp
        // is strictly ordered after all record HLCs in the batch.
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
    /// The body is two nested switches: event kind (insert/update/delete)
    /// × conflict policy (four cases each). Each arm is a short operation —
    /// upsert, insert-if-absent, delete, or early-return. The length comes
    /// from the cross-product of cases, not from complex logic.
    ///
    /// `lastWriterWinsByHLC` compares the incoming record's HLC against the
    /// stored row's `_syncHLC`. If the incoming HLC is older (strictly less),
    /// the write is silently dropped. On every apply that wins the comparison
    /// the row is written with `_syncHLC` so the next inbound can compare.
    /// This mirrors the CloudKitStateActor.applyInbound semantics exactly.
    /// The same HLC gate applies to delete events: a stale delete (incoming
    /// HLC < local `_syncHLC`) is silently rejected; a newer delete proceeds.
    ///
    /// Internal (not private) so the LWW force-tests can call it directly
    /// via @testable import without going through the full push/pull stack.
    func applyInbound(
        _ record: SyncRecord,
        syncedTable: SyncedTable,
        storage: any Storage
    ) async throws {
        switch record.event {
        case .insert, .update:
            let values = record.values?.asTypedValues ?? [:]
            switch syncedTable.conflictPolicy {
            case .appendOnly:
                _ = try await storage.rowStore.upsert(
                    table: record.table,
                    values: values,
                    conflictColumns: [syncedTable.primaryKeyColumn]
                )

            case .lastWriterWinsByHLC:
                // Compare HLC; only apply if remote >= local.
                // Mirrors CloudKitStateActor.applyInbound exactly.
                let existing = try? await storage.rowStore.query(
                    table: record.table,
                    where: .eq(Column(table: record.table, name: syncedTable.primaryKeyColumn), .uuid(record.rowKey))
                )
                if let first = existing?.first {
                    // Recover the stored HLC from either `.hlc` (InMemory, where
                    // TypedValue is preserved verbatim) or `.int` (SQLite/Postgres,
                    // where the schema does not declare _syncHLC as .hlc so
                    // readColumn returns the raw packed integer). Both cases carry
                    // the canonical HLC.packed layout (node<<56 | logical<<40 | phys).
                    let localHLC: HLC?
                    switch first["_syncHLC"] ?? .null {
                    case .hlc(let h): localHLC = h
                    case .int(let i): localHLC = HLC(packed: UInt64(bitPattern: i))
                    default: localHLC = nil
                    }
                    let incomingHLC = record.hlc.asHLC
                    if let localHLC, incomingHLC < localHLC {
                        return
                    }
                }
                // Merge sync meta into the persisted row so the next inbound
                // write can read _syncHLC back and compare.
                var rowValues = values
                rowValues["_syncHLC"] = .hlc(record.hlc.asHLC)
                _ = try await storage.rowStore.upsert(
                    table: record.table,
                    values: rowValues,
                    conflictColumns: [syncedTable.primaryKeyColumn]
                )

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

        case .delete:
            let predicate: StoragePredicate = .eq(
                Column(table: record.table, name: syncedTable.primaryKeyColumn),
                .uuid(record.rowKey)
            )
            switch syncedTable.conflictPolicy {
            case .appendOnly:
                // Append-only tables are write-once; silently reject remote deletes.
                return

            case .lastWriterWinsByHLC:
                // HLC gate on the delete path: a stale delete (incoming HLC <
                // local _syncHLC) must not remove a newer local row. A newer
                // delete (incoming HLC >= local _syncHLC) proceeds.
                let existing = try? await storage.rowStore.query(
                    table: record.table,
                    where: .eq(Column(table: record.table, name: syncedTable.primaryKeyColumn), .uuid(record.rowKey))
                )
                if let first = existing?.first {
                    let localHLC: HLC?
                    switch first["_syncHLC"] ?? .null {
                    case .hlc(let h): localHLC = h
                    case .int(let i): localHLC = HLC(packed: UInt64(bitPattern: i))
                    default: localHLC = nil
                    }
                    let incomingHLC = record.hlc.asHLC
                    if let localHLC, incomingHLC < localHLC {
                        return
                    }
                }
                _ = try await storage.rowStore.delete(table: record.table, where: predicate)

            case .remoteWins:
                // Remote delete wins unconditionally; hard-delete the row by primary key.
                _ = try await storage.rowStore.delete(table: record.table, where: predicate)

            case .localWins:
                // Local state is authoritative; silently reject remote deletes
                // regardless of whether the row exists locally.
                return
            }
        }
    }

    /// Current wall-clock in milliseconds, passed explicitly into
    /// the HLC generator so the engine stays deterministic and the
    /// single clock read is easy to audit.
    private func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
