// NMFAlternatingLeastSquaresTests.swift
//
// Non-negative matrix factorization via Lee-Seung multiplicative
// updates per cookbook § 6.9 / § 8.9. swift-testing peer suite for
// Sources/SubstrateML/NMFAlternatingLeastSquares.swift.
//
// rust/src/nmf.rs carries NO #[test], so this suite asserts the
// documented behavior set: dimensional correctness, non-negativity
// (the defining constraint), SplitMix64-seed determinism, the
// reconstruction-error contract (RMS, zero on an exact factoring),
// and convergence on a clean low-rank input. The default seed
// 0xDEADBEEFCAFEBABE matches the Rust mirror.
//
// Isolation strategy:
//   NMFAlternatingLeastSquares.factorize() calls Intellectus.report().
//   Tests that call factorize() wrap their body in GlobalTestLock.shared.withLock { }
//   to prevent concurrent VizGraphSignalTests from capturing stray samples.
//   reconstructionErrorExact does not call factorize() and is exempt.

import Testing
@testable import SubstrateML

@Suite("NMFAlternatingLeastSquares")
struct NMFAlternatingLeastSquaresTests {

    @Test("the factors have the expected dimensions")
    func factorDimensions() async {
        // factorize() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            let V: [[Float32]] = [[1, 1], [2, 2], [3, 3]] // 3×2
            let f = NMFAlternatingLeastSquares.factorize(V: V, rank: 2)
            #expect(f.W.count == 3)            // m rows
            #expect(f.W[0].count == 2)         // rank columns
            #expect(f.H.count == 2)            // rank rows
            #expect(f.H[0].count == 2)         // n columns
            #expect(f.rank == 2)
            #expect(f.iterations >= 1 && f.iterations <= 100)
        }
    }

    @Test("all factor entries are non-negative (the defining constraint)")
    func factorsAreNonNegative() async {
        // factorize() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            let V: [[Float32]] = [[4, 1, 0], [1, 5, 2], [0, 2, 6]]
            let f = NMFAlternatingLeastSquares.factorize(V: V, rank: 2)
            for row in f.W { for v in row { #expect(v >= 0) } }
            for row in f.H { for v in row { #expect(v >= 0) } }
        }
    }

    @Test("the same seed produces an identical factorization")
    func seedDeterminism() async {
        // factorize() calls Intellectus.report() (two calls) — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            let V: [[Float32]] = [[4, 1, 0], [1, 5, 2], [0, 2, 6]]
            let a = NMFAlternatingLeastSquares.factorize(V: V, rank: 2, seed: 0xCAFE_F00D)
            let b = NMFAlternatingLeastSquares.factorize(V: V, rank: 2, seed: 0xCAFE_F00D)
            #expect(a.W == b.W)
            #expect(a.H == b.H)
            #expect(a.finalError == b.finalError)
        }
    }

    @Test("reconstruction error is zero for an exact factoring")
    func reconstructionErrorExact() {
        // V = W × H exactly: W = [[1],[2]], H = [[1, 2]] ⇒ [[1,2],[2,4]].
        let V: [[Float32]] = [[1, 2], [2, 4]]
        let W: [[Float32]] = [[1], [2]]
        let H: [[Float32]] = [[1, 2]]
        #expect(NMFAlternatingLeastSquares.reconstructionError(V: V, W: W, H: H) == 0)
    }

    @Test("finalError equals the reconstruction error of the returned factors")
    func finalErrorMatchesReconstruction() async {
        // factorize() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            let V: [[Float32]] = [[4, 1, 0], [1, 5, 2], [0, 2, 6]]
            let f = NMFAlternatingLeastSquares.factorize(V: V, rank: 2)
            let recomputed = NMFAlternatingLeastSquares.reconstructionError(V: V, W: f.W, H: f.H)
            #expect(abs(f.finalError - recomputed) < 1e-5)
        }
    }

    @Test("a clean rank-1 input factorizes to low error")
    func convergesOnRankOne() async {
        // factorize() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            // Exactly rank-1: outer product of [1,2,3] and [1,1].
            let V: [[Float32]] = [[1, 1], [2, 2], [3, 3]]
            let f = NMFAlternatingLeastSquares.factorize(V: V, rank: 1, maxIterations: 200)
            // RMS error of the zero factorization would be ~2.16; a
            // converged rank-1 fit sits far below that.
            #expect(f.finalError < 0.5)
        }
    }
}
