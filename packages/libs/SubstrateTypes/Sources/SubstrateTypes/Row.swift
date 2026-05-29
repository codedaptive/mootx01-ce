// Row.swift
//
// Phase 6.6 (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.6)
// Moved from SubstrateLib/Sources/SubstrateLib/Verbs.swift.
//
// A substrate row at its current state. Mirrors the row layout
// in cookbook § 2.1. Pure data — no logic, no I/O. The full
// substrate (containing rows + audit log + matrices) stays in
// SubstrateLib alongside the verb implementations.

import Foundation

/// Wire-compatible row identifier. Swift uses UUID directly;
/// the Rust port spells this `RowId(u128)` as a newtype. The
/// two are byte-identical: UUID's 16-byte big-endian wire form
/// equals u128's big-endian 16-byte encoding. The typealias
/// lets Swift call sites use the substrate vocabulary
/// (`RowId`) while remaining transparently a `UUID` value.
public typealias RowId = UUID

/// A substrate row at its current state. Mirrors the row layout
/// in cookbook § 2.1.
public struct Row: Sendable {
    public let id: UUID
    public let nounType: NounType
    public var state: RowState          // see § 9.1
    public var adjectiveBitmap: Int64
    public var operationalBitmap: Int64
    public var provenanceBitmap: Int64
    public var fingerprint: Fingerprint256
    public var latticeAnchor: LatticeAnchor
    public var lineageId: UUID?
    public var content: Data?

    public init(id: UUID, nounType: NounType, state: RowState,
                adjectiveBitmap: Int64, operationalBitmap: Int64,
                provenanceBitmap: Int64, fingerprint: Fingerprint256,
                latticeAnchor: LatticeAnchor,
                lineageId: UUID? = nil, content: Data? = nil) {
        self.id = id
        self.nounType = nounType
        self.state = state
        self.adjectiveBitmap = adjectiveBitmap
        self.operationalBitmap = operationalBitmap
        self.provenanceBitmap = provenanceBitmap
        self.fingerprint = fingerprint
        self.latticeAnchor = latticeAnchor
        self.lineageId = lineageId
        self.content = content
    }
}
