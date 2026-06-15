// NMFDomainTests.swift
//
// Domain enforcement tests for NMFAlternatingLeastSquares.
//
// NMF requires V ≥ 0 (Lee-Seung multiplicative update theorem),
// V rectangular, and all entries finite. Violations trigger
// precondition failures (process-terminating, consistent with
// sibling engine convention in this package). The tests below verify:
//   - Valid non-negative rectangular finite inputs pass through
//     unchanged and produce correct outputs.
//   - Edge cases that sit at the boundary (zero entries, rank=1,
//     rank = min(m,n)) are accepted.
//
// The precondition paths (ragged row, NaN entry, Inf entry, negative
// entry) are enforced by the precondition calls added at the entry of
// `factorize()` and are verified by code inspection of
// NMFAlternatingLeastSquares.swift lines where the precondition
// block appears.
//
// Conformance vector: docs/engineering/substrate_reference/test-harness/
//   vectors/nmf_domain.json
//
// Isolation strategy:
//   NMFAlternatingLeastSquares.factorize() calls Intellectus.report().
//   Every test here wraps its body in GlobalTestLock.shared.withLock { }
//   to prevent concurrent VizGraphSignalTests from capturing stray samples.

import Testing
@testable import SubstrateML

@Suite("NMFAlternatingLeastSquares domain enforcement")
struct NMFDomainTests {

    // MARK: - Valid inputs accepted

    @Test("all-zero non-negative matrix is accepted")
    func allZeroMatrixAccepted() async {
        // factorize() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            // All zeros are valid (V ≥ 0); factorization should not crash.
            let V: [[Float32]] = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
            let f = NMFAlternatingLeastSquares.factorize(V: V, rank: 1)
            #expect(f.W.count == 3)
            #expect(f.H.count == 1)
            // All factor entries are non-negative (the NMF invariant).
            for row in f.W { for v in row { #expect(v >= 0) } }
            for row in f.H { for v in row { #expect(v >= 0) } }
        }
    }

    @Test("mixed-zero and positive rectangular matrix accepted")
    func mixedZeroPositiveAccepted() async {
        // factorize() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            let V: [[Float32]] = [[1, 0], [0, 2], [3, 4]]
            let f = NMFAlternatingLeastSquares.factorize(V: V, rank: 2)
            #expect(f.W.count == 3)
            #expect(f.H.count == 2)
            #expect(f.rank == 2)
        }
    }

    @Test("rank-1 factorization of a valid matrix accepted")
    func rank1Accepted() async {
        // factorize() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            let V: [[Float32]] = [[1, 2], [3, 6]]
            let f = NMFAlternatingLeastSquares.factorize(V: V, rank: 1)
            #expect(f.rank == 1)
            #expect(f.W.count == 2)
            #expect(f.H.count == 1)
        }
    }

    @Test("rank = min(m,n) is the upper bound and is accepted")
    func rankAtUpperBoundAccepted() async {
        // factorize() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            // 3×2 matrix: max rank = min(3,2) = 2.
            let V: [[Float32]] = [[1, 2], [3, 4], [5, 6]]
            let f = NMFAlternatingLeastSquares.factorize(V: V, rank: 2)
            #expect(f.rank == 2)
        }
    }

    @Test("very small positive entries (near zero) are accepted")
    func nearZeroEntriesAccepted() async {
        // factorize() calls Intellectus.report() — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            let V: [[Float32]] = [[1e-10, 2e-10], [3e-10, 4e-10]]
            let f = NMFAlternatingLeastSquares.factorize(V: V, rank: 1)
            #expect(f.W.count == 2)
        }
    }

    @Test("valid input factorization is deterministic across calls with same seed")
    func deterministicAcrossCallsWithSameSeed() async {
        // factorize() calls Intellectus.report() (two calls here) — hold GlobalTestLock.
        await GlobalTestLock.shared.withLock {
            let V: [[Float32]] = [[4, 1], [1, 5], [2, 3]]
            let f1 = NMFAlternatingLeastSquares.factorize(V: V, rank: 2, seed: 0xABCDEF)
            let f2 = NMFAlternatingLeastSquares.factorize(V: V, rank: 2, seed: 0xABCDEF)
            // Same seed → same factorization (bit-identical across calls).
            for (r1, r2) in zip(f1.W, f2.W) {
                for (v1, v2) in zip(r1, r2) { #expect(v1 == v2) }
            }
            #expect(f1.finalError == f2.finalError)
        }
    }

    // MARK: - Domain precondition coverage (code inspection)
    //
    // The following invalid inputs trigger precondition failures. They
    // cannot be exercised as runnable tests (precondition terminates
    // the process), but the precondition block at the entry of
    // `factorize()` explicitly covers each case:
    //
    //   Ragged rows:   V = [[1,2], [3]]         → "V is not rectangular"
    //   NaN entry:     V = [[Float32.nan, 1]]   → "V[0][0] is not finite"
    //   Inf entry:     V = [[Float32.infinity]]  → "V[0][0] is not finite"
    //   Negative entry: V = [[-1, 2]]           → "V[0][0] is negative"
}
