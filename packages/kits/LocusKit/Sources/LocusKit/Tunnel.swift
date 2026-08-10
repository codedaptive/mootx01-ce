import Foundation
import SubstrateKernel

/// A typed cross-reference between two locations in the
/// MemPalace surface.
///
/// Tunnels link wings, rooms, or specific drawers. They are
/// intentionally symmetric in spirit — a tunnel from A to B
/// implies the inverse — but stored directionally so that
/// queries can ask "what does this side know about?" without
/// scanning both endpoints. The symmetric-id contract (the
/// canonical id is a hash of the sorted endpoint pair) is
/// documented here but not enforced at this layer; LOCI-5
/// adds the enforcement once the broader tunnel surface lands.
///
/// Source and target endpoints both carry wing + room + optional
/// drawer id. A nil drawer id at either end means "the room
/// itself" — useful for room-level concepts that are not
/// anchored to any single drawer.
///
/// `tombstonedAt` is written by tunnel-tombstone operations (e.g.
/// outline-parent replacement) and filtered by active-tunnel queries.
/// `removedByBatch` is reserved for the Rev 2.0 receipt-rollback
/// workflow.
public struct Tunnel: Equatable, Hashable, Codable, Sendable {

    /// Stable identifier. Conventionally the SHA-256 of the
    /// canonicalised endpoint pair so that A→B and B→A collapse
    /// to one row. This mission accepts whatever id the caller
    /// supplies; LOCI-5 enforces the canonicalisation.
    public let id: String

    /// Wing of the source endpoint.
    public let sourceWing: String

    /// Room of the source endpoint.
    public let sourceRoom: String

    /// Drawer id at the source endpoint, when the tunnel
    /// targets a specific drawer. Nil means the room itself.
    public let sourceDrawerId: String?

    /// Wing of the target endpoint.
    public let targetWing: String

    /// Room of the target endpoint.
    public let targetRoom: String

    /// Drawer id at the target endpoint. Nil means the room
    /// itself.
    public let targetDrawerId: String?

    /// Free-form relationship label. Domain-specific; LocusKit
    /// does not validate against a closed catalogue.
    public let label: String

    /// Typed relationship kind from the closed spec vocabulary
    /// (Appendix A). Defaulted to `.references` so existing call
    /// sites stay source-compatible. The SQLite `kind_id` column
    /// and the four ALTER guards added by LOCI_V035_05B persist this
    /// value; legacy pre-05B rows fall back to `.references` via the
    /// column's `DEFAULT 1`. Distinct from `label` because `label` is
    /// free-form and `kind` is the indexed, finite vocabulary the
    /// retrieval layer dispatches on.
    public let kind: TunnelKind

    /// Cross-row adjective bitmap (state, sensitivity, exportability,
    /// trust per spec § 5.5). Stored as a single Int64 column. Default
    /// 0 leaves every axis at its zero-value (state=.active,
    /// sensitivity=.normal, exportability=.private, trust=.verbatim).
    public let adjectiveBitmap: Int64

    /// Per-noun operational bitmap (spec § 5.6, tunnel layout).
    /// Stored as a single Int64 column. Accessors in
    /// `TunnelOperational.swift` decode direction, lifecycle,
    /// origin_class, strength, and has_inverse.
    public let operationalBitmap: Int64

    /// Provenance bitmap (spec § 5.7, Q1-locked layout). Stored as a
    /// single Int64 column. Captures source type, confirmation,
    /// confidence, channel, and sensitivity at row birth.
    public let provenanceBitmap: Int64

    /// Name of the agent or process that filed this tunnel.
    public let addedBy: String

    /// When the tunnel was added. TEXT ISO8601 in SQLite.
    public let filedAt: Date

    /// When this tunnel was tombstoned, if it has been. Written by
    /// tunnel-tombstone operations; live tunnel queries filter this field.
    public let tombstonedAt: Date?

    /// Batch identifier used for receipt-based rollback of a
    /// tombstone. Reserved for the Rev 2.0 soft-delete workflow.
    public let removedByBatch: String?

    /// Fractional-index ordering key for `.parent` tunnels
    ///. Siblings under the same parent sort by
    /// ascending `orderKey`. Nil for non-parent tunnel kinds.
    public let orderKey: Double?

    /// Forward-compat JSON extension slot (nullable `ext` column, present
    /// in the tunnels table since the one-`ext`-column-per-persistent-
    /// entity convention landed). MXE-CT3 P2.5 is the first consumer: the
    /// review-ladder endorsement ledger lives here as canonical JSON (see
    /// `TunnelReviewLedger`). Nil for tunnels that have never carried a
    /// review record. Decoded tolerantly from `.json`/`.text` read-back;
    /// unknown keys inside the JSON are preserved on rewrite.
    public let ext: String?

    /// Designated initializer.
    public init(
        id: String,
        sourceWing: String,
        sourceRoom: String,
        sourceDrawerId: String? = nil,
        targetWing: String,
        targetRoom: String,
        targetDrawerId: String? = nil,
        label: String,
        kind: TunnelKind = .references,
        adjectiveBitmap: Int64 = 0,
        operationalBitmap: Int64 = 0,
        provenanceBitmap: Int64 = 0,
        addedBy: String,
        filedAt: Date,
        tombstonedAt: Date? = nil,
        removedByBatch: String? = nil,
        orderKey: Double? = nil,
        ext: String? = nil
    ) {
        self.id = id
        self.sourceWing = sourceWing
        self.sourceRoom = sourceRoom
        self.sourceDrawerId = sourceDrawerId
        self.targetWing = targetWing
        self.targetRoom = targetRoom
        self.targetDrawerId = targetDrawerId
        self.label = label
        self.kind = kind
        self.adjectiveBitmap = adjectiveBitmap
        self.operationalBitmap = operationalBitmap
        self.provenanceBitmap = provenanceBitmap
        self.addedBy = addedBy
        self.filedAt = filedAt
        self.tombstonedAt = tombstonedAt
        self.removedByBatch = removedByBatch
        self.orderKey = orderKey
        self.ext = ext
    }
}

// MARK: - Adjective bitmap accessors

public extension Tunnel {

    /// Decode bits 6–11 of `adjectiveBitmap` as an `AdjectiveSensitivity`.
    ///
    /// Returns `.normal` for unrecognised raw values, matching the estate-level
    /// default access posture (same fail-closed direction as `KGFact.adjectiveSensitivity`
    /// and `Drawer.adjectiveSensitivity`). Named `adjectiveSensitivity` (not `sensitivity`)
    /// to avoid colliding with the provenance-bitmap `sensitivity` accessor. Cookbook
    /// §2.3 6-bit field. Parity peer of Rust `Tunnel::adjective_sensitivity`.
    var adjectiveSensitivity: AdjectiveSensitivity {
        // Cookbook §2.3: sensitivity at bits 6–11 of adjectiveBitmap.
        AdjectiveSensitivity(rawValue: Int(BitField.extractField(adjectiveBitmap, shift: 6, width: 6))) ?? .normal
    }
}
