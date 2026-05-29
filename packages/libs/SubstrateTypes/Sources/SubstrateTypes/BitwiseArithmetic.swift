// BitwiseArithmetic.swift
//
// Fingerprint bitwise arithmetic combinators per cookbook § 8.6.
//
// Three operations beyond OR-reduction that the substrate supports
// mathematically and that CognitionKit exposes through
// `recall_by_fingerprint` (cookbook § 11.17):
//
//   intersect(a, b)    bitwise AND      — patterns present in BOTH
//   difference(a, b)   bitwise XOR      — patterns where they differ
//   prototype(cohort)  weighted majority — typical exemplar
//
// Each enables a distinct human-natural query:
//
//   AND:   "What do Bob and Amelia BOTH care about" (case 1)
//   XOR:   "What changed in our household pattern last month"
//   PROTO: "What's the typical posture of a healthy server" (case 2)

import Foundation

public enum BitwiseArithmetic {

    /// Bitwise AND of two fingerprints.
    ///
    /// Cookbook § 11.17: input to `recall_by_fingerprint` for the
    /// "intersection of structural patterns" query.
    ///
    /// Phase 2 (decision 2026-05-28 §6.2): delegates to
    /// `Fingerprint256.zip4(_:_:)` with `&`. Bit-identical.
    @inlinable
    public static func intersect(_ a: Fingerprint256,
                                  _ b: Fingerprint256) -> Fingerprint256 {
        return a.zip4(b, &)
    }

    /// Bitwise XOR of two fingerprints.
    ///
    /// Cookbook § 11.17: input to `recall_by_fingerprint` for the
    /// "symmetric difference of structural patterns" query —
    /// isolates the bits where the two fingerprints disagree.
    ///
    /// Phase 2 (decision 2026-05-28 §6.2): delegates to
    /// `Fingerprint256.zip4(_:_:)` with `^`. Bit-identical.
    @inlinable
    public static func difference(_ a: Fingerprint256,
                                   _ b: Fingerprint256) -> Fingerprint256 {
        return a.zip4(b, ^)
    }

    /// Weighted-majority prototype across a cohort of
    /// fingerprints. Bit `i` of the result is 1 iff strictly more
    /// than 50% of cohort fingerprints have bit `i` set.
    ///
    /// Cookbook § 11.17: input to `recall_by_fingerprint` for the
    /// "find rows closest to the prototype of this cohort" query.
    ///
    /// Phase 3.1 (decision 2026-05-28 §6.3): the open-coded per-bit
    /// count loop is deleted; this delegates to
    /// `CountVector256.fold(_:).majorityVote()`, the canonical
    /// lossless cohort fold + threshold primitive. The two
    /// threshold predicates are equivalent: `counts[i] > n/2`
    /// (old) iff `2 * counts[i] > n` (new).
    public static func prototype<S: Sequence>(
        _ cohort: S
    ) -> Fingerprint256 where S.Element == Fingerprint256 {
        return CountVector256.fold(Array(cohort)).majorityVote()
    }
}

// MARK: - FingerprintBuilder (CognitionKit § 11.17 surface)
//
// The cookbook's `FingerprintBuilder` ADT lets a CognitionKit
// caller compose anchor fingerprints declaratively rather than
// materializing intermediates. The reference implementation here
// is the small interpreter.

public indirect enum FingerprintBuilder: Sendable {
    case literal(Fingerprint256)
    case intersect(FingerprintBuilder, FingerprintBuilder)
    case difference(FingerprintBuilder, FingerprintBuilder)
    case prototypeOf([Fingerprint256])

    /// Evaluate the builder to a concrete fingerprint.
    public func evaluate() -> Fingerprint256 {
        switch self {
        case .literal(let fp):
            return fp
        case .intersect(let l, let r):
            return BitwiseArithmetic.intersect(l.evaluate(), r.evaluate())
        case .difference(let l, let r):
            return BitwiseArithmetic.difference(l.evaluate(), r.evaluate())
        case .prototypeOf(let cohort):
            return BitwiseArithmetic.prototype(cohort)
        }
    }
}

// MARK: - Properties (informally verified)
//
//   intersect commutative:    A ∩ B == B ∩ A
//   intersect idempotent:     A ∩ A == A
//   intersect with zero:      A ∩ 0 == 0
//   difference symmetric:     A ⊕ B == B ⊕ A
//   difference self-zero:     A ⊕ A == 0
//   prototype empty cohort:   returns Fingerprint256.zero
//   prototype unanimous bit:  bit i set in every fingerprint ⇒ set in prototype
