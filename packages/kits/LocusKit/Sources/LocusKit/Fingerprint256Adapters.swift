// Fingerprint256Adapters.swift
//
// LocusKit-specific marshaling adapters between Int64 bitmap-coded
// values and the substrate's canonical Fingerprint256 width.
//
// Routing convention. The substrate's math primitives live in
// SubstrateLib at Fingerprint256 width (cookbook §1.2 P1-P12;
// SUBSTRATE_MATHEMATICS §4). LocusKit stores per-row bitmaps as
// Int64 columns (adjective, operational, provenance). To route a
// per-column bit operation through a SubstrateLib primitive — XOR
// via BitwiseArithmetic.difference, OR via ORReduce, AND via
// BitwiseArithmetic.intersect, popcount via kernel.popcount64 —
// the column packs into block 0 of a Fingerprint256 with blocks
// 1–3 reserved zero.
//
// These adapters are NOT math primitives. They are type
// conversions for the column-as-block-0 packing convention. The
// math is owned by SubstrateLib; this file owns only the carrier
// shape. No proof, no platform optimization, and no conformance
// gate apply to a pack-and-unpack.
//
// Semantic note on block 0. Cookbook §3.2 assigns block 0 the
// Bitmap-LSH SimHash output (a 64-bit signed projection over the
// 192-bit row bitmap). When LocusKit packs a single Int64 column
// into block 0 for the purpose of routing a per-column bit op,
// block 0 is being used as a generic 64-bit lane within the
// carrier — NOT as a SimHash output. The math is correct (OR, XOR,
// AND, popcount on 256 bits are well-defined for any partition
// into blocks); only the SimHash-semantic interpretation is
// contextual. Callers must not mix this packing with code that
// reads block 0 as a Bitmap-LSH SimHash output.

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
import SubstrateLib
import SubstrateTypes

extension Fingerprint256 {

    /// Pack a single Int64 bitmap column into block 0 of a
    /// Fingerprint256 with blocks 1–3 zero. The packing is a
    /// type-shape convention for routing per-column bit math
    /// through SubstrateLib primitives at canonical width.
    init(int64Column value: Int64) {
        self.init(block0: UInt64(bitPattern: value),
                  block1: 0, block2: 0, block3: 0)
    }

    /// Unpack block 0 of a Fingerprint256 back to an Int64 bitmap
    /// column. Inverse of `init(int64Column:)`. Blocks 1–3 are
    /// ignored.
    var int64Column: Int64 {
        Int64(bitPattern: block0)
    }
}
