// SubstrateMLTests.swift
//
// SubstrateML package-level smoke suite. Confirms the ML surface
// is importable and the canonical deterministic primitive runs.
// Per-type behavior suites live in the dedicated peer files
// (one <Type>Tests.swift per Sources/SubstrateML/<Type>.swift),
// each mirroring the corresponding Rust `#[test]` module. The
// four-way conformance harness at
// docs/validation/substrate_math_performance/ is a separate
// concern (algorithm validity, not library coverage).

import Testing
import SubstrateKernel
import SubstrateTypes
@testable import SubstrateML

@Suite("SubstrateML package smoke")
struct SubstrateMLSmokeTests {

    @Test("FloatSimHash is deterministic across two identical calls")
    func floatSimHashIsDeterministic() {
        // FloatSimHash is one of the ML primitives. Two runs with
        // identical inputs must produce identical output — guards
        // against accidental mutable state or RNG leakage.
        let v: [Float] = (0..<384).map { Float($0) / 384.0 - 0.5 }
        let a = FloatSimHash.project(vector: v, seed: 0xDEAD_BEEF)
        let b = FloatSimHash.project(vector: v, seed: 0xDEAD_BEEF)
        #expect(a == b)
    }
}
