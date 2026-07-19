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
    /// Engine-level relay: shared across all peers. Passed to the state actor
    /// at `enable()` time so `pair()`, `push()`, and `pull()` all use the same
    /// transport. For in-process testing, give both engines the same
    /// `FederationRelay` instance at init time.
    let relay: any Relay

    /// Create a new sync engine with the given transport relay.
    ///
    /// For in-process testing, two engines must share the same relay so their
    /// inboxes are connected. For production, supply a hosted relay conforming
    /// to `Relay` (the v1.x extension point).
    ///
    /// - Parameter relay: The relay used by this engine for all send/drain
    ///   operations. Defaults to a private `FederationRelay` instance (useful
    ///   for single-engine setups or stub tests that do not pair).
    public init(relay: any Relay = FederationRelay()) {
        self.relay = relay
        self.stateActor = FederationStateActor()
    }

    public func enable(manifest: SyncManifest, storage: any Storage) async throws {
        try await stateActor.enable(manifest: manifest, storage: storage, relay: relay)
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

    /// Pair with a peer engine using a signed Ed25519 handshake.
    ///
    /// Both sides verify each other's signatures over the canonical proposal
    /// bytes (proposerPublicKey || seed || dimension || nonce). If either
    /// signature fails verification, or if the accepter echoes back a
    /// different family spec, `SyncError.authenticationFailed` is thrown and
    /// neither side is registered as a peer.
    ///
    /// On success, both sides persist the peer to `_fed_peers` so the pairing
    /// survives an engine restart (`enable()` reloads peers on re-open).
    ///
    /// For v1.0 pairing is in-process: both engines must share the same relay
    /// passed at `init(relay:)` time.
    public func pair(with peer: FederationSyncEngine, family: HyperplaneFamilySpec) async throws {
        try await stateActor.pair(with: peer.stateActor, family: family)
    }

    /// Accept a pairing proposal from a remote proposer.
    ///
    /// Verifies the proposer's Ed25519 signature over the canonical proposal
    /// bytes. On success, signs the same bytes with the local key, persists the
    /// proposer as a peer, and returns a `PairingAcceptance` the caller can
    /// forward to the proposer for its own verification.
    ///
    /// This method is the server-side leg of the pairing handshake. In v1.0,
    /// `pair(with:family:)` drives both legs in-process. In v1.x this method
    /// will be called when a proposal arrives over a relay transport (WC7).
    ///
    /// - Parameters:
    ///   - proposal: The proposal sent by the remote engine.
    ///   - proposerSignature: Ed25519 signature the proposer computed over
    ///     `proposalSigningBytes(proposal)`.
    /// - Returns: A signed acceptance carrying the local public key and family.
    /// - Throws: `SyncError.authenticationFailed` if signature verification
    ///   fails.
    public func acceptPairingProposal(
        _ proposal: PairingProposal,
        proposerSignature: Data
    ) async throws -> PairingAcceptance {
        try await stateActor.acceptProposal(proposal, proposerSignature: proposerSignature)
    }

    public var identity: LocalIdentity {
        get async { await stateActor.localIdentity }
    }
}

// MARK: - PayloadKind

/// Discriminator for the opaque payload carried by `SignedEnvelope`.
/// The single-byte tag is embedded in the canonical signing bytes so the
/// receiver knows how to decode the payload without ambiguity.
///
/// Variants are assigned stable byte values; never reuse a value.
/// `syncRecordBatch` (0x01) is the only v1.0 sync payload.
/// Pairing payloads (0x10, 0x11) are WC7 extension points for relay-based
/// handshake transport — reserved here so the byte space is locked.
/// `fieldWriteEventBatch` (0x02) is reserved for the next-gen write-path
/// payload (C1 extension point).
public enum PayloadKind: UInt8, Sendable, Codable, Hashable {
    /// A JSON-encoded array of `SyncRecord` values. The only v1.0 sync payload.
    case syncRecordBatch = 0x01
    // fieldWriteEventBatch = 0x02  — reserved; add when FieldWriteEvent
    // wire format lands. Do not assign 0x02 to anything else.

    /// A JSON-encoded `PairingProposal`. Extension point for relay-based
    /// pairing (WC7). In v1.0, pairing is direct actor-to-actor and these
    /// kinds are never placed on the relay; `pull()` silently ignores them.
    case pairingProposal   = 0x10
    /// A JSON-encoded `PairingAcceptance`. Extension point for relay-based
    /// pairing (WC7). Silently ignored by `pull()` in v1.0.
    case pairingAcceptance = 0x11
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
    ///
    /// Throws on transport failure (e.g. network error from a hosted relay
    /// conformer). The in-process `FederationRelay` never throws. When
    /// `send` throws, `push()` retains the outbox entries in `_fed_outbox`
    /// for the next push cycle's retry — this is the "retain on failure"
    /// contract that the durable outbox (WC2) makes possible.
    func send(to recipient: Data, message: SignedEnvelope) throws
    /// Drain (and clear) the recipient's pending inbound envelopes.
    func drain(for recipient: Data) -> [SignedEnvelope]
}

/// Shared in-process relay used by paired engines for v1.0 (the
/// local/test `Relay`). In production a hosted relay conforms instead.
public final class FederationRelay: Relay, @unchecked Sendable {
    private let lock = NSLock()
    private var inboxes: [Data: [SignedEnvelope]] = [:]  // keyed by recipient public key

    public init() {}

