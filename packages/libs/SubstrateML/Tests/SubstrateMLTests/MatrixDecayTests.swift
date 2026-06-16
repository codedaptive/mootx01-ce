// MatrixDecayTests.swift
//
// Lazy multiplicative half-life decay per cookbook § 6.8.
// swift-testing peer suite for Sources/SubstrateML/MatrixDecay.swift,
// mirroring rust/src/decay.rs (7 #[test]) case-for-case, with the
// Rust 1e-12 tolerance. Rust's m.set/m.get map to the Swift
// `m[row, col]` subscript.
//
// Isolation strategy:
//   MatrixDecay.apply() calls Intellectus.report() on BOTH the dt>0 path
//   (normal decay) and the dt<=0 path (no-op, emits factor 1.0). Tests
//   that call apply() or decayAndAdd() (which calls apply internally) wrap
//   their body in GlobalTestLock.shared.withLock { } to prevent concurrent
//   VizGraphSignalTests from capturing stray samples.
//   decayFactor() is a pure math function and is exempt.

import Testing
@testable import SubstrateML

@Suite("MatrixDecay")
struct MatrixDecayTests {

    private let tol = 1e-12

    @Test("a value halves after exactly one half-life")
    func decayHalvesAtOneHalfLife() async {
        // apply() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            var m = DecayingMatrix(rows: 1, cols: 1, halfLifeSeconds: 100.0, lastDecayTimeSeconds: 0)
            m[0, 0] = 1.0
            MatrixDecay.apply(to: &m, nowSeconds: 100)
            #expect(abs(m[0, 0] - 0.5) < tol)
        }
    }

    @Test("decay is a no-op when no time has elapsed")
    func decayIsNoopWhenNoTimeElapsed() async {
        // apply() calls Intellectus.report() even on the no-op path (emits factor 1.0) —
        // hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            var m = DecayingMatrix(rows: 1, cols: 1, halfLifeSeconds: 100.0, lastDecayTimeSeconds: 50)
            m[0, 0] = 0.7
            MatrixDecay.apply(to: &m, nowSeconds: 50)
            #expect(m[0, 0] == 0.7)
        }
    }

    @Test("decay never runs backward in time")
    func decayDoesNotGoBackward() async {
        // apply() calls Intellectus.report() even for backward-time (dt<0 → no-op path) —
        // hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            var m = DecayingMatrix(rows: 1, cols: 1, halfLifeSeconds: 100.0, lastDecayTimeSeconds: 100)
            m[0, 0] = 0.7
            MatrixDecay.apply(to: &m, nowSeconds: 50) // earlier than last decay time
            #expect(m[0, 0] == 0.7)
            #expect(m.lastDecayTimeSeconds == 100)
        }
    }

    @Test("a value quarters after two half-lives")
    func decayQuartersAtTwoHalfLives() async {
        // apply() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            var m = DecayingMatrix(rows: 1, cols: 1, halfLifeSeconds: 100.0, lastDecayTimeSeconds: 0)
            m[0, 0] = 1.0
            MatrixDecay.apply(to: &m, nowSeconds: 200)
            #expect(abs(m[0, 0] - 0.25) < tol)
        }
    }

    @Test("decay-then-add composes atomically")
    func decayAndAddRoundTrip() async {
        // decayAndAdd() calls apply() which calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            var m = DecayingMatrix(rows: 1, cols: 1, halfLifeSeconds: 100.0, lastDecayTimeSeconds: 0)
            m[0, 0] = 1.0
            MatrixDecay.decayAndAdd(to: &m, nowSeconds: 100, row: 0, col: 0, increment: 0.5)
            // After one half-life: 1.0 → 0.5, then +0.5 → 1.0.
            #expect(abs(m[0, 0] - 1.0) < tol)
        }
    }

    @Test("the decay factor for zero elapsed time is one")
    func decayFactorForZeroElapsedIsOne() {
        // decayFactor() is pure math with no Intellectus emit — no lock needed.
        #expect(MatrixDecay.decayFactor(elapsedSeconds: 0.0, halfLifeSeconds: 100.0) == 1.0)
    }

    @Test("the decay factor at one half-life is one half")
    func decayFactorAtOneHalfLifeIsHalf() {
        // decayFactor() is pure math with no Intellectus emit — no lock needed.
        let f = MatrixDecay.decayFactor(elapsedSeconds: 100.0, halfLifeSeconds: 100.0)
        #expect(abs(f - 0.5) < tol)
    }
}
