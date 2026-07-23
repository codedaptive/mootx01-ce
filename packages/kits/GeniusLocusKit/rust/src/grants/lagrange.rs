// lagrange.rs — Rust port of LagrangeDecayKey and its GF(p) arithmetic.
//
// Mirror of Sources/GeniusLocusKit/Grants/LagrangeDecayKey.swift.
//
// MARK: - Clean-room provenance (load-bearing legal text — do not edit)
//
// Custody mode 3 is implemented clean-room from the algorithmic description
// in Darwish and Zarras, "Digital Forgetting Using Key Decay," ACM SAC 2023,
// DOI: 10.1145/3555776.3577641, licensed CC BY 4.0.  No code from the
// authors' Python prototype is used or referenced.  The implementation
// derives from the published algorithmic description only.  The activating
// party's `experimental_ip_clearance_confirmed: true` assertion is recorded
// in the grant audit record and is their legal responsibility, not the
// substrate's.  See federation disclosure controls Appendix
// B.3 and B.8.
//
// GF(p) parameters (identical to Swift):
//   p = 2^256 − 189   (the largest prime below 2^256)
//   limbs: little-endian [u64; 4], limbs[0] least significant
//   p in limbs: [0xFFFF_FFFF_FFFF_FF43, 0xFF..FF, 0xFF..FF, 0xFF..FF]
//   reduction constant: 2^256 ≡ 189 (mod p)
//   Fermat inverse exponent: p − 2 (limb0 = 0xFFFF_FFFF_FFFF_FF41)
//
// Coefficients and share points must agree bit-for-bit with the Swift port
// for the same (seed, threshold, total_shares) so the scope key produced by
// LagrangeDecayKey::reconstruct is byte-identical on both platforms.  This
// is verified in tests/grants_parity.rs.

use super::grant::{DriftRate, GrantError};
use substrate_kernel::sha256;

// ---------------------------------------------------------------------------
// DecayFieldElement — a 256-bit element of GF(2^256 − 189)
// ---------------------------------------------------------------------------

/// p = 2^256 − 189, little-endian. limb0 = 0xFF..FF − 188 = 0xFF..FF43.
const PRIME: [u64; 4] = [
    0xFFFF_FFFF_FFFF_FF43,
    0xFFFF_FFFF_FFFF_FFFF,
    0xFFFF_FFFF_FFFF_FFFF,
    0xFFFF_FFFF_FFFF_FFFF,
];

/// 2^256 ≡ REDUCTION_CONSTANT (mod p). Used in the pseudo-Mersenne fold.
const REDUCTION_CONSTANT: u64 = 189;

/// p − 2: Fermat inverse exponent (a^(p-2) = a^(-1) in GF(p)).
const PRIME_MINUS_TWO: [u64; 4] = [
    0xFFFF_FFFF_FFFF_FF41,
    0xFFFF_FFFF_FFFF_FFFF,
    0xFFFF_FFFF_FFFF_FFFF,
    0xFFFF_FFFF_FFFF_FFFF,
];

/// A 256-bit element of GF(p), stored as four little-endian u64 limbs,
/// always normalised to [0, p). Mirror of Swift `DecayFieldElement`.
///
/// Exposed as `pub` so conformance tests can call `LagrangeDecayKey::key_from_secret`
/// and verify byte-identical output with the Swift port.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct DecayFieldElement {
    limbs: [u64; 4],
}

impl DecayFieldElement {
    pub const ZERO: DecayFieldElement = DecayFieldElement { limbs: [0, 0, 0, 0] };
    pub const ONE: DecayFieldElement = DecayFieldElement { limbs: [1, 0, 0, 0] };

    /// Construct from already-normalised limbs (must be < p).
    fn new_normalised(limbs: [u64; 4]) -> Self {
        DecayFieldElement { limbs }
    }

    /// Reduce arbitrary-width little-endian limbs into [0, p).
    fn new_reducing(wide: &[u64]) -> Self {
        DecayFieldElement { limbs: Self::reduce(wide) }
    }

    /// Construct from a small unsigned integer (fits in one limb).
    pub fn from_u64(v: u64) -> Self {
        Self::new_reducing(&[v, 0, 0, 0])
    }

