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

// ─────────────────────────────────────────────────────────────────────────────
// Distilled-column seam coverage (SPEC_DISTILLATION_STORAGE §2).
// The `distilled` column is content-derived text and carries the same
// row-level protection class as `content`. Mirrors the Swift
// DistilledColumnCryptoTests seam cases (twin-parity gate).
// ─────────────────────────────────────────────────────────────────────────────

mod distilled_seam {
    use super::*;
    use crate::sqlite::{
        assert_content_key_id_invariant, decrypted_for_read, encrypted_for_write,
    };
    use crate::types::TypedValue;
    use std::collections::BTreeMap;

    #[test]
    fn seals_distilled_alongside_content_and_stamps_key_id() {
        let config = EstateEncryptionConfig::row_encryption();
        let mut values = BTreeMap::new();
        values.insert("id".to_string(), TypedValue::Text("d1".to_string()));
        values.insert("content".to_string(), TypedValue::Text("original body".to_string()));
        values.insert("distilled".to_string(), TypedValue::Text("dense body".to_string()));
        let sealed = encrypted_for_write(values, "drawers", &config, &AesGcmAeadProvider).unwrap();
        assert!(matches!(sealed.get("content"), Some(TypedValue::Blob(_))));
        assert!(matches!(sealed.get("distilled"), Some(TypedValue::Blob(_))));
        assert_eq!(
            sealed.get("keyID"),
            Some(&TypedValue::Text(config.key_identifier.clone().unwrap()))
        );
    }

    #[test]
    fn seals_representation_only_value_map() {
        // A distillation write is an UPDATE carrying only representation
        // columns — the seam must still run for it.
        let config = EstateEncryptionConfig::row_encryption();
        let mut values = BTreeMap::new();
        values.insert("distilled".to_string(), TypedValue::Text("dense body".to_string()));
        let sealed = encrypted_for_write(values, "drawers", &config, &AesGcmAeadProvider).unwrap();
        assert!(matches!(sealed.get("distilled"), Some(TypedValue::Blob(_))));
        assert_eq!(
            sealed.get("keyID"),
            Some(&TypedValue::Text(config.key_identifier.clone().unwrap()))
        );
    }

    #[test]
    fn opens_sealed_distilled_back_to_text() {
        let config = EstateEncryptionConfig::row_encryption();
        let mut values = BTreeMap::new();
        values.insert("content".to_string(), TypedValue::Text("body".to_string()));
        values.insert("distilled".to_string(), TypedValue::Text("dense body".to_string()));
        let sealed = encrypted_for_write(values, "drawers", &config, &AesGcmAeadProvider).unwrap();
        let opened = decrypted_for_read(sealed, "drawers", &config, &AesGcmAeadProvider).unwrap();
        assert_eq!(opened.get("content"), Some(&TypedValue::Text("body".to_string())));
        assert_eq!(
            opened.get("distilled"),
            Some(&TypedValue::Text("dense body".to_string()))
        );
    }

    #[test]
    fn plaintext_mode_passes_distilled_through_unchanged() {
        let config = EstateEncryptionConfig::plaintext();
        let mut values = BTreeMap::new();
        values.insert("distilled".to_string(), TypedValue::Text("dense body".to_string()));
        let out = encrypted_for_write(values, "drawers", &config, &AesGcmAeadProvider).unwrap();
        assert_eq!(
            out.get("distilled"),
            Some(&TypedValue::Text("dense body".to_string()))
        );
        assert!(out.get("keyID").is_none());
    }

