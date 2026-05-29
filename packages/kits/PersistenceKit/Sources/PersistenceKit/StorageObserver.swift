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
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
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

public protocol StorageObserver: Sendable {
    /// Observe changes on `table` for the listed events.
    /// Multiple observers on the same table coexist.
    func observe(
        table: String,
        events: Set<StorageEvent>
    ) -> AsyncStream<TableChange>
}
