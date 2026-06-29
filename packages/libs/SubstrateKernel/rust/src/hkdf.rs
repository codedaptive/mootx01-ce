// hkdf.rs — RFC 5869 HKDF-SHA256 over the in-repo sha256 primitive.
//
// Mirror of SubstrateKernel/Sources/SubstrateKernel/HKDF.swift.
// Both legs use ONLY the in-repo sha256::hash for inner and outer hashes,
// so a scope key derived on Apple Silicon is byte-identical to the same
// key derived here on Linux x86_64 / aarch64. That identity is the whole
// point of the grant-crypto cross-port conformance gate.
//
// The two-step RFC 5869 construction:
//
//   extract(salt, ikm) → prk
//     HMAC-SHA256(key=salt, data=ikm)
//
//   expand(prk, info, length) → okm
//     T(1) = HMAC-SHA256(key=prk, data=info || 0x01)
//     T(n) = HMAC-SHA256(key=prk, data=T(n-1) || info || n)
//     okm  = T(1) || T(2) || ... truncated to `length` bytes
//
// HMAC-SHA256 is the RFC 2104 construction:
//   HMAC(key, data) = SHA256((key xor opad) || SHA256((key xor ipad) || data))
//   where ipad = 0x36 × 64, opad = 0x5C × 64.
//   Keys longer than 64 bytes are SHA-256-hashed first (RFC 2104 §2).

use crate::sha256;

/// RFC 5869 HKDF-SHA256 public entry point.
///
/// Derives `output_byte_count` bytes of key material from `ikm` (input keying
/// material), a fixed-domain `salt` (UTF-8 string), and a context-binding
/// `info` byte slice. `output_byte_count` must be ≤ 32 × 255 (≤ 8160).
///
/// Mirror of `GrantHKDF.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)`
/// in SubstrateKernel/HKDF.swift.
pub fn derive_key(ikm: &[u8], salt: &str, info: &[u8], output_byte_count: usize) -> Vec<u8> {
    let salt_bytes = salt.as_bytes();
    let prk = extract(salt_bytes, ikm);
    expand(&prk, info, output_byte_count)
}

/// RFC 5869 §2.2 Extract step.
/// `prk = HMAC-SHA256(key=salt, data=ikm)`
pub(crate) fn extract(salt: &[u8], ikm: &[u8]) -> [u8; 32] {
    hmac(salt, ikm)
}

/// RFC 5869 §2.3 Expand step.
///
/// Generates `length` bytes of key material by chaining HMAC invocations,
/// each appending the 1-byte counter. `length` must be ≤ 32 × 255 = 8160.
pub(crate) fn expand(prk: &[u8; 32], info: &[u8], length: usize) -> Vec<u8> {
    assert!(
        length <= 32 * 255,
        "HKDF-SHA256 can produce at most 8160 bytes"
    );
    let mut okm: Vec<u8> = Vec::with_capacity(length + 32);
    let mut t: Vec<u8> = Vec::new();
    let mut counter: u8 = 1;
    while okm.len() < length {
        // T(n) = HMAC-SHA256(key=prk, data=T(n-1) || info || n)
        let mut data = Vec::with_capacity(t.len() + info.len() + 1);
        data.extend_from_slice(&t);
        data.extend_from_slice(info);
        data.push(counter);
        let t_n = hmac(prk, &data);
        t = t_n.to_vec();
        okm.extend_from_slice(&t);
        counter = counter.wrapping_add(1);
    }
    okm.truncate(length);
    okm
}