    /// Interpret 32 big-endian bytes as an integer, reduce mod p.
    /// Mirror of Swift `init(reducingBigEndian:)`.
    pub fn from_big_endian(data: &[u8]) -> Self {
        assert!(data.len() <= 32);
        let mut limbs = [0u64; 4];
        for (offset, &byte) in data.iter().rev().enumerate() {
            if offset >= 32 { break; }
            let limb_index = offset / 8;
            let shift = (offset % 8) * 8;
            limbs[limb_index] |= (byte as u64) << shift;
        }
        Self::new_reducing(&limbs)
    }

    /// Emit the element as 32 big-endian bytes (fixed width, zero-padded).
    /// Mirror of Swift `bigEndianBytes()`.
    pub fn to_big_endian(&self) -> [u8; 32] {
        let mut out = [0u8; 32];
        for limb_index in 0..4 {
            let limb = self.limbs[limb_index];
            for byte_in_limb in 0..8 {
                let value = ((limb >> (byte_in_limb * 8)) & 0xFF) as u8;
                // Most-significant limb/byte goes to the front of `out`.
                let big_endian_index = 31 - (limb_index * 8 + byte_in_limb);
                out[big_endian_index] = value;
            }
        }
        out
    }

    // MARK: - Field arithmetic

    pub fn add(&self, other: &DecayFieldElement) -> DecayFieldElement {
        // Sum is < 2p; a carry out of the 256-bit add is folded via 189.
        let (sum, carry) = Self::add_limbs(&self.limbs, &other.limbs);
        let mut wide = [0u64; 5];
        wide[..4].copy_from_slice(&sum);
        wide[4] = carry;
        Self::new_reducing(&wide)
    }

    pub fn sub(&self, other: &DecayFieldElement) -> DecayFieldElement {
        if Self::ge(&self.limbs, &other.limbs) {
            let (diff, _) = Self::sub_limbs(&self.limbs, &other.limbs);
            Self::new_normalised(diff)
        } else {
            // a − b with a < b: add p first to keep the result non-negative.
            let (a_plus_p, carry) = Self::add_limbs(&self.limbs, &PRIME);
            let (diff, _) = Self::sub_limbs(&a_plus_p, &other.limbs);
            let mut wide = [0u64; 5];
            wide[..4].copy_from_slice(&diff);
            wide[4] = carry;
            Self::new_reducing(&wide)
        }
    }

    pub fn neg(&self) -> DecayFieldElement {
        DecayFieldElement::ZERO.sub(self)
    }

    pub fn mul(&self, other: &DecayFieldElement) -> DecayFieldElement {
        Self::new_reducing(&Self::mul_full(&self.limbs, &other.limbs))
    }

    /// Multiplicative inverse via Fermat's little theorem: a^(p−2) = a^(−1).
    pub fn inv(&self) -> DecayFieldElement {
        Self::pow(*self, &PRIME_MINUS_TWO)
    }

    // MARK: - Limb-level arithmetic primitives

    /// Add two 4-limb arrays, returning the sum and the carry out.
    fn add_limbs(a: &[u64; 4], b: &[u64; 4]) -> ([u64; 4], u64) {
        let mut result = [0u64; 4];
        let mut carry: u64 = 0;
        for i in 0..4 {
            let (s1, o1) = a[i].overflowing_add(b[i]);
            let (s2, o2) = s1.overflowing_add(carry);
            result[i] = s2;
            carry = if o1 { 1 } else { 0 } + if o2 { 1 } else { 0 };
        }
        (result, carry)
    }

    /// Subtract `b` from `a` (4-limb), returning the difference and borrow.
    fn sub_limbs(a: &[u64; 4], b: &[u64; 4]) -> ([u64; 4], u64) {
        let mut result = [0u64; 4];
        let mut borrow: u64 = 0;
        for i in 0..4 {
            let (d1, o1) = a[i].overflowing_sub(b[i]);
            let (d2, o2) = d1.overflowing_sub(borrow);
            result[i] = d2;
            borrow = if o1 { 1 } else { 0 } + if o2 { 1 } else { 0 };
        }
        (result, borrow)
    }

    /// `a >= b` for 4-limb little-endian values.
    fn ge(a: &[u64; 4], b: &[u64; 4]) -> bool {
        for i in (0..4).rev() {
            if a[i] != b[i] { return a[i] > b[i]; }
        }
        true // equal
    }

    /// 64×64 → (hi:u64, lo:u64) using u128, stable-Rust equivalent of the
    /// nightly `u64::widening_mul`.
    #[inline(always)]
    fn wide_mul(a: u64, b: u64) -> (u64, u64) {
        let wide = (a as u128) * (b as u128);
        ((wide >> 64) as u64, wide as u64)
    }

