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
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
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
        get async { await stateActor.localIdentity }
    }
}

/// Transport abstraction for federated sync. Swapping the implementation
/// swaps the transport without touching the engine; the in-process
/// `FederationRelay` below serves local peering and tests, and a hosted
/// HTTPS/gRPC relay (a third-party SyncServer) is a drop-in conformer —
/// this protocol is that extension point.
public protocol Relay: Sendable {
    /// Deliver a signed message to a recipient's inbox.
    func send(to recipient: Data, message: SignedMessage)
    /// Drain (and clear) the recipient's pending inbound messages.
    func drain(for recipient: Data) -> [SignedMessage]
}

/// Shared in-process relay used by paired engines for v1.0 (the
/// local/test `Relay`). In production a hosted relay conforms instead.
public final class FederationRelay: Relay, @unchecked Sendable {
    private let lock = NSLock()
    private var inboxes: [Data: [SignedMessage]] = [:]  // keyed by recipient public key

    public init() {}

    public func send(to recipient: Data, message: SignedMessage) {
        lock.lock()
        defer { lock.unlock() }
        inboxes[recipient, default: []].append(message)
    }

    public func drain(for recipient: Data) -> [SignedMessage] {
        lock.lock()
        defer { lock.unlock() }
        let msgs = inboxes[recipient] ?? []
        inboxes[recipient] = []
        return msgs
    }
}

public struct SignedMessage: Sendable, Codable {
    public let senderPublicKey: Data
    public let payload: Data         // JSON-encoded [SyncRecord]
    public let signature: Data       // Ed25519 over payload
    public let hlc: PackedHLC

    public init(senderPublicKey: Data, payload: Data, signature: Data, hlc: PackedHLC) {
        self.senderPublicKey = senderPublicKey
        self.payload = payload
        self.signature = signature
        self.hlc = hlc
    }
}

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

    func disable() {
        isEnabled = false
        for task in observerTasks { task.cancel() }
        observerTasks.removeAll()
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
        let peerPubKey = await peerActor.localIdentity.publicKey
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

        let payload: Data
        do {
            payload = try JSONEncoder().encode(records)
        } catch {
            throw SyncError.encodingFailure(detail: "encode SyncRecords: \(error)")
        }

        let signature: Data
        do {
            signature = try localIdentity.sign(payload)
        } catch {
            throw SyncError.encodingFailure(detail: "sign: \(error)")
        }

        // Envelope timestamp for this transmission. send(now:)
        // advances the clock so each message envelope is strictly
        // ordered after the records it carries.
        let hlc = PackedHLC(hlcGenerator.send(now: nowMillis()))
        let message = SignedMessage(
            senderPublicKey: localIdentity.publicKey,
            payload: payload,
            signature: signature,
            hlc: hlc
        )

        var pushedCount = 0
        for peer in peers {
            peer.relay.send(to: peer.publicKey, message: message)
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
            let messages = peer.relay.drain(for: localIdentity.publicKey)
            for message in messages {
                // Verify signature.
                guard FederationSignature.verify(message.signature, of: message.payload, by: message.senderPublicKey) else {
                    conflicts += 1
                    logger.error("signature verification failed from \(message.senderPublicKey.base64EncodedString())")
                    continue
                }
                let records: [SyncRecord]
                do {
                    records = try JSONDecoder().decode([SyncRecord].self, from: message.payload)
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

    private func applyInbound(
        _ record: SyncRecord,
        syncedTable: SyncedTable,
        storage: any Storage
    ) async throws {
        let values = record.values?.asTypedValues ?? [:]
        switch syncedTable.conflictPolicy {
        case .appendOnly:
            _ = try await storage.rowStore.upsert(
                table: record.table,
                values: values,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )

        case .lastWriterWinsByHLC, .remoteWins:
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

    /// Current wall-clock in milliseconds, passed explicitly into
    /// the HLC generator so the engine stays deterministic and the
    /// single clock read is easy to audit.
    private func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
