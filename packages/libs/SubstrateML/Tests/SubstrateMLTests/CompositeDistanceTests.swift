// CompositeDistanceTests.swift
//
// Composite distance per cookbook § 8.4. swift-testing peer suite
// for Sources/SubstrateML/CompositeDistance.swift, mirroring
// rust/src/composite_distance.rs (5 #[test]) case-for-case, with
// the Rust 1e-12 tolerance.

import Testing
@testable import SubstrateML

@Suite("CompositeDistance")
struct CompositeDistanceTests {

    private let tol = 1e-12

    @Test("identical rows have zero composite distance")
    func reflexiveIdenticalRows() {
        let d = CompositeDistance.distance(
            latticeDistance: 0.0, fingerprintHammingDistance: 0,
            alphaLattice: 0.5, alphaFingerprint: 0.5, compatibleSeedScope: true)
        #expect(abs(d) < tol)
    }

    @Test("max lattice + max hamming with equal weights = 1.0")
    func equalWeightsMaxDistance() {
        // d = 0.5 * 1.0 + 0.5 * (256/256) = 1.0.
        let d = CompositeDistance.distance(
            latticeDistance: 1.0, fingerprintHammingDistance: 256,
            alphaLattice: 0.5, alphaFingerprint: 0.5, compatibleSeedScope: true)
        #expect(abs(d - 1.0) < tol)
    }

    @Test("cross-perimeter scope drops the fingerprint term")
    func crossPerimeterDropsFingerprint() {
        // d_full = 0.5*0.4 + 0.5*0.5 = 0.45 ; d_lat = 0.5*0.4 = 0.20.
        let dFull = CompositeDistance.distance(
            latticeDistance: 0.4, fingerprintHammingDistance: 128,
            alphaLattice: 0.5, alphaFingerprint: 0.5, compatibleSeedScope: true)
        let dLat = CompositeDistance.distance(
            latticeDistance: 0.4, fingerprintHammingDistance: 128,
            alphaLattice: 0.5, alphaFingerprint: 0.5, compatibleSeedScope: false)
        #expect(abs(dFull - 0.45) < tol)
        #expect(abs(dLat - 0.20) < tol)
    }

    @Test("weight skew toward lattice")
    func weightSkew() {
        // d = 0.9*0.4 + 0.1*(64/256) = 0.36 + 0.025 = 0.385.
        let d = CompositeDistance.distance(
            latticeDistance: 0.4, fingerprintHammingDistance: 64,
            alphaLattice: 0.9, alphaFingerprint: 0.1, compatibleSeedScope: true)
        #expect(abs(d - 0.385) < tol)
    }

    @Test("the formula is linear in the alphas")
    func linearityInAlphas() {
        // Halving both alphas halves the result.
        let d1 = CompositeDistance.distance(
            latticeDistance: 0.4, fingerprintHammingDistance: 64,
            alphaLattice: 0.5, alphaFingerprint: 0.5, compatibleSeedScope: true)
        let d2 = CompositeDistance.distance(
            latticeDistance: 0.4, fingerprintHammingDistance: 64,
            alphaLattice: 0.25, alphaFingerprint: 0.25, compatibleSeedScope: true)
        #expect(abs(d1 - 2.0 * d2) < tol)
    }
}
