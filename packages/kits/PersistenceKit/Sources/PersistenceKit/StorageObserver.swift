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

public struct TableChange: Sendable {
    public let table: String
    public let event: StorageEvent
    public let rowKey: RowKey?
    public let values: [String: TypedValue]?
    public let hlc: HLC?

    public init(
        table: String,
        event: StorageEvent,
        rowKey: RowKey? = nil,
        values: [String: TypedValue]? = nil,
        hlc: HLC? = nil
    ) {
        self.table = table
        self.event = event
        self.rowKey = rowKey
        self.values = values
        self.hlc = hlc
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
}
