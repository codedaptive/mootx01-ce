// src/harness/splitmix64.rs
//
// Deterministic PRNG mirroring the Swift harness's SplitMix64.
// Same algorithm, same constants. Two ports seeded with the same
// u64 produce the same stream.

pub struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    pub fn next(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic() {
        let mut a = SplitMix64::new(42);
        let mut b = SplitMix64::new(42);
        for _ in 0..10 {
            assert_eq!(a.next(), b.next());
        }
    }

    #[test]
    fn matches_swift_first_three_outputs() {
        // The Swift harness, seed = 42, produces these first
        // three u64 values. CRC32 over their LE concatenation:
        // see the cross-language test in tests/cross_language.rs.
        let mut rng = SplitMix64::new(42);
        let a = rng.next();
        let b = rng.next();
        let c = rng.next();
        // Reference values produced by Swift SplitMix64(seed: 42).
        // SplitMix64 is a public algorithm; these are stable.
        assert_eq!(a, 0xBDD7_3226_2FEB_6E95);
        assert_eq!(b, 0x28EF_E333_B266_F103);
        assert_eq!(c, 0x4752_6757_130F_9F52);
    }
}