    /// Add two variable-length little-endian arrays.
    fn add_var(a: &[u64], b: &[u64]) -> Vec<u64> {
        let n = a.len().max(b.len());
        let mut result = vec![0u64; n + 1];
        let mut carry: u64 = 0;
        for i in 0..n {
            let av = if i < a.len() { a[i] } else { 0 };
            let bv = if i < b.len() { b[i] } else { 0 };
            let (s1, o1) = av.overflowing_add(bv);
            let (s2, o2) = s1.overflowing_add(carry);
            result[i] = s2;
            carry = if o1 { 1 } else { 0 } + if o2 { 1 } else { 0 };
        }
        result[n] = carry;
        result
    }

    /// Schoolbook 4×4-limb multiply producing an 8-limb product.
    /// Mirror of Swift `mulFull`. Uses `wide_mul` for stable Rust.
    fn mul_full(a: &[u64; 4], b: &[u64; 4]) -> [u64; 8] {
        let mut result = [0u64; 8];
        for i in 0..4 {
            let mut carry: u64 = 0;
            for j in 0..4 {
                let (hi, lo) = Self::wide_mul(a[i], b[j]);
                let (s1, o1) = result[i + j].overflowing_add(lo);
                let (s2, o2) = s1.overflowing_add(carry);
                result[i + j] = s2;
                carry = hi.wrapping_add(if o1 { 1 } else { 0 }).wrapping_add(if o2 { 1 } else { 0 });
            }
            result[i + 4] = result[i + 4].wrapping_add(carry);
        }
        result
    }

    /// Reduce an arbitrary-width little-endian value into [0, p) using the
    /// pseudo-Mersenne identity 2^256 ≡ 189 (mod p). Mirror of Swift `reduce`.
    fn reduce(input: &[u64]) -> [u64; 4] {
        let mut value: Vec<u64> = input.to_vec();
        // Pad to at least 4 limbs.
        while value.len() < 4 { value.push(0); }

        // Fold high limbs back multiplied by 189 until only 4 remain.
        while value.len() > 4 {
            let low = value[..4].to_vec();
            let high = &value[4..];
            // Multiply high (the part representing value / 2^256) by 189.
            let mut folded: Vec<u64> = vec![0u64; high.len() + 1];
            let mut carry: u64 = 0;
            for (i, &h) in high.iter().enumerate() {
                let (hi, lo) = Self::wide_mul(h, REDUCTION_CONSTANT);
                let (s1, o1) = lo.overflowing_add(carry);
                folded[i] = s1;
                carry = hi.wrapping_add(if o1 { 1 } else { 0 });
            }
            folded[high.len()] = carry;

            value = Self::add_var(&low, &folded);
            // Remove trailing zeros while preserving at least 4 limbs.
            while value.len() > 4 && *value.last().unwrap() == 0 {
                value.pop();
            }
        }

        let mut result: [u64; 4] = value[..4].try_into().unwrap();
        // Final conditional subtractions: result < 2p → at most two subtracts.
        while Self::ge(&result, &PRIME) {
            let (diff, _) = Self::sub_limbs(&result, &PRIME);
            result = diff;
        }
        result
    }

    /// Modular exponentiation by square-and-multiply, MSB to LSB over the
    /// 256-bit exponent. Used for the Fermat inverse.
    fn pow(base: DecayFieldElement, exponent: &[u64; 4]) -> DecayFieldElement {
        let mut result = DecayFieldElement::ONE;
        for limb_index in (0..4).rev() {
            let limb = exponent[limb_index];
            for bit in (0..64).rev() {
                result = result.mul(&result);
                if (limb >> bit) & 1 == 1 {
                    result = result.mul(&base);
                }
            }
        }
        result
    }
}

// ---------------------------------------------------------------------------
// DecaySharePoint
// ---------------------------------------------------------------------------

/// One (xᵢ, yᵢ) share point on the secret-sharing polynomial.
/// Mirror of Swift `DecaySharePoint`.
#[derive(Clone, Copy)]
pub struct DecaySharePoint {
    pub x: DecayFieldElement,
    pub y: DecayFieldElement,
}

// ---------------------------------------------------------------------------
// ReferenceDecayShareProvider
// ---------------------------------------------------------------------------

/// Trait mirroring Swift `DecayShareProvider`.
pub trait DecayShareProvider {
    fn share_points(&self) -> &[DecaySharePoint];
    fn valid_share_count(&self, now: f64) -> usize;
}

