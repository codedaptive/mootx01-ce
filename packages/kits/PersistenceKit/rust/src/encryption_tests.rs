//! Tests for the at-rest encryption module (PAR-5-PK).
//!
//! Sections:
//!   1. EstateEncryptionConfig construction — mirrors Swift EncryptionModeTests.
//!   2. AES-GCM-256 Known-Answer Test (NIST-aligned vector) — proves
//!      `AesGcmAeadProvider` implements standard AES-GCM-256 correctly.
//!      The vector uses the same key/nonce/PT as the Swift KAT, confirming
//!      cross-decryptability between Swift and Rust.
//!   3. Round-trip and tamper-detection tests for AesGcmAeadProvider.
//!   4. AeadProvider swap-proof test — injects a test-double provider
//!      through RowCrypto WITHOUT changing any RowCrypto or storage call
//!      site, proving a future FedRAMP provider is drop-in.

use crate::encryption::{
    AeadProvider, AesGcmAeadProvider, EncryptionMode, EstateEncryptionConfig, RowCrypto,
};

// ─────────────────────────────────────────────────────────────────────────────
// Test-double provider (swap-proof test only)
// ─────────────────────────────────────────────────────────────────────────────

/// A minimal AeadProvider that XORs with the first key byte — not
/// cryptographically secure, but sufficient to prove the seam works:
/// the test double round-trips and RowCrypto never hard-codes the algorithm.
/// Mirrors the Swift `XorTestDoubleAeadProvider`.
struct XorTestDoubleAeadProvider;

impl AeadProvider for XorTestDoubleAeadProvider {
    fn encrypt(&self, plaintext: &[u8], key: &[u8]) -> Result<Vec<u8>, String> {
        // Layout: [1-byte nonce][1-byte tag][XOR-encrypted payload]
        let key_byte = key.first().copied().unwrap_or(0x00);
        let mut out = vec![0xAAu8, 0xBBu8]; // simulated nonce + tag
        out.extend(plaintext.iter().map(|b| b ^ key_byte));
        Ok(out)
    }

