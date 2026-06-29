// KeyedCommitmentAudit.swift
//
// Audit entry kind for keyed-commitment expunge provenance (ADR-017 §17).
//
// This is a separate entry type from AuditEntry — it records the
// HMAC commitment made at expunge time, not the state transition.
// The entry carries the drawer id, the KeyedCommitmentValue (HMAC
// bytes + key version), the tombstone HLC, and the reason string.
//
// Append-only (G-Set invariant preserved): the log is a grow-only
// set keyed by a deterministic content hash of the entry fields.
//
// Mirror: rust/src/keyed_commitment.rs (KeyedCommitmentAuditEntry
// and CommitmentAuditLog defined alongside the commitment API).

import Foundation
import SubstrateTypes
import SubstrateKernel

/// One immutable entry in the commitment audit log.
///
/// Records that a keyed commitment was made at expunge time, proving
/// the payload existed without retaining a reversible fingerprint of
/// destroyed personal data. The entry is distinct from the existing
/// tombstone audit event — it records the commitment, not the state
/// transition.
public struct KeyedCommitmentAuditEntry: Hashable, Sendable {
    /// Deterministic content hash (32-byte SHA-256) over the entry's
    /// identifying fields, used as the G-Set key for deduplication.
    public let id: [UInt8]
    /// The drawer whose payload was committed before expunge.
    public let drawerId: UUID
    /// The HMAC commitment value (HMAC bytes + key version).
    public let commitment: KeyedCommitmentValue
    /// The HLC at which the tombstone was applied.
    public let tombstoneHLC: HLC
    /// Human-readable reason for the expunge.
    public let reason: String

    public init(
        drawerId: UUID,
        commitment: KeyedCommitmentValue,
        tombstoneHLC: HLC,
        reason: String
    ) {
        self.drawerId = drawerId
        self.commitment = commitment
        self.tombstoneHLC = tombstoneHLC
        self.reason = reason
        // Deterministic content-ID over the identifying fields.
        self.id = Self.computeID(
            drawerId: drawerId,
            commitment: commitment,
            tombstoneHLC: tombstoneHLC,
            reason: reason
        )
    }

    /// Compute a deterministic content ID so two replicas producing
    /// the same logical commitment entry produce identical IDs and
    /// the G-Set deduplicates them.
    private static func computeID(
        drawerId: UUID,
        commitment: KeyedCommitmentValue,
        tombstoneHLC: HLC,
        reason: String
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        // Drawer id: 16 bytes.
        withUnsafeBytes(of: drawerId.uuid) { bytes.append(contentsOf: $0) }
        // HMAC bytes: 32 bytes.
        bytes.append(contentsOf: commitment.hmacBytes)
        // Key version: 8 bytes big-endian.
        let kv = UInt64(bitPattern: Int64(commitment.keyVersion))
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((kv >> shift) & 0xFF))
        }
        // Tombstone HLC wire bytes.
        bytes.append(contentsOf: tombstoneHLC.wireBytes)
        // Reason: UTF-8 with NUL terminator.
        bytes.append(contentsOf: Array(reason.utf8))
        bytes.append(0)
        return SHA256.hash(bytes)
    }
}

/// Grow-only set for keyed-commitment audit entries.
///
/// Mirrors the GSetAuditLog pattern: entries can be added but never
/// removed. Two replicas merge their sets via set union and converge
/// regardless of message order.
public struct CommitmentAuditLog: Sendable {

    /// Backing store keyed by content hash for O(1) dedupe.
    private(set) public var entries: [[UInt8]: KeyedCommitmentAuditEntry]

    public init() {
        self.entries = [:]
    }

    /// Add a single entry. Idempotent: re-adding an entry with the
    /// same content hash is a no-op.
    public mutating func add(_ entry: KeyedCommitmentAuditEntry) {
        entries[entry.id] = entry
    }

    /// CRDT join. Merging two logs is set union of entries.
    public mutating func merge(_ other: CommitmentAuditLog) {
        for (id, entry) in other.entries {
            entries[id] = entry
        }
    }

    public var count: Int { entries.count }

    /// All entries in tombstone-HLC order.
    public var orderedEntries: [KeyedCommitmentAuditEntry] {
        entries.values.sorted { $0.tombstoneHLC < $1.tombstoneHLC }
    }

    /// Entries for a specific drawer.
    public func entries(forDrawer drawerId: UUID) -> [KeyedCommitmentAuditEntry] {
        entries.values
            .filter { $0.drawerId == drawerId }
            .sorted { $0.tombstoneHLC < $1.tombstoneHLC }
    }
}
