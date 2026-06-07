//! Drawer structural fingerprint derivation. Ports
//! `DrawerFingerprint.swift`.
//!
//! Derives a drawer's 256-bit structural fingerprint, the estate's
//! coordinate system for structural similarity (cookbook § 3). LocusKit
//! glue over the substrate-lib SimHash machinery.
//!
//! A fingerprint is four 64-bit SimHash blocks, each a projection of
//! one facet of the row through a hyperplane family:
//!
//! - block 0: bitmap-LSH — the 192-bit adjective/operational/provenance
//!   bitmap triple
//! - block 1: lattice-LSH — UDC prefix, Q-ID direct, Q-ID closure
//! - block 2: lineage+temporal — lineage hash, capture week, posture
//!   fields
//! - block 3: channel+source — channel, source type, capture channel,
//!   sensitivity, estate hash
//!
//! The families come from `EstateFingerprintFamilies`, which derives
//! four independent seeds from the estate UUID per
//! `DECISION_FINGERPRINT_SEEDS_DERIVED_2026-05-20`. Determinism is the
//! contract: two rows with identical fields, even on independently
//! started replicas of one estate, produce bit-identical fingerprints.
//!
//! Cross-noun compatibility (invariant I-17): a drawer does not carry
//! the AmbientSample-specific facets (defer pattern, completion bucket,
//! behavioral recency, stream-source bitset) nor, until the Q-ID
//! closure cache lands, the taxonomic closure. Those sub-fields take
//! the deterministic null value zero, which keeps Hamming distance
//! well-defined across noun types.

use crate::drawer::Drawer;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hyperplane::HyperplaneFamily;
use substrate_types::simhash;

// FNV-1a (consumed from SubstrateLib)
//
// FNV-1a is a SubstrateLib public atomic (I-25). DrawerFingerprint
// consumes `substrate_types::fnv::hash64` and `substrate_types::fnv::hash16`
// by name; the kit-local `fnv1a64` / `fnv1a16` helpers that used to
// live here were retired in F5b along with the substrate's internal
// copy in feature_extractors.

// MARK: - Estate fingerprint families

/// The four hyperplane families for one estate, derived from its UUID.
/// Built once and held; generation is a one-time per-estate cost.
///
/// The families come from `HyperplaneFamily::block_families`, the same
/// canonical routine the shared pairing families use, so the local and
/// shared constructions cannot drift: per-block diversified seeds and
/// the canonical widths `[192, 64, 64, 64]`. Only the base seed differs
/// — the estate UUID here versus the pairing nonce there.
///
/// Density defaults to `1.0` (the Swift default for
/// `blockFamilies(baseSeed:density:)`). The Rust signature has no
/// default; the constructor passes `1.0` explicitly so cross-leg
/// fingerprints match.
pub struct EstateFingerprintFamilies {
    pub families: [HyperplaneFamily; 4],
    pub estate_uuid: String,
}

impl EstateFingerprintFamilies {
    /// Build the four families for the named estate.
    pub fn new(estate_uuid: impl Into<String>) -> Self {
        let estate_uuid: String = estate_uuid.into();
        let base = Self::base_seed(&estate_uuid);
        // Density 1.0 matches the Swift default. Diverging here would
        // silently produce incompatible fingerprints across the two legs.
        let families = HyperplaneFamily::block_families(&base, 1.0);
        EstateFingerprintFamilies {
            families,
            estate_uuid,
        }
    }

    /// Derive the 32-byte base seed from the estate UUID. The same UUID
    /// always gives the same base, and `block_families` diversifies it
    /// per block, so two replicas of an estate agree and the four
    /// families stay independent. Mirrors the Swift `baseSeed`.
    pub fn base_seed(estate_uuid: &str) -> [u8; 32] {
        HyperplaneFamily::expand_seed_64(substrate_types::fnv::hash64(&format!(
            "GLfp-base:{}",
            estate_uuid
        )))
    }

    /// The estate-UUID hash byte that block 3 carries (cookbook § 3.5).
    pub fn estate_uuid_byte(&self) -> u8 {
        substrate_types::fnv::hash64(&self.estate_uuid) as u8
    }

