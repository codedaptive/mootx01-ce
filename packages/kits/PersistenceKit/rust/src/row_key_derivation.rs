// row_key_derivation.rs
//
// Deterministic, content-derived `RowKey` minting for single-column TEXT
// primary keys (gap 5 — LocusKit TEXT-PK federation HLC ordering). Rust
// twin of `RowKeyDerivation.swift`. See that file's header for the full
// gap-5 rationale (defect mechanism, ordering-only impact, scope).
//
// SIBLING TO KEEP IN LOCKSTEP: this is a deliberate duplication (not a
// shared-crate promotion, to avoid a new persistence-kit→substrate-kernel
// crate dependency edge) of `deterministic_uuid`
// (`LocusKit/rust/src/merkle_rollup.rs:308-324`) and its Swift twin
// `Estate.deterministicUUID(from:)` (`LocusKit/MerkleRollup.swift:329-350`),
// which in turn is byte-for-byte the same SHA-256 primitive as
// `substrate_kernel::sha256::hash` (`SubstrateKernel/rust/src/sha256.rs`) /
// `SubstrateKernel.SHA256` (Swift). Any change to the derivation algorithm
// (parse rule, hash function, version/variant bit placement) must be
// applied identically to ALL FOUR copies (this file, `RowKeyDerivation.swift`,
// `merkle_rollup.rs`, `MerkleRollup.swift`) or cross-spoke rowKey agreement
// breaks silently. `row_key_derivation_conformance_tests.rs` cross-checks
// this file's output against a shared vector set that also gates the Swift
// side (`RowKeyDerivationCrossCheckTests.swift`, LocusKit test target).
//
// SCOPE: single-column TEXT primary keys only. Composite (multi-column) PKs
// and `.uuid`-typed PKs are untouched by this file — callers invoke
// `deterministic_row_key` ONLY as the `.text` fallback branch, mirroring
// exactly where the old `Uuid::new_v4()` used to sit in each resolver cell.

use uuid::Uuid;

/// Derive a deterministic `RowKey` (`Uuid`) from a single-column TEXT
/// primary-key VALUE.
///
/// Parses `string_id` as a UUID when possible (today's reality for every
/// LocusKit drawer/kg_fact id); otherwise derives a stable UUID from
/// SHA-256 of the string (UUIDv5-style version/variant bits set on the
/// first 16 hash bytes), so a non-UUID deterministic id (LocusKit's
/// documented, not-yet-exercised capability) ALSO resolves identically on
/// every spoke.
///
/// # Fail-loud on the degenerate case
/// `string_id` must not be empty. An empty single-column TEXT PK value is a
/// data-quality violation — every caller writing a row MUST supply the PK
/// value being written, there is no legitimate "absent PK" case for a
/// declared single-column PK. `debug_assert!` panics in debug/test builds
/// so this is caught immediately; `eprintln!` ensures release builds are
/// never silent. The random-UUID fallback executes ONLY for this
/// already-degenerate input — it is not the ordinary path and does not
/// reintroduce gap 5's defect for any well-formed PK value.
pub fn deterministic_row_key(string_id: &str) -> Uuid {
    if string_id.is_empty() {
        debug_assert!(
            !string_id.is_empty(),
            "row_key_derivation::deterministic_row_key: PK value must not be empty"
        );
        eprintln!(
            "[persistence_kit] deterministic_row_key called with an empty single-column TEXT PK value — this indicates a caller bug, not a legitimate absent-PK case"
        );
        return Uuid::new_v4();
    }
    if let Ok(uuid) = Uuid::parse_str(string_id) {
        return uuid;
    }
    let hash = sha256::hash(string_id.as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&hash[..16]);
    // Set version nibble (byte 6 high nibble) to 5.
    bytes[6] = (bytes[6] & 0x0F) | 0x50;
    // Set variant bits (byte 8 high 2 bits) to 10.
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    Uuid::from_bytes(bytes)
}