    fn decrypt(&self, ciphertext: &[u8], key: &[u8]) -> Result<Vec<u8>, String> {
        if ciphertext.len() < 2 {
            return Err("XorDoubleProvider: envelope too short".into());
        }
        let key_byte = key.first().copied().unwrap_or(0x00);
        // Strip the 2-byte simulated header, XOR-decrypt the rest.
        Ok(ciphertext[2..].iter().map(|b| b ^ key_byte).collect())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section 1 — EstateEncryptionConfig construction
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn plaintext_config_mints_no_key() {
    let config = EstateEncryptionConfig::plaintext();
    assert_eq!(config.mode, EncryptionMode::Plaintext);
    assert!(config.key_identifier.is_none());
    assert!(config.key.is_none());
}

#[test]
fn row_encryption_config_generates_key_and_identifier() {
    let config = EstateEncryptionConfig::row_encryption();
    assert_eq!(config.mode, EncryptionMode::RowEncryption);
    assert!(config.key_identifier.is_some());
    assert!(!config.key_identifier.as_ref().unwrap().is_empty());
    assert!(config.key.is_some());
    // AES-GCM-256 key is 32 bytes.
    assert_eq!(config.key.as_ref().unwrap().len(), 32);
}

#[test]
fn full_database_config_generates_key_and_identifier() {
    let config = EstateEncryptionConfig::full_database();
    assert_eq!(config.mode, EncryptionMode::FullDatabase);
    assert!(config.key_identifier.is_some());
    assert!(!config.key_identifier.as_ref().unwrap().is_empty());
    assert!(config.key.is_some());
    assert_eq!(config.key.as_ref().unwrap().len(), 32);
}

#[test]
fn encryption_modes_are_distinct() {
    assert_ne!(EncryptionMode::Plaintext, EncryptionMode::RowEncryption);
    assert_ne!(EncryptionMode::RowEncryption, EncryptionMode::FullDatabase);
    assert_ne!(EncryptionMode::Plaintext, EncryptionMode::FullDatabase);
}

// ─────────────────────────────────────────────────────────────────────────────
// Section 2 — NIST AES-GCM-256 Known-Answer Test
//
// Vector: the "feffe9" key/nonce pattern used in both the Swift KAT and
// the NIST GCM reference publications. Proves this Rust implementation
// produces standard AES-GCM-256 output and is cross-decryptable with Swift.
//
// NOTE on the ciphertext layout difference: `aes-gcm` returns ct||tag but
// our wire format is nonce||tag||ct. The KAT tests against `aes-gcm`'s
// raw output (before our rearrangement) to avoid coupling to the wire
// framing and to keep the assertion on the algorithm itself.
// ─────────────────────────────────────────────────────────────────────────────

fn hex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

#[test]
fn nist_aes_gcm_256_known_answer_test() {
    use aes_gcm::{
        aead::{Aead, KeyInit},
        Aes256Gcm, Key, Nonce,
    };

    // NIST "feffe9" reference pattern (same vector as Swift KAT).
    // Key (256-bit / 32 bytes):
    let key_bytes = hex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308");
    // Nonce (96-bit / 12 bytes):
    let nonce_bytes = hex("cafebabefacedbaddecaf888");
    // Plaintext (128-bit / 16 bytes):
    let pt = hex("d9313225f88406e5a55909c5aff5269a");
    // Expected ciphertext (16 bytes, no AAD, from NIST SP 800-38D appendix):
    let expected_ct = hex("522dc1f099567d07f47f37a32a84427d");
    // Expected tag (128-bit GCM auth tag, same as Swift KAT):
    let expected_tag = hex("7ea353da7e9241a1d90d693a4954186b");

    let key = Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);
    let nonce = Nonce::from_slice(&nonce_bytes);

    // `aes-gcm` encrypt returns ct||tag (tag appended last).
    let ct_with_tag = cipher.encrypt(nonce, pt.as_slice()).expect("KAT encrypt");
    let ct_len = ct_with_tag.len().saturating_sub(16);
    let (ct_bytes, tag_bytes) = ct_with_tag.split_at(ct_len);

    assert_eq!(
        ct_bytes, expected_ct.as_slice(),
        "KAT: ciphertext mismatch — aes-gcm crate is not producing standard AES-GCM-256"
    );
    assert_eq!(
        tag_bytes, expected_tag.as_slice(),
        "KAT: tag mismatch — aes-gcm crate is not producing standard AES-GCM-256"
    );

    // Verify decryption round-trips the KAT vector.
    let recovered = cipher
        .decrypt(nonce, ct_with_tag.as_slice())
        .expect("KAT decrypt");
    assert_eq!(recovered, pt, "KAT: decrypt did not yield original plaintext");
}

// ─────────────────────────────────────────────────────────────────────────────
// Section 3 — AesGcmAeadProvider round-trip, key isolation, tamper detection
// ─────────────────────────────────────────────────────────────────────────────

fn fresh_key() -> Vec<u8> {
    use aes_gcm::aead::{KeyInit, OsRng};
    use aes_gcm::Aes256Gcm;
    Aes256Gcm::generate_key(&mut OsRng).to_vec()
}

#[test]
fn aes_gcm_provider_round_trip() {
    let provider = AesGcmAeadProvider;
    let key = fresh_key();
    let pt = b"the secret note";
    let ct = provider.encrypt(pt, &key).expect("encrypt");
    assert_ne!(ct.as_slice(), pt.as_slice());
    let recovered = provider.decrypt(&ct, &key).expect("decrypt");
    assert_eq!(recovered.as_slice(), pt.as_slice());
}

#[test]
fn aes_gcm_provider_wrong_key_fails() {
    let provider = AesGcmAeadProvider;
    let key1 = fresh_key();
    let key2 = fresh_key();
    let ct = provider.encrypt(b"isolate me", &key1).expect("encrypt");
    assert!(
        provider.decrypt(&ct, &key2).is_err(),
        "decrypting with a different key must fail"
    );
}

#[test]
fn aes_gcm_provider_tamper_detection() {
    let provider = AesGcmAeadProvider;
    let key = fresh_key();
    let mut ct = provider.encrypt(b"tamper-evident", &key).expect("encrypt");
    // Flip the last byte of the ciphertext payload.
    let last = ct.len() - 1;
    ct[last] ^= 0xFF;
    assert!(
        provider.decrypt(&ct, &key).is_err(),
        "tampered ciphertext must fail authentication"
    );
}

#[test]
fn aes_gcm_provider_stored_format_overhead() {
    let provider = AesGcmAeadProvider;
    let key = fresh_key();
    let pt = b"format check";
    let ct = provider.encrypt(pt, &key).expect("encrypt");
    // Wire format: [12-byte nonce][16-byte tag][ciphertext] = 28 bytes overhead.
    assert_eq!(ct.len(), pt.len() + 12 + 16);
}

#[test]
fn aes_gcm_provider_each_encrypt_uses_fresh_nonce() {
    // Two encryptions of the same plaintext under the same key must produce
    // different nonces (and therefore different ciphertexts). This is the
    // fundamental AES-GCM safety requirement: nonce reuse is prohibited.
    let provider = AesGcmAeadProvider;
    let key = fresh_key();
    let pt = b"nonce uniqueness";
    let ct1 = provider.encrypt(pt, &key).expect("encrypt 1");
    let ct2 = provider.encrypt(pt, &key).expect("encrypt 2");
    // The first 12 bytes are the nonce — they must differ.
    assert_ne!(
        &ct1[..12], &ct2[..12],
        "two encryptions of the same plaintext must use different nonces"
    );
    // Both must round-trip correctly despite different nonces.
    assert_eq!(provider.decrypt(&ct1, &key).unwrap(), pt.as_slice());
    assert_eq!(provider.decrypt(&ct2, &key).unwrap(), pt.as_slice());
}

// ─────────────────────────────────────────────────────────────────────────────
// Section 4 — AeadProvider swap-proof test
//
// Demonstrates that a future FedRAMP/FIPS-validated AEAD provider is
// drop-in: it implements AeadProvider, is injected at the `provider`
// parameter of RowCrypto::encrypt/decrypt, and the storage call sites
// (SQLite backend) are NOT touched. Mirrors the Swift swap-proof test.
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn aead_provider_swap_proof_round_trip() {
    let provider = XorTestDoubleAeadProvider;
    let key = fresh_key();
    let pt = b"FedRAMP swap-ready";

    // Encrypt through RowCrypto with the test-double provider.
    let ct = RowCrypto::encrypt(pt, &key, &provider).expect("encrypt");
    assert_ne!(ct.as_slice(), pt.as_slice());

    // Decrypt through RowCrypto with the same provider round-trips correctly.
    let recovered = RowCrypto::decrypt(&ct, &key, &provider).expect("decrypt");
    assert_eq!(recovered.as_slice(), pt.as_slice());
}

#[test]
fn aead_provider_swap_ciphertext_is_provider_specific() {
    // Ciphertext from the test-double cannot be decrypted by the default
    // AesGcmAeadProvider (different layout, different algorithm).
    let xor_provider = XorTestDoubleAeadProvider;
    let default_provider = AesGcmAeadProvider;
    let key = fresh_key();
    let ct = RowCrypto::encrypt(b"provider isolation", &key, &xor_provider).expect("encrypt");
    assert!(
        RowCrypto::decrypt(&ct, &key, &default_provider).is_err(),
        "ciphertext from test-double provider must not be decryptable by the default provider"
    );
}
