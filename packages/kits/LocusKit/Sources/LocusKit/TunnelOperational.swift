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

/// Tunnel operational value types per
/// `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` Appendix A
/// and § 5.6.
///
/// Five typed axes describe a tunnel's relationship semantics and
/// operational state. `TunnelKind` is the relationship vocabulary
/// (10 cases). The remaining four enums — `TunnelDirection`,
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
    /// Outline containment edge. Source is the child,
    /// target is the parent. One parent per child enforced in
    /// `addTunnel` (kit-level constraint, not a DB-level partial
    /// unique index). The companion `orderKey` on the
    /// Tunnel struct provides fractional-index sibling ordering.
    case parent = 9
}

/// Directionality of a tunnel — whether traversal is meaningful one
/// way, both ways, fully symmetric, or hub-like. Per spec § 5.6.
/// Contiguous encoding; 4 used, 4 reserved when packed into the
/// 3-bit direction field at bits 0–2 of `operationalBitmap`.
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
//   bit  13    is_retired         (1 bit, exclusive — /recall-driven dreaming)
//   bit  14    is_endorsed        (1 bit — MXE-CT3 review ladder: a model
//              reviewer endorsed this still-PROPOSED tunnel. Endorsed is
//              NOT a lifecycle case; lifecycle stays .proposed and only
//              the user moves it to .active via respondToTunnel.)
//   bit  15    is_contested       (1 bit — MXE-CT3 review ladder: the ext
//              ledger holds BOTH a model endorsement and a model
//              objection. Genuine model disagreement — floats to the top
//              of its tier band in the review queue.)
//   bits 16–63 reserved
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

    /// Bit 13 of `operationalBitmap` — retired flag.
    ///
    /// A retired tunnel is a dreamed tunnel whose two endpoints have not been
    /// co-recalled within the OMEGA reinforcement window (14 days). Retirement
    /// is REVERSIBLE: setting this bit suspends the tunnel from active reads
    /// (it is not a tombstone and not a hard delete); clearing it restores the
    /// tunnel. A later co-recall re-forms the association by proposing it again
    /// (§ 12.8: "a later co-recall re-forms it"). The bit is backed by
    /// `operationalBitmap`; there is NO Bool stored property (schema invariant).
    ///
    /// Declared constant:
    ///   `static let isRetiredBit: Int64 = 1 << 13`
    ///
    /// Mirrors Rust `TunnelOperational::IS_RETIRED_BIT` (bit 13).
    static let isRetiredBit: Int64 = 1 << 13

    /// True when this tunnel has been retired by the REM-OMEGA cycle.
    ///
    /// Computed from bit 13 of `operationalBitmap` — no Bool stored property.
    /// A retired tunnel is excluded from active tunnel reads (it is not a live
    /// graph edge) but remains in the substrate for audit and reversibility.
    var isRetired: Bool {
        operationalBitmap & Tunnel.isRetiredBit != 0
    }

    /// Bit 14 of `operationalBitmap` — endorsed flag (MXE-CT3 review
    /// ladder: Rejected / Proposed / Endorsed / Accepted).
    ///
    /// Set when a model reviewer endorses a `.proposed` tunnel via the GLK
    /// endorsement verb. Endorsed is deliberately NOT a `TunnelLifecycle`
    /// case: the tunnel remains `.proposed`, and edge activation stays
    /// human-authoritative — only `respondToTunnel(accept: true)` (the
    /// user path) moves lifecycle to `.active`. The endorsement ledger
    /// (who endorsed, when, under which tier lens) lives in `ext`; this
    /// bit is the cheap bitmap-tier filter over it.
    ///
    /// Mirrors Rust `Tunnel::IS_ENDORSED_BIT` (bit 14).
    static let isEndorsedBit: Int64 = 1 << 14

    /// True when at least one model reviewer has endorsed this proposed
    /// tunnel. Computed from bit 14 of `operationalBitmap` — no Bool
    /// stored property (schema invariant).
    var isEndorsed: Bool {
        operationalBitmap & Tunnel.isEndorsedBit != 0
    }

    /// Bit 15 of `operationalBitmap` — contested flag (MXE-CT3 review
    /// ladder).
    ///
    /// Set when the `ext` ledger holds BOTH a model endorsement and a
    /// model objection for this tunnel: one model reviewer endorsed the
    /// claim and another rejected/objected. Genuine model disagreement is
    /// the most user-worthy queue position, so the review-queue ranking
    /// floats contested tunnels to the top of their tier band. The bit is
    /// backed by `operationalBitmap`; no Bool stored property.
    ///
    /// Mirrors Rust `Tunnel::IS_CONTESTED_BIT` (bit 15).
    static let isContestedBit: Int64 = 1 << 15

    /// True when the ledger holds both a model endorsement and a model
    /// objection. Computed from bit 15 of `operationalBitmap` — no Bool
    /// stored property (schema invariant).
    var isContested: Bool {
        operationalBitmap & Tunnel.isContestedBit != 0
    }

    /// Return a copy of this tunnel with the retired bit set (`isRetired = true`).
    ///
    /// Used internally by `DrawerStore.retireTunnel` and its Rust equivalent to
    /// produce the updated tunnel value before persisting. The caller is
    /// responsible for the actual `rowStore.update` write.
    func withRetired() -> Tunnel {
        Tunnel(
            id: id,
            sourceWing: sourceWing, sourceRoom: sourceRoom, sourceDrawerId: sourceDrawerId,
            targetWing: targetWing, targetRoom: targetRoom, targetDrawerId: targetDrawerId,
            label: label, kind: kind,
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: operationalBitmap | Tunnel.isRetiredBit,
            provenanceBitmap: provenanceBitmap,
            addedBy: addedBy, filedAt: filedAt,
            tombstonedAt: tombstonedAt, removedByBatch: removedByBatch, orderKey: orderKey,
            ext: ext
        )
    }

    /// Return a copy of this tunnel with lifecycle bits 3–5 rewritten to
    /// `lifecycle`. Used internally by `DrawerStore.respondToTunnel` (and its
    /// Rust equivalent) to move a `.proposed` tunnel to `.active` (accepted)
    /// or `.withdrawn` (rejected). The caller is responsible for the actual
    /// `rowStore.update` write.
    func withLifecycle(_ lifecycle: TunnelLifecycle) -> Tunnel {
        Tunnel(
            id: id,
            sourceWing: sourceWing, sourceRoom: sourceRoom, sourceDrawerId: sourceDrawerId,
            targetWing: targetWing, targetRoom: targetRoom, targetDrawerId: targetDrawerId,
            label: label, kind: kind,
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: BitField.writeField(
                Int64(lifecycle.rawValue),
                into: operationalBitmap, shift: 3, width: 3
            ),
            provenanceBitmap: provenanceBitmap,
            addedBy: addedBy, filedAt: filedAt,
            tombstonedAt: tombstonedAt, removedByBatch: removedByBatch, orderKey: orderKey,
            ext: ext
        )
    }

    /// Return a copy of this tunnel with the endorsed bit (14) set.
    ///
    /// Used by the GLK endorsement verb to produce the updated tunnel value
    /// before persisting via `DrawerStore.stampTunnelReview`. Lifecycle bits
    /// are NOT touched: an endorsed tunnel stays `.proposed` — acceptance is
    /// the user's alone. Mirrors Rust `Tunnel::with_endorsed`.
    func withEndorsed() -> Tunnel {
        Tunnel(
            id: id,
            sourceWing: sourceWing, sourceRoom: sourceRoom, sourceDrawerId: sourceDrawerId,
            targetWing: targetWing, targetRoom: targetRoom, targetDrawerId: targetDrawerId,
            label: label, kind: kind,
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: operationalBitmap | Tunnel.isEndorsedBit,
            provenanceBitmap: provenanceBitmap,
            addedBy: addedBy, filedAt: filedAt,
            tombstonedAt: tombstonedAt, removedByBatch: removedByBatch, orderKey: orderKey,
            ext: ext
        )
    }

    /// Return a copy of this tunnel with the contested bit (15) set.
    ///
    /// Used by the GLK review verbs when the ext ledger holds both a model
    /// endorsement and a model objection. The endorsed bit is left as-is —
    /// a contested tunnel IS endorsed by someone; contested marks the
    /// disagreement, it does not erase the endorsement. Mirrors Rust
    /// `Tunnel::with_contested`.
    func withContested() -> Tunnel {
        Tunnel(
            id: id,
            sourceWing: sourceWing, sourceRoom: sourceRoom, sourceDrawerId: sourceDrawerId,
            targetWing: targetWing, targetRoom: targetRoom, targetDrawerId: targetDrawerId,
            label: label, kind: kind,
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: operationalBitmap | Tunnel.isContestedBit,
            provenanceBitmap: provenanceBitmap,
            addedBy: addedBy, filedAt: filedAt,
            tombstonedAt: tombstonedAt, removedByBatch: removedByBatch, orderKey: orderKey,
            ext: ext
        )
    }

    /// Return a copy of this tunnel with the retired bit cleared (`isRetired = false`).
    ///
    /// Used internally by `DrawerStore.unretireTunnel` and its Rust equivalent to
    /// reverse a prior retirement. The tunnel re-enters active reads once persisted.
    func withUnretired() -> Tunnel {
        Tunnel(
            id: id,
            sourceWing: sourceWing, sourceRoom: sourceRoom, sourceDrawerId: sourceDrawerId,
            targetWing: targetWing, targetRoom: targetRoom, targetDrawerId: targetDrawerId,
            label: label, kind: kind,
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: operationalBitmap & ~Tunnel.isRetiredBit,
            provenanceBitmap: provenanceBitmap,
            addedBy: addedBy, filedAt: filedAt,
            tombstonedAt: tombstonedAt, removedByBatch: removedByBatch, orderKey: orderKey,
            ext: ext
        )
    }
}

