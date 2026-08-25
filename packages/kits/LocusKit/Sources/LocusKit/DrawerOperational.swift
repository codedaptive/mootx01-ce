import Foundation
import SubstrateTypes
import SubstrateKernel
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

/// Operational bitmap value types per cookbook §2.4 (Drawer
/// operational layout, v0.6 6-bit floor) and §2.8 (verification table).
///
/// The operational bitmap is the second of three Int64 columns each
/// drawer row carries (the first being `provenance` per cookbook §2.5,
/// the second `adjectiveBitmap` per §2.3, and this one per §2.4).
/// Where the adjective bitmap is cross-noun and gradient-dominant, the
/// operational bitmap is per-noun and empirical-dominant — its layout
/// is specific to `Drawer` and encodes how the content was captured,
/// what kind of content it is, what feature flags apply, plus the
/// state-extension and lineage-clustering flags.
///
/// Drawer operational layout (cookbook §2.4 v0.6):
///
/// ```
/// bits 0–5    capture_channel        (contiguous, 6 cases at raw 0…5)
/// bits 6–11   content_kind           (contiguous, 8 cases at raw 0…7)
/// bits 12–23  feature_flags          (bitset, 11 named bits 12…23)
/// bit  24     state_extension flag
/// bit  25     lineage_clustering flag (NEW in v0.6)
/// bit  26     isAnomalous — low-cohesion outlier flag (§11.18, 2026-08-20)
/// bits 27–63  reserved
/// ```
///
/// F12 cascade (2026-05-27): bumped from v0.35's 4-bit fields to
/// cookbook v0.6's 6-bit fields per I-15. NEW raws: `CaptureChannel.actuator`
/// (raw 5), `ContentKind.fingerprintOnly` (raw 6 for AmbientSample
/// per cookbook §2.5). NEW feature flags: `isKeystone` (bit 17 per §7.2),
/// `isLockedZone` (bit 18). NEW lineage-clustering flag at bit 25.
///
/// The pattern matches `Adjectives.swift` exactly for the named-enum
/// axes — bit-extraction accessors with safe fallbacks for
/// unrecognised raw values (which can happen when a future-version
/// row encodes a case that does not exist in this build). Feature
/// flags differ in shape: bits 12–23 are a non-exclusive set, so
/// `DrawerFeatureFlags` is an `OptionSet` rather than an enum.

/// Capture channel — how the drawer's content entered the system.
/// Lives in bits 0–5 of `Drawer.operationalBitmap` (6 bits, 64 values;
/// 6 used, 58 reserved). Per cookbook §2.4.
///
/// Contiguous encoding: cases sit at raw values 0…5 in the order the
/// cookbook §2.4 declares them. F12 cascade (2026-05-27): added
/// `actuator = 5` per cookbook v0.6 (case-2 actuator-driven capture).
public enum CaptureChannel: Int, Sendable, Codable {
    case typed = 0
    case voiced = 1
    case ocr = 2
    case importedFile = 3
    case sensor = 4
    case actuator = 5    // NEW in v0.6 per cookbook §2.4
}

/// Content kind — the shape of the drawer's content.
/// Lives in bits 6–11 of `Drawer.operationalBitmap` (6 bits, 64 values;
/// 8 used, 56 reserved). Per cookbook §2.4.
///
/// Contiguous encoding: cases sit at raw values 0…7 in the order the
/// cookbook §2.4 declares them. F12 cascade (2026-05-27): added
/// `fingerprintOnly = 6` per cookbook v0.6 (the AmbientSample noun
/// type uses fingerprint-only rows; see §2.5). MX-TAB-3 (2026-07-11):
/// added `dataset = 7` per cookbook §2.4 (dataset handle rows).
public enum ContentKind: Int, Sendable, Codable {
    case prose = 0
    case code = 1
    case transcript = 2
    case list = 3
    case structuredJSON = 4
    case imageCaption = 5
    case fingerprintOnly = 6   // NEW in v0.6 per cookbook §2.4 / §2.5
    case dataset = 7           // NEW per MX-TAB-3 / cookbook §2.4 (contiguous, raw 7)
}