    // MARK: - Drawer derivation

    /// Derive the structural fingerprint of a drawer.
    pub fn fingerprint(&self, drawer: &Drawer) -> Fingerprint256 {
        let bitmap_input = simhash::bitmap_input(
            drawer.adjective_bitmap as u64,
            drawer.operational_bitmap as u64,
            drawer.provenance as u64,
        );

        let lattice_input = simhash::lattice_input(
            udc_prefix_hash(&drawer.udc_code),
            substrate_types::fnv::hash16(drawer.wikidata_qid.as_deref().unwrap_or("")),
            // Q-ID closure cache deferred; null per I-17 (cross-noun).
            0,
        );

        let lineage_temporal_input = simhash::lineage_temporal_input(
            substrate_types::fnv::hash16(&drawer.lineage_id.to_string()),
            // Fingerprint keys off event_time (ING-01): bulk historical ingest
            // must bucket to the original authorship week, not the ingest instant.
            // event_time is always non-optional (resolved eagerly at construction/decode).
            capture_week_bucket(drawer.event_time),
            // Drawers carry no defer pattern; null per I-17.
            0,
            // Drawers carry no completion gradient; null per I-17.
            0,
            // Drawers carry no recency vector; null per I-17.
            0,
        );

        let channel_source_input = simhash::channel_source_input(
            drawer.channel().raw_value() as u8,
            drawer.source_type().raw_value() as u8,
            // Block 3's `capture_channel` slot per cookbook §3.5 is the
            // OPERATIONAL `CaptureChannel` axis (typed / voiced / ocr /
            // imported / sensor / actuator), distinct from the provenance
            // `Channel` axis already supplied above. Mirrors Swift
            // DrawerFingerprint.swift.
            drawer.capture_channel().raw_value() as u8,
            drawer.sensitivity().raw_value() as u8,
            self.estate_uuid_byte(),
            // Non-AmbientSample noun; null per I-17.
            0,
        );

        simhash::fingerprint(
            &bitmap_input,
            &lattice_input,
            &lineage_temporal_input,
            &channel_source_input,
            &self.families,
        )
    }
}

// MARK: - Free helpers

/// Reference epoch for the capture-week bucket: 2020-01-01 00:00 UTC
/// (epoch seconds). Matches the Swift `captureWeekEpoch` constant
/// exactly.
const CAPTURE_WEEK_EPOCH_SECONDS: i64 = 1_577_836_800;

/// The capture-week bucket: whole weeks from the 2020 epoch to the
/// event time, modulo 256. Times before the epoch bucket at zero.
///
/// `event_time` is epoch seconds (the Rust port's timestamp shape). The
/// Swift port passes a `Date` whose `timeIntervalSince1970` is a
/// `Double` of seconds — wire-identical for any time the substrate
/// stores. Receives `drawer.event_time` (ING-01 two-clock ingest) so
/// bulk historical content buckets to the authorship week, not the
/// ingest instant.
pub fn capture_week_bucket(event_time: i64) -> u8 {
    let seconds = event_time - CAPTURE_WEEK_EPOCH_SECONDS;
    if seconds <= 0 {
        return 0;
    }
    let weeks = seconds / (7 * 86_400);
    (weeks % 256) as u8
}