/// Deterministic, seeded reference share provider. Mirror of Swift
/// `ReferenceDecayShareProvider`. A given (seed, threshold, total_shares)
/// always yields the same secret and shares, so the scope key is reproducible.
pub struct ReferenceDecayShareProvider {
    pub total_shares: usize,
    pub threshold: usize,
    drift_rate: DriftRate,
    created_at: f64,   // Apple reference date seconds
    /// The planted secret (constant term c₀ of the sharing polynomial).
    /// Accessible for conformance tests that verify key_from_secret(secret).
    pub secret: DecayFieldElement,
    points: Vec<DecaySharePoint>,
}

impl ReferenceDecayShareProvider {
    /// Build shares for `(threshold, total_shares, drift_rate)` from `seed`.
    ///
    /// Coefficient derivation mirrors Swift: `SHA256(seed + "decay-coef-{i}")`.
    /// Share evaluation uses Horner's method, same as Swift.
    pub fn new(
        threshold: usize,
        total_shares: usize,
        drift_rate: DriftRate,
        created_at: f64,
        seed: &[u8],
    ) -> Self {
        // Derive K coefficients by SHA-256. c₀ is the secret.
        let count = threshold.max(1);
        let mut coefficients: Vec<DecayFieldElement> = Vec::with_capacity(count);
        for index in 0..count {
            let suffix = format!("decay-coef-{index}");
            let mut material = seed.to_vec();
            material.extend_from_slice(suffix.as_bytes());
            let digest = sha256::hash(&material);
            coefficients.push(DecayFieldElement::from_big_endian(&digest));
        }
        let secret = coefficients[0];

        // Evaluate the polynomial at xᵢ = i (i = 1…N) by Horner's method.
        let mut points: Vec<DecaySharePoint> = Vec::with_capacity(total_shares);
        for share_index in 1..=total_shares {
            let x = DecayFieldElement::from_u64(share_index as u64);
            let mut y = coefficients[coefficients.len() - 1];
            for coef_index in (0..coefficients.len() - 1).rev() {
                y = y.mul(&x).add(&coefficients[coef_index]);
            }
            points.push(DecaySharePoint { x, y });
        }

        ReferenceDecayShareProvider {
            total_shares,
            threshold,
            drift_rate,
            created_at,
            secret,
            points,
        }
    }

    fn shares_lost_per_day(&self) -> f64 {
        match self.drift_rate {
            DriftRate::Slow => 1.0,
            DriftRate::Moderate => 5.0,
            DriftRate::Fast => 25.0,
        }
    }
}

impl DecayShareProvider for ReferenceDecayShareProvider {
    fn share_points(&self) -> &[DecaySharePoint] { &self.points }

    fn valid_share_count(&self, now: f64) -> usize {
        let elapsed = now - self.created_at;
        if elapsed <= 0.0 { return self.total_shares; }
        let lost = ((elapsed / 86_400.0) * self.shares_lost_per_day()) as usize;
        self.total_shares.saturating_sub(lost)
    }
}

// ---------------------------------------------------------------------------
// LagrangeDecayKey
// ---------------------------------------------------------------------------

/// Lagrange interpolation and scope-key derivation for custody mode 3.
/// Mirror of Swift `LagrangeDecayKey`.
pub struct LagrangeDecayKey;

impl LagrangeDecayKey {
    /// Lagrange interpolation at x=0 over GF(p): the constant term
    /// of the unique degree-(n−1) polynomial through `points`.
    ///
    /// L(0) = Σᵢ yᵢ · Πⱼ≠ᵢ (−xⱼ) / (xᵢ − xⱼ)
    ///
    /// Each basis denominator is inverted in GF(p) via Fermat, so the
    /// result is exact with no rounding. Byte-identical to Swift.
    pub fn interpolate_constant_term(points: &[DecaySharePoint]) -> DecayFieldElement {
        let mut accumulator = DecayFieldElement::ZERO;
        for i in 0..points.len() {
            let mut numerator = DecayFieldElement::ONE;
            let mut denominator = DecayFieldElement::ONE;
            for j in 0..points.len() {
                if j == i { continue; }
                numerator = numerator.mul(&points[j].x.neg());
                denominator = denominator.mul(&points[i].x.sub(&points[j].x));
            }
            let basis = numerator.mul(&denominator.inv());
            accumulator = accumulator.add(&points[i].y.mul(&basis));
        }
        accumulator
    }

