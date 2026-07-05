//! core/sensitivity_crypto.rs — HMAC-SHA256 and PBKDF2-HMAC-SHA256 for
//! ADR-025 sensitivity-unlock password verification (Rust backend only;
//! Swift's primary backend is LocalAuthentication — see ADR-025 §2).
//!
//! HAND-ROLLED, deliberately, per Bob's ruling (2026-07-04): the C-1
//! per-crate-exception process (`DECISION_RUST_AEAD_CRATE_2026-06-05`)
//! approved RustCrypto `aes-gcm` for AEAD and explicitly REJECTED `ring`;
//! there is no approved pbkdf2/hmac crate in this codebase, and adding
//! one requires its own per-crate exception. HMAC (RFC 2104) and PBKDF2
//! (RFC 8018 §5.2) are simple, fully-specified, easily-vectored
//! constructions built entirely from a hash primitive — unlike an AEAD
//! cipher (DECISION_RUST_AEAD_CRATE's "never hand-roll an AEAD" applies
//! to authenticated *encryption*, which has subtle timing/nonce-reuse
//! failure modes; HMAC/PBKDF2 have no such pitfall class). Built over
//! `sha2 = "0.10"`, ALREADY linked in this crate's Cargo.toml (used
//! elsewhere for release tarball checksums, `core::release::sha256_hex`).
//!
//! Test vectors below are the published PBKDF2-HMAC-SHA256 vectors from
//! RFC 7914 §11 ("Test Vectors for PBKDF2 with HMAC-SHA-256") — RFC 7914
//! (scrypt) needed to test PBKDF2 as a building block, so it publishes
//! SHA-256 vectors RFC 6070 (SHA-1 only) does not carry. These are the
//! same vectors independently reproduced across many implementations
//! (Go's `golang.org/x/crypto/pbkdf2` tests, Python's `hashlib` test
//! suite, the RustCrypto `pbkdf2` crate's own test suite).

use sha2::{Digest, Sha256};

/// SHA-256 block size in bytes (RFC 2104 requires the key be padded/
/// hashed to this length before HMAC's inner/outer XOR).
const SHA256_BLOCK_SIZE: usize = 64;
/// SHA-256 output size in bytes.
const SHA256_OUTPUT_SIZE: usize = 32;

/// HMAC-SHA256 per RFC 2104: `H((K' ^ opad) || H((K' ^ ipad) || m))`,
/// where `K'` is `key` zero-padded to the block size (or `H(key)` first
/// if `key` is longer than the block size).
pub fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; SHA256_OUTPUT_SIZE] {
    // RFC 2104 step 1: keys longer than the block size are first hashed
    // down to the output size, then zero-padded like any other key.
    let mut key_block = [0u8; SHA256_BLOCK_SIZE];
    if key.len() > SHA256_BLOCK_SIZE {
        let hashed = Sha256::digest(key);
        key_block[..SHA256_OUTPUT_SIZE].copy_from_slice(&hashed);
    } else {
        key_block[..key.len()].copy_from_slice(key);
    }
    // key_block is now exactly SHA256_BLOCK_SIZE bytes, zero-padded on
    // the right — matches RFC 2104's K' construction either way.

    let mut ipad = [0x36u8; SHA256_BLOCK_SIZE];
    let mut opad = [0x5cu8; SHA256_BLOCK_SIZE];
    for i in 0..SHA256_BLOCK_SIZE {
        ipad[i] ^= key_block[i];
        opad[i] ^= key_block[i];
    }

    let mut inner = Sha256::new();
    inner.update(ipad);
    inner.update(message);
    let inner_hash = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(opad);
    outer.update(inner_hash);
    let result = outer.finalize();

    let mut out = [0u8; SHA256_OUTPUT_SIZE];
    out.copy_from_slice(&result);
    out
}

