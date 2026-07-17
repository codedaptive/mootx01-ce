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
        // Ensure Federation side tables exist: _fed_sync_meta (v1), _fed_sync_meta_cols
        // (v2), and _fed_pending_skew (v3, R9). Mirrors the CloudKit engine's
        // CKSideSchema.ensure call in enable().
        try await Self.ensureFedSyncMetaTable(storage: storage)

        // Schema-skew replay (R9, CVK-ICLOUD P3-M4).
        //
        // Drain records from _fed_pending_skew whose schema_version matches the
        // now-active manifest version. Echo suppression is active by construction:
        // observer tasks are not yet started, so applyInbound writes (upsertSync /
        // deleteSync) cannot re-enter the outbox (I-10).
        let skewReady = try await SkewReplay.drainReady(
            currentVersion: manifest.schemaVersion,
            from: storage,
            sideTable: Self.fedPendingSkewTable
        )
        if !skewReady.isEmpty {
            logger.info("fed skew-queue replay: \(skewReady.count) held record(s) ready for schema v\(manifest.schemaVersion)")
            var replayedIDs: [UUID] = []
            for (id, record) in skewReady {
                guard let syncedTable = manifest.table(named: record.table) else { continue }
                guard syncedTable.direction != .pushOnly else { continue }
                do {
                    try await applyInbound(record, syncedTable: syncedTable, storage: storage)
                    replayedIDs.append(id)
                } catch {
                    logger.warning("fed skew replay failed for \(record.table)/\(record.rowKey): \(String(describing: error))")
                }
            }
            try await SkewReplay.deleteApplied(
                ids: replayedIDs,
                from: storage,
                sideTable: Self.fedPendingSkewTable
            )
            logger.info("fed skew-queue replay: applied \(replayedIDs.count)/\(skewReady.count) records")
        }
        let skewStillHeld = try await SkewReplay.countHeld(
            from: storage,
            sideTable: Self.fedPendingSkewTable
        )
        if skewStillHeld > 0 {
            emit(.recordsHeldForMigration(count: skewStillHeld))
        }

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
        // Echo suppression (I-10, CVK-ICLOUD P1-M1): discard changes that
        // originated from applyInbound. Without this guard, every inbound
        // sync write fires the storage observer, re-enters pendingOutbound,
        // and is pushed back to the sending peer — two live machines
        // ping-pong forever. The .syncApply origin is stamped by the
        // RowStore sync-tagged write paths (upsertSync / insertSync / deleteSync).
        guard change.origin != .syncApply else { return }

        // Column projection (R2, CVK-ICLOUD P2-M2): strip excluded columns
        // before enqueueing. Excluded columns are locally recomputed on every
        // device (scores, caches, derived values); syncing them creates outbound
        // traffic proportional to local compute — a sync storm.
        //
        // Deletes are unaffected: a delete carries no column values, and the
        // tombstone must still propagate so remote replicas GC the row.
        let excluded = manifest?.table(named: change.table)?.excludedColumns ?? []
        if !excluded.isEmpty, let rawValues = change.values {
            let stripped = Projection.outboundStrip(values: rawValues, excluded: excluded)
            if change.event == .update {
                // Storm kill: no sync-meaningful columns survived exclusion.
                //
                // Precision path (CVK-WB4, Scorandum Q1 closed): when changedColumns
                // is present, check whether every actually-changed column is excluded.
                // This catches mixed-column writes (e.g. a score recompute that carries
                // title in the merged row snapshot but did not actually change it).
                //
                // Classic fallback (changedColumns nil = unknown/all): check whether
                // only the primary key survived the strip (pre-CVK-WB4 behavior).
                let pkColumn = manifest?.table(named: change.table)?.primaryKeyColumn ?? ""
                if let changedCols = change.changedColumns {
                    if changedCols.allSatisfy({ excluded.contains($0) }) {
                        return
                    }
                } else if Projection.isStormKill(stripped: stripped, primaryKeyColumn: pkColumn) {
                    return
                }
            }
            let strippedChange = TableChange(
                table: change.table,
                event: change.event,
                rowKey: change.rowKey,
                values: stripped,
                hlc: change.hlc,
                origin: change.origin,
                changedColumns: change.changedColumns
            )
            pendingOutbound.append(strippedChange)
            return
        }
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
            // For fieldLevelLWW tables, stamp columns with the capture HLC.
            //
            // Precision path (CVK-WB4): when changedColumns is present, stamp only
            // the columns that were actually written (intersection of changedColumns
            // with the projected key set). Columns present in the row snapshot but not
            // changed retain their existing remote HLC — they are not displaced.
            //
            // Fallback (changedColumns nil = unknown/all): stamp all projected columns
            // (pre-CVK-WB4 behavior; conservative but safe).
            let columnHLCs: ColumnHLCMap?
            if let raw = change.values,
               let syncedTable = manifest.table(named: change.table),
               syncedTable.conflictPolicy == .fieldLevelLWW,
               eventKind != .delete {
                let keysToStamp: [String]
                if let changedCols = change.changedColumns {
                    keysToStamp = raw.keys.filter { changedCols.contains($0) }
                } else {
                    keysToStamp = Array(raw.keys)
                }
                columnHLCs = ColumnHLCMap.stampAll(keys: keysToStamp, hlc: PackedHLC(hlc))
            } else {
                columnHLCs = nil
            }
            let record = SyncRecord(
                table: change.table,
                event: eventKind,
                rowKey: rowKey,
                values: change.values.map { SyncValueMap($0) },
                hlc: PackedHLC(hlc),
                schemaVersion: manifest.schemaVersion,
                kitID: manifest.kitID,
                syncDeleted: syncDeleted,
                columnHLCs: columnHLCs
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
        // Count of records held in _fed_pending_skew this pull cycle (R9).
        var fedSkewHeldCount = 0
        // Collect row keys per table for the post-apply integrity hook (R3).
        var appliedByTable: [String: [UUID]] = [:]
        var deletedByTable: [String: [UUID]] = [:]

        for peer in peers {
            let envelopes = peer.relay.drain(for: localIdentity.publicKey)
            for envelope in envelopes {
                // SECURITY (F-3 class): `envelope.senderPublicKey` is a field
                // the sender controls and must never be trusted as the
                // verification key. The authoritative trust anchor is the key
                // registered at pairing time (`peer.publicKey`). Require the
                // envelope's claimed sender key to equal the registered key;
                // any mismatch is a federation-auth rejection. All trust in
                // the verification chain derives from the pairing registry,
                // not from the envelope's own fields. Mirrors Rust pull().
                guard envelope.senderPublicKey == peer.publicKey else {
                    conflicts += 1
                    logger.error("federation-auth: senderPublicKey \(envelope.senderPublicKey.base64EncodedString()) does not match registered peer key \(peer.publicKey.base64EncodedString()) — rejected")
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
                // the same bytes here. SECURITY: use the REGISTERED peer key
                // (`peer.publicKey`) as the sender key in the canonical bytes
                // and as the verification key — not `envelope.senderPublicKey`.
                // The guard above confirms they are equal, but trust derives
                // from the pairing registry, not from the envelope's claim.
                let signingBytes = envelopeSigningBytes(
                    senderPublicKey: peer.publicKey,          // registered key, not envelope claim
                    payloadKind: envelope.payloadKind,
                    payload: envelope.payload,
                    hlc: envelope.hlc
                )
                guard FederationSignature.verify(
                    envelope.signature,
                    of: signingBytes,
                    by: peer.publicKey                        // registered key, not envelope claim
                ) else {
                    conflicts += 1
                    logger.error("federation-auth: signature verification failed for registered peer \(peer.publicKey.base64EncodedString())")
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
                        // Schema-skew split (R9, CVK-ICLOUD P3-M4):
                        //
                        // Future-schema (sender on newer schema than receiver):
                        //   Enqueue in _fed_pending_skew. NOT a conflict — the record is
                        //   valid and replayed on enable() after the receiver updates.
                        //
                        // Downgrade-apply (sender on older schema than receiver):
                        //   Reject. Applying an older-schema record could overwrite
                        //   newer-schema columns with missing-field defaults. Sender
                        //   resends after updating. Count as conflict.
                        if record.schemaVersion > manifest.schemaVersion {
                            try await PendingSkewQueue.enqueue(
                                record,
                                to: storage,
                                sideTable: Self.fedPendingSkewTable
                            )
                            fedSkewHeldCount += 1
                            continue
                        } else if record.schemaVersion < manifest.schemaVersion {
                            throw SyncError.schemaMismatch(
                                expected: manifest.schemaVersion,
                                received: record.schemaVersion
                            )
                        }
                        // record.schemaVersion == manifest.schemaVersion — normal apply path.
                        guard let syncedTable = manifest.table(named: record.table) else {
                            throw SyncError.unsupportedTable(name: record.table)
                        }
                        guard syncedTable.direction != .pushOnly else { continue }

                        try await applyInbound(record, syncedTable: syncedTable, storage: storage)
                        appliedCount += 1
                        // Track for post-apply hook: deletes go to deletedByTable,
                        // inserts/updates go to appliedByTable.
                        if record.event == .delete {
                            deletedByTable[record.table, default: []].append(record.rowKey)
                        } else {
                            appliedByTable[record.table, default: []].append(record.rowKey)
                        }
                    } catch {
                        conflicts += 1
                    }
                }
            }
        }

        // Emit recordsHeldForMigration when at least one future-schema record
        // was enqueued this cycle (R9).
        if fedSkewHeldCount > 0 {
            emit(.recordsHeldForMigration(count: fedSkewHeldCount))
        }

        lastPullAt = Date()

        // Post-apply integrity hook (R3): invoked once per batch when at least
        // one record was applied. Hook throws count as one additional conflict
        // but never abort the cycle. Hook writes carry origin == .local and
        // flow into the outbox (hook-writes-must-ship, Kong Q2).
        if appliedCount > 0 {
            let batch = AppliedBatch(
                storage: storage,
                appliedByTable: appliedByTable,
                deletedByTable: deletedByTable
            )
            conflicts += await invokeIntegrityHook(manifest.postApplyIntegrityHook, batch: batch)
        }

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
        // All writes use the sync-tagged variants (upsertSync / insertSync / deleteSync)
        // so the emitted TableChange carries origin: .syncApply. FederationStateActor's
        // recordOutbound discards .syncApply changes, preventing the echo loop (I-10).
        //
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
                _ = try? await storage.rowStore.deleteSync(table: record.table, where: predicate)
                // P5-M1b: purge stale skew-queue entries and parked outbox entries.
                // remoteWins applies the tombstone without an HLC gate; purge older-HLC
                // skew entries and all parked outbox entries for this row.
                _ = try? await PendingSkewQueue.deleteMatchingOlderThan(
                    tableName: record.table, rowKey: record.rowKey,
                    tombstoneHLC: record.hlc,
                    from: storage, sideTable: Self.fedPendingSkewTable)
                _ = try? await OutboxStore.deleteMatchingParked(
                    tableName: record.table, rowKey: record.rowKey.uuidString, from: storage)
            case .lastWriterWinsByHLC:
                // HLC gate: stale delete (incoming HLC < side-table HLC) must not
                // remove a newer local row (D2 fix). Side table persists the HLC
                // after delete so stale resurrections are also blocked (A6).
                let localHLC = try await readFedSyncHLC(
                    storage: storage, table: record.table, primaryKey: record.rowKey)
                if let localHLC, record.hlc.asHLC < localHLC {
                    return // stale delete — local row is newer
                }
                _ = try? await storage.rowStore.deleteSync(table: record.table, where: predicate)
                // A6: persist tombstone HLC in side table after hard-delete.
                // WHY: without this, a stale insert arriving after the delete would
                // find localHLC = nil and be accepted, resurrecting the deleted row.
                try await writeFedTombstoneHLC(
                    storage: storage, table: record.table,
                    primaryKey: record.rowKey, hlc: record.hlc.asHLC,
                    schemaVersion: record.schemaVersion, kitID: record.kitID)
                // P5-M1b: purge stale skew-queue entries and parked outbox entries.
                // The tombstone won the LWW gate; older-HLC skew entries are already
                // superseded (they would be rejected on replay by the same gate).
                // Parked outbox entries are indefinite retention after row deletion.
                _ = try? await PendingSkewQueue.deleteMatchingOlderThan(
                    tableName: record.table, rowKey: record.rowKey,
                    tombstoneHLC: record.hlc,
                    from: storage, sideTable: Self.fedPendingSkewTable)
                _ = try? await OutboxStore.deleteMatchingParked(
                    tableName: record.table, rowKey: record.rowKey.uuidString, from: storage)

            case .fieldLevelLWW:
                // Tombstone interplay (edit-beats-delete): tombstone wins only when
                // its HLC is >= ALL local per-column HLCs.
                let localColumnHLCs = try await ColumnHLCStore.readAll(
                    from: storage, sideTable: Self.fedSyncMetaColsTable,
                    tableName: record.table, primaryKey: record.rowKey)
                let tombstoneHLC = record.hlc  // PackedHLC
                if !FieldLWWMerge.tombstoneWins(
                    tombstoneHLC: tombstoneHLC, localColumnHLCs: localColumnHLCs) {
                    return // edit-beats-delete: a local column was written later
                }
                _ = try? await storage.rowStore.deleteSync(table: record.table, where: predicate)
                // Clear per-column side table — row is gone.
                try? await ColumnHLCStore.clearAll(
                    from: storage, sideTable: Self.fedSyncMetaColsTable,
                    tableName: record.table, primaryKey: record.rowKey)
                // A6: persist tombstone HLC in row-grain side table.
                try await writeFedTombstoneHLC(
                    storage: storage, table: record.table,
                    primaryKey: record.rowKey, hlc: record.hlc.asHLC,
                    schemaVersion: record.schemaVersion, kitID: record.kitID)
                // P5-M1b: purge stale skew-queue entries and parked outbox entries.
                // tombstoneHLC is already declared above in this arm; reuse it.
                _ = try? await PendingSkewQueue.deleteMatchingOlderThan(
                    tableName: record.table, rowKey: record.rowKey,
                    tombstoneHLC: tombstoneHLC,
                    from: storage, sideTable: Self.fedPendingSkewTable)
                _ = try? await OutboxStore.deleteMatchingParked(
                    tableName: record.table, rowKey: record.rowKey.uuidString, from: storage)
            }
            return
        }

        // Normal (non-tombstone) insert/update path.

        // Inbound projection (R2, CVK-ICLOUD P2-M2): drop excluded columns before
        // the conflict-policy switch. A peer on a different manifest version may
        // send columns this manifest marks excluded. Writing them would overwrite
        // locally-computed derived values with stale remote copies.
        let rawInboundValues = record.values?.asTypedValues ?? [:]
        let values: [String: TypedValue]
        if !syncedTable.excludedColumns.isEmpty {
            let droppedKeys = rawInboundValues.keys.filter { syncedTable.excludedColumns.contains($0) }
            if !droppedKeys.isEmpty {
                let keyList = droppedKeys.sorted().joined(separator: ", ")
                logger.warning("inbound projection: dropping \(droppedKeys.count) excluded column(s) for table '\(syncedTable.name)': \(keyList)")
            }
            values = Projection.outboundStrip(values: rawInboundValues, excluded: syncedTable.excludedColumns)
        } else {
            values = rawInboundValues
        }

        switch syncedTable.conflictPolicy {
        case .appendOnly:
            _ = try await storage.rowStore.upsertSync(
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
            _ = try await storage.rowStore.upsertSync(
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
            _ = try await storage.rowStore.upsertSync(
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
                _ = try await storage.rowStore.insertSync(table: record.table, values: values)
            }

        case .fieldLevelLWW:
            // Per-column LWW apply. Mirrors the CloudKit ApplyInbound arm.
            let localColumnHLCs = try await ColumnHLCStore.readAll(
                from: storage, sideTable: Self.fedSyncMetaColsTable,
                tableName: record.table, primaryKey: record.rowKey)

            let incomingColumnHLCs = record.columnHLCs ?? ColumnHLCMap()
            let incomingRowHLC = record.hlc  // PackedHLC

            let (columnsToApply, updatedColumnHLCs) = FieldLWWMerge.merge(
                incomingValues: values,
                incomingColumnHLCs: incomingColumnHLCs,
                incomingRowHLC: incomingRowHLC,
                localColumnHLCs: localColumnHLCs
            )

            if !columnsToApply.isEmpty {
                var upsertValues = columnsToApply
                upsertValues[syncedTable.primaryKeyColumn] = .uuid(record.rowKey)
                _ = try await storage.rowStore.upsertSync(
                    table: record.table,
                    values: upsertValues,
                    conflictColumns: [syncedTable.primaryKeyColumn]
                )
            }

            if !updatedColumnHLCs.isEmpty {
                try await ColumnHLCStore.writeAll(
                    map: updatedColumnHLCs,
                    to: storage, sideTable: Self.fedSyncMetaColsTable,
                    tableName: record.table, primaryKey: record.rowKey)
            }

            // Also update row-grain HLC in _fed_sync_meta for stale-resurrect guard.
            let existingRowHLC = try await readFedSyncHLC(
                storage: storage, table: record.table, primaryKey: record.rowKey)
            if existingRowHLC == nil || record.hlc.asHLC > (existingRowHLC ?? record.hlc.asHLC) {
                try await writeFedSyncHLC(
                    storage: storage, table: record.table,
                    primaryKey: record.rowKey, hlc: record.hlc.asHLC,
                    schemaVersion: record.schemaVersion, kitID: record.kitID)
            }
        }
    }

    // MARK: - _fed_sync_meta side table (A6 unification)

    /// Side table name for Federation row-grain HLC. Mirrors `_ck_sync_meta`.
    private static let fedSyncMetaTable = "_fed_sync_meta"

    /// Side table name for Federation per-column HLC (fieldLevelLWW).
    /// Mirrors `_ck_sync_meta_cols` added to CKSideSchema at v6.
    static let fedSyncMetaColsTable = "_fed_sync_meta_cols"

    /// Side table name for Federation pending-skew queue (R9, CVK-ICLOUD P3-M4).
    /// Mirrors `_ck_pending_skew` added to CKSideSchema at v7.
    static let fedPendingSkewTable = "_fed_pending_skew"

    /// Create the Federation side tables: _fed_sync_meta, _fed_sync_meta_cols,
    /// and _fed_pending_skew.
    ///
    /// Must be called from `enable()` before any `applyInbound`. Mirrors
    /// `CKSideSchema.ensure`. Marked `internal` (not private) so tests that
    /// call `applyInbound` directly can call this in their setup.
    ///
    /// - v1: `_fed_sync_meta` row-grain HLC (original)
    /// - v2: `_fed_sync_meta_cols` per-column HLC for fieldLevelLWW (CVK-ICLOUD P2-M1)
    /// - v3: `_fed_pending_skew` schema-skew pending queue (R9, CVK-ICLOUD P3-M4)
    static func ensureFedSyncMetaTable(storage: any Storage) async throws {
        let fedSyncMetaDecl = TableDeclaration(
            name: fedSyncMetaTable,
            columns: [
                ColumnDeclaration(name: "table_name",    type: .text, nullable: false),
                ColumnDeclaration(name: "primary_key",   type: .text, nullable: false),
                ColumnDeclaration(name: "sync_hlc",      type: .int,  nullable: false,
                                  defaultValue: .int(0)),
                ColumnDeclaration(name: "schema_version",type: .int,  nullable: false,
                                  defaultValue: .int(0)),
                ColumnDeclaration(name: "kit_id",        type: .text, nullable: false,
                                  defaultValue: .text("")),
                // is_deleted: 1 for tombstone entries (delete HLC that outlives
                // the row). Used by GC to identify entries eligible for compaction
                // after SyncTombstone.gcRetentionSeconds.
                ColumnDeclaration(name: "is_deleted",    type: .int,  nullable: false,
                                  defaultValue: .int(0)),
            ],
            primaryKey: ["table_name", "primary_key"]
        )

        // _fed_sync_meta_cols: per-column HLC for fieldLevelLWW (v2, CVK-ICLOUD P2-M1).
        // Schema mirrors _ck_sync_meta_cols in CKSideSchema v6.
        let fedSyncMetaColsDecl = TableDeclaration(
            name: fedSyncMetaColsTable,
            columns: [
                ColumnDeclaration(name: "table_name",  type: .text, nullable: false),
                ColumnDeclaration(name: "primary_key", type: .text, nullable: false),
                ColumnDeclaration(name: "column_name", type: .text, nullable: false),
                ColumnDeclaration(name: "col_hlc",     type: .int,  nullable: false,
                                  defaultValue: .int(0)),
            ],
            primaryKey: ["table_name", "primary_key", "column_name"]
        )

        // _fed_pending_skew schema (v3 — schema-skew pending queue, R9, CVK-ICLOUD P3-M4):
        //   id             — UUID primary key assigned at enqueue time.
        //   table_name     — application table the record belongs to.
        //   row_key        — UUID as TEXT (primary key of the application row).
        //   schema_version — schemaVersion from the wire record (sender's version).
        //                    INT, not Bool, per schema invariants.
        //   received_at    — ISO8601 wall-clock TEXT for oldest-eviction ordering.
        //                    Date storage is TEXT (ISO8601) per schema invariants.
        //   payload        — JSON-encoded SyncRecord (full wire format).
        let fedPendingSkewDecl = TableDeclaration(
            name: fedPendingSkewTable,
            columns: [
                ColumnDeclaration(name: "id",             type: .uuid, nullable: false),
                ColumnDeclaration(name: "table_name",     type: .text, nullable: false),
                ColumnDeclaration(name: "row_key",        type: .text, nullable: false),
                ColumnDeclaration(name: "schema_version", type: .int,  nullable: false,
                                  defaultValue: .int(0)),
                ColumnDeclaration(name: "received_at",    type: .text, nullable: false),
                ColumnDeclaration(name: "payload",        type: .blob, nullable: false),
            ],
            primaryKey: ["id"]
        )

        let schema = SchemaDeclaration(
            kitID: "ConvergenceKitFederation",
            version: 3,
            tables: [fedSyncMetaDecl, fedSyncMetaColsDecl, fedPendingSkewDecl],
            migrations: [
                // v1 → v2: add per-column HLC side table for fieldLevelLWW.
                Migration(fromVersion: 1, toVersion: 2, operations: [
                    .createTable(fedSyncMetaColsDecl),
                ]),
                // v2 → v3: add pending-skew queue (R9, CVK-ICLOUD P3-M4).
                // Holds future-schema records until a schema update makes them
                // applicable. Drained by SkewReplay.drainReady at enable() time.
                Migration(fromVersion: 2, toVersion: 3, operations: [
                    .createTable(fedPendingSkewDecl),
                ]),
            ]
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
        _ = try await storage.rowStore.upsertSync(
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
        _ = try await storage.rowStore.upsertSync(
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
