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

/// `Association` operational value types per cookbook §2.4 ("Association
/// operational", empirical-dominant, 6-bit floor).
///
/// Three axes describe how an association formed and how it ages. They
/// pack into the low 20 bits of `Association.operationalBitmap`:
///
/// ```
/// bits 0–11   signal_sources_seen  (bitset — each bit independent)
/// bits 12–17  decay_class          (scale-gapped, raws 0/16/32/48)
/// bits 18–19  arity                (contiguous, raws 0/1)
/// bits 20–63  reserved
/// ```
///
/// Unlike the contiguous-field axes of `TunnelOperational` /
/// `ProposalOperational`, `signal_sources_seen` is a **bitset**: more
/// than one source can be set at once (an association seen by both
/// co-recall and vector similarity carries both bits). It is therefore
/// surfaced as an `OptionSet` read off the masked low 12 bits, not as a
/// named-enum field extract. `decay_class` and `arity` are ordinary
/// fields decoded with `BitField.extractField` and a safe fallback to the
/// zero case, matching `TunnelOperational`.

// MARK: - AssociationSignalSources

/// The set of signals that have contributed to an association, per
/// cookbook §2.4 bits 0–11 (a bitset). Each member is one independent
/// bit; an association accumulates members as the dreaming pass observes
/// more evidence for the pairing (cookbook §10.10). Bits 10–11 are
/// reserved.
public struct AssociationSignalSources: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }

    /// Bit 0 — the two rows were recalled together.
    public static let coRecall = AssociationSignalSources(rawValue: 1 << 0)
    /// Bit 1 — the two rows were confirmed together.
    public static let coConfirmed = AssociationSignalSources(rawValue: 1 << 1)
    /// Bit 2 — paired by a dreaming pass.
    public static let dreamPairing = AssociationSignalSources(rawValue: 1 << 2)
    /// Bit 3 — paired by vector similarity.
    public static let vectorSimilarity = AssociationSignalSources(rawValue: 1 << 3)
    /// Bit 4 — the rows share an entity.
    public static let sharedEntity = AssociationSignalSources(rawValue: 1 << 4)
    /// Bit 5 — asserted explicitly by a human.
    public static let explicitHuman = AssociationSignalSources(rawValue: 1 << 5)
    /// Bit 6 — paired by fingerprint similarity. (NEW, v0.36.)
    public static let fingerprintSimilarity = AssociationSignalSources(rawValue: 1 << 6)
    /// Bit 7 — the pairing crosses estates. (NEW, v0.36 case 1.)
    public static let crossEstate = AssociationSignalSources(rawValue: 1 << 7)
    /// Bit 8 — the pairing crosses tiers. (NEW, v0.36 case 3.)
    public static let crossTier = AssociationSignalSources(rawValue: 1 << 8)
    /// Bit 9 — derived from an action outcome. (NEW, v0.36 case 2.)
    public static let actionOutcome = AssociationSignalSources(rawValue: 1 << 9)

    /// Mask covering the assigned bits 0–11 (bits 10–11 reserved). The
    /// accessor masks `operationalBitmap` with this so reserved or
    /// higher-axis bits never bleed into the set.
    public static let mask: Int64 = 0xFFF
}

// MARK: - AssociationDecayClass

/// How fast an association ages out of relevance. Per cookbook §2.4 bits
/// 12–17. Scale-gapped encoding (raws 0/16/32/48) so future intermediate
/// tiers can slot in without disturbing existing equality or ordering
/// masks; every other raw is an intentional sentinel that falls back to
/// `.pinned`.
///
/// `Comparable` so retrieval/decay-layer filters such as
/// `association.decayClass >= .normal` compose without raw-value math,
/// matching `TunnelStrength` / `ProposalConfidenceBucket`. Ordering runs
/// pinned < slow < normal < fast — increasing decay speed.
public enum AssociationDecayClass: Int, Sendable, Codable, Comparable {
    case pinned = 0
    case slow = 16
    case normal = 32
    case fast = 48

    public static func < (lhs: AssociationDecayClass, rhs: AssociationDecayClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - AssociationArity

/// The arity of an association. Per cookbook §2.4 bits 18–19. Contiguous
/// encoding. v1 is always `.binary` (I-23 limits associations to binary);
/// `.nAry` is reserved for v2+.
public enum AssociationArity: Int, Sendable, Codable {
    case binary = 0
    case nAry = 1
}

// MARK: - Association accessors

// Layout per cookbook §2.4 (low-to-high):
//   bits 0–11   signal_sources_seen  (bitset, OptionSet over the low 12 bits)
//   bits 12–17  decay_class          (6 bits, scale-gapped, raws 0/16/32/48)
//   bits 18–19  arity                (2 bits, contiguous, raws 0/1)
// Unknown raw values fall back to the zero case of each field axis,
// matching the `Tunnel` operational accessors in `TunnelOperational.swift`.
public extension Association {

    /// Decode bits 0–11 of `operationalBitmap` as the set of signals that
    /// have contributed to this association. A bitset, so callers test
    /// membership (`signalSourcesSeen.contains(.coRecall)`); reserved bits
    /// 10–11 and all higher bits are masked off.
    var signalSourcesSeen: AssociationSignalSources {
        // Cookbook §2.4: signal_sources_seen bitset at bits 0–11.
        AssociationSignalSources(rawValue: operationalBitmap & AssociationSignalSources.mask)
    }

    /// Decode bits 12–17 of `operationalBitmap` as an
    /// `AssociationDecayClass`. Returns `.pinned` for unrecognised raw
    /// values, including the intentionally-gapped scale sentinels.
    var decayClass: AssociationDecayClass {
        // Cookbook §2.4: decay_class at bits 12–17.
        AssociationDecayClass(rawValue: Int(BitField.extractField(operationalBitmap, shift: 12, width: 6))) ?? .pinned
    }

    /// Decode bits 18–19 of `operationalBitmap` as an `AssociationArity`.
    /// Returns `.binary` for unrecognised raw values (raws 2–3 reserved).
    var arity: AssociationArity {
        // Cookbook §2.4: arity at bits 18–19.
        AssociationArity(rawValue: Int(BitField.extractField(operationalBitmap, shift: 18, width: 2))) ?? .binary
    }
}