/// PBKDF2-HMAC-SHA256 per RFC 8018 §5.2.
///
/// `DK = T_1 || T_2 || ... || T_l`, `T_i = F(P, S, c, i)`,
/// `F(P, S, c, i) = U_1 ^ U_2 ^ ... ^ U_c`,
/// `U_1 = HMAC(P, S || INT_32_BE(i))`, `U_j = HMAC(P, U_{j-1})` for `j > 1`.
///
/// `iterations` must be >= 1 (a 0-iteration request is a caller error —
/// this function clamps it to 1 rather than looping zero times and
/// returning an unhashed derivation, which would silently produce a
/// dangerously weak "hash").
pub fn pbkdf2_hmac_sha256(password: &[u8], salt: &[u8], iterations: u32, dklen: usize) -> Vec<u8> {
    let iterations = iterations.max(1);
    let hlen = SHA256_OUTPUT_SIZE;
    let block_count = dklen.div_ceil(hlen);
    let mut derived = Vec::with_capacity(block_count * hlen);

    for block_index in 1..=(block_count as u32) {
        let mut salt_and_index = Vec::with_capacity(salt.len() + 4);
        salt_and_index.extend_from_slice(salt);
        salt_and_index.extend_from_slice(&block_index.to_be_bytes());

        let mut u = hmac_sha256(password, &salt_and_index);
        let mut t = u;
        for _ in 1..iterations {
            u = hmac_sha256(password, &u);
            for i in 0..hlen {
                t[i] ^= u[i];
            }
        }
        derived.extend_from_slice(&t);
    }

    derived.truncate(dklen);
    derived
}

/// Constant-time byte-slice comparison — used to compare a freshly
/// derived hash against the stored hash so password verification does
/// not leak timing information about how many leading bytes matched.
/// Returns `false` immediately on a length mismatch (length is not
/// secret; only the CONTENT comparison needs to be constant-time).
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    /// RFC 7914 §11, PBKDF2-HMAC-SHA256 test vector 1.
    #[test]
    fn rfc7914_vector_1() {
        let dk = pbkdf2_hmac_sha256(b"passwd", b"salt", 1, 64);
        assert_eq!(
            hex(&dk),
            "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"
        );
    }

    /// RFC 7914 §11, PBKDF2-HMAC-SHA256 test vector 2.
    #[test]
    fn rfc7914_vector_2() {
        let dk = pbkdf2_hmac_sha256(b"Password", b"NaCl", 80_000, 64);
        assert_eq!(
            hex(&dk),
            "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d"
        );
    }

    /// Widely-published PBKDF2-HMAC-SHA256 vectors (independently
    /// reproduced across Go's x/crypto/pbkdf2, Python hashlib, and the
    /// RustCrypto `pbkdf2` crate test suites) — password="password",
    /// salt="salt", varying iteration counts, dkLen=32.
    #[test]
    fn published_vector_password_salt_c1() {
        let dk = pbkdf2_hmac_sha256(b"password", b"salt", 1, 32);
        assert_eq!(
            hex(&dk),
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
        );
    }

    #[test]
    fn published_vector_password_salt_c2() {
        let dk = pbkdf2_hmac_sha256(b"password", b"salt", 2, 32);
        assert_eq!(
            hex(&dk),
            "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"
        );
    }

    #[test]
    fn published_vector_password_salt_c4096() {
        let dk = pbkdf2_hmac_sha256(b"password", b"salt", 4096, 32);
        assert_eq!(
            hex(&dk),
            "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"
        );
    }

    /// Longer password/salt, dkLen=40 (exercises the "derived key length
    /// not a multiple of the hash output size" truncation path — 40 is
    /// not a multiple of 32).
    #[test]
    fn published_vector_long_password_and_salt_dklen_40() {
        let dk = pbkdf2_hmac_sha256(
            b"passwordPASSWORDpassword",
            b"saltSALTsaltSALTsaltSALTsaltSALTsalt",
            4096,
            40,
        );
        assert_eq!(
            hex(&dk),
            "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9"
        );
    }

    /// HMAC-SHA256 self-check against a well-known RFC 4231 test vector
    /// (Test Case 2: key="Jefe", data="what do ya want for nothing?").
    #[test]
    fn hmac_sha256_rfc4231_test_case_2() {
        let mac = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
        assert_eq!(
            hex(&mac),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn constant_time_eq_matches_and_mismatches() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"ab"));
        assert!(!constant_time_eq(b"", b"a"));
        assert!(constant_time_eq(b"", b""));
    }

    #[test]
    fn zero_iterations_clamps_to_one_rather_than_looping_zero_times() {
        let zero = pbkdf2_hmac_sha256(b"pw", b"salt", 0, 32);
        let one = pbkdf2_hmac_sha256(b"pw", b"salt", 1, 32);
        assert_eq!(zero, one, "0 iterations must clamp to 1, never skip hashing entirely");
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }
}