    #[test]
    fn invariant_refuses_plaintext_distilled_without_key_id() {
        let config = EstateEncryptionConfig::row_encryption();
        let mut values = BTreeMap::new();
        values.insert("id".to_string(), TypedValue::Text("d1".to_string()));
        values.insert(
            "distilled".to_string(),
            TypedValue::Text("leaked dense body".to_string()),
        );
        assert!(assert_content_key_id_invariant(&values, "drawers", &config).is_err());
        // NULL distilled (the cleared-representation write) is exempt —
        // clearing carries nothing to encrypt.
        let mut cleared = BTreeMap::new();
        cleared.insert("id".to_string(), TypedValue::Text("d1".to_string()));
        cleared.insert("distilled".to_string(), TypedValue::Null);
        assert!(assert_content_key_id_invariant(&cleared, "drawers", &config).is_ok());
        // Empty-string protected text is the erasure-scrub exemption (#76).
        let mut scrub = BTreeMap::new();
        scrub.insert("content".to_string(), TypedValue::Text(String::new()));
        assert!(assert_content_key_id_invariant(&scrub, "drawers", &config).is_ok());
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Table-aware protection (MXE-RD).
//
// `subject` is content-derived text on the drawers table and carries the
// same protection class as `content`. It is ALSO the name of an unrelated
// column on `kg_facts` — the subject term of an S-P-O triple, on a table
// with no `keyID` column — so these cases pin both halves: drawers.subject
// is sealed, kg_facts.subject is byte-identical to a pre-seam write. A seam
// intercepting by column name alone fails the kg_facts cases.
//
// Mirrors the Swift DistilledColumnCryptoTests table-aware section
// (twin-parity gate).
// ─────────────────────────────────────────────────────────────────────────────

mod table_aware_seam {
    use super::*;
    use crate::sqlite::{
        assert_content_key_id_invariant, decrypted_for_read, encrypted_for_write,
    };
    use crate::types::TypedValue;
    use std::collections::BTreeMap;

    fn kg_fact_row() -> BTreeMap<String, TypedValue> {
        let mut values = BTreeMap::new();
        values.insert("id".to_string(), TypedValue::Text("f1".to_string()));
        values.insert(
            "subject".to_string(),
            TypedValue::Text("Ada Lovelace".to_string()),
        );
        values.insert(
            "predicate".to_string(),
            TypedValue::Text("worked_on".to_string()),
        );
        values.insert(
            "object".to_string(),
            TypedValue::Text("Analytical Engine".to_string()),
        );
        values
    }

    /// The regression this rescope exists for. A by-name seam would seal
    /// `kg_facts.subject` and stamp a keyID, producing an INSERT that names
    /// a column the table does not have.
    #[test]
    fn kg_facts_subject_is_never_sealed_and_never_gains_a_key_id() {
        let config = EstateEncryptionConfig::row_encryption();
        let fact = kg_fact_row();
        let out =
            encrypted_for_write(fact.clone(), "kg_facts", &config, &AesGcmAeadProvider).unwrap();
        // Byte-identical to the input: no sealing, no keyID stamp.
        assert_eq!(out, fact);
        assert!(out.get("keyID").is_none());
        // A read of the same row is equally untouched.
        let read =
            decrypted_for_read(fact.clone(), "kg_facts", &config, &AesGcmAeadProvider).unwrap();
        assert_eq!(read, fact);
    }

    /// Before the table filter the guard would have rejected every KG fact
    /// write on an encrypting estate: `subject` carried plaintext and the
    /// row has no keyID to satisfy it.
    #[test]
    fn invariant_guard_does_not_fire_for_kg_facts() {
        let config = EstateEncryptionConfig::row_encryption();
        assert!(assert_content_key_id_invariant(&kg_fact_row(), "kg_facts", &config).is_ok());
    }

    #[test]
    fn seals_subject_alongside_content_and_distilled() {
        let config = EstateEncryptionConfig::row_encryption();
        let mut values = BTreeMap::new();
        values.insert("id".to_string(), TypedValue::Text("d1".to_string()));
        values.insert(
            "content".to_string(),
            TypedValue::Text("original body".to_string()),
        );
        values.insert(
            "distilled".to_string(),
            TypedValue::Text("dense body".to_string()),
        );
        values.insert(
            "subject".to_string(),
            TypedValue::Text("a summary of the body".to_string()),
        );
        let sealed = encrypted_for_write(values, "drawers", &config, &AesGcmAeadProvider).unwrap();
        for column in ["content", "distilled", "subject"] {
            assert!(
                matches!(sealed.get(column), Some(TypedValue::Blob(_))),
                "{column} was not sealed"
            );
        }
        assert_eq!(
            sealed.get("keyID"),
            Some(&TypedValue::Text(config.key_identifier.clone().unwrap()))
        );
    }

    /// Provenance columns describe how a subject was produced, not what it
    /// says — the recall path reads them without holding a key.
    #[test]
    fn subject_provenance_columns_stay_plaintext() {
        let config = EstateEncryptionConfig::row_encryption();
        let mut values = BTreeMap::new();
        values.insert("content".to_string(), TypedValue::Text("body".to_string()));
        values.insert(
            "subject".to_string(),
            TypedValue::Text("a summary".to_string()),
        );
        values.insert(
            "subject_pipeline_version".to_string(),
            TypedValue::Text("2.1.0".to_string()),
        );
        values.insert(
            "subject_at".to_string(),
            TypedValue::Text("2026-08-03T10:00:00Z".to_string()),
        );
        let sealed = encrypted_for_write(values, "drawers", &config, &AesGcmAeadProvider).unwrap();
        assert_eq!(
            sealed.get("subject_pipeline_version"),
            Some(&TypedValue::Text("2.1.0".to_string()))
        );
        assert_eq!(
            sealed.get("subject_at"),
            Some(&TypedValue::Text("2026-08-03T10:00:00Z".to_string()))
        );
        assert!(matches!(sealed.get("subject"), Some(TypedValue::Blob(_))));
    }

    #[test]
    fn opens_sealed_subject_back_to_text() {
        let config = EstateEncryptionConfig::row_encryption();
        let mut values = BTreeMap::new();
        values.insert(
            "subject".to_string(),
            TypedValue::Text("a summary of the body".to_string()),
        );
        let sealed = encrypted_for_write(values, "drawers", &config, &AesGcmAeadProvider).unwrap();
        assert!(matches!(sealed.get("subject"), Some(TypedValue::Blob(_))));
        let opened = decrypted_for_read(sealed, "drawers", &config, &AesGcmAeadProvider).unwrap();
        assert_eq!(
            opened.get("subject"),
            Some(&TypedValue::Text("a summary of the body".to_string()))
        );
    }

    #[test]
    fn invariant_guard_refuses_plaintext_subject_on_drawers() {
        let config = EstateEncryptionConfig::row_encryption();
        let mut values = BTreeMap::new();
        values.insert("id".to_string(), TypedValue::Text("d1".to_string()));
        values.insert(
            "subject".to_string(),
            TypedValue::Text("leaked summary".to_string()),
        );
        assert!(assert_content_key_id_invariant(&values, "drawers", &config).is_err());
        // Empty-string subject is the erasure exemption, same as content.
        let mut scrub = BTreeMap::new();
        scrub.insert("id".to_string(), TypedValue::Text("d1".to_string()));
        scrub.insert("subject".to_string(), TypedValue::Text(String::new()));
        assert!(assert_content_key_id_invariant(&scrub, "drawers", &config).is_ok());
    }

    /// Plaintext and FullDatabase never reach the per-row seam, so subject
    /// passes through in both directions exactly as it did before the
    /// column joined the protected set.
    #[test]
    fn plaintext_and_full_database_pass_subject_through_untouched() {
        let mut values = BTreeMap::new();
        values.insert(
            "subject".to_string(),
            TypedValue::Text("a summary".to_string()),
        );
        for config in [
            EstateEncryptionConfig::plaintext(),
            EstateEncryptionConfig::full_database(),
        ] {
            let out =
                encrypted_for_write(values.clone(), "drawers", &config, &AesGcmAeadProvider)
                    .unwrap();
            assert_eq!(out, values);
            assert!(out.get("keyID").is_none());
            let read =
                decrypted_for_read(values.clone(), "drawers", &config, &AesGcmAeadProvider)
                    .unwrap();
            assert_eq!(read, values);
        }
    }

    /// A plaintext subject already on disk (written before the column joined
    /// the protected set) reads back untouched alongside sealed columns —
    /// the non-blob guard is what makes the residual-exposure case readable
    /// rather than broken.
    #[test]
    fn pre_existing_plaintext_subject_still_reads() {
        let config = EstateEncryptionConfig::row_encryption();
        let mut values = BTreeMap::new();
        values.insert("content".to_string(), TypedValue::Text("body".to_string()));
        let mut sealed =
            encrypted_for_write(values, "drawers", &config, &AesGcmAeadProvider).unwrap();
        // Simulate the older row shape: sealed content, plaintext subject.
        sealed.insert(
            "subject".to_string(),
            TypedValue::Text("an old plaintext summary".to_string()),
        );
        let opened = decrypted_for_read(sealed, "drawers", &config, &AesGcmAeadProvider).unwrap();
        assert_eq!(
            opened.get("content"),
            Some(&TypedValue::Text("body".to_string()))
        );
        assert_eq!(
            opened.get("subject"),
            Some(&TypedValue::Text("an old plaintext summary".to_string()))
        );
    }
}