/// The UDC prefix hash: FNV-1a (16 bits) of the first four digits of
/// the UDC code, with non-digit separators stripped. "613.71" keys on
/// "6137".
pub fn udc_prefix_hash(udc_code: &str) -> u16 {
    let digits: String = udc_code
        .chars()
        .filter(|c| c.is_ascii_digit())
        .take(4)
        .collect();
    substrate_types::fnv::hash16(&digits)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    const UUID_A: &str = "11111111-1111-1111-1111-111111111111";
    const UUID_B: &str = "22222222-2222-2222-2222-222222222222";

    fn sample(udc: &str) -> Drawer {
        let mut d = Drawer::new(
            "d1",
            "hello",
            "study",
            "notes",
            "alice",
            1_700_000_000,
            "test-v1",
        );
        d.udc_code = udc.to_string();
        d
    }

    // --- FNV-1a helpers (now SubstrateLib-owned, see substrate_types::fnv tests) ---
    //
    // The pure-FNV-1a determinism tests live in SubstrateLib; here we
    // keep only the tests that pin DrawerFingerprint's specific use of
    // it (udc_prefix_hash, estate_uuid_byte).

    // --- udc_prefix_hash strips non-digits and takes first four ---

    #[test]
    fn udc_prefix_hash_strips_separators() {
        // "613.71" -> "6137"
        assert_eq!(
            udc_prefix_hash("613.71"),
            substrate_types::fnv::hash16("6137")
        );
    }

    #[test]
    fn udc_prefix_hash_caps_at_four_digits() {
        // "1234567" -> "1234"
        assert_eq!(
            udc_prefix_hash("1234567"),
            substrate_types::fnv::hash16("1234")
        );
    }

    #[test]
    fn udc_prefix_hash_empty_string() {
        assert_eq!(udc_prefix_hash(""), substrate_types::fnv::hash16(""));
    }

    // --- capture_week_bucket: pre-epoch zero, post-epoch modulo 256 ---

    #[test]
    fn capture_week_bucket_zero_before_2020_epoch() {
        assert_eq!(capture_week_bucket(0), 0);
        assert_eq!(capture_week_bucket(CAPTURE_WEEK_EPOCH_SECONDS), 0);
        assert_eq!(capture_week_bucket(CAPTURE_WEEK_EPOCH_SECONDS - 1), 0);
    }

    #[test]
    fn capture_week_bucket_counts_weeks_from_epoch() {
        // Exactly 1 week after epoch -> bucket 1.
        let one_week = CAPTURE_WEEK_EPOCH_SECONDS + 7 * 86_400;
        assert_eq!(capture_week_bucket(one_week), 1);
        // 10 weeks -> bucket 10.
        let ten_weeks = CAPTURE_WEEK_EPOCH_SECONDS + 10 * 7 * 86_400;
        assert_eq!(capture_week_bucket(ten_weeks), 10);
    }

    #[test]
    fn capture_week_bucket_wraps_at_256() {
        // 256 weeks after epoch -> bucket 0 (wraps).
        let two_fifty_six_weeks = CAPTURE_WEEK_EPOCH_SECONDS + 256 * 7 * 86_400;
        assert_eq!(capture_week_bucket(two_fifty_six_weeks), 0);
        // 257 weeks -> bucket 1.
        let two_fifty_seven_weeks = CAPTURE_WEEK_EPOCH_SECONDS + 257 * 7 * 86_400;
        assert_eq!(capture_week_bucket(two_fifty_seven_weeks), 1);
    }

    // --- EstateFingerprintFamilies ---

    /// Determinism: same UUID always produces the same base seed.
    #[test]
    fn base_seed_deterministic() {
        let s1 = EstateFingerprintFamilies::base_seed(UUID_A);
        let s2 = EstateFingerprintFamilies::base_seed(UUID_A);
        assert_eq!(s1, s2);
    }

    /// Different UUIDs produce different base seeds.
    #[test]
    fn base_seed_diverges_on_uuid() {
        let s1 = EstateFingerprintFamilies::base_seed(UUID_A);
        let s2 = EstateFingerprintFamilies::base_seed(UUID_B);
        assert_ne!(s1, s2);
    }

    /// Replica agreement (the central determinism contract): two
    /// EstateFingerprintFamilies built from the same UUID produce
    /// bit-identical fingerprints for the same drawer.
    #[test]
    fn replica_agreement_for_same_uuid_and_drawer() {
        let fam_a = EstateFingerprintFamilies::new(UUID_A);
        let fam_b = EstateFingerprintFamilies::new(UUID_A);
        let d = sample("547");
        assert_eq!(fam_a.fingerprint(&d), fam_b.fingerprint(&d));
    }

    /// Different estates produce different fingerprints for the same
    /// drawer (the per-estate hyperplane families really do diversify).
    #[test]
    fn different_estates_differ_for_same_drawer() {
        let fam_a = EstateFingerprintFamilies::new(UUID_A);
        let fam_b = EstateFingerprintFamilies::new(UUID_B);
        let d = sample("547");
        assert_ne!(fam_a.fingerprint(&d), fam_b.fingerprint(&d));
    }

    /// Per-block family independence — the landmine guard
    /// (`DECISION_FINGERPRINT_SEEDS_DERIVED_2026-05-20`): the four
    /// families must not collapse to a single family or to the same
    /// canonical hash. If `diversified_seed` ever stops mixing, this
    /// test catches the regression.
    #[test]
    fn four_families_distinct() {
        let fam = EstateFingerprintFamilies::new(UUID_A);
        let h0 = fam.families[0].canonical_hash();
        let h1 = fam.families[1].canonical_hash();
        let h2 = fam.families[2].canonical_hash();
        let h3 = fam.families[3].canonical_hash();
        assert_ne!(h0, h1);
        assert_ne!(h0, h2);
        assert_ne!(h0, h3);
        assert_ne!(h1, h2);
        assert_ne!(h1, h3);
        assert_ne!(h2, h3);
    }

    /// Field sensitivity, bitmap field: flipping bits in the bitmap
    /// triple shifts the fingerprint. Without this the bitmap facet is
    /// not actually routed through block 0.
    #[test]
    fn fingerprint_sensitive_to_bitmap_field() {
        let fam = EstateFingerprintFamilies::new(UUID_A);
        let mut a = sample("547");
        a.adjective_bitmap = 0;
        let mut b = sample("547");
        b.adjective_bitmap = 0xFFFF_FFFF_FFFF_FFFFu64 as i64;
        assert_ne!(fam.fingerprint(&a), fam.fingerprint(&b));
    }

    /// Field sensitivity, provenance field.
    #[test]
    fn fingerprint_sensitive_to_provenance_field() {
        let fam = EstateFingerprintFamilies::new(UUID_A);
        let mut a = sample("547");
        a.provenance = 0;
        let mut b = sample("547");
        b.provenance = 0xFFFF_FFFFu64 as i64;
        assert_ne!(fam.fingerprint(&a), fam.fingerprint(&b));
    }

    /// Field sensitivity, lineage field: a new lineage_id changes the
    /// fingerprint via block 2's lineage hash.
    #[test]
    fn fingerprint_sensitive_to_lineage_field() {
        let fam = EstateFingerprintFamilies::new(UUID_A);
        let mut a = sample("547");
        a.lineage_id = uuid::Uuid::parse_str(UUID_A).unwrap();
        let mut b = sample("547");
        b.lineage_id = uuid::Uuid::parse_str(UUID_B).unwrap();
        assert_ne!(fam.fingerprint(&a), fam.fingerprint(&b));
    }

    /// I-17 deterministic null: cross-noun-deferred sub-fields take
    /// zero, so two drawers identical in their populated fields produce
    /// bit-identical fingerprints. Establishes that the deferred slots
    /// (defer pattern, completion bucket, recency, stream source, QID
    /// closure) are not accidentally being seeded from elsewhere.
    #[test]
    fn i17_null_holds_for_identical_drawers() {
        let fam = EstateFingerprintFamilies::new(UUID_A);
        let a = sample("547");
        let b = sample("547");
        // Same lineage too, so block 2 hashes match.
        let mut a2 = a;
        let mut b2 = b;
        a2.lineage_id = uuid::Uuid::parse_str(UUID_A).unwrap();
        b2.lineage_id = uuid::Uuid::parse_str(UUID_A).unwrap();
        assert_eq!(fam.fingerprint(&a2), fam.fingerprint(&b2));
    }

    /// Estate-UUID byte is the low byte of `substrate_types::fnv::hash64(estate_uuid)`.
    #[test]
    fn estate_uuid_byte_is_low_byte_of_fnv() {
        let fam = EstateFingerprintFamilies::new(UUID_A);
        assert_eq!(
            fam.estate_uuid_byte(),
            substrate_types::fnv::hash64(UUID_A) as u8
        );
    }
}
