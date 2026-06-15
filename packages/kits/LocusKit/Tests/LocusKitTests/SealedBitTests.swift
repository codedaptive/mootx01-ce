import Testing
import SubstrateTypes
import SubstrateKernel
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
@testable import LocusKit

/// Pins the sealed flag to adjective bit 27, polarity 1 = sealed, and
/// its independence from trust/neighbors. Mirror of rust drawer.rs
/// sealed_bit_tests — both legs MUST agree on bit 27 or seals verify
/// against the wrong bit. Tests the bit contract the `sealed` accessor
/// reads (BitField.extractFlag(adjectiveBitmap, bit: 27)).
@Suite("SealedBitTests")
struct SealedBitTests {

    @Test
    func testBit27SetMeansSealed() {
        let adj = BitField.writeFlag(true, into: 0, bit: 27)
        #expect(BitField.extractFlag(adj, bit: 27))
    }

    @Test
    func testBit27ClearMeansUnsealed() {
        #expect(!BitField.extractFlag(Int64(0), bit: 27))
    }

    /// Sealing must not disturb trust (bits 18-23) — different bits.
    @Test
    func testSealedIndependentOfTrust() {
        let adj = BitField.writeField(3, into: 0, shift: 18, width: 6) // canonical
        #expect(!BitField.extractFlag(adj, bit: 27), "trust set must not set seal")
        let sealed = BitField.writeFlag(true, into: adj, bit: 27)
        #expect(BitField.extractFlag(sealed, bit: 27))
        #expect((sealed >> 18) & 0x3F == 3, "sealing must not disturb trust")
    }

    /// Seal bit (27) must not be read by the neighboring bit-26 accessor.
    @Test
    func testBit27DoesNotCollideWithBit26() {
        let onlySeal = BitField.writeFlag(true, into: 0, bit: 27)
        #expect(!BitField.extractFlag(onlySeal, bit: 26), "27 must not read as 26")
    }
}
