// SimHash.swift
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
// per Hyperplane.sign(over:).
//
// The full row fingerprint is four 64-bit SimHash blocks under
// four distinct hyperplane families (H_0..H_3). Each block hashes
// a different aspect of the row (§ 3.2–§ 3.5).
//
// Cost: unbatched ~500ns per fingerprint on Apple Silicon;
// batched ~200ns/fingerprint amortized when computing across 64+
// rows. Hot path is bandwidth-bound, not compute-bound (§ 17.5).

import Foundation

public enum SimHash {

    /// Computes one 64-bit SimHash block over input vector `v`
    /// using the given hyperplane family. The `family.blockIndex`
    /// is informational; the caller is responsible for routing
    /// the correct family to each block.
    ///
    /// Reference algorithm (cookbook § 3.6):
    ///
    ///   for k in 0..63:
    ///       result_bit_k = 1 if sign(<v, family.planes[k]>) > 0 else 0
    @inlinable
    public static func block(over v: [UInt64],
                             family: HyperplaneFamily) -> UInt64 {
        var result: UInt64 = 0
        for k in 0..<64 {
            if family.planes[k].sign(over: v) {
                result |= (UInt64(1) << k)
            }
        }
        return result
    }

    /// Computes a full 256-bit fingerprint from the four block
    /// input vectors and the manifest's four hyperplane families.
    /// The caller assembles the input vectors per § 3.2–§ 3.5;
    /// this function does the math.
    public static func fingerprint(bitmapInput: [UInt64],
                                    latticeInput: [UInt64],
                                    lineageTemporalInput: [UInt64],
                                    channelSourceInput: [UInt64],
                                    families: [HyperplaneFamily]) -> Fingerprint256 {
        precondition(families.count == 4, "must supply H_0..H_3")
        return Fingerprint256(
            block0: block(over: bitmapInput,         family: families[0]),
            block1: block(over: latticeInput,        family: families[1]),
            block2: block(over: lineageTemporalInput, family: families[2]),
            block3: block(over: channelSourceInput,  family: families[3])
        )
    }

    /// Batched fingerprint computation for N rows. Returns
    /// fingerprints in the same order as inputs.
    ///
    /// The reference implementation here is a straightforward
    /// loop; the production NeuronKit implementation vectorizes
    /// across rows using AMX/AVX-512/NEON popcount kernels
    /// (cookbook § 4.4). The output must be bit-identical to this
    /// loop for every input.
    public static func fingerprintBatch(bitmapInputs: [[UInt64]],
                                         latticeInputs: [[UInt64]],
                                         lineageTemporalInputs: [[UInt64]],
                                         channelSourceInputs: [[UInt64]],
                                         families: [HyperplaneFamily]) -> [Fingerprint256] {
        let n = bitmapInputs.count
        precondition(latticeInputs.count == n &&
                     lineageTemporalInputs.count == n &&
                     channelSourceInputs.count == n,
                     "all input arrays must have equal count")
        var out = [Fingerprint256]()
        out.reserveCapacity(n)
        for i in 0..<n {
            out.append(fingerprint(
                bitmapInput: bitmapInputs[i],
                latticeInput: latticeInputs[i],
                lineageTemporalInput: lineageTemporalInputs[i],
                channelSourceInput: channelSourceInputs[i],
                families: families))
        }
        return out
    }

    /// Convenience: build a `Fingerprint256` from four 64-bit
    /// subhashes (one per block) and the four hyperplane families.
    /// Each subhash is wrapped as a single-word input vector and
    /// fed through the canonical `block(over:family:)`. Used by
    /// ambient feature extractors (cookbook § 3.9) which produce a
    /// per-block subhash digest from the raw stream payload.
    public static func fingerprint(fromSubhashes subhashes: [UInt64],
                                    hyperplanes: [HyperplaneFamily]) -> Fingerprint256 {
        precondition(subhashes.count == 4, "need exactly 4 subhashes")
        precondition(hyperplanes.count == 4, "need exactly 4 hyperplane families")
        return Fingerprint256(
            block0: block(over: [subhashes[0]], family: hyperplanes[0]),
            block1: block(over: [subhashes[1]], family: hyperplanes[1]),
            block2: block(over: [subhashes[2]], family: hyperplanes[2]),
            block3: block(over: [subhashes[3]], family: hyperplanes[3])
        )
    }
}

