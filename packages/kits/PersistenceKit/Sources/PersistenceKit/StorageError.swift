// StorageError.swift

import Foundation

public enum StorageError: Error, Sendable, Equatable {
    case backendUnavailable(reason: String)
    case schemaMismatch(expected: Int, actual: Int)
    case migrationFailed(version: Int, reason: String)
    case constraintViolation(detail: String)
    case poolExhausted(timeout: TimeInterval)
    case transactionConflict(detail: String)
    case typeMismatch(column: String, expected: ColumnType, actual: String)
    case rowNotFound(table: String, key: String)
    case duplicateKey(table: String, key: String)
    case invalidQuery(detail: String)
    case appendOnlyViolation(table: String)
    case backendError(underlying: String)
    /// A stored value could not be parsed back to its declared type. The
    /// `storedText` field carries the raw string from SQLite for diagnosis.
    /// This is thrown instead of silently substituting a default (e.g. a random
    /// UUID or epoch-0 timestamp) so callers know their data is corrupt.
    case corruptStoredValue(table: String, column: String, storedText: String)
    /// The supplied `EstateConfiguration` contains a value that is invalid for
    /// the current platform or runtime. For example, selecting `.nlTagger` on
    /// a non-Apple platform (where `NaturalLanguage` is unavailable) produces
    /// this error at configuration validation time. Fail-closed: an invalid
    /// configuration is rejected before any storage is opened.
    case invalidConfiguration(reason: String)
    /// A storage surface exists but is gated off until prerequisite missions
    /// land. The `feature` string names the gate so the caller knows which
    /// capability is unavailable and why.
    ///
    /// The as-of query gate (ADR-017 §17) stays closed until NT-L4
    /// (lineage-wide expunge) and NT-P3 (erasure overlay) merge, preventing
    /// the governance defect where an as-of read resurfaces un-erased payload
    /// from a superseded lineage version.
    case featureGated(feature: String)
    /// A caller-supplied SQL identifier (column name, table name) contains
    /// characters outside the safe set `[A-Za-z_][A-Za-z0-9_]*`. Allowing
    /// arbitrary identifiers into a dynamically-constructed SELECT list is a
    /// SQL-injection vector even when the name is double-quoted, because a
    /// name containing `"` can break out of the quoting and alter the query.
    /// Planned hardening landed 2026-06-28 (SECFIX-WS2-PK).
    case invalidIdentifier(name: String)
}
