import Foundation
import SubstrateML
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
import SubstrateLib
import SubstrateTypes

/// Snapshot of all three bitmap columns for a row at a specific point
/// in time. Returned by `Estate.bitmapState(rowID:asOf:)`.
///
/// The three `Int64` columns are the row's `adjectiveBitmap`,
/// `operationalBitmap`, and `provenance` values as they would have
/// read at `asOf` — reconstructed by folding the row's audit log via
/// `AuditLogFold.projectStateAt` (clock-decision §11: state evolves
/// in ingest-HLC order; wall-clock is not a fold axis).
public struct BitmapState: Sendable {
    public let rowID: RowID
    public let asOf: HLC
    public let adjectiveBitmap: Int64
    public let operationalBitmap: Int64
    public let provenanceBitmap: Int64
}
