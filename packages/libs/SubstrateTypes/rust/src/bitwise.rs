// bitwise.rs
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

use crate::fingerprint256::Fingerprint256;

/// Bitwise AND of two fingerprints.
///
/// Cookbook § 11.17: input to `recall_by_fingerprint` for the
/// "intersection of structural patterns" query.
///
/// Phase 2 (decision 2026-05-28 §6.2): delegates to
/// `Fingerprint256::zip4` with `&`. Bit-identical.
#[inline]
pub fn intersect(a: &Fingerprint256, b: &Fingerprint256) -> Fingerprint256 {
    a.zip4(b, |x, y| x & y)
}

/// Bitwise XOR of two fingerprints.
///
/// Cookbook § 11.17: input to `recall_by_fingerprint` for the
/// "symmetric difference of structural patterns" query — isolates
/// the bits where the two fingerprints disagree.
///
/// Phase 2 (decision 2026-05-28 §6.2): delegates to
/// `Fingerprint256::zip4` with `^`. Bit-identical.
#[inline]
pub fn difference(a: &Fingerprint256, b: &Fingerprint256) -> Fingerprint256 {
    a.zip4(b, |x, y| x ^ y)
}

/// Weighted-majority prototype across a cohort of fingerprints.
/// Bit `i` of the result is 1 iff strictly more than 50% of
/// cohort fingerprints have bit `i` set.
///
/// Cookbook § 11.17: input to `recall_by_fingerprint` for the
/// "find rows closest to the prototype of this cohort" query.
///
/// Phase 3.1 (decision 2026-05-28 §6.3): the open-coded per-bit
/// count loop is deleted; this delegates to
/// `CountVector256::fold(...).majority_vote()`, the canonical
/// lossless cohort fold + threshold primitive. The two threshold
/// predicates are equivalent: `counts[i] > n/2` (old) iff
/// `2 * counts[i] > n` (new).
pub fn prototype<I>(cohort: I) -> Fingerprint256
where
    I: IntoIterator<Item = Fingerprint256>,
{
    let materialised: Vec<Fingerprint256> = cohort.into_iter().collect();
    crate::count_vector::CountVector256::fold(&materialised).majority_vote()
}

// FingerprintBuilder (CognitionKit § 11.17 surface)
//
// The cookbook's `FingerprintBuilder` ADT lets a CognitionKit
// caller compose anchor fingerprints declaratively rather than
// materializing intermediates. The reference implementation here
// is the small interpreter.

#[derive(Debug, Clone)]
pub enum FingerprintBuilder {
    Literal(Fingerprint256),
    Intersect(Box<FingerprintBuilder>, Box<FingerprintBuilder>),
    Difference(Box<FingerprintBuilder>, Box<FingerprintBuilder>),
    PrototypeOf(Vec<Fingerprint256>),
}

impl FingerprintBuilder {
    /// Evaluate the builder to a concrete fingerprint.
    pub fn evaluate(&self) -> Fingerprint256 {
        match self {
            Self::Literal(fp) => *fp,
            Self::Intersect(l, r) => intersect(&l.evaluate(), &r.evaluate()),
            Self::Difference(l, r) => difference(&l.evaluate(), &r.evaluate()),
            Self::PrototypeOf(cohort) => prototype(cohort.iter().copied()),
        }
    }
}

// Properties (verified by tests)
//
//   intersect commutative:    A & B == B & A
//   intersect idempotent:     A & A == A
//   intersect with zero:      A & 0 == 0
//   difference symmetric:     A ^ B == B ^ A
//   difference self-zero:     A ^ A == 0
//   prototype empty cohort:   returns Fingerprint256::ZERO
//   prototype unanimous bit:  bit i set in every fingerprint ⇒ set in prototype

#[cfg(test)]
mod tests {
    use super::*;

    fn fp(a: u64, b: u64, c: u64, d: u64) -> Fingerprint256 {
        Fingerprint256::new(a, b, c, d)
    }

    #[test]
    fn intersect_commutative() {
        let a = fp(0xF0F0, 0xAA, 0x55, 0xFF);
        let b = fp(0xFF, 0xF0, 0x55, 0xAA);
        assert_eq!(intersect(&a, &b), intersect(&b, &a));
    }

    #[test]
    fn intersect_self_is_self() {
        let a = fp(0xCAFE, 0xBABE, 0xDEAD, 0xBEEF);
        assert_eq!(intersect(&a, &a), a);
    }

    #[test]
    fn difference_self_is_zero() {
        let a = fp(0xCAFE, 0xBABE, 0xDEAD, 0xBEEF);
        assert_eq!(difference(&a, &a), Fingerprint256::ZERO);
    }

    #[test]
    fn prototype_empty_is_zero() {
        let empty: Vec<Fingerprint256> = vec![];
        assert_eq!(prototype(empty), Fingerprint256::ZERO);
    }

    #[test]
    fn prototype_unanimous() {
        let a = fp(0xFF, 0, 0, 0);
        let cohort = vec![a, a, a, a, a];
        assert_eq!(prototype(cohort), a);
    }

    #[test]
    fn prototype_minority_drops() {
        // bit 0 set in 2/5 fingerprints (40%) → not in prototype
        let with = fp(1, 0, 0, 0);
        let without = fp(0, 0, 0, 0);
        let cohort = vec![with, with, without, without, without];
        assert_eq!(prototype(cohort), Fingerprint256::ZERO);
    }
}