    public func send(to recipient: Data, message: SignedEnvelope) throws {
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
    // Placeholder replaced by loadOrMintIdentity(storage:) at the start of enable().
    // Do not read localIdentity before enable() completes — the placeholder key
    // is ephemeral and will not match the persisted estate identity (I-8, WC1).
    var localIdentity: LocalIdentity = LocalIdentity()
    var manifest: SyncManifest?
    var storage: (any Storage)?
    var isEnabled: Bool = false
    var lastPushAt: Date?
    var lastPullAt: Date?
    var observerTasks: [Task<Void, Never>] = []
    // pendingOutbound removed (WC2): replaced by durable _fed_outbox side table.
    // See FedOutboxStore.swift. recordOutbound now appends a JSON-encoded SyncRecord
    // to _fed_outbox via FedOutboxStore.append. push() reads from _fed_outbox and
    // confirms entries on successful relay delivery.
    var subscribers: [AsyncStream<SyncEvent>.Continuation] = []
    var peers: [PairedPeer] = []
    var hlcGenerator = HLCGenerator(nodeID: Int32.random(in: 1...0x0F))
    /// Engine-level relay. Set by enable(relay:); nilled by disable().
    /// Nil when the engine is not active — push/pull gate on this.
    var relay: (any Relay)?

    /// A peer registered via the signed handshake (pair() or acceptProposal()).
    /// `publicKey` is the 32-byte Ed25519 verifying key of the remote estate.
    /// `family` is the agreed HyperplaneFamilySpec for fingerprint comparability.
    /// Both fields are persisted to `_fed_peers` so pairing survives restart.
    struct PairedPeer {
        let publicKey: Data
        let family: HyperplaneFamilySpec
    }

    func enable(manifest: SyncManifest, storage: any Storage, relay: any Relay) async throws {
        if isEnabled { throw SyncError.alreadyEnabled }
        self.manifest = manifest
        self.storage = storage
        self.relay = relay
        // Ensure Federation side tables exist through schema v6:
        //   v1 _fed_sync_meta, v2 _fed_sync_meta_cols, v3 _fed_pending_skew (R9),
        //   v4 _fed_identity (WC1), v5 _fed_outbox (WC2 durable outbox),
        //   v6 _fed_peers (WC6).
        // Mirrors the CloudKit engine's CKSideSchema.ensure call in enable().
        try await Self.ensureFedSyncMetaTable(storage: storage)

        // Load or mint the persistent estate Ed25519 identity (I-8, WC1).
        // Must run after ensureFedSyncMetaTable so _fed_identity exists.
        try await loadOrMintIdentity(storage: storage)

        // Drain-on-enable (WC2): check for outbox entries that survived from a prior
        // process lifetime. This is informational — the host triggers push() to deliver
        // them. No entries are consumed here; push() reads-without-clearing.
        let leftoverCount = (try? await FedOutboxStore.count(
            from: storage, table: Self.fedOutboxTable)) ?? 0
        if leftoverCount > 0 {
            logger.info("federation: \(leftoverCount) durable outbox entry(ies) survived from prior process — next push() will deliver them")
        }

        // Reload paired peers from _fed_peers so pairing survives restart (WC6).
        // Must run after loadOrMintIdentity (we need localIdentity to be set)
        // and after ensureFedSyncMetaTable (_fed_peers must exist).
        try await reloadPeers(storage: storage)

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
                    // recordOutbound is async (WC2: appends to the durable _fed_outbox).
                    // The await hop into the actor context is correct; errors are
                    // handled internally in recordOutbound with try?.
                    await self?.recordOutbound(change)
                }
            }
            observerTasks.append(task)
        }
        isEnabled = true
    }

    func disable() async {
        isEnabled = false
        // Nil the relay so push/pull gate on it after disable. The paired peers
        // are persisted in _fed_peers in storage; nilling the relay does NOT
        // remove them. The in-memory peers list is cleared here (it is rebuilt
        // from _fed_peers on the next enable() call via reloadPeers).
        relay = nil
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
        // _fed_outbox entries survive disable: they are a durable queue that outlives
        // the engine lifecycle (WC2). On re-enable, enable() counts leftover entries
        // and logs; the host triggers push() to deliver them. Clearing peers and
        // storage here does NOT clear the on-disk outbox.
        peers.removeAll()
        manifest = nil
        storage = nil
    }

    func recordOutbound(_ change: TableChange) async {
        // Echo suppression (I-10, CVK-ICLOUD P1-M1): discard changes that
        // originated from applyInbound. Without this guard, every inbound
        // sync write fires the storage observer, re-enters the outbox,
        // and is pushed back to the sending peer — two live machines
        // ping-pong forever. The .syncApply origin is stamped by the
        // RowStore sync-tagged write paths (upsertSync / insertSync / deleteSync).
        //
        // ECHO SUPPRESSION INVARIANT ON RESTART (WC2): entries loaded from
        // _fed_outbox on engine restart are SyncRecords minted at observe
        // time — before this guard. No re-evaluation is needed: durability
        // does not break echo suppression.
        guard change.origin != .syncApply else { return }
        guard let manifest, let storage = self.storage else { return }
        guard let syncedTable = manifest.table(named: change.table) else { return }
        // Pull-only tables do not originate local writes.
        guard syncedTable.direction != .pullOnly else { return }
        guard let rowKey = change.rowKey else { return }

        // Column projection (R2, CVK-ICLOUD P2-M2): strip excluded columns
        // before enqueueing. Excluded columns are locally recomputed on every
        // device (scores, caches, derived values); syncing them creates outbound
        // traffic proportional to local compute — a sync storm.
        //
        // Deletes are unaffected: a delete carries no column values, and the
        // tombstone must still propagate so remote replicas GC the row.
        var effectiveChange = change
        let excluded = syncedTable.excludedColumns
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
                let pkColumn = syncedTable.primaryKeyColumn
                if let changedCols = change.changedColumns {
                    if changedCols.allSatisfy({ excluded.contains($0) }) {
                        return
                    }
                } else if Projection.isStormKill(stripped: stripped, primaryKeyColumn: pkColumn) {
                    return
                }
            }
            effectiveChange = TableChange(
                table: change.table,
                event: change.event,
                rowKey: change.rowKey,
                values: stripped,
                hlc: change.hlc,
                origin: change.origin,
                changedColumns: change.changedColumns
            )
        }

        // Convert TableChange → SyncRecord at observe time (WC2 key design).
        //
        // WHY encode at observe time (not at push time):
        // The durable outbox stores self-contained wire units so the push drain
        // is a straight read → batch → sign → send with no re-processing.
        // Echo suppression fires at observe time; the SyncRecord carries no
        // origin field, but by construction only origin != .syncApply changes
        // reach this point. Durability is safe.
        //
        // Prefer the HLC that already ordered the change. If the observation
        // carried none, mint a monotonic one through the generator.
        let hlc = effectiveChange.hlc ?? hlcGenerator.send(now: nowMillis())
        let eventKind = SyncEventKind(from: effectiveChange.event)
        // Tombstone flag: set syncDeleted = true for delete events so the
        // receiver knows to apply the tombstone path (LWW gate + side-table
        // HLC persistence). Matches the A6 unification contract.
        let syncDeleted: Bool? = eventKind == .delete ? true : nil
        // For fieldLevelLWW tables, stamp columns with the capture HLC.
        //
        // Precision path (CVK-WB4): when changedColumns is present, stamp only
        // the columns that were actually written. Columns in the row snapshot but
        // not changed retain their existing remote HLC — they are not displaced.
        //
        // Gap 3: `columnHLCs` (the actual map, not just the SyncRecord field it
        // ends up in) is kept in scope below so the SAME local write's HLC that
        // gets shipped to peers on the wire is also stamped into the LOCAL
        // `_fed_sync_meta_cols` side table (ColumnHLCStore.writeAll below) —
        // closing the "local write never HLC-gated" window. Without this,
        // applyInbound's fieldLevelLWW gate has no truthful local baseline for
        // a column this device just wrote, so a later-arriving stale remote
        // edit for that column wins unconditionally (FieldLWWMerge.merge:
        // `localColumnHLC == nil` → `shouldApply = true`).
        let columnHLCs: ColumnHLCMap?
        if let raw = effectiveChange.values,
           syncedTable.conflictPolicy == .fieldLevelLWW,
           eventKind != .delete {
            let keysToStamp: [String]
            if let changedCols = effectiveChange.changedColumns {
                keysToStamp = raw.keys.filter { changedCols.contains($0) }
            } else {
                keysToStamp = Array(raw.keys)
            }
            columnHLCs = ColumnHLCMap.stampAll(keys: keysToStamp, hlc: PackedHLC(hlc))
        } else {
            columnHLCs = nil
        }
        let record = SyncRecord(
            table: effectiveChange.table,
            event: eventKind,
            rowKey: rowKey,
            values: effectiveChange.values.map { SyncValueMap($0) },
            hlc: PackedHLC(hlc),
            schemaVersion: manifest.schemaVersion,
            kitID: manifest.kitID,
            syncDeleted: syncDeleted,
            columnHLCs: columnHLCs
        )

        // Encode the SyncRecord to JSON and append to the durable outbox.
        // Coalescing by (table_name, row_key) newest-HLC in FedOutboxStore.append
        // bounds hot-row growth in high-write workloads — mirrors CloudKit OutboxStore.
        guard let payload = try? JSONEncoder().encode(record) else {
            logger.warning("federation recordOutbound: JSON encode failed for \(change.table)/\(rowKey) — entry dropped")
            return
        }
        let packedHLC = Int64(bitPattern: hlc.packed)
        let entry = FedOutboxEntry(
            id: UUID(),
            tableName: record.table,
            rowKey: rowKey.uuidString,
            packedHLC: packedHLC,
            payload: payload,
            enqueuedAt: iso8601Now()
        )
        do {
            // Gap 3: when this local write has a non-empty column-HLC stamp
            // (fieldLevelLWW table, non-delete event, at least one written
            // column), the local `_fed_sync_meta_cols` bookkeeping write and
            // the durable outbox append commit as ONE transaction — the same
            // atomicity guarantee shipped for the receive side in gap 4. This
            // does NOT (and cannot) extend to the original application-level
            // row write itself: that write already committed, via arbitrary
            // caller code, before the storage observer delivered this
            // `TableChange` to recordOutbound — recordOutbound is a reactive
            // notification handler, not the write path. What this transaction
            // guarantees is that recordOutbound's OWN two writes (column-HLC
            // bookkeeping + outbox entry) never partially land.
            if let columnHLCs, !columnHLCs.isEmpty {
                // `effectiveChange` is a `var` above (mutated by the projection-strip
                // branch) — snapshot the one field the transaction closure needs into
                // a `let` so the `@Sendable` closure can capture it (Swift 6 strict
                // concurrency forbids capturing a `var` directly).
                let tableName = effectiveChange.table
                try await storage.transaction(isolation: .serializable) { txn in
                    try await ColumnHLCStore.writeAll(
                        map: columnHLCs,
                        to: txn, sideTable: Self.fedSyncMetaColsTable,
                        tableName: tableName, primaryKey: rowKey)
                    try await FedOutboxStore.append(entry: entry, to: txn, table: Self.fedOutboxTable)
                }
            } else {
                try await FedOutboxStore.append(entry: entry, to: storage, table: Self.fedOutboxTable)
            }
        } catch {
            logger.warning("federation recordOutbound: outbox append failed for \(change.table)/\(rowKey): \(error)")
        }
    }

    /// ISO8601 timestamp for the current moment. Used by recordOutbound to stamp
    /// enqueued_at on durable outbox entries.
    private func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
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

    /// Signed pairing handshake (WC6). Derives a 16-byte cryptographically
    /// random nonce, builds a PairingProposal, signs the canonical bytes with
    /// the local Ed25519 key, and calls `acceptProposal` on the peer actor
    /// (direct cross-actor call for v1.0 in-process pairing). Delegates
    /// acceptance verification and peer registration to
    /// `verifyAndRegisterAcceptance(_:for:proposalBytes:)`.
    func pair(with peerActor: FederationStateActor, family: HyperplaneFamilySpec) async throws {
        // 16-byte cryptographically random nonce (CryptoKit SymmetricKey).
        let nonce = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let proposal = PairingProposal(
            proposerPublicKey: localIdentity.publicKey,
            proposedFamily: family,
            nonce: nonce
        )
        let sigBytes = proposalSigningBytes(proposal)
        let proposerSig = try localIdentity.sign(sigBytes)

        // Direct cross-actor call (v1.0 in-process). Peer verifies our
        // signature, signs the same bytes, persists us, and returns acceptance.
        let acceptance = try await peerActor.acceptProposal(proposal, proposerSignature: proposerSig)
        try await verifyAndRegisterAcceptance(acceptance, for: family, proposalBytes: sigBytes)
    }

    /// Proposer-side acceptance verification and peer registration.
    ///
    /// Separated from `pair(with:family:)` so the two proposer-side guard
    /// branches (family mismatch, signature mismatch) can be exercised by tests
    /// with an injected misbehaving acceptance — without needing a second real
    /// peer engine that returns the wrong response.
    ///
    /// Guards (in order):
    ///  1. `acceptance.acceptedFamily == family` — misbehaving accepter guard.
    ///  2. `FederationSignature.verify(...)` — accepter public key ownership guard.
    ///
    /// On success: persists the peer to `_fed_peers` and appends to in-memory
    /// `peers`. On guard failure: throws `SyncError.authenticationFailed`;
    /// no peer is registered.
    func verifyAndRegisterAcceptance(
        _ acceptance: PairingAcceptance,
        for family: HyperplaneFamilySpec,
        proposalBytes sigBytes: Data
    ) async throws {
        // Guard 1: family must echo back unchanged. A misbehaving accepter
        // could lie about the family it accepted — reject before sig check.
        guard acceptance.acceptedFamily == family else {
            throw SyncError.authenticationFailed(
                detail: "accepter echoed a different family spec")
        }
        // Guard 2: accepter must prove ownership of the key it claims.
        guard FederationSignature.verify(
            acceptance.signatureOfProposal,
            of: sigBytes,
            by: acceptance.accepterPublicKey
        ) else {
            throw SyncError.authenticationFailed(
                detail: "accepter signature verification failed")
        }

        // Both guards passed: persist and register the peer on the proposer side.
        let peerPubKey = acceptance.accepterPublicKey
        if let storage {
            try await persistPeer(publicKey: peerPubKey, family: family, storage: storage)
        }
        peers.append(PairedPeer(publicKey: peerPubKey, family: family))
        emit(.peerConnected(identity: peerPubKey.base64EncodedString()))
    }

    /// Accepter side of the signed pairing handshake (WC6).
    ///
    /// Verifies the proposer's Ed25519 signature over `proposalSigningBytes(proposal)`.
    /// On success, signs the same bytes with the local key, persists the proposer
    /// to `_fed_peers`, and returns a `PairingAcceptance`. Throws
    /// `SyncError.authenticationFailed` if the proposer's signature does not
    /// verify against `proposal.proposerPublicKey`.
    func acceptProposal(
        _ proposal: PairingProposal,
        proposerSignature: Data
    ) async throws -> PairingAcceptance {
        let sigBytes = proposalSigningBytes(proposal)
        // Verify proposer's signature. If verification fails, the proposer
        // does not control the key they claim — reject immediately.
        guard FederationSignature.verify(
            proposerSignature,
            of: sigBytes,
            by: proposal.proposerPublicKey
        ) else {
            throw SyncError.authenticationFailed(
                detail: "proposer signature verification failed")
        }

        // Sign the same proposal bytes with the accepter's private key.
        // This proves the accepter has seen and agreed to this specific nonce.
        let accepterSig = try localIdentity.sign(sigBytes)

        // Persist and register the proposer as a peer on the accepter side.
        let proposerPubKey = proposal.proposerPublicKey
        let family = proposal.proposedFamily
        if let storage {
            try await persistPeer(publicKey: proposerPubKey, family: family, storage: storage)
        }
        peers.append(PairedPeer(publicKey: proposerPubKey, family: family))
        emit(.peerConnected(identity: proposerPubKey.base64EncodedString()))

        return PairingAcceptance(
            accepterPublicKey: localIdentity.publicKey,
            acceptedFamily: family,
            signatureOfProposal: accepterSig
        )
    }

    func push() async throws -> SyncReceipt {
        // Manifest presence guards that the engine was configured before push.
        // The actual SyncRecord fields were stamped at observe time in recordOutbound;
        // push() only reads, packs, signs, and delivers — no per-record manifest access.
        // The engine-level relay (WC6) is required to deliver envelopes to peers.
        guard isEnabled, manifest != nil, let relay else { throw SyncError.notEnabled }
        if peers.isEmpty {
            return SyncReceipt.empty
        }
        guard let storage = self.storage else { throw SyncError.notEnabled }

        // Read durable outbox entries (WC2). SyncRecords were encoded at observe
        // time in recordOutbound; each entry's payload is a JSON-encoded SyncRecord.
        // readBatch does NOT delete entries — they survive until confirm() is called
        // after successful relay delivery (retain-on-failure contract).
        let outboxEntries = try await FedOutboxStore.readBatch(
            from: storage, table: Self.fedOutboxTable)

        // Decode each entry's payload back to SyncRecord for batching.
        var records: [SyncRecord] = []
        var entryIDs: [UUID] = []
        for entry in outboxEntries {
            do {
                let record = try JSONDecoder().decode(SyncRecord.self, from: entry.payload)
                records.append(record)
                entryIDs.append(entry.id)
            } catch {
                logger.warning("federation push: decode outbox payload failed for entry \(entry.id) — skipping")
            }
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

        // Deliver to each paired peer. Relay.send now throws on transport failure
        // (WC2 — enables "retain on failure" semantic). The in-process relay never
        // throws; a hosted relay (WC7) may throw on network error.
        //
        // Confirmation strategy: if ALL peers receive the envelope successfully,
        // confirm (delete) the outbox entries. If ANY peer's send throws, retain
        // all entries for the next push cycle's retry. Partial delivery to some
        // peers is acceptable — LWW idempotency at the receiver absorbs re-delivery.
        var pushedCount = 0
        var anyPeerFailed = false
        for peer in peers {
            do {
                try relay.send(to: peer.publicKey, message: envelope)
                pushedCount += records.count
            } catch {
                logger.warning("federation push: relay send to peer \(peer.publicKey.base64EncodedString().prefix(8)) failed: \(error) — entries retained for retry")
                anyPeerFailed = true
            }
        }

        // Confirm outbox entries on success; leave them on failure (retain-on-failure).
        // For the in-process relay (WC2), send never fails, so confirm is always called.
        if !anyPeerFailed {
            try await FedOutboxStore.confirm(ids: entryIDs, from: storage, table: Self.fedOutboxTable)
        }

        lastPushAt = Date()
        let receipt = SyncReceipt(pushed: pushedCount, pulled: 0, conflicts: 0)
        emit(.pushCompleted(receipt: receipt))
        return receipt
    }

    func pull() async throws -> SyncReceipt {
        guard isEnabled, let manifest, let storage, let relay else { throw SyncError.notEnabled }
        var appliedCount = 0
        var conflicts = 0
        // Count of records held in _fed_pending_skew this pull cycle (R9).
        var fedSkewHeldCount = 0
        // Collect row keys per table for the post-apply integrity hook (R3).
        var appliedByTable: [String: [UUID]] = [:]
        var deletedByTable: [String: [UUID]] = [:]

        // Drain the engine-level relay inbox once. All peers deliver to the
        // same local inbox (keyed by this engine's public key). Resolving the
        // sender by looking up envelope.senderPublicKey in the pairing registry
        // mirrors the Rust pull() design (single inbox, registry lookup).
        let envelopes = relay.drain(for: localIdentity.publicKey)
        for envelope in envelopes {
                // Pairing payload kinds (0x10, 0x11) are WC7 extension points;
                // v1.0 pairing is direct actor-to-actor and never traverses the
                // relay. Silently skip rather than count as conflicts.
                if envelope.payloadKind == .pairingProposal
                    || envelope.payloadKind == .pairingAcceptance {
                    continue
                }

                // SECURITY (F-3 class): Resolve the registered peer from the
                // pairing registry using the claimed sender key. Trust derives
                // from the registry, not from the envelope's own fields. An
                // envelope from an unregistered sender is rejected as a conflict.
                // Mirrors Rust pull() registry lookup.
                guard let peer = peers.first(where: {
                    $0.publicKey == envelope.senderPublicKey
                }) else {
                    conflicts += 1
                    logger.error("federation-auth: senderPublicKey \(envelope.senderPublicKey.base64EncodedString()) not in pairing registry — rejected")
                    continue
                }

                // Advisory-field check: the lookup above guarantees equality,
                // but the explicit comparison makes the security intent visible.
                // If the lookup mechanism ever changes, a mismatch here is a
                // federation-auth rejection, not a silent pass.
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
        // Scheduled tombstone GC (CVK-WB7): after each successful pull, compact
        // stale _fed_sync_meta tombstone entries if the daily interval has elapsed.
        // Non-fatal: a GC failure is swallowed so it never interrupts pull.
        try? await gcIfDue(nowMs: nowMillis())
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
                // N1 fix: the hard-delete and the tombstone-HLC bookkeeping write
                // commit as ONE transaction. Previously these were two separate
                // top-level `await` calls; a crash/kill between them could leave
                // the row deleted with no tombstone HLC recorded in _fed_sync_meta,
                // defeating the A6 stale-resurrect guard (a later stale insert
                // would find `localHLC == nil` and resurrect the row). Mirrors the
                // Swift CloudKit ApplyInbound.swift N1 fix.
                //
                // The delete keeps its pre-existing `try?` (best-effort) semantics
                // inside the transaction — a delete failure here is swallowed the
                // same way it always was, it just now happens inside the same
                // atomic unit as the tombstone-HLC write instead of before it.
                try await storage.transaction(isolation: .serializable) { txn in
                    _ = try? await txn.rowStore.deleteSync(table: record.table, where: predicate)
                    // A6: persist tombstone HLC in side table after hard-delete.
                    // WHY: without this, a stale insert arriving after the delete would
                    // find localHLC = nil and be accepted, resurrecting the deleted row.
                    try await self.writeFedTombstoneHLC(
                        storage: txn, table: record.table,
                        primaryKey: record.rowKey, hlc: record.hlc.asHLC,
                        schemaVersion: record.schemaVersion, kitID: record.kitID)
                }
                // P5-M1b: purge stale skew-queue entries and parked outbox entries.
                // The tombstone won the LWW gate; older-HLC skew entries are already
                // superseded (they would be rejected on replay by the same gate).
                // Parked outbox entries are indefinite retention after row deletion.
                // These purges remain outside the transaction: they are a separate,
                // already best-effort (`try?`) storage-reclaim concern (skew queue /
                // outbox), not part of the value+HLC correctness gate this fix closes.
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
                // N1 fix: the hard-delete, the column-HLC side-table clear, and the
                // row-grain tombstone-HLC write commit as ONE transaction. Previously
                // these were three separate top-level `await` calls; a crash/kill
                // between any two of them could leave a deleted row with stale
                // column-HLC entries still on record (confusing a future re-insert
                // under fieldLevelLWW) or with no tombstone HLC in _fed_sync_meta
                // (defeating the A6 stale-resurrect guard). Mirrors the Swift
                // CloudKit ApplyInbound.swift N1 fix.
                //
                // The delete and the column-HLC clear keep their pre-existing `try?`
                // (best-effort) semantics inside the transaction — a failure there
                // is swallowed exactly as before, just now inside the same atomic
                // unit as the tombstone-HLC write instead of before it.
                try await storage.transaction(isolation: .serializable) { txn in
                    _ = try? await txn.rowStore.deleteSync(table: record.table, where: predicate)
                    // Clear per-column side table — row is gone.
                    try? await ColumnHLCStore.clearAll(
                        from: txn, sideTable: Self.fedSyncMetaColsTable,
                        tableName: record.table, primaryKey: record.rowKey)
                    // A6: persist tombstone HLC in row-grain side table.
                    try await self.writeFedTombstoneHLC(
                        storage: txn, table: record.table,
                        primaryKey: record.rowKey, hlc: record.hlc.asHLC,
                        schemaVersion: record.schemaVersion, kitID: record.kitID)
                }
                // P5-M1b: purge stale skew-queue entries and parked outbox entries.
                // tombstoneHLC is already declared above in this arm; reuse it.
                // These purges remain outside the transaction — see the identical
                // note in the .lastWriterWinsByHLC tombstone arm above.
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
            // N1 fix: the value upsert and the sync-HLC bookkeeping write commit as
            // ONE transaction. Previously these were two separate top-level `await`
            // calls; a crash/kill between them could leave a committed value row
            // with a stale (or missing) `_fed_sync_meta` HLC, letting a later stale
            // edit silently overwrite the newer value (the exact N1 failure mode).
            // Mirrors the Swift CloudKit ApplyInbound.swift N1 fix.
            //
            // Apply the row WITHOUT embedding _syncHLC in the row values.
            // A6: HLC lives in _fed_sync_meta, not in the application row.
            try await storage.transaction(isolation: .serializable) { txn in
                _ = try await txn.rowStore.upsertSync(
                    table: record.table,
                    values: values,
                    conflictColumns: [syncedTable.primaryKeyColumn]
                )
                // Persist HLC in side table (is_deleted = 0, live row).
                try await self.writeFedSyncHLC(
                    storage: txn, table: record.table,
                    primaryKey: record.rowKey, hlc: record.hlc.asHLC,
                    schemaVersion: record.schemaVersion, kitID: record.kitID)
            }

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
            // Gap 2 fix: reject a stale edit that predates a recorded row-grain
            // tombstone — see readFedTombstoneHLC's doc comment for the full
            // rationale. Mirrors the Swift CloudKit ApplyInbound.swift gap-2 fix.
            // Strict `<` matches the existing `.lastWriterWinsByHLC` gates above.
            if let tombstoneHLC = try await readFedTombstoneHLC(
                storage: storage, table: record.table, primaryKey: record.rowKey),
               record.hlc.asHLC < tombstoneHLC {
                return // stale-before-tombstone edit — row stays deleted, no resurrection
            }

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

            // Also update row-grain HLC in _fed_sync_meta for stale-resurrect guard.
            // Read BEFORE the write transaction below — this decision is independent
            // of (does not read back) any of the writes the transaction makes.
            let existingRowHLC = try await readFedSyncHLC(
                storage: storage, table: record.table, primaryKey: record.rowKey)
            let rowHLCIsNewer = existingRowHLC == nil || record.hlc.asHLC > (existingRowHLC ?? record.hlc.asHLC)

            // N1 fix: the winning-column value upsert, the column-HLC bookkeeping
            // write, and the (conditional) row-grain HLC bookkeeping write all
            // commit as ONE transaction. Previously these were up to three separate
            // top-level `await` calls; a crash/kill between any two of them could
            // leave a committed value row with stale (or missing) HLC bookkeeping
            // in either side table, letting a later stale edit silently overwrite
            // the newer value (the exact N1 failure mode). Mirrors the Swift
            // CloudKit ApplyInbound.swift N1 fix.
            try await storage.transaction(isolation: .serializable) { txn in
                if !columnsToApply.isEmpty {
                    var upsertValues = columnsToApply
                    upsertValues[syncedTable.primaryKeyColumn] = .uuid(record.rowKey)
                    _ = try await txn.rowStore.upsertSync(
                        table: record.table,
                        values: upsertValues,
                        conflictColumns: [syncedTable.primaryKeyColumn]
                    )
                }

                if !updatedColumnHLCs.isEmpty {
                    try await ColumnHLCStore.writeAll(
                        map: updatedColumnHLCs,
                        to: txn, sideTable: Self.fedSyncMetaColsTable,
                        tableName: record.table, primaryKey: record.rowKey)
                }

                if rowHLCIsNewer {
                    try await self.writeFedSyncHLC(
                        storage: txn, table: record.table,
                        primaryKey: record.rowKey, hlc: record.hlc.asHLC,
                        schemaVersion: record.schemaVersion, kitID: record.kitID)
                }
            }
        }
    }

    // MARK: - _fed_sync_meta side table (A6 unification)

    /// Side table name for Federation row-grain HLC. Mirrors `_ck_sync_meta`.
    // Internal (not private) so tests can pass this to TombstoneGC.compact
    // directly via gcIfDue(storage:nowMs:) with @testable import.
    static let fedSyncMetaTable = "_fed_sync_meta"

    /// Side table name for Federation per-column HLC (fieldLevelLWW).
    /// Mirrors `_ck_sync_meta_cols` added to CKSideSchema at v6.
    static let fedSyncMetaColsTable = "_fed_sync_meta_cols"

    /// Side table name for Federation pending-skew queue (R9, CVK-ICLOUD P3-M4).
    /// Mirrors `_ck_pending_skew` added to CKSideSchema at v7.
    static let fedPendingSkewTable = "_fed_pending_skew"

    /// Side table name for the persistent estate Ed25519 identity (I-8, WC1).
    /// One row per estate: key_id TEXT PK (fixed "local"), secret_key BLOB (32 bytes,
    /// Ed25519 private key), public_key BLOB (32 bytes), created_at TEXT (ISO8601).
    /// At-rest posture: covered by SQLCipher per ADR-014. Keychain storage is a
    /// follow-up for Swift only; Rust leg stores in-estate for parity.
    static let fedIdentityTable = "_fed_identity"

    /// Side table name for the Federation durable outbox (WC2).
    /// Stores post-encoded SyncRecord payloads pending relay delivery.
    /// Columns: id UUID PK, table_name TEXT, row_key TEXT, packed_hlc INT,
    /// payload BLOB (JSON SyncRecord), enqueued_at TEXT (ISO8601).
    /// Entries are written at observe time and confirmed (deleted) after
    /// successful relay.send; retained on transport failure for retry.
    static let fedOutboxTable = "_fed_outbox"

    /// Side table name for the persistent paired-peer registry (WC6).
    ///
    /// One row per paired peer:
    ///   peer_id        TEXT PRIMARY KEY — deterministic UUID derived from the first
    ///                  16 bytes of the peer's Ed25519 public key. Used as the conflict
    ///                  column on upsert, so re-pairing the same physical peer is idempotent.
    ///   public_key     BLOB — raw 32-byte Ed25519 public key.
    ///   family_seed    INT  — HyperplaneFamilySpec.seed (LE u64 stored as INT64).
    ///   family_dimension INT — HyperplaneFamilySpec.dimension.
    ///   paired_at      TEXT — ISO8601 wall-clock timestamp (date storage is TEXT per
    ///                  schema invariants).
    ///
    /// Note: revoke and key-rotation are deferred to a future mission. See
    /// docs/reference/CONVERGENCEKIT_SPEC.md §B-7 for the deferred scope.
    static let fedPeersTable = "_fed_peers"

    /// Create the Federation side tables through schema v6.
    ///
    /// Must be called from `enable()` before any `applyInbound`. Mirrors
    /// `CKSideSchema.ensure`. Marked `internal` (not private) so tests that
    /// call `applyInbound` directly can call this in their setup.
    ///
    /// - v1: `_fed_sync_meta` row-grain HLC (original)
    /// - v2: `_fed_sync_meta_cols` per-column HLC for fieldLevelLWW (CVK-ICLOUD P2-M1)
    /// - v3: `_fed_pending_skew` schema-skew pending queue (R9, CVK-ICLOUD P3-M4)
    /// - v4: `_fed_identity` persistent estate Ed25519 identity (I-8, WC1)
    /// - v5: `_fed_outbox` durable outbound SyncRecord queue (WC2)
    /// - v6: `_fed_peers` persistent paired-peer registry (WC6)
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

        // _fed_identity: one-row side table for the persistent estate Ed25519 identity
        // (I-8, WC1). key_id is fixed "local"; secret_key and public_key are the 32-byte
        // raw Ed25519 key material. created_at is ISO8601 TEXT per schema invariants.
        // At-rest: covered by SQLCipher (ADR-014). Keychain is a follow-up (Swift only).
        let fedIdentityDecl = TableDeclaration(
            name: fedIdentityTable,
            columns: [
                ColumnDeclaration(name: "key_id",     type: .text, nullable: false),
                ColumnDeclaration(name: "secret_key", type: .blob, nullable: false),
                ColumnDeclaration(name: "public_key", type: .blob, nullable: false),
                ColumnDeclaration(name: "created_at", type: .text, nullable: false),
            ],
            primaryKey: ["key_id"]
        )

        // _fed_outbox: durable outbound SyncRecord queue (WC2).
        // Stores post-encoded SyncRecord payloads (JSON BLOB) pending relay delivery.
        // packed_hlc: Int64 bit-cast of SubstrateTypes.HLC.packed (UInt64 MSB-node
        //   layout per SPEC §4). Used for coalescing: same (table_name, row_key) pair
        //   keeps the entry with the higher packed_hlc; stale entries are deleted on
        //   append. packed_hlc INT DEFAULT 0 (signed, not UInt — matches PersistenceKit
        //   .int TypedValue).
        // enqueued_at: ISO8601 TEXT wall-clock timestamp (schema invariant: never REAL).
        let fedOutboxDecl = TableDeclaration(
            name: fedOutboxTable,
            columns: [
                ColumnDeclaration(name: "id",          type: .uuid, nullable: false),
                ColumnDeclaration(name: "table_name",  type: .text, nullable: false),
                ColumnDeclaration(name: "row_key",     type: .text, nullable: false),
                ColumnDeclaration(name: "packed_hlc",  type: .int,  nullable: false,
                                  defaultValue: .int(0)),
                ColumnDeclaration(name: "payload",     type: .blob, nullable: false),
                ColumnDeclaration(name: "enqueued_at", type: .text, nullable: false),
            ],
            primaryKey: ["id"]
        )

        // _fed_peers: one row per paired peer. peer_id is a deterministic UUID
        // derived from the first 16 bytes of the peer's Ed25519 public key, used
        // as the conflict column on upsert so re-pairing the same physical peer
        // is idempotent. Date storage is TEXT (ISO8601) per schema invariants.
        let fedPeersDecl = TableDeclaration(
            name: fedPeersTable,
            columns: [
                ColumnDeclaration(name: "peer_id",          type: .text, nullable: false),
                ColumnDeclaration(name: "public_key",        type: .blob, nullable: false),
                ColumnDeclaration(name: "family_seed",       type: .int,  nullable: false),
                ColumnDeclaration(name: "family_dimension",  type: .int,  nullable: false),
                ColumnDeclaration(name: "paired_at",         type: .text, nullable: false),
            ],
            primaryKey: ["peer_id"]
        )

        let schema = SchemaDeclaration(
            kitID: "ConvergenceKitFederation",
            version: 6,
            tables: [fedSyncMetaDecl, fedSyncMetaColsDecl, fedPendingSkewDecl, fedIdentityDecl, fedOutboxDecl, fedPeersDecl],
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
                // v3 → v4: add _fed_identity for persistent estate Ed25519 identity
                // (I-8, WC1). loadOrMintIdentity reads or writes this table after
                // ensure returns.
                Migration(fromVersion: 3, toVersion: 4, operations: [
                    .createTable(fedIdentityDecl),
                ]),
                // v4 → v5: add _fed_outbox durable outbound queue (WC2).
                // Replaces the in-memory pendingOutbound: [TableChange] array.
                // Entries survive process restart (drain-on-enable, retain-on-failure).
                Migration(fromVersion: 4, toVersion: 5, operations: [
                    .createTable(fedOutboxDecl),
                ]),
                // v5 → v6: add _fed_peers persistent paired-peer registry (WC6).
                // Fresh installs use the tables array directly (schema version 6,
                // all tables created); this migration block only runs for estates
                // upgrading from an existing v5 estate.
                Migration(fromVersion: 5, toVersion: 6, operations: [
                    .createTable(fedPeersDecl),
                ]),
            ]
        )
        // migrate(to:) is ADDITIVE — creates missing tables/columns without clobbering
        // the application schema. This matches the CloudKit engine's pattern.
        try await storage.migrate(to: schema)
    }

    /// Read the row-grain tombstone HLC for a specific row — ONLY if that row
    /// is currently tombstoned (`is_deleted == 1`). Returns `nil` when there is
    /// no `_fed_sync_meta` entry at all, OR when an entry exists but the row is
    /// live (`is_deleted == 0`) — in both cases there is no active tombstone to
    /// gate against.
    ///
    /// Gap 2 fix: `applyInbound`'s `.fieldLevelLWW` normal-apply arm has no
    /// visibility, from `ColumnHLCStore` alone, into whether a column's absence
    /// means "never written" or "history cleared by a tombstone"
    /// (`ColumnHLCStore.clearAll` wipes ALL column entries when a tombstone
    /// wins — see the `.fieldLevelLWW` tombstone arm above). Without this
    /// row-grain check, a stale edit that predates a delete is indistinguishable
    /// from a first-ever write and gets applied, resurrecting a correctly-deleted
    /// row. The row-grain tombstone HLC survives the delete specifically for
    /// this purpose (A6) and is untouched by the gap-3 fix — it remains the
    /// reliable signal. Mirrors the Swift CloudKit `readTombstoneHLC` gap-2 fix.
    ///
    /// Distinct from `readFedSyncHLC` below, which returns the row-grain HLC
    /// unconditionally (correct for `.lastWriterWinsByHLC`'s single whole-row
    /// comparison). Gating `.fieldLevelLWW`'s column merge on the UNCONDITIONAL
    /// row-grain HLC instead of ONLY the tombstone case would reject a
    /// legitimate concurrent edit to a DIFFERENT column merely because some
    /// other column in the same row was touched more recently — defeating
    /// fieldLevelLWW's whole purpose (independent per-column resolution).
    private func readFedTombstoneHLC(
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
              case .int(let isDeleted) = row["is_deleted"], isDeleted == 1,
              case .int(let packed) = row["sync_hlc"] else { return nil }
        return HLC(packed: UInt64(bitPattern: packed))
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
        try await writeFedSyncHLC(rowStore: storage.rowStore, table: table, primaryKey: primaryKey,
                                   hlc: hlc, schemaVersion: schemaVersion, kitID: kitID)
    }

    /// Transactional variant of `writeFedSyncHLC(storage:table:primaryKey:hlc:schemaVersion:kitID:)`.
    ///
    /// N1 fix: `applyInbound`'s `.lastWriterWinsByHLC` and `.fieldLevelLWW` arms
    /// call this overload from inside an open `storage.transaction { txn in ... }`
    /// block so the row-grain HLC bookkeeping write commits atomically with the
    /// application-row value write. Previously these were two separate top-level
    /// `await` calls; a crash/kill between them could leave a committed value
    /// row with a stale (or missing) `_fed_sync_meta` HLC, letting a later stale
    /// edit silently overwrite the newer value. Mirrors the Swift CloudKit
    /// ApplyInbound.swift / SyncMetaStore.swift N1 fix.
    private func writeFedSyncHLC(
        storage transaction: any StorageTransaction, table: String, primaryKey: UUID,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        try await writeFedSyncHLC(rowStore: transaction.rowStore, table: table, primaryKey: primaryKey,
                                   hlc: hlc, schemaVersion: schemaVersion, kitID: kitID)
    }

    /// Shared implementation — both overloads above only ever touch `.rowStore`.
    private func writeFedSyncHLC(
        rowStore: any RowStore, table: String, primaryKey: UUID,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        _ = try await rowStore.upsertSync(
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
        try await writeFedTombstoneHLC(rowStore: storage.rowStore, table: table, primaryKey: primaryKey,
                                        hlc: hlc, schemaVersion: schemaVersion, kitID: kitID)
    }

    /// Transactional variant of `writeFedTombstoneHLC(storage:table:primaryKey:hlc:schemaVersion:kitID:)`.
    ///
    /// N1 fix: `applyInbound`'s `.lastWriterWinsByHLC` and `.fieldLevelLWW`
    /// tombstone arms call this overload from inside an open
    /// `storage.transaction { txn in ... }` block so the hard-delete of the
    /// application row and the persisted tombstone HLC commit atomically.
    /// Without this, a crash between the delete and this write could leave a
    /// deleted row with no tombstone HLC recorded, letting a later stale
    /// insert resurrect it (defeating the A6 stale-resurrect guard). Mirrors
    /// the Swift CloudKit ApplyInbound.swift / SyncMetaStore.swift N1 fix.
    private func writeFedTombstoneHLC(
        storage transaction: any StorageTransaction, table: String, primaryKey: UUID,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        try await writeFedTombstoneHLC(rowStore: transaction.rowStore, table: table, primaryKey: primaryKey,
                                        hlc: hlc, schemaVersion: schemaVersion, kitID: kitID)
    }

    /// Shared implementation — both overloads above only ever touch `.rowStore`.
    private func writeFedTombstoneHLC(
        rowStore: any RowStore, table: String, primaryKey: UUID,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        _ = try await rowStore.upsertSync(
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

    // MARK: - Persistent estate identity (I-8, WC1)

    /// Load the estate Ed25519 identity from `_fed_identity`, or mint a fresh one and
    /// persist it if this is the first `enable()` on this estate.
    ///
    /// Must be called after `ensureFedSyncMetaTable` (which creates the table) and
    /// before any push/pull/pair operation that reads `localIdentity`.
    ///
    /// At-rest posture: the 32-byte private key lives in the estate SQLite file.
    /// SQLCipher covers the file at rest (ADR-014). Per-key Keychain storage is a
    /// follow-up for the Swift leg only; both legs store in-estate for parity now.
    ///
    /// I-8: identity is per-estate. Keypair derivation is unchanged — only
    /// persistence is added. A second `enable()` against the same storage reloads
    /// the same keypair minted on the first `enable()`.
    private func loadOrMintIdentity(storage: any Storage) async throws {
        let rows = try await storage.rowStore.query(
            table: Self.fedIdentityTable,
            where: .eq(
                Column(table: Self.fedIdentityTable, name: "key_id"),
                .text("local")
            )
        )
        if let row = rows.first, case .blob(let secretBlob) = row["secret_key"] {
            // Restore from the persisted private key bytes.
            localIdentity = try LocalIdentity(privateKeyBytes: secretBlob)
            logger.debug("federation: restored LocalIdentity from _fed_identity")
            return
        }
        // First enable on this estate: mint a new keypair and persist it.
        let newIdentity = LocalIdentity()
        let now = ISO8601DateFormatter().string(from: Date())
        _ = try await storage.rowStore.upsertSync(
            table: Self.fedIdentityTable,
            values: [
                "key_id":     .text("local"),
                "secret_key": .blob(newIdentity.privateKey.rawRepresentation),
                "public_key": .blob(newIdentity.publicKey),
                "created_at": .text(now),
            ],
            conflictColumns: ["key_id"]
        )
        localIdentity = newIdentity
        logger.info("federation: minted new LocalIdentity for estate, persisted to _fed_identity")
    }

    // MARK: - Paired peer persistence (_fed_peers, WC6)

    /// Derive a deterministic UUID from the first 16 bytes of an Ed25519 public key.
    ///
    /// Used as the `peer_id` primary key in `_fed_peers` so that upsert on
    /// `conflictColumns: ["peer_id"]` is idempotent — re-pairing the same physical
    /// peer overwrites the existing row rather than inserting a duplicate.
    ///
    /// The derivation is intentionally simple (raw byte slice, no hashing) because
    /// Ed25519 public keys already have sufficient entropy in their first 16 bytes.
    private func peerUUID(from publicKey: Data) -> String {
        let bytes = publicKey.prefix(16)
        return UUID(uuid: (
            bytes[bytes.startIndex],
            bytes[bytes.startIndex + 1],
            bytes[bytes.startIndex + 2],
            bytes[bytes.startIndex + 3],
            bytes[bytes.startIndex + 4],
            bytes[bytes.startIndex + 5],
            bytes[bytes.startIndex + 6],
            bytes[bytes.startIndex + 7],
            bytes[bytes.startIndex + 8],
            bytes[bytes.startIndex + 9],
            bytes[bytes.startIndex + 10],
            bytes[bytes.startIndex + 11],
            bytes[bytes.startIndex + 12],
            bytes[bytes.startIndex + 13],
            bytes[bytes.startIndex + 14],
            bytes[bytes.startIndex + 15]
        )).uuidString
    }

    /// Upsert a paired peer into `_fed_peers`.
    ///
    /// `peer_id` is the conflict column so re-pairing the same physical peer
    /// (same Ed25519 public key) updates `paired_at` without inserting a duplicate.
    /// `paired_at` is ISO8601 TEXT per schema invariants.
    private func persistPeer(publicKey: Data, family: HyperplaneFamilySpec, storage: any Storage) async throws {
        let peerID = peerUUID(from: publicKey)
        let now = ISO8601DateFormatter().string(from: Date())
        _ = try await storage.rowStore.upsert(
            table: Self.fedPeersTable,
            values: [
                "peer_id":         .text(peerID),
                "public_key":      .blob(publicKey),
                "family_seed":     .int(Int64(bitPattern: family.seed)),
                "family_dimension": .int(Int64(family.dimension)),
                "paired_at":       .text(now),
            ],
            conflictColumns: ["peer_id"]
        )
        logger.debug("federation: persisted peer \(peerID) to _fed_peers")
    }

    /// Load all rows from `_fed_peers` and rebuild the in-memory `peers` array.
    ///
    /// Called from `enable()` after `ensureFedSyncMetaTable` and `loadOrMintIdentity`,
    /// so the table exists and `localIdentity` is set. Rows with unreadable column
    /// values are skipped with a warning rather than aborting enable().
    private func reloadPeers(storage: any Storage) async throws {
        let rows = try await storage.rowStore.query(table: Self.fedPeersTable)
        var loaded = 0
        for row in rows {
            guard
                case .blob(let pubKey) = row["public_key"],
                case .int(let seedInt) = row["family_seed"],
                case .int(let dimInt) = row["family_dimension"]
            else {
                logger.warning("federation: _fed_peers row with unreadable columns — skipped")
                continue
            }
            let family = HyperplaneFamilySpec(
                seed: UInt64(bitPattern: seedInt),
                dimension: Int(dimInt)
            )
            peers.append(PairedPeer(publicKey: pubKey, family: family))
            loaded += 1
        }
        if loaded > 0 {
            logger.info("federation: reloaded \(loaded) paired peer(s) from _fed_peers")
        }
    }

    // MARK: - Tombstone GC (CVK-WB7)
    //
    // Periodic compaction of stale tombstone HLC entries in _fed_sync_meta.
    // Called at the end of each successful pull() cycle via gcIfDue(nowMs:
    // nowMillis()). Non-fatal: errors are swallowed by the pull() caller.
    //
    // STORAGE CHOICE — _fed_sync_meta sentinel row:
    // _fed_sync_meta is keyed by (table_name, primary_key). We insert a
    // sentinel row with table_name='_gc_state', primary_key='_tombstone_sweep'.
    // Underscore-prefixed names cannot collide with real application table
    // names (application tables come from the SyncManifest and use plain
    // identifiers). The sync_hlc column stores the last-GC wall time in ms
    // directly (not as a packed HLC) — this is an internal convention limited
    // to the sentinel row. Adding a new side table would require a schema
    // version bump and migration; reusing the existing table is both minimal
    // and correct for a single sentinel value.
    //
    // CRITICAL INVARIANT: SyncTombstone.gcRetentionSeconds (90 d) MUST STRICTLY exceed
    // the slot-eviction long window (P1-M3 DeviceSlotRegistry, not yet shipped).
    // A device offline during its slot window must still find tombstone HLCs
    // when it reconnects, otherwise stale inserts can resurrect deleted rows
    // (A6 adjudication). The 90 d window (3x the eviction window) provides a conservative buffer;
    // once P1-M3 ships, verify gcRetentionSeconds >= that constant.

    private static let gcSentinelTableName  = "_gc_state"
    private static let gcSentinelPrimaryKey = "_tombstone_sweep"

    /// Run tombstone GC if the daily interval has elapsed. Production entry
    /// point: reads `self.storage`.
    func gcIfDue(nowMs: Int64) async throws {
        guard let storage else { return }
        try await gcIfDue(storage: storage, nowMs: nowMs)
    }

    /// Testable GC entry point. Takes `storage` explicitly so unit tests can
    /// exercise GC without calling `enable()`.
    func gcIfDue(storage: any Storage, nowMs: Int64) async throws {
        let lastGCMs = try await readFedLastGCMs(from: storage)
        guard (nowMs - lastGCMs) >= TombstoneGCSchedule.gcIntervalMs else { return }

        _ = try await TombstoneGC.compact(
            from: storage,
            sideTable: Self.fedSyncMetaTable,
            nowMillis: nowMs
        )
        try await writeFedLastGCMs(nowMs, to: storage)
    }

    private func readFedLastGCMs(from storage: any Storage) async throws -> Int64 {
        let rows = try await storage.rowStore.query(
            table: Self.fedSyncMetaTable,
            where: .and([
                .eq(Column(table: Self.fedSyncMetaTable, name: "table_name"),
                    .text(Self.gcSentinelTableName)),
                .eq(Column(table: Self.fedSyncMetaTable, name: "primary_key"),
                    .text(Self.gcSentinelPrimaryKey))
            ])
        )
        guard let row = rows.first,
              case .int(let ms) = row["sync_hlc"] else {
            // No prior GC run — return 0 so (nowMs - 0) is always >= gcIntervalMs.
            return 0
        }
        return ms
    }

    private func writeFedLastGCMs(_ ms: Int64, to storage: any Storage) async throws {
        // upsertSync: marks the write as .syncApply origin so recordOutbound's
        // echo-suppression gate drops it. The sentinel row has no application
        // meaning and must never be pushed to peers.
        _ = try await storage.rowStore.upsertSync(
            table: Self.fedSyncMetaTable,
            values: [
                "table_name":     .text(Self.gcSentinelTableName),
                "primary_key":    .text(Self.gcSentinelPrimaryKey),
                "sync_hlc":       .int(ms),
                "schema_version": .int(0),
                "kit_id":         .text(""),
                "is_deleted":     .int(0),
            ],
            conflictColumns: ["table_name", "primary_key"]
        )
    }
}