/// Feature flags — non-exclusive set of properties a drawer may carry.
/// Lives in bits 12–23 of `Drawer.operationalBitmap` (12-bit bitset;
/// 11 named bits 12…23). Per cookbook §2.4.
///
/// F12 cascade (2026-05-27): field shifted from v0.35 bits 8–15 to
/// v0.6 bits 12–23. NEW flags: `isKeystone` (bit 17, cookbook §7.2),
/// `isLockedZone` (bit 18). 2026-07-28: `hasCurrentRepresentation`
/// (bit 19, cookbook §2.4.1) assigned. 2026-07-29: Wave-2 vague tier
/// bits 20–23 assigned per cookbook §2.4.2 — `isVague` (bit 20),
/// `representedByVague` (bit 21), `vagueLevel` 2-bit sub-field
/// (bits 22–23, accessed via `BitField.extractField` rather than an
/// OptionSet member because it is a contiguous integer, not a flag).
///
/// Bitset encoding (one bit per value), so this is an `OptionSet`
/// rather than an enum. `rawValue` is `Int64` so members compose
/// directly into the 64-bit operational bitmap with `|` and decode
/// with `&` against the field mask.
public struct DrawerFeatureFlags: OptionSet, Sendable, Codable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }

    /// Bit 12 — drawer has one or more file attachments alongside its
    /// `content` field. Attachment storage itself is out of scope for
    /// this rev.
    public static let hasAttachments = DrawerFeatureFlags(rawValue: 1 << 12)

    /// Bit 13 — drawer was captured with or carries voice audio.
    public static let hasVoice = DrawerFeatureFlags(rawValue: 1 << 13)

    /// Bit 14 — drawer was captured from or carries an image.
    public static let hasImage = DrawerFeatureFlags(rawValue: 1 << 14)

    /// Bit 15 — drawer's content contains links (URLs, citations).
    public static let hasLinks = DrawerFeatureFlags(rawValue: 1 << 15)

    /// Bit 16 — user-pinned drawer; retrieval surfaces this with
    /// elevated priority regardless of recency.
    public static let isPinned = DrawerFeatureFlags(rawValue: 1 << 16)

    /// Bit 17 — keystone drawer per cookbook §7.2 (NEW in v0.6).
    /// Keystones anchor a lineage/cluster and have elevated semantics
    /// in the supersession cascade and similarity-based retrieval.
    public static let isKeystone = DrawerFeatureFlags(rawValue: 1 << 17)

    /// Bit 18 — locked-zone drawer (NEW in v0.6 per cookbook §2.4).
    /// Privacy-aware bucket; the drawer's contents are gated by an
    /// additional zone-policy check at recall time.
    public static let isLockedZone = DrawerFeatureFlags(rawValue: 1 << 18)

    /// Bit 19 — drawer carries a current distilled representation per
    /// SPEC_DISTILLATION_STORAGE §4 (cookbook §2.4.1, 2026-07-28).
    ///
    /// Set iff all four distillation columns (`distilled`,
    /// `distilled_pipeline_version`, `distilled_token_count`,
    /// `distilled_at`) are populated. Clear when those columns are NULL.
    ///
    /// The §4 invariant ("NULL together or populated together") makes this
    /// bit skew-impossible: it travels in the SAME SQL UPDATE statement as
    /// the four columns — set by `setDistilledRepresentation`, cleared by
    /// every `withClearedRepresentation` call site (content-edit §7.3,
    /// expunge scrub, gate-reject scrub, dataset-content patch).
    ///
    /// Design tenet: open bitmap space means new features enter WITHOUT
    /// migration overhead. 1.0.x rows migrated to 1.1.x carry the bit
    /// clear (all-NULL columns) — no schema change, no backfill required.
    ///
    /// Wire value: 1 << 19 = 524288 (0x80000).
    public static let hasCurrentRepresentation = DrawerFeatureFlags(rawValue: 1 << 19)

    // ── Wave-2 vague tier bits (cookbook §2.4.2, 2026-07-29) ──────────────

    /// Bit 20 — this drawer is a Wave-2 consolidated vague item.
    ///
    /// Set iff this drawer was synthesised by `consolidateTransactionally`
    /// from N ≥ 3 constituent episodic drawers. Clear for every ordinary
    /// drawer and every constituent (which carries `representedByVague`
    /// instead).
    ///
    /// Invariant: set only by `consolidateTransactionally` / the Rust twin,
    /// never outside that path. The default recall tier
    /// (`.recallTier(.currentAndVague)`) includes vague items because
    /// this bit does NOT imply `representedByVague`.
    ///
    /// Wire value: 1 << 20 = 0x100000.
    public static let isVague = DrawerFeatureFlags(rawValue: 1 << 20)

    /// Bit 21 — this drawer has been absorbed into a vague item.
    ///
    /// Set on each constituent when `consolidateTransactionally` runs.
    /// The default recall tier (`.recallTier(.currentAndVague)`) excludes
    /// drawers carrying this bit — callers widening to constituents must
    /// pass `.recallTier(.all)` or `.recallTier(.currentOnly)`.
    ///
    /// Clear path (§5.3): when a vague item is expunged, `expungeGated`
    /// clears this bit on all its constituents in the same transaction.
    ///
    /// Wire value: 1 << 21 = 0x200000.
    public static let representedByVague = DrawerFeatureFlags(rawValue: 1 << 21)

    // Note: bits 22–23 hold the `vague_level` 2-bit integer sub-field.
    // That sub-field is NOT represented as an OptionSet member because
    // it is a contiguous integer (0–2), not a flag.  It is accessed via
    // the `Drawer.vagueLevel` computed property using
    // `BitField.extractField(operationalBitmap, shift: 22, width: 2)`.
    // Mask for the entire sub-field: 0xC00000.

    // ── Anomalous flag (§11.18 anomalous-flag recall prefilter, 2026-08-20) ──

    /// Bit 26 — drawer is a low-cohesion outlier in its room, computed by
    /// the anomaly-flag maintenance sweep in GeniusLocusKit (§11.18).
    ///
    /// Set/cleared by `Estate.setAnomalousFlag` during the room-cohesion
    /// sweep: drawers whose shingle-similarity z-score against room peers
    /// falls below the anomaly threshold get this bit set; all others are
    /// cleared. Requires ≥ 3 drawers in the room for z-score stability.
    ///
    /// This is a DERIVED signal — the maintenance sweep owns it. Do NOT
    /// set this flag through belief-state or manual edit paths.
    ///
    /// NOTE: bit 26 is above the 12-bit feature-flags region (bits 12–23).
    /// `hasFeatureFlag(.isAnomalous)` will always return false. Use the
    /// `Drawer.isAnomalous` computed property to test this bit.
    ///
    /// Wire value: 1 << 26 = 67108864 (0x4000000).
    public static let isAnomalous = DrawerFeatureFlags(rawValue: 1 << 26)
}