/// RFC 2104 HMAC-SHA256.
///
/// HMAC(key, data) = SHA256((key ^ opad) || SHA256((key ^ ipad) || data))
/// where ipad = 0x36 × 64, opad = 0x5C × 64. Keys longer than the block size
/// (64 bytes) are pre-hashed per RFC 2104 §2.
///
/// Public so substrate-lib's KeyedCommitment API can compute HMAC-SHA256
/// over canonical leaf payload bytes without reimplementing the
/// construction.
pub fn hmac(key: &[u8], data: &[u8]) -> [u8; 32] {
    const BLOCK_SIZE: usize = 64;
    // Normalise the key to exactly BLOCK_SIZE bytes.
    let mut k = [0u8; BLOCK_SIZE];
    if key.len() > BLOCK_SIZE {
        // Pre-hash long keys.
        let hashed = sha256::hash(key);
        k[..32].copy_from_slice(&hashed);
    } else {
        k[..key.len()].copy_from_slice(key);
    }

    // ipad = 0x36 × BLOCK_SIZE, opad = 0x5C × BLOCK_SIZE.
    let mut ipad = [0u8; BLOCK_SIZE];
    let mut opad = [0u8; BLOCK_SIZE];
    for i in 0..BLOCK_SIZE {
        ipad[i] = k[i] ^ 0x36;
        opad[i] = k[i] ^ 0x5c;
    }

    // inner = SHA256(ipad || data)
    let mut inner_input = Vec::with_capacity(BLOCK_SIZE + data.len());
    inner_input.extend_from_slice(&ipad);
    inner_input.extend_from_slice(data);
    let inner = sha256::hash(&inner_input);

    // outer = SHA256(opad || inner)
    let mut outer_input = Vec::with_capacity(BLOCK_SIZE + 32);
    outer_input.extend_from_slice(&opad);
    outer_input.extend_from_slice(&inner);
    sha256::hash(&outer_input)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{:02x}", x)).collect()
    }

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    // MARK: - HMAC-SHA256 (RFC 4231 test cases)

    // TC1: key = 0x0b * 20, data = "Hi There"
    #[test]
    fn hmac_sha256_rfc4231_tc1() {
        let key = vec![0x0bu8; 20];
        let data = b"Hi There";
        let mac = hmac(&key, data);
        assert_eq!(
            hex(&mac),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
            "HMAC-SHA256 TC1 must match RFC 4231 §4.2"
        );
    }

    // TC2: key = "Jefe", data = "what do ya want for nothing?"
    // Expected confirmed against Python hmac.new("Jefe", msg, sha256).hexdigest().
    #[test]
    fn hmac_sha256_rfc4231_tc2() {
        let key = b"Jefe";
        let data = b"what do ya want for nothing?";
        let mac = hmac(key, data);
        assert_eq!(
            hex(&mac),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
            "HMAC-SHA256 TC2"
        );
    }

    // MARK: - RFC 5869 HKDF vectors (Appendix A.1)

    #[test]
    fn rfc5869_vector_a1_prk() {
        let ikm = vec![0x0bu8; 22];
        let salt: Vec<u8> = (0x00u8..=0x0cu8).collect();
        let prk = extract(&salt, &ikm);
        assert_eq!(
            hex(&prk),
            "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5",
            "A.1 PRK must match RFC 5869"
        );
    }

    #[test]
    fn rfc5869_vector_a1_okm() {
        let ikm = vec![0x0bu8; 22];
        let salt: Vec<u8> = (0x00u8..=0x0cu8).collect();
        let info: Vec<u8> = (0xf0u8..=0xf9u8).collect();
        let prk = extract(&salt, &ikm);
        let okm = expand(&prk.try_into().unwrap(), &info, 42);
        assert_eq!(
            hex(&okm),
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            "A.1 OKM must match RFC 5869"
        );
    }

    // MARK: - RFC 5869 A.3 (zero-length info, implicit zero salt)

    #[test]
    fn rfc5869_vector_a3_okm() {
        let ikm = vec![0x0bu8; 22];
        // No salt → salt = 0x00 * HashLen (32 bytes) per RFC 5869 §2.2.
        let salt = vec![0x00u8; 32];
        let prk = extract(&salt, &ikm);
        let okm = expand(&prk.try_into().unwrap(), &[], 42);
        assert_eq!(
            hex(&okm),
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8",
            "A.3 OKM must match RFC 5869"
        );
    }

    // MARK: - Grant-domain conformance vector

    // Matches Swift GrantHKDF HKDFTests.grantDomainScopeKeyVector:
    //   IKM = [0xAB; 32], salt = "mootx01.grant.scope-key.v1",
    //   info = "scope|12345678-1234-1234-1234-123456789ABC", length = 32.
    // Both ports must produce the SAME 32 bytes (the parity gate for scope-key
    // derivation across Apple Silicon and Linux x86_64/aarch64).
    #[test]
    fn grant_hkdf_scope_key_vector() {
        let ikm = vec![0xABu8; 32];
        let salt = "mootx01.grant.scope-key.v1";
        let info = b"scope|12345678-1234-1234-1234-123456789ABC";
        let derived = derive_key(&ikm, salt, info, 32);
        assert_eq!(
            hex(&derived),
            "fd23318310153a0ce2d588d1d226a612b45eec75e50d71515472eb333075d8e8",
            "grant-domain scope key must match cross-port (Swift) conformance vector"
        );
    }
}
