// SubstrateLibConformanceTests.swift
//
// Conformance tests for SubstrateLib's bit-identity gate.
//
// The substrate's mathematical primitives MUST produce bit-
// identical output across the four conformance cells:
//
//   1. Swift aarch64 macOS
//   2. Swift x86_64 Linux
//   3. Rust  aarch64 Linux
//   4. Rust  x86_64 Linux
//
// This is invariant I-19 from the paper. Bit-identity means
// the same input bytes produce the same output bytes,
// regardless of compiler optimization, SIMD path selection,
// or BNNS / Metal acceleration.
//
// This file is a STAGING POINT. The full Phase 2 conformance
// fixtures live in the reference test harness; they will be
// promoted into this target as part of the conformance test
// packaging sub-deliverable. For the initial promotion the
// gate is enforced by running the reference test harness
// against the SubstrateLib-built library externally.

import Testing
@testable import SubstrateLib
import SubstrateML
import SubstrateKernel
import SubstrateTypes

@Suite("SubstrateLib bit-identity smoke (I-19 staging)")
struct SubstrateLibConformanceTests {

    /// Identical Fingerprint256 values (same four block words)
    /// MUST compare equal — verifying value-type equality semantics.
    @Test func testFingerprintDeterminism() throws {
        let a = Fingerprint256(block0: 0xDEADBEEF, block1: 0xCAFEBABE,
                               block2: 0xFEEDFACE, block3: 0xBAADF00D)
        let b = Fingerprint256(block0: 0xDEADBEEF, block1: 0xCAFEBABE,
                               block2: 0xFEEDFACE, block3: 0xBAADF00D)
        #expect(a == b)
    }

    /// HLC equality must hold for identical components.
    @Test func testHLCDeterminism() throws {
        let hlc1 = HLC(physicalTime: 1_000_000, logicalCount: 0, nodeID: 1)
        let hlc2 = HLC(physicalTime: 1_000_000, logicalCount: 0, nodeID: 1)
        #expect(hlc1 == hlc2)
    }
}