// MARK: - Drawer accessors

public extension Drawer {

    /// Decode bits 0–5 of `operationalBitmap` as a `CaptureChannel`.
    /// Returns `.typed` for unrecognised raw values — typed input is
    /// the neutral default channel for content of unknown origin.
    /// Cookbook §2.4 6-bit field.
    var captureChannel: CaptureChannel {
        // Cookbook §2.4: capture_channel at bits 0–5.
        CaptureChannel(rawValue: Int(BitField.extractField(operationalBitmap, shift: 0, width: 6))) ?? .typed
    }

    /// Decode bits 6–11 of `operationalBitmap` as a `ContentKind`.
    /// Returns `.prose` for unrecognised raw values — prose is the
    /// neutral default kind for unstructured text. Cookbook §2.4 6-bit field.
    var contentKind: ContentKind {
        // Cookbook §2.4: content_kind at bits 6–11.
        ContentKind(rawValue: Int(BitField.extractField(operationalBitmap, shift: 6, width: 6))) ?? .prose
    }

    /// Decode bits 12–23 of `operationalBitmap` as a
    /// `DrawerFeatureFlags` set. The mask `0xFFF000` selects the
    /// 12-bit feature region; the bit positions inside the set
    /// (12…18) match the underlying bitmap so the OptionSet's
    /// `rawValue` is the same Int64 region. Cookbook §2.4.
    var featureFlags: DrawerFeatureFlags {
        // Cookbook §2.4: feature_flags occupy bits 12–23. The OptionSet's
        // rawValues are already pre-shifted (e.g. `1 << 12`), so the extraction
        // is a 12-bit field starting at bit 12 left in its native position.
        DrawerFeatureFlags(rawValue: BitField.extractField(operationalBitmap, shift: 12, width: 12) << 12)
    }

    /// True when `flag` is present in the operational bitmap. Pure
    /// convenience over `featureFlags.contains(flag)` — kept here so
    /// retrieval-layer call sites read naturally without an
    /// intermediate `featureFlags` reference.
    func hasFeatureFlag(_ flag: DrawerFeatureFlags) -> Bool {
        featureFlags.contains(flag)
    }

    /// True when bit 19 of `operationalBitmap` is set, indicating that
    /// all four distillation columns are populated (cookbook §2.4.1).
    ///
    /// Consumers use this instead of `distilled == nil` for eligibility
    /// checks — it is a direct bitmap read, not a column-presence test.
    /// `distillItemsSweep` and `wireCorpusRoomRollup` use this accessor
    /// as the primary eligibility gate; `countUndistilled` uses the
    /// corresponding `bitmaskNone` predicate on the database side.
    ///
    /// The bit and the four columns are always in agreement by
    /// construction: they travel in the same SQL UPDATE statement
    /// (`setDistilledRepresentation` sets both; every content-clearing
    /// path clears both simultaneously).
    var hasCurrentRepresentation: Bool {
        // Cookbook §2.4.1: has_current_representation at bit 19.
        featureFlags.contains(.hasCurrentRepresentation)
    }