/// SHA-256 (duplicated from `substrate_kernel::sha256` — see file header).
///
/// FIPS 180-4 SHA-256. Pure, dependency-free, deterministic. Byte-for-byte
/// duplicate of `substrate_kernel::sha256::hash` — persistence-kit does not
/// depend on the substrate-kernel crate (see file header for why this is a
/// deliberate duplication, not a promotion).
mod sha256 {
    pub fn hash(bytes: &[u8]) -> [u8; 32] {
        const K: [u32; 64] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
            0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
            0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
            0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
            0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
            0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
            0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ];
        let mut h: [u32; 8] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ];
        let bit_len = (bytes.len() as u64) * 8;
        let mut msg = Vec::with_capacity(bytes.len() + 64);
        msg.extend_from_slice(bytes);
        msg.push(0x80);
        while msg.len() % 64 != 56 {
            msg.push(0x00);
        }
        msg.extend_from_slice(&bit_len.to_be_bytes());

        let mut offset = 0;
        while offset < msg.len() {
            let mut w = [0u32; 64];
            for i in 0..16 {
                let j = offset + i * 4;
                w[i] = ((msg[j] as u32) << 24)
                    | ((msg[j + 1] as u32) << 16)
                    | ((msg[j + 2] as u32) << 8)
                    | (msg[j + 3] as u32);
            }
            for i in 16..64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
                w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
            }
            let (mut a, mut b, mut c, mut d) = (h[0], h[1], h[2], h[3]);
            let (mut e, mut f, mut g, mut hh) = (h[4], h[5], h[6], h[7]);
            for i in 0..64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
                let ch = (e & f) ^ ((!e) & g);
                let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
                let mj = (a & b) ^ (a & c) ^ (b & c);
                let t2 = s0.wrapping_add(mj);
                hh = g;
                g = f;
                f = e;
                e = d.wrapping_add(t1);
                d = c;
                c = b;
                b = a;
                a = t1.wrapping_add(t2);
            }
            h[0] = h[0].wrapping_add(a);
            h[1] = h[1].wrapping_add(b);
            h[2] = h[2].wrapping_add(c);
            h[3] = h[3].wrapping_add(d);
            h[4] = h[4].wrapping_add(e);
            h[5] = h[5].wrapping_add(f);
            h[6] = h[6].wrapping_add(g);
            h[7] = h[7].wrapping_add(hh);
            offset += 64;
        }
        let mut out = [0u8; 32];
        for (i, word) in h.iter().enumerate() {
            out[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
        }
        out
    }

    #[inline]
    fn rotr(x: u32, n: u32) -> u32 {
        (x >> n) | (x << (32 - n))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_uuid_shaped_string_directly() {
        let id = Uuid::new_v4();
        assert_eq!(deterministic_row_key(&id.to_string()), id);
    }

    #[test]
    fn derives_stable_uuid_from_non_uuid_string() {
        let a = deterministic_row_key("supersedes:abc:def");
        let b = deterministic_row_key("supersedes:abc:def");
        assert_eq!(a, b, "same input must derive the same UUID every time");
        assert_ne!(a, deterministic_row_key("different-string"));
    }

    // ── Shared vectors — gap 5 conformance (row-values→rowKey minting seam) ──
    //
    // These exact (input, expected output) pairs are asserted identically in
    // Swift's `RowKeyDerivationConformanceTests.swift::sharedVectorWidgetAlpha`
    // / `sharedVectorSupersedesSlug` (PersistenceKitTests target). This IS the
    // conformance gate for the minting seam: before gap 5, no vector anywhere
    // fed raw row values through the resolver in both languages and compared
    // results — every existing wire-format conformance test
    // (FederationJSONConformanceTests.swift) started from a pre-built rowKey.

    #[test]
    fn shared_vector_widget_alpha_matches_swift() {
        assert_eq!(
            deterministic_row_key("widget-alpha").to_string(),
            "5653f1d5-d5de-5b4f-a820-e6ba150a14e2"
        );
    }

    #[test]
    fn shared_vector_supersedes_matches_swift() {
        assert_eq!(
            deterministic_row_key("supersedes:abc:def").to_string(),
            "6ef50667-202d-5ead-b435-0f49a7c45c0c"
        );
    }

    #[test]
    fn sha256_matches_nist_vectors() {
        fn hex(bytes: &[u8]) -> String {
            bytes.iter().map(|b| format!("{:02x}", b)).collect()
        }
        assert_eq!(
            hex(&sha256::hash(b"")),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hex(&sha256::hash(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