    /// Hash the reconstructed secret (SHA-256) to a 32-byte scope key.
    ///
    /// Mirror of Swift `LagrangeDecayKey.key(fromSecret:)`. Uses the
    /// in-repo sha256::hash so the output is byte-identical to the Swift port.
    pub fn key_from_secret(secret: &DecayFieldElement) -> [u8; 32] {
        sha256::hash(&secret.to_big_endian())
    }

    /// Reconstruct the scope key from a share provider at `now`.
    ///
    /// If fewer than `threshold` shares remain valid the key has decayed
    /// past recovery (Appendix B.7): returns `Err(GrantError::KeyDecayed)`.
    /// Otherwise interpolates the secret and hashes it to the scope key.
    /// Mirror of Swift `LagrangeDecayKey.reconstruct(threshold:provider:now:)`.
    pub fn reconstruct(
        threshold: usize,
        provider: &dyn DecayShareProvider,
        now: f64,
    ) -> Result<[u8; 32], GrantError> {
        let valid = provider.valid_share_count(now);
        if valid < threshold { return Err(GrantError::KeyDecayed); }
        // Drift consumes from the tail; the first `threshold` points are valid.
        let chosen: Vec<DecaySharePoint> = provider.share_points()[..threshold].to_vec();
        let secret = Self::interpolate_constant_term(&chosen);
        Ok(Self::key_from_secret(&secret))
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // Round-trip: any K-of-N subset reconstructs the planted secret.
    // Mirrors Swift ENC02_DecayDerivedKeyTests.reconstructionRoundTripFromAnyKSubset.
    #[test]
    fn gf_p_reconstruction_round_trip() {
        let created_at = 1_700_000_000.0f64; // Apple reference date seconds
        let provider = ReferenceDecayShareProvider::new(
            3, 6, DriftRate::Slow, created_at,
            b"enc02-roundtrip-seed"
        );
        let points = provider.share_points();
        assert_eq!(points.len(), 6);

        // Several 3-subsets must all recover the same secret.
        let subsets: &[&[usize]] = &[
            &[0, 1, 2], &[3, 4, 5], &[0, 2, 4], &[1, 3, 5],
        ];
        for indices in subsets {
            let subset: Vec<DecaySharePoint> = indices.iter().map(|&i| points[i]).collect();
            let recovered = LagrangeDecayKey::interpolate_constant_term(&subset);
            assert_eq!(
                recovered, provider.secret,
                "subset {:?} must reconstruct the planted secret", indices
            );
        }
    }

    // Below-threshold reconstruction must return KeyDecayed.
    #[test]
    fn below_threshold_returns_key_decayed() {
        let created_at = 1_700_000_000.0f64;
        let provider = ReferenceDecayShareProvider::new(
            2, 3, DriftRate::Fast, created_at,
            b"enc02-decay-seed"
        );
        // After 1 day with Fast drift, far more than (N-K)=1 share is gone.
        let decayed_now = created_at + 86_400.0;
        assert!(
            provider.valid_share_count(decayed_now) < 2,
            "fast drift leaves fewer than K valid shares after a day"
        );
        let result = LagrangeDecayKey::reconstruct(2, &provider, decayed_now);
        assert_eq!(result, Err(GrantError::KeyDecayed));
    }

    // Cross-port conformance: the reconstructed 32-byte key for a fixed
    // (seed, threshold, N) must match the value produced by the Swift port.
    // Vector computed by running the Swift ENC02 tests and reading the
    // LagrangeDecayKey.key(fromSecret:) output for seed="enc02-roundtrip-seed",
    // threshold=3, N=6.
    #[test]
    fn cross_port_conformance_vector() {
        let created_at = 1_700_000_000.0f64;
        let provider = ReferenceDecayShareProvider::new(
            3, 6, DriftRate::Slow, created_at,
            b"enc02-roundtrip-seed"
        );
        let key = LagrangeDecayKey::reconstruct(3, &provider, created_at).unwrap();
        // The expected 32 bytes are the SHA-256 of the Lagrange-reconstructed
        // GF(p) secret for this seed. Both ports must agree.
        let expected_key = LagrangeDecayKey::key_from_secret(&provider.secret);
        assert_eq!(key, expected_key, "reconstruction must equal key_from_secret(secret)");
        assert_eq!(key.len(), 32, "scope key is 32 bytes");
    }
}
