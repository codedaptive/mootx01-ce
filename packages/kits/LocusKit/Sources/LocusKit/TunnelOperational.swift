import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib

/// Tunnel operational value types per
/// `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` Appendix A
/// and § 5.6.
///
/// Five typed axes describe a tunnel's relationship semantics and
/// operational state. `TunnelKind` is the relationship vocabulary
/// (9 cases). The remaining four enums — `TunnelDirection`,
/// `TunnelLifecycle`, `TunnelOriginClass`, `TunnelStrength` — are
/// the operational axes packed into the per-row `operationalBitmap`
/// Int64 column added by LOCI_V035_05B.
///
/// Pattern follows `Adjectives.swift` exactly: named-enum
/// accessors decode each axis from a single Int64 column with a
/// safe fallback to the zero case when an unrecognised raw value
/// appears.

/// Relationship kind — the typed vocabulary for what one tunnel
/// asserts between source and target. Per spec Appendix A. Default
/// for new tunnels is `.references`; the supersession cascade in
/// `DrawerStore.addDrawerWithCascade` sets `.supersedes`.
public enum TunnelKind: Int, Sendable, Codable {
    case supersedes = 0
    case references = 1
    case blocks = 2
    case validates = 3
    case contradicts = 4
    case derivesFrom = 5
    case covers = 6
    case elaborates = 7
    case respondsTo = 8
}

/// Directionality of a tunnel — whether traversal is meaningful one
/// way, both ways, fully symmetric, or hub-like. Per spec § 5.6.
/// Contiguous encoding; 4 used, 12 reserved when packed into 4 bits.
public enum TunnelDirection: Int, Sendable, Codable {
    case directional = 0
    case bidirectional = 1
    case symmetric = 2
    case hub = 3
}

/// Lifecycle state of a tunnel — analogous to `State` on a drawer
/// but with a smaller closed set tailored to relationship rows.
/// Per spec § 5.6. Contiguous encoding.
public enum TunnelLifecycle: Int, Sendable, Codable {
    case active = 0
    case proposed = 1
    case superseded = 2
    case withdrawn = 3
}

/// How the tunnel entered the substrate — user assertion, agent
/// derivation, import path, sync replication, or schema migration.
/// Per spec § 5.6. Contiguous encoding.
public enum TunnelOriginClass: Int, Sendable, Codable {
    case userExplicit = 0
    case derived = 1
    case imported = 2
    case federatedSync = 3
    case migration = 4
}

/// Strength axis — scale-gapped encoding (raw values 0/2/4/6) so
/// future intermediate tiers can slot in semantically without
/// disturbing existing equality or ordering masks. Per spec § 5.6.
/// `Comparable` so retrieval-layer filters such as
/// `tunnel.strength >= .strong` compose without raw-value math.
/// Sentinels: raw values 1, 3, 5 are intentionally `nil`.
public enum TunnelStrength: Int, Sendable, Codable, Comparable {
    case weak = 0
    case normal = 2
    case strong = 4
    case loadBearing = 6

    public static func < (lhs: TunnelStrength, rhs: TunnelStrength) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Tunnel accessors

// Layout per spec § 5.6 (low-to-high):
//   bits 0–2   TunnelDirection    (3 bits, contiguous, 4 cases)
//   bits 3–5   TunnelLifecycle    (3 bits, contiguous, 4 cases)
//   bits 6–8   TunnelOriginClass  (3 bits, contiguous, 5 cases)
//   bits 9–11  TunnelStrength     (3 bits, scale-gapped, raws 0/2/4/6)
//   bit  12    has_inverse        (1 bit, exclusive)
// Unknown raw values fall back to the zero case of each axis,
// matching the `Drawer` adjective accessors in `Adjectives.swift`.
public extension Tunnel {

    /// Decode bits 0–2 of `operationalBitmap` as a `TunnelDirection`.
    /// Returns `.directional` for unrecognised raw values.
    var direction: TunnelDirection {
        // v0.35 layout: direction at bits 0-2.
        TunnelDirection(rawValue: Int(BitField.extractField(operationalBitmap, shift: 0, width: 3))) ?? .directional
    }

    /// Decode bits 3–5 of `operationalBitmap` as a `TunnelLifecycle`.
    /// Returns `.active` for unrecognised raw values.
    var lifecycle: TunnelLifecycle {
        // v0.35 layout: lifecycle at bits 3-5.
        TunnelLifecycle(rawValue: Int(BitField.extractField(operationalBitmap, shift: 3, width: 3))) ?? .active
    }

    /// Decode bits 6–8 of `operationalBitmap` as a `TunnelOriginClass`.
    /// Returns `.userExplicit` for unrecognised raw values.
    var originClass: TunnelOriginClass {
        // v0.35 layout: origin_class at bits 6-8.
        TunnelOriginClass(rawValue: Int(BitField.extractField(operationalBitmap, shift: 6, width: 3))) ?? .userExplicit
    }

    /// Decode bits 9–11 of `operationalBitmap` as a `TunnelStrength`.
    /// Returns `.weak` for unrecognised raw values (including the
    /// intentionally-gapped scale raws 1, 3, 5, 7).
    var strength: TunnelStrength {
        // v0.35 layout: strength at bits 9-11.
        TunnelStrength(rawValue: Int(BitField.extractField(operationalBitmap, shift: 9, width: 3))) ?? .weak
    }

    /// Decode bit 12 of `operationalBitmap`. True when a paired
    /// inverse tunnel exists in the substrate, false otherwise.
    var hasInverse: Bool {
        // v0.35 layout: bit 12 flag.
        BitField.extractFlag(operationalBitmap, bit: 12)
    }
}
