// DrawerFingerprint.swift
//
// Derives a drawer's 256-bit structural fingerprint, the estate's
// coordinate system for structural similarity (cookbook section 3).
// This is the LocusKit glue over SubstrateLib's SimHash machinery, and
// it is what un-defers LOCI_V035_18: fingerprint pruning (spec section
// 7.9.4 step 1) was carved out "until fingerprints exist," and this is
// where they begin to exist.
//
// A fingerprint is four 64-bit SimHash blocks, each a projection of one
// facet of the row through a hyperplane family:
//
//   block 0  bitmap-LSH      the 192-bit adjective/operational/
//                            provenance bitmap triple
//   block 1  lattice-LSH     UDC prefix, Q-ID direct, Q-ID closure
//   block 2  lineage+temporal lineage hash, capture week, and the
//                            posture fields
//   block 3  channel+source  channel, source type, capture channel,
//                            sensitivity, estate hash
//
// The families come from EstateFingerprintFamilies, which derives four
// independent seeds from the estate UUID per
// DECISION_FINGERPRINT_SEEDS_DERIVED_2026-05-20. Determinism is the
// contract: two rows with identical fields, even on independently
// started replicas of one estate, produce bit-identical fingerprints.
//
// Cross-noun compatibility (invariant I-17): a drawer does not carry
// the AmbientSample-specific facets (defer pattern, completion bucket,
// behavioral recency, stream-source bitset) nor, until the Q-ID closure
// cache lands, the taxonomic closure. Those sub-fields take the
// deterministic null value zero, which keeps Hamming distance
// well-defined across noun types.

import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
import SubstrateTypes

// MARK: - FNV-1a (consumed from SubstrateLib)
//
// FNV-1a is a SubstrateLib public atomic (I-25). DrawerFingerprint
// consumes `FNV.hash64` and `FNV.hash16` by name; the kit-local
// `fnv1a64` / `fnv1a16` helpers that used to live here were retired
// in F5b along with the substrate's internal copy in FeatureExtractors.

// MARK: - Estate fingerprint families

/// The four hyperplane families for one estate, derived from its UUID.
/// Built once and held; generation is a one-time per-estate cost.
///
/// The families come from the canonical `HyperplaneFamily.blockFamilies`
/// routine, the same one the shared pairing families use, so the local
/// and shared constructions cannot drift: per-block diversified seeds
/// and the canonical widths [192, 64, 64, 64]. Only the base seed
/// differs, the estate UUID here versus the pairing nonce there.
public struct EstateFingerprintFamilies: Sendable {

    public let families: [HyperplaneFamily]
    public let estateUUID: String

    public init(estateUUID: String) {
        self.estateUUID = estateUUID
        self.families = HyperplaneFamily.blockFamilies(
            baseSeed: EstateFingerprintFamilies.baseSeed(estateUUID: estateUUID))
    }

    /// Derive the 32-byte base seed from the estate UUID. The same UUID
    /// always gives the same base, and `blockFamilies` diversifies it
    /// per block, so two replicas of an estate agree and the four
    /// families stay independent.
    static func baseSeed(estateUUID: String) -> [UInt8] {
        HyperplaneFamily.expandSeed64(FNV.hash64("GLfp-base:" + estateUUID))
    }

    /// The estate-UUID hash byte that block 3 carries (cookbook 3.5).
    var estateUUIDByte: UInt8 { UInt8(truncatingIfNeeded: FNV.hash64(estateUUID)) }
}

// MARK: - Drawer derivation

/// Reference epoch for the capture-week bucket: 2020-01-01 00:00 UTC.
private let captureWeekEpoch: TimeInterval = 1_577_836_800

extension EstateFingerprintFamilies {

    /// Derive the structural fingerprint of a drawer.
    public func fingerprint(of drawer: Drawer) -> Fingerprint256 {
        let bitmapInput = SimHashInput.bitmap(
            adjective:   UInt64(bitPattern: drawer.adjectiveBitmap),
            operational: UInt64(bitPattern: drawer.operationalBitmap),
            provenance:  UInt64(bitPattern: drawer.provenance))

        let latticeInput = SimHashInput.lattice(
            udcPrefixHash: Self.udcPrefixHash(drawer.udcCode),
            qidDirectHash: FNV.hash16(drawer.wikidataQID ?? ""),
            qidClosureHash: 0)        // Q-ID closure cache deferred; null (I-17)

        let lineageTemporalInput = SimHashInput.lineageTemporal(
            lineageHash: FNV.hash16(drawer.lineageID.uuidString),
            captureWeekBucket: Self.captureWeekBucket(drawer.eventTime),
            deferPatternHash: 0,      // drawers carry no defer pattern; null (I-17)
            completionBucket: 0,      // drawers carry no completion gradient; null (I-17)
            behavioralRecency: 0)     // drawers carry no recency vector; null (I-17)

        let channelSourceInput = SimHashInput.channelSource(
            channel:        UInt8(truncatingIfNeeded: drawer.channel.rawValue),
            sourceType:     UInt8(truncatingIfNeeded: drawer.sourceType.rawValue),
            captureChannel: UInt8(truncatingIfNeeded: drawer.captureChannel.rawValue),
            sensitivity:    UInt8(truncatingIfNeeded: drawer.sensitivity.rawValue),
            estateUUIDHash: estateUUIDByte,
            streamSourceBitset: 0)    // non-AmbientSample noun; null (I-17)

        return SimHash.fingerprint(
            bitmapInput: bitmapInput,
            latticeInput: latticeInput,
            lineageTemporalInput: lineageTemporalInput,
            channelSourceInput: channelSourceInput,
            families: families)
    }

    /// The capture-week bucket: whole weeks from the 2020 epoch to the
    /// event time, modulo 256. Times before the epoch bucket at zero.
    ///
    /// Keys off `eventTime`, not `filedAt` (ING-01). For bulk historical
    /// ingest the two differ: `filedAt` is the ingest instant, `eventTime`
    /// is the original authorship date, and the temporal coordinate must
    /// reflect when the content happened in the world — so a four-year-old
    /// document imported today buckets to its real week, not "today".
    static func captureWeekBucket(_ eventTime: Date) -> UInt8 {
        let seconds = eventTime.timeIntervalSince1970 - captureWeekEpoch
        guard seconds > 0 else { return 0 }
        let weeks = Int(seconds / (7 * 86_400))
        return UInt8(truncatingIfNeeded: weeks % 256)
    }

    /// The UDC prefix hash: FNV-1a (16 bits) of the first four digits of
    /// the UDC code, with non-digit separators stripped. "613.71" keys
    /// on "6137".
    static func udcPrefixHash(_ udcCode: String) -> UInt16 {
        let digits = String(udcCode.filter { $0.isNumber }.prefix(4))
        return FNV.hash16(digits)
    }
}
