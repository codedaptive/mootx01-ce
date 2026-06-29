// fnv.rs
//
// Fowler–Noll–Vo 1a string hash, in the two widths the substrate
// uses and the 16-bit fold the cookbook calls out. Substrate-
// canonical: every kit that needs a deterministic string hash
// (drawer fingerprints, manifest-derived node ids, deterministic
// tokenization) consumes this by name (I-25). Behavior is byte-
// identical to FNV.swift on the same input.
//
// The 64-bit and 32-bit variants are independent FNV-1a hashes
// with different offset bases and primes; they are not derivable
// from each other. `hash16` IS derivable — it is the low-16 fold
// of `hash64` (cookbook §3.3 / §3.4).

/// FNV-1a 64-bit. Offset basis `0xCBF29CE484222325`, prime
/// `0x100000001B3`. Hashes UTF-8 bytes of the input string.
#[inline]
pub fn hash64(s: &str) -> u64 {
    let mut h: u64 = 0xCBF29CE484222325;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001B3);
    }
    h
}

/// FNV-1a 32-bit. Offset basis `0x811C9DC5`, prime `0x01000193`
/// (decimal 16_777_619). A different hash family from `hash64`,
/// not a truncation of it.
#[inline]
pub fn hash32(s: &str) -> u32 {
    let mut h: u32 = 0x811C9DC5;
    for b in s.bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(0x01000193);
    }
    h
}

/// `hash64(s)` folded to 16 bits by low-bit truncation. This is
/// the form the cookbook specifies for UDC-prefix and lattice
/// sub-hashes (§3.3, §3.4). It is *not* an FNV-1a 16-bit variant;
/// FNV-1a is not defined at 16 bits in the canonical reference.
#[inline]
pub fn hash16(s: &str) -> u16 {
    hash64(s) as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash64_empty_string_is_offset_basis() {
        assert_eq!(hash64(""), 0xCBF29CE484222325);
    }

    #[test]
    fn hash64_is_deterministic() {
        assert_eq!(hash64("hello"), hash64("hello"));
        assert_ne!(hash64("hello"), hash64("world"));
    }

    #[test]
    fn hash32_empty_string_is_offset_basis() {
        assert_eq!(hash32(""), 0x811C9DC5);
    }

    #[test]
    fn hash32_is_deterministic() {
        assert_eq!(hash32("hello"), hash32("hello"));
        assert_ne!(hash32("hello"), hash32("world"));
    }

    #[test]
    fn hash16_is_low_truncation_of_hash64() {
        let s = "drawer-fingerprint-test";
        assert_eq!(hash16(s), hash64(s) as u16);
    }

    #[test]
    fn hash64_and_hash32_are_independent_families() {
        // Different offset bases, different primes, no derivation.
        // Verify on a sentinel input that they don't coincidentally
        // match on the low 32 bits.
        let s = "GeniusLocus";
        assert_ne!(hash64(s) as u32, hash32(s));
    }
}
