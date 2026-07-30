// SyncMetadataField.swift
//
// Canonical CloudKit wire keys for ConvergenceKit metadata.
//
// CloudKit reserves leading-underscore record fields for system use. Client
// saves that contain names such as `_syncDeleted` fail with
// CKError.permissionFailure before the record reaches the custom zone. These
// names therefore begin with the product namespace `moot_`, followed by the
// sync role, and are shared by encoding, decoding, tombstones, and manifest
// validation so those paths cannot drift independently.

/// Client-writable CloudKit field names reserved for ConvergenceKit metadata.
package enum SyncMetadataField {
    /// Namespace reserved for current and future ConvergenceKit wire metadata.
    package static let namespacePrefix = "moot_sync_"

    /// Packed row-level hybrid logical clock.
    package static let hlc = namespacePrefix + "hlc"

    /// Schema version that encoded the record.
    package static let schemaVersion = namespacePrefix + "schema_version"

    /// Sync manifest kit identifier.
    package static let kitID = namespacePrefix + "kit_id"

    /// JSON-encoded per-column hybrid logical clocks.
    package static let columnHLCs = namespacePrefix + "column_hlcs"

    /// JSON map that restores `TypedValue` discriminators after CloudKit transit.
    package static let typeTags = namespacePrefix + "type_tags"

    /// Marker whose numeric value `1` identifies a typed delete tombstone.
    package static let deleted = namespacePrefix + "deleted"

    /// The complete reserved wire-key set.
    package static let all: Set<String> = [
        hlc,
        schemaVersion,
        kitID,
        columnHLCs,
        typeTags,
        deleted,
    ]

    /// Whether an application column collides with current or future sync metadata.
    package static func isReserved(_ field: String) -> Bool {
        field.hasPrefix(namespacePrefix)
    }
}
