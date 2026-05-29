// simhash.rs
//
// SimHash construction per cookbook § 3.6.
//
// SimHash is the Locality-Sensitive Hashing variant that produces
// outputs where similar inputs share many bits (the opposite of
// cryptographic hashes). For binary inputs with ±1-valued
// hyperplanes, each output bit is:
//
//   output_bit_k = sign(<v, h_k>)
//
// reduced to popcount comparisons on bit-vector representations
// per Hyperplane::sign.
//
// The full row fingerprint is four 64-bit SimHash blocks under
// four distinct hyperplane families (H_0..H_3). Each block hashes
// a different aspect of the row (§ 3.2..§ 3.5).
//
// Cost: unbatched ~500ns per fingerprint on Apple Silicon;
// batched ~200ns/fingerprint amortized when computing across 64+
// rows. Hot path is bandwidth-bound, not compute-bound (§ 17.5).

use crate::fingerprint256::Fingerprint256;
use crate::hyperplane::HyperplaneFamily;

/// Computes one 64-bit SimHash block over input vector `v` using
/// the given hyperplane family. The `family.block_index` is
/// informational; the caller is responsible for routing the
/// correct family to each block.
///
/// Reference algorithm (cookbook § 3.6):
///
/// ```text
///   for k in 0..64:
///       result_bit_k = 1 if sign(<v, family.planes[k]>) > 0 else 0
/// ```
#[inline]
pub fn block(v: &[u64], family: &HyperplaneFamily) -> u64 {
    let mut result: u64 = 0;
    for k in 0..64 {
        if family.planes[k].sign(v) {
            result |= 1u64 << k;
        }
    }
    result
}

/// Convenience: build a Fingerprint256 from four 64-bit
/// subhashes (one per block) and the four hyperplane families.
/// Each subhash is wrapped as a single-word input vector and
/// fed through the canonical `block` function. Used by ambient
/// feature extractors (cookbook § 3.9) which produce a per-
/// block subhash digest from the raw stream payload.
pub fn fingerprint_from_subhashes(
    subhashes: &[u64; 4],
    families: &[HyperplaneFamily; 4],
) -> Fingerprint256 {
    Fingerprint256::new(
        block(&[subhashes[0]], &families[0]),
        block(&[subhashes[1]], &families[1]),
        block(&[subhashes[2]], &families[2]),
        block(&[subhashes[3]], &families[3]),
    )
}

/// Computes a full 256-bit fingerprint from the four block input
/// vectors and the manifest's four hyperplane families. The
/// caller assembles the input vectors per § 3.2..§ 3.5; this
/// function does the math.
pub fn fingerprint(
    bitmap_input: &[u64],
    lattice_input: &[u64],
    lineage_temporal_input: &[u64],
    channel_source_input: &[u64],
    families: &[HyperplaneFamily; 4],
) -> Fingerprint256 {
    Fingerprint256::new(
        block(bitmap_input, &families[0]),
        block(lattice_input, &families[1]),
        block(lineage_temporal_input, &families[2]),
        block(channel_source_input, &families[3]),
    )
}

/// Batched fingerprint computation for N rows. Returns
/// fingerprints in the same order as inputs.
///
/// The reference implementation here is a straightforward loop;
/// the production NeuronKit implementation vectorizes across rows
/// using AMX/AVX-512/NEON popcount kernels (cookbook § 4.4). The
/// output must be bit-identical to this loop for every input.
pub fn fingerprint_batch(
    bitmap_inputs: &[Vec<u64>],
    lattice_inputs: &[Vec<u64>],
    lineage_temporal_inputs: &[Vec<u64>],
    channel_source_inputs: &[Vec<u64>],
    families: &[HyperplaneFamily; 4],
) -> Vec<Fingerprint256> {
    let n = bitmap_inputs.len();
    assert_eq!(lattice_inputs.len(), n);
    assert_eq!(lineage_temporal_inputs.len(), n);
    assert_eq!(channel_source_inputs.len(), n);
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        out.push(fingerprint(
            &bitmap_inputs[i],
            &lattice_inputs[i],
            &lineage_temporal_inputs[i],
            &channel_source_inputs[i],
            families,
        ));
    }
    out
}

// Input-vector assembly helpers
//
// Per cookbook § 3.2..§ 3.5, each block has a specific input vector
// shape. These helpers build the canonical input vectors from
// row-level fields. They are part of the reference implementation
// because the input encoding is part of the spec; a mismatched
// encoding would silently produce incompatible fingerprints.

/// Block 0 input: concatenation of the three Int64 bitmap columns
/// (192 bits total). Result is three u64 words in
/// adjective-operational-provenance order.
pub fn bitmap_input(adjective: u64, operational: u64, provenance: u64) -> Vec<u64> {
    vec![adjective, operational, provenance]
}

