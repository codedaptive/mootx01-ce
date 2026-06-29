// SnapshotId.swift
//
// Typed UUID wrapper for snapshot identifiers per ADR-017 §15.
// Each snapshot in the snapshot registry carries a unique
// SnapshotId that distinguishes it from drawer IDs, node IDs,
// and estate IDs at the type level.

import Foundation

/// Unique identifier for a point-in-time snapshot of an estate.
///
/// SnapshotId is a UUID wrapper that prevents accidental
/// substitution of drawer, node, or estate identifiers where
/// a snapshot identifier is expected.
public struct SnapshotId: Hashable, Sendable, Codable, CustomStringConvertible {

    /// The underlying UUID value.
    public let uuid: UUID

    /// Creates a SnapshotId from a UUID.
    public init(_ uuid: UUID) {
        self.uuid = uuid
    }

    /// Creates a new random SnapshotId.
    public init() {
        self.uuid = UUID()
    }

    /// Creates a SnapshotId from a UUID string.
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.uuid = uuid
    }

    /// The UUID string representation.
    public var uuidString: String { uuid.uuidString }

    public var description: String { uuid.uuidString }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw SnapshotIdError.invalidUUID(string)
        }
        self.uuid = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid.uuidString)
    }
}

/// Errors for SnapshotId construction from external input.
public enum SnapshotIdError: Error, Sendable {
    case invalidUUID(String)
}