// MARK: - Tunnel provenance accessors

// Tunnel provenanceBitmap layout (recall-driven dreaming, low-to-high):
//   bit  0   is_dreamed   (1 bit) — set by dreaming pipeline when the
//            tunnel was proposed by REM-ALPHA or REM-THETA (emergent channel).
//            Cleared for declared tunnels (palace tunnels.json, vault wikilinks,
//            user-explicit `capture` tunnel frames). OMEGA retires only tunnels
//            where is_dreamed = 1 (§ 12.8 "provenance = dreamed AND not
//            reinforced by recall"). Declared tunnels (is_dreamed = 0) are
//            NEVER retired by OMEGA regardless of recall activity.
//   bits 1–63 reserved for future provenance axes.
public extension Tunnel {

    /// Bit 0 of `provenanceBitmap` — dreamed-provenance flag.
    ///
    /// Set to 1 when this tunnel entered the substrate through the dreaming
    /// pipeline (REM-ALPHA or REM-THETA co-recall proposal, subsequently
    /// accepted). Set to 0 for all declared tunnels (palace `tunnels.json`,
    /// vault wikilinks, user-explicit `capture` frames). OMEGA's retire predicate
    /// requires `isDreamed == true` — declared tunnels are never retired (§ 12.8).
    ///
    /// Constant:
    ///   `static let isDreamedBit: Int64 = 1 << 0`
    ///
    /// Mirrors Rust `TunnelProvenance::IS_DREAMED_BIT` (bit 0).
    static let isDreamedBit: Int64 = 1 << 0

    /// True when this tunnel has dreamed provenance (emerged from REM-ALPHA
    /// or REM-THETA co-recall). False for all declared tunnels.
    ///
    /// Computed from bit 0 of `provenanceBitmap` — no Bool stored property.
    var isDreamed: Bool {
        provenanceBitmap & Tunnel.isDreamedBit != 0
    }

    /// Return a copy of this tunnel with `isDreamed` stamped (bit 0 set).
    ///
    /// Used when the dreaming pipeline forms a real Tunnel from an accepted
    /// proposal. Declared tunnels never call this method — their
    /// `provenanceBitmap` leaves bit 0 at 0.
    func withDreamedProvenance() -> Tunnel {
        Tunnel(
            id: id,
            sourceWing: sourceWing, sourceRoom: sourceRoom, sourceDrawerId: sourceDrawerId,
            targetWing: targetWing, targetRoom: targetRoom, targetDrawerId: targetDrawerId,
            label: label, kind: kind,
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: operationalBitmap,
            provenanceBitmap: provenanceBitmap | Tunnel.isDreamedBit,
            addedBy: addedBy, filedAt: filedAt,
            tombstonedAt: tombstonedAt, removedByBatch: removedByBatch, orderKey: orderKey,
            ext: ext
        )
    }
}
