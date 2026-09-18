//! Jaccard similarity over 256-bit fingerprints. Twin of Swift
//! `SubstrateTypes/Jaccard.swift` (W2.5 Track M1 activation) — see that
//! file for the empty-union convention (both-empty → 0.0, never 1.0) and
//! the bit-identity argument (integer popcount operands; the single f64
//! division of exact small integers is IEEE-identical across ports).

use crate::fingerprint256::Fingerprint256;

/// Jaccard similarity in [0, 1]. Twin of Swift `Jaccard.similarity`.
pub fn similarity(a: &Fingerprint256, b: &Fingerprint256) -> f64 {
    let union_count = a.zip4(b, |x, y| x | y).popcount();
    if union_count == 0 {
        return 0.0;
    }
    let intersection_count = a.zip4(b, |x, y| x & y).popcount();
    f64::from(intersection_count) / f64::from(union_count)
}

/// Jaccard distance in [0, 1]: `1 - similarity`. Twin of Swift.
pub fn distance(a: &Fingerprint256, b: &Fingerprint256) -> f64 {
    1.0 - similarity(a, b)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Cross-port golden pins — literal twins of Swift JaccardTests.
    fn fp(b0: u64, b1: u64, b2: u64, b3: u64) -> Fingerprint256 {
        Fingerprint256 { block0: b0, block1: b1, block2: b2, block3: b3 }
    }

    #[test]
    fn pins() {
        // identical non-empty → 1.0
        let a = fp(0b1011, 0, 0, u64::MAX);
        assert_eq!(similarity(&a, &a), 1.0);
        // disjoint → 0.0
        let b = fp(0b0100, 0, 1, 0);
        assert_eq!(similarity(&fp(0b1011, 0, 0, 0), &b), 0.0);
        // both empty → 0.0 (empty-union convention)
        assert_eq!(similarity(&Fingerprint256::ZERO, &Fingerprint256::ZERO), 0.0);
        // half overlap: a={bits0,1}, b={bits1,2}: |∩|=1, |∪|=3 → 1/3
        let x = fp(0b011, 0, 0, 0);
        let y = fp(0b110, 0, 0, 0);
        assert_eq!(similarity(&x, &y), 1.0 / 3.0);
        assert_eq!(distance(&x, &y), 1.0 - 1.0 / 3.0);
    }
}
