// RecallTypes.swift
//
// Substrate-layer types for recall results and row projections.
//
// These types are the wire vocabulary that recall primitives,
// federation queries (TierAscendingQuery), and downstream
// cognition recipes share. They live in SubstrateTypes because
// federation needs them (paper § 9: federation responses are
// RecallResult-shaped wire objects) and because keeping them
// in one place across kits avoids redefinition drift.
//
// RecallScore: a single (RowId, score) pair. The score's meaning
// is per-primitive: cosine for vector recall, Hamming-distance
// (inverted) for fingerprint recall, BM25 for text recall.
// Composition primitives normalize across scoring scales.
//
// RecallResult: a ranked list of RecallScore plus optional
// metadata (DistanceBreakdown, confidence interval, primitive
// name). The primitive name identifies which recall produced
// the result so composition can apply RRF or MMR correctly.
//
// DistanceBreakdown: per-component distance contribution for a
// recall result. Components are lattice, fingerprint, temporal,
// and bitmap; each contribution is in [0, 1] after normalization.
// Used to surface "why this row matched" to downstream consumers
// and to drive Reciprocal Rank Fusion weights.
//
// RowProjection: the minimal projection of a substrate row that
// recall primitives consume. RowProjection deliberately omits
// the verbatim content blob (rung 1) and structured metadata
// (rung 2 beyond bitmaps); primitives operate on the structural
// fingerprint and bitmap predicates only. The verbatim content
// is fetched separately by consumers that need it (typically
// after ranking is settled).
//
// PROMOTED 2026-05-19 from glref-swift-CognitionKit.swift, then
// relocated 2026-05-29 from SubstrateLib to SubstrateTypes per the
// four-package split (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR
// addendum 2026-05-29). TierAscendingQuery (federation, SubstrateML)
// and CognitionKit (upstream) both consume these types from this
// single source.

import Foundation

/// A single (RowId, score) pair from a recall primitive.
///
/// The score's meaning is per-primitive. Composition primitives
/// (RRF, MMR) normalize across scoring scales.
public struct RecallScore: Equatable, Sendable {
    public let rowId: RowId
    public let score: Float32

    public init(rowId: RowId, score: Float32) {
        self.rowId = rowId
        self.score = score
    }
}

/// Per-component distance contributions for a recall result.
///
/// Each contribution is in [0, 1] after normalization.
/// Used to surface match attribution and to drive RRF weights.
public struct DistanceBreakdown: Equatable, Sendable {
    public var latticeContribution: Float32
    public var fingerprintContribution: Float32
    public var temporalContribution: Float32
    public var bitmapContribution: Float32

    public init(lattice: Float32 = 0, fingerprint: Float32 = 0,
                temporal: Float32 = 0, bitmap: Float32 = 0) {
        self.latticeContribution = lattice
        self.fingerprintContribution = fingerprint
        self.temporalContribution = temporal
        self.bitmapContribution = bitmap
    }
}

/// A ranked recall result.
///
/// Carries the ranked list of (RowId, score) pairs plus optional
/// distance breakdown, confidence interval, and the primitive's
/// name for composition tracking.
public struct RecallResult: Sendable {
    public let rows: [RecallScore]
    public let breakdown: DistanceBreakdown
    public let confidenceInterval: (lower: Float32, upper: Float32)?
    public let primitiveName: String

    public init(rows: [RecallScore],
                breakdown: DistanceBreakdown = DistanceBreakdown(),
                confidenceInterval: (Float32, Float32)? = nil,
                primitiveName: String) {
        self.rows = rows
        self.breakdown = breakdown
        self.confidenceInterval = confidenceInterval
        self.primitiveName = primitiveName
    }
}

/// Minimal substrate row projection consumed by recall primitives.
///
/// Omits verbatim content (rung 1) and structured metadata (rung 2
/// beyond bitmaps). Primitives operate on structural fingerprint
/// and bitmap predicates; verbatim content is fetched separately
/// after ranking is settled.
public struct RowProjection: Sendable {
    public let rowId: RowId
    public let captureHLC: HLC
    public let fingerprint: Fingerprint256
    public let lattice: LatticeAnchor
    public let bitmaps: (adjective: UInt64, operational: UInt64, provenance: UInt64)
    public let rowState: UInt8

    public init(rowId: RowId, captureHLC: HLC,
                fingerprint: Fingerprint256, lattice: LatticeAnchor,
                bitmaps: (UInt64, UInt64, UInt64),
                rowState: UInt8) {
        self.rowId = rowId
        self.captureHLC = captureHLC
        self.fingerprint = fingerprint
        self.lattice = lattice
        self.bitmaps = bitmaps
        self.rowState = rowState
    }
}
