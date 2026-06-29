// Node.swift
//
// Container node in the estate's containment tree (ADR-017 §1–§2).
//
// The estate is a fixed-depth tree: estate (depth 0), wing (depth 1),
// room (depth 2). Drawers are leaf nodes and live in the `drawers`
// table, not the `nodes` table. Container nodes carry lifecycle state
// (active/tombstoned) with HLC timestamps for temporal filtering,
// supporting the as-of read surface (NT-P1).
//
// Two name fields (§8): `displayName` preserves first-writer casing;
// `lookupName` is normalized (NFC + casefold + whitespace-collapse)
// and used for resolution and uniqueness enforcement.

import Foundation
import SubstrateTypes

/// A container node in the estate's containment tree.
///
/// Nodes represent the structural skeleton: estate root, wings, and
/// rooms. Drawers reference their parent room via `parent_node_id`
/// on the drawers table (NT-L2). The `merkleRoot` field carries the
/// per-node SHA-256 hash populated by `MerkleRollup`; current capture
/// paths defer rollup rather than computing it inline.
public struct Node: Sendable, Equatable, Codable, Hashable {

    /// Stable UUID identifier for this node.
    public let id: UUID

    /// Parent node UUID. Nil only for the estate root (depth 0).
    public let parentId: UUID?

    /// Human-readable name preserving first-writer casing (§8).
    public let displayName: String

    /// Normalized resolution key: NFC + casefold + whitespace-collapse (§8).
    /// All resolution, uniqueness enforcement, and index keys use this field.
    public let lookupName: String

    /// Tree depth: 0 = estate, 1 = wing, 2 = room. Write-once, no reparent.
    public let depth: Int

    /// Lifecycle state: 0 = active, 1 = tombstoned (§5).
    public var lifecycle: Int

    /// HLC at node creation — temporal floor for as-of filter.
    public let createdHlc: HLC

    /// HLC at tombstone transition; nil while active (§5, §15).
    /// As-of test: createdHlc <= T AND (tombstonedHlc == nil OR tombstonedHlc > T).
    public var tombstonedHlc: HLC?

    /// Wall-clock mirror of tombstonedHlc, for display only.
    /// Never used in temporal filtering — wall time is not HLC-comparable.
    public var tombstonedAt: Date?

    /// Per-node Merkle content-integrity root (§16). Stored as a 32-byte
    /// BLOB in SQLite. Nil until `MerkleRollup` populates it;
    /// hash-on-write applies to drawer content hashes, not node roots.
    public var merkleRoot: MerkleRoot?

    /// Wall-clock creation timestamp (ISO8601 TEXT in SQLite).
    public let createdAt: Date

    /// Wall-clock last-update timestamp (ISO8601 TEXT in SQLite).
    public var updatedAt: Date

    /// Forward-compat JSON extension slot (ADR-012). Nil in 1.0.
    public var ext: String?

    public init(
        id: UUID,
        parentId: UUID?,
        displayName: String,
        lookupName: String,
        depth: Int,
        lifecycle: Int = 0,
        createdHlc: HLC,
        tombstonedHlc: HLC? = nil,
        tombstonedAt: Date? = nil,
        merkleRoot: MerkleRoot? = nil,
        createdAt: Date,
        updatedAt: Date,
        ext: String? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.displayName = displayName
        self.lookupName = lookupName
        self.depth = depth
        self.lifecycle = lifecycle
        self.createdHlc = createdHlc
        self.tombstonedHlc = tombstonedHlc
        self.tombstonedAt = tombstonedAt
        self.merkleRoot = merkleRoot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ext = ext
    }

    /// Whether this node is active (not tombstoned).
    public var isActive: Bool {
        lifecycle == 0
    }

    /// Whether this node has been tombstoned.
    public var isTombstoned: Bool {
        lifecycle == 1
    }

    // MARK: - Name normalization (§8)

    /// Derive a lookup name from a display name: Unicode NFC, trim,
    /// collapse internal whitespace to single spaces, then Unicode casefold.
    /// Conformance-gated: Swift and Rust must produce byte-identical results.
    public static func normalizeLookupName(_ displayName: String) -> String {
        let nfc = displayName.precomposedStringWithCanonicalMapping
        let trimmed = nfc.trimmingCharacters(in: .whitespaces)
        let collapsed = trimmed.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.lowercased()
    }
}