    // ── Wave-2 vague tier accessors (cookbook §2.4.2) ─────────────────────

    /// True when bit 20 of `operationalBitmap` is set, indicating this
    /// drawer is a Wave-2 consolidated vague item (cookbook §2.4.2).
    ///
    /// Vague items are returned by the default recall tier
    /// (`.recallTier(.currentAndVague)`) alongside ordinary drawers.
    /// Use `vagueRecall` to retrieve their constituents.
    var isVague: Bool {
        // Cookbook §2.4.2: is_vague at bit 20.
        featureFlags.contains(.isVague)
    }

    /// True when bit 21 of `operationalBitmap` is set, indicating this
    /// drawer has been absorbed into a vague item (cookbook §2.4.2).
    ///
    /// Drawers with this flag are excluded from the default recall tier
    /// (`.recallTier(.currentAndVague)`). They are reachable via the
    /// `vague_recall` two-hop verb or by passing `.recallTier(.all)`.
    var representedByVague: Bool {
        // Cookbook §2.4.2: represented_by_vague at bit 21.
        featureFlags.contains(.representedByVague)
    }

    /// The nesting depth of this drawer in the vague hierarchy,
    /// decoded from bits 22–23 of `operationalBitmap` (cookbook §2.4.2).
    ///
    /// - `0` — not a vague item (ordinary episodic drawer, or clear).
    /// - `1` — first-level vague item; constituents are ordinary drawers.
    /// - `2` — second-level vague item; at least one constituent is itself
    ///   a vague item. The spec caps depth at 2 — level-3 consolidation
    ///   is rejected.
    ///
    /// Wire: mask 0xC00000, shift 22, width 2. Value `0b11` (3) is
    /// reserved and treated as level 2 at read time.
    var vagueLevel: UInt8 {
        // Cookbook §2.4.2: vague_level at bits 22–23 (2-bit sub-field).
        let raw = UInt8(BitField.extractField(operationalBitmap, shift: 22, width: 2))
        return min(raw, 2)  // cap at 2: value 3 is reserved, treat as 2
    }

    /// True when bit 24 of `operationalBitmap` is set, indicating the
    /// adjective state field has overflowed its 6-bit allotment per
    /// cookbook §2.9 (state-extension growth budget). The flag is
    /// specific to the state field only; other bitmap fields use their
    /// own reserved-bit growth budgets rather than this flag.
    var stateExtensionActive: Bool {
        // Cookbook §2.4 bit 24: state_extension flag.
        BitField.extractFlag(operationalBitmap, bit: 24)
    }

    /// True when bit 25 of `operationalBitmap` is set, indicating the
    /// drawer belongs to a lineage cluster per cookbook §2.4 (NEW in v0.6).
    /// Used by the federation / cross-tier replication paths to opt
    /// rows into clustered transport.
    var lineageClusteringActive: Bool {
        // Cookbook §2.4 bit 25: lineage_clustering flag.
        BitField.extractFlag(operationalBitmap, bit: 25)
    }

    // ── Anomalous flag (bit 26, §11.18 anomalous-flag recall prefilter) ───────

    /// True when bit 26 of `operationalBitmap` is set, indicating this
    /// drawer is a low-cohesion outlier in its room (cookbook §2.4, §11.18).
    ///
    /// Computed and maintained by GeniusLocusKit's anomaly-flag sweep:
    /// the sweep scores each drawer's mean shingle-similarity to its room
    /// peers, computes z-scores, and sets this flag on negative-z-score
    /// outliers. Rooms with fewer than 3 drawers are skipped.
    ///
    /// Callers filtering on anomaly status should use this accessor
    /// rather than `featureFlags.contains(.isAnomalous)` — bit 26 is
    /// above the 12-bit feature-flags region (bits 12–23) and will not
    /// appear in the `featureFlags` OptionSet.
    ///
    /// Wire: `operationalBitmap & (1 << 26) != 0`. Mirrors Rust
    /// `Drawer::is_anomalous()`.
    var isAnomalous: Bool {
        // Cookbook §2.4 bit 26: anomalous flag (§11.18). Reads the raw
        // bitmap directly because bit 26 is outside the featureFlags region.
        operationalBitmap & DrawerFeatureFlags.isAnomalous.rawValue != 0
    }
}
