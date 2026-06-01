// MatrixDecayTests.swift
//
// Lazy multiplicative half-life decay per cookbook § 6.8.
// swift-testing peer suite for Sources/SubstrateML/MatrixDecay.swift,
// mirroring rust/src/decay.rs (7 #[test]) case-for-case, with the
// Rust 1e-12 tolerance. Rust's m.set/m.get map to the Swift
// `m[row, col]` subscript.

import Testing
@testable import SubstrateML

@Suite("MatrixDecay")
struct MatrixDecayTests {

    private let tol = 1e-12

    @Test("a value halves after exactly one half-life")
    func decayHalvesAtOneHalfLife() {
        var m = DecayingMatrix(rows: 1, cols: 1, halfLifeSeconds: 100.0, lastDecayTimeSeconds: 0)
        m[0, 0] = 1.0
        MatrixDecay.apply(to: &m, nowSeconds: 100)
        #expect(abs(m[0, 0] - 0.5) < tol)
    }

    @Test("decay is a no-op when no time has elapsed")
    func decayIsNoopWhenNoTimeElapsed() {
        var m = DecayingMatrix(rows: 1, cols: 1, halfLifeSeconds: 100.0, lastDecayTimeSeconds: 50)
        m[0, 0] = 0.7
        MatrixDecay.apply(to: &m, nowSeconds: 50)
        #expect(m[0, 0] == 0.7)
    }

    @Test("decay never runs backward in time")
    func decayDoesNotGoBackward() {
        var m = DecayingMatrix(rows: 1, cols: 1, halfLifeSeconds: 100.0, lastDecayTimeSeconds: 100)
        m[0, 0] = 0.7
        MatrixDecay.apply(to: &m, nowSeconds: 50) // earlier than last decay time
        #expect(m[0, 0] == 0.7)
        #expect(m.lastDecayTimeSeconds == 100)
    }

    @Test("a value quarters after two half-lives")
    func decayQuartersAtTwoHalfLives() {
        var m = DecayingMatrix(rows: 1, cols: 1, halfLifeSeconds: 100.0, lastDecayTimeSeconds: 0)
        m[0, 0] = 1.0
        MatrixDecay.apply(to: &m, nowSeconds: 200)
        #expect(abs(m[0, 0] - 0.25) < tol)
    }

    @Test("decay-then-add composes atomically")
    func decayAndAddRoundTrip() {
        var m = DecayingMatrix(rows: 1, cols: 1, halfLifeSeconds: 100.0, lastDecayTimeSeconds: 0)
        m[0, 0] = 1.0
        MatrixDecay.decayAndAdd(to: &m, nowSeconds: 100, row: 0, col: 0, increment: 0.5)
        // After one half-life: 1.0 → 0.5, then +0.5 → 1.0.
        #expect(abs(m[0, 0] - 1.0) < tol)
    }

    @Test("the decay factor for zero elapsed time is one")
    func decayFactorForZeroElapsedIsOne() {
        #expect(MatrixDecay.decayFactor(elapsedSeconds: 0.0, halfLifeSeconds: 100.0) == 1.0)
    }

    @Test("the decay factor at one half-life is one half")
    func decayFactorAtOneHalfLifeIsHalf() {
        let f = MatrixDecay.decayFactor(elapsedSeconds: 100.0, halfLifeSeconds: 100.0)
        #expect(abs(f - 0.5) < tol)
    }
}
