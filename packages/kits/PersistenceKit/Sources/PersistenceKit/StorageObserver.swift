// StorageObserver.swift
//
// Change-notification primitive. Downstream kits subscribe to
// table changes to wake on writes (QueueKit's watch(), Brain
// layer standing signals, ConvergenceKit's outbound replication).
//
// Delivery is at-least-once. Ordering is preserved within an
// observer but not across tables. Writes do not block on
// subscribers; if a subscriber falls behind, the backend's
// AsyncStream applies backpressure and may drop oldest under
// load.

import Foundation
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

public enum StorageEvent: Sendable, Hashable {
    case insert
    case update
    case delete
}

/// The origin of a write that produced a `TableChange`.
///
/// - `local`: a caller-initiated write (default for every ordinary write path).
///   ConvergenceKit's outbound observer records these for replication.
/// - `syncApply`: a write issued by `applyInbound` inside ConvergenceKit.
///   ConvergenceKit's outbound observer **discards** these to prevent the
///   inbound→outbox→push→remote echo loop (invariant I-10).
///
/// PersistenceKit stamps this field at write time and carries it transparently.
/// All existing construction sites receive `origin: .local` by default.
public enum ChangeOrigin: Sendable, Hashable {
    /// A caller-initiated write. Recorded for outbound replication.
    case local
    /// A write issued by `applyInbound`. Discarded by the outbound observer.
    case syncApply
}

public struct TableChange: Sendable {
    public let table: String
    public let event: StorageEvent
    public let rowKey: RowKey?
    public let values: [String: TypedValue]?
    public let hlc: HLC?
    /// The origin of the write that produced this change notification.
    /// Defaults to `.local`; set to `.syncApply` by the sync-tagged write
    /// paths (`insertSync`, `upsertSync`, `deleteSync`) used by `applyInbound`.
    public let origin: ChangeOrigin

    public init(
        table: String,
        event: StorageEvent,
        rowKey: RowKey? = nil,
        values: [String: TypedValue]? = nil,
        hlc: HLC? = nil,
        origin: ChangeOrigin = .local
    ) {
        self.table = table
        self.event = event
        self.rowKey = rowKey
        self.values = values
        self.hlc = hlc
        self.origin = origin
    }
}

// MARK: - Blob observer

/// The kind of change that occurred on the blob store.
///
/// - `put`: a blob was written (created or overwritten).
/// - `delete`: a blob was deleted.
public enum BlobEvent: Sendable, Hashable {
    case put
    case delete
}

/// A change notification emitted by the blob store.
///
/// The replication primitive's incremental session subscribes to
/// `observeBlobs()` to track which blob keys became dirty between
/// sync runs. The key field is the BlobKey (arbitrary string)
/// that changed; the bytes field carries the payload on `put`
/// events so the incremental session can propagate the value
/// without a second round-trip to the source, but is nil on `delete`.
public struct BlobChange: Sendable {
    public let key: BlobKey
    public let event: BlobEvent
    /// The blob content for `put` events; nil for `delete` events.
    ///
    /// Carrying the payload in the change notification avoids a second
    /// `get` round-trip in the incremental replication path: the session
    /// accumulates (key, bytes) for `put` events and `key` for `delete`
    /// events. The bytes are the value at the moment of the write; a
    /// subsequent overwrite of the same key before the next sync run
    /// will produce a newer `put` event that supersedes this one in the
    /// dirty accumulator (last-write-wins on the same key).
    public let bytes: Data?

    public init(key: BlobKey, event: BlobEvent, bytes: Data? = nil) {
        self.key = key
        self.event = event
        self.bytes = bytes
    }
}

// MARK: - Dirty-chain event (ADR-017 §16 / NT-P2)

/// A dirty-chain notification emitted by the hash-on-write hook.
///
/// When a row in a hashable table is written (insert, update, or upsert),
/// the `HashingRowStore` computes the row's content hash and emits this
/// event carrying the three-identifier dirty chain: the changed row's UUID
/// and its two ancestors in the Merkle containment hierarchy. These IDs are
/// the minimum payload for dirty-chain incremental re-rooting (NT-L3).
///
/// PersistenceKit does not assign meaning to the parent IDs — the consuming
/// kit's `ParentChainProvider` callback supplies them. A consumer that has
/// no parent chain (or whose table is not hashable) never sees this event.
///
/// Consumed by:
/// - CachingRowStore (NT-P4) to invalidate cached Merkle roots
/// - Merkle rollup (NT-L3) to recompute affected subtrees
public struct DirtyChainEvent: Sendable {
    /// The row that was written. Named `changedRowId` (not `changedDrawerId`)
    /// because PersistenceKit operates on generic rows — LocusKit maps this
    /// to drawer/node semantics at its own layer.
    public let changedRowId: UUID
    /// The immediate parent node in the containment hierarchy.
    public let parentNodeId: UUID
    /// The grandparent node in the containment hierarchy.
    public let grandparentNodeId: UUID
    /// The content hash computed by the hash-on-write hook.
    public let contentHash: ContentHash
    /// The table the row belongs to.
    public let table: String

    public init(
        changedRowId: UUID,
        parentNodeId: UUID,
        grandparentNodeId: UUID,
        contentHash: ContentHash,
        table: String
    ) {
        self.changedRowId = changedRowId
        self.parentNodeId = parentNodeId
        self.grandparentNodeId = grandparentNodeId
        self.contentHash = contentHash
        self.table = table
    }
}

public protocol StorageObserver: Sendable {
    /// Observe changes on `table` for the listed events.
    /// Multiple observers on the same table coexist.
    func observe(
        table: String,
        events: Set<StorageEvent>
    ) -> AsyncStream<TableChange>

    /// Observe blob changes (put and delete) on the blob store.
    ///
    /// Consumed by the incremental replication session to track which blob
    /// keys became dirty between sync runs. Multiple subscribers coexist.
    func observeBlobs() -> AsyncStream<BlobChange>

    /// Observe dirty-chain events from hash-on-write hooks.
    ///
    /// Emitted when a row in a hashable table is written and the
    /// hash-on-write hook fires. The event carries the changed row's
    /// content hash and its Merkle-containment parent chain.
    ///
    /// Default implementation returns an immediately-finished stream
    /// (backward-compatible for observers that predate hash-on-write).
    func observeDirtyChain() -> AsyncStream<DirtyChainEvent>
}

public extension StorageObserver {
    /// Default: returns an immediately-finished stream. Observers that
    /// support hash-on-write override this to deliver live events.
    func observeDirtyChain() -> AsyncStream<DirtyChainEvent> {
        AsyncStream { $0.finish() }
    }
}