/// Block 1 input (cookbook § 3.3): 64 bits assembled as
///   bits 0..16   UDC code prefix FNV-1a (16 bits)
///   bits 16..32  Q-ID direct FNV-1a (16 bits)
///   bits 32..64  Q-ID subclass closure XOR-FNV (32 bits)
pub fn lattice_input(udc_prefix_hash: u16, qid_direct_hash: u16,
                     qid_closure_hash: u32) -> Vec<u64> {
    let mut w: u64 = 0;
    w |= udc_prefix_hash as u64;
    w |= (qid_direct_hash as u64) << 16;
    w |= (qid_closure_hash as u64) << 32;
    vec![w]
}

/// Block 2 input (cookbook § 3.4): 64 bits assembled as
///   bits 0..16   lineage_id FNV-1a (16 bits)
///   bits 16..24  capture-week bucket (8 bits)
///   bits 24..32  defer-pattern hash (8 bits)
///   bits 32..40  completion bucket (8 bits)
///   bits 40..64  behavioral-recency vector (24 bits)
pub fn lineage_temporal_input(
    lineage_hash: u16,
    capture_week_bucket: u8,
    defer_pattern_hash: u8,
    completion_bucket: u8,
    behavioral_recency: u32,
) -> Vec<u64> {
    let mut w: u64 = 0;
    w |= lineage_hash as u64;
    w |= (capture_week_bucket as u64) << 16;
    w |= (defer_pattern_hash as u64) << 24;
    w |= (completion_bucket as u64) << 32;
    w |= ((behavioral_recency as u64) & 0xFF_FFFF) << 40;
    vec![w]
}

/// Block 3 input (cookbook § 3.5): 64 bits assembled as
///   bits 0..6    provenance channel (6 bits)
///   bits 6..12   source_type (6 bits)
///   bits 12..18  capture_channel (6 bits)
///   bits 18..24  sensitivity (6 bits)
///   bits 24..32  estate-uuid hash (8 bits)
///   bits 32..64  stream-source bitset for AmbientSamples (32 bits;
///                zero for non-AmbientSample nouns)
pub fn channel_source_input(
    channel: u8,
    source_type: u8,
    capture_channel: u8,
    sensitivity: u8,
    estate_uuid_hash: u8,
    stream_source_bitset: u32,
) -> Vec<u64> {
    let mut w: u64 = 0;
    w |= (channel & 0x3F) as u64;
    w |= ((source_type & 0x3F) as u64) << 6;
    w |= ((capture_channel & 0x3F) as u64) << 12;
    w |= ((sensitivity & 0x3F) as u64) << 18;
    w |= (estate_uuid_hash as u64) << 24;
    w |= (stream_source_bitset as u64) << 32;
    vec![w]
}

// Conformance notes
//
// 1. Determinism: SimHash output depends only on input vector +
//    hyperplane family. The family is manifest-immutable. Two
//    rows with identical bitmaps, lattice anchors, lineages, and
//    provenance produce bit-identical fingerprints, even across
//    independently-started replicas of the same estate.
//
// 2. Cross-noun compatibility (I-17): blocks with missing fields
//    (e.g. AmbientSample has no lineage_id) use a deterministic
//    null hash (zero is acceptable; the cookbook leaves the exact
//    null value as an implementation choice as long as it is
//    deterministic and stable).
//
// 3. Federation: pairing scopes (household, fleet, company,
//    industry, MSP) carry their own HyperplaneFamily under
//    `shared_hyperplane_seeds.<scope>`. SimHash with that family
//    produces fingerprints compatible across paired estates.
//    Pairing algebra (cookbook § 12.1) — reflexive, symmetric,
//    NOT transitive — is enforced by the federation layer; the
//    SimHash math is the same regardless of scope.

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hyperplane::HyperplaneFamily;

    #[test]
    fn determinism() {
        let seed = [0x5Au8; 32];
        let h0 = HyperplaneFamily::generate(&seed, 0, 192, 1.0);
        let v: Vec<u64> = vec![0x12345, 0x67890, 0xABCDEF];
        let a = block(&v, &h0);
        let b = block(&v, &h0);
        assert_eq!(a, b);
    }

    #[test]
    fn block3_layout_roundtrip() {
        let v = channel_source_input(5, 2, 1, 32, 0xAB, 0x12345678);
        // bits 0..6 = 5
        assert_eq!(v[0] & 0x3F, 5);
        // bits 6..12 = 2
        assert_eq!((v[0] >> 6) & 0x3F, 2);
        // bits 18..24 = 32
        assert_eq!((v[0] >> 18) & 0x3F, 32);
    }
}