// MARK: - Input-vector assembly helpers
//
// Per cookbook § 3.2–§ 3.5, each block has a specific input vector
// shape. These helpers build the canonical input vectors from
// row-level fields. They are part of the reference implementation
// because the input encoding is part of the spec; a mismatched
// encoding would silently produce incompatible fingerprints.

public enum SimHashInput {

    /// Block 0 input: concatenation of the three Int64 bitmap
    /// columns (192 bits total). The result is exactly three
    /// 64-bit words in adjective-operational-provenance order.
    public static func bitmap(adjective: UInt64,
                              operational: UInt64,
                              provenance: UInt64) -> [UInt64] {
        return [adjective, operational, provenance]
    }

    /// Block 1 input (cookbook § 3.3): 64 bits assembled as
    ///   bits 0–15    UDC code prefix FNV-1a (16 bits)
    ///   bits 16–31   Q-ID direct FNV-1a (16 bits)
    ///   bits 32–63   Q-ID subclass closure XOR-FNV (32 bits)
    ///
    /// The caller supplies these three pre-computed components.
    public static func lattice(udcPrefixHash: UInt16,
                                qidDirectHash: UInt16,
                                qidClosureHash: UInt32) -> [UInt64] {
        var w: UInt64 = 0
        w |= UInt64(udcPrefixHash)
        w |= UInt64(qidDirectHash) << 16
        w |= UInt64(qidClosureHash) << 32
        return [w]
    }

    /// Block 2 input (cookbook § 3.4): 64 bits assembled as
    ///   bits 0–15    lineage_id FNV-1a (16 bits)
    ///   bits 16–23   capture-week bucket (8 bits)
    ///   bits 24–31   defer-pattern hash (8 bits)
    ///   bits 32–39   completion bucket (8 bits)
    ///   bits 40–63   behavioral-recency vector (24 bits)
    public static func lineageTemporal(lineageHash: UInt16,
                                        captureWeekBucket: UInt8,
                                        deferPatternHash: UInt8,
                                        completionBucket: UInt8,
                                        behavioralRecency: UInt32) -> [UInt64] {
        var w: UInt64 = 0
        w |= UInt64(lineageHash)
        w |= UInt64(captureWeekBucket) << 16
        w |= UInt64(deferPatternHash) << 24
        w |= UInt64(completionBucket) << 32
        w |= (UInt64(behavioralRecency) & 0xFF_FFFF) << 40
        return [w]
    }

    /// Block 3 input (cookbook § 3.5): 64 bits assembled as
    ///   bits 0–5     provenance channel (6 bits)
    ///   bits 6–11    source_type (6 bits)
    ///   bits 12–17   capture_channel (6 bits)
    ///   bits 18–23   sensitivity (6 bits)
    ///   bits 24–31   estate-uuid hash (8 bits)
    ///   bits 32–63   stream-source bitset for AmbientSamples (32
    ///                bits; zero for non-AmbientSample nouns)
    public static func channelSource(channel: UInt8,
                                       sourceType: UInt8,
                                       captureChannel: UInt8,
                                       sensitivity: UInt8,
                                       estateUUIDHash: UInt8,
                                       streamSourceBitset: UInt32) -> [UInt64] {
        var w: UInt64 = 0
        w |= UInt64(channel & 0x3F)
        w |= UInt64(sourceType & 0x3F) << 6
        w |= UInt64(captureChannel & 0x3F) << 12
        w |= UInt64(sensitivity & 0x3F) << 18
        w |= UInt64(estateUUIDHash) << 24
        w |= UInt64(streamSourceBitset) << 32
        return [w]
    }
}

// MARK: - Conformance notes
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
