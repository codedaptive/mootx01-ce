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
/// bits 6–11   content_kind           (contiguous, 7 cases at raw 0…6)
/// bits 12–23  feature_flags          (bitset, 7 named bits 12…18)
/// bit  24     state_extension flag
/// bit  25     lineage_clustering flag (NEW in v0.6)
/// bits 26–63  reserved
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
/// flags differ in shape: bits 8–15 are a non-exclusive set, so
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
/// 7 used, 57 reserved). Per cookbook §2.4.
///
/// Contiguous encoding: cases sit at raw values 0…6 in the order the
/// cookbook §2.4 declares them. F12 cascade (2026-05-27): added
/// `fingerprintOnly = 6` per cookbook v0.6 (the AmbientSample noun
/// type uses fingerprint-only rows; see §2.5).
public enum ContentKind: Int, Sendable, Codable {
    case prose = 0
    case code = 1
    case transcript = 2
    case list = 3
    case structuredJSON = 4
    case imageCaption = 5
    case fingerprintOnly = 6   // NEW in v0.6 per cookbook §2.4 / §2.5
}

/// Feature flags — non-exclusive set of properties a drawer may carry.
/// Lives in bits 12–23 of `Drawer.operationalBitmap` (12-bit bitset;
/// 7 named bits 12…18, bits 19–23 reserved). Per cookbook §2.4.
///
/// F12 cascade (2026-05-27): field shifted from v0.35 bits 8–15 to
/// v0.6 bits 12–23. NEW flags: `isKeystone` (bit 17, cookbook §7.2),
/// `isLockedZone` (bit 18).
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
}
