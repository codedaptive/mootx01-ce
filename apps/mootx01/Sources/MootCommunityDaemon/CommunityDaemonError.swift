// CommunityDaemonError.swift
//
// Typed errors for the community-daemon estate layer (Wave A1a).
//
// Every error path in CommunityEstateHost and CommunitySourceEstateAccess
// throws one of these cases. No silent fallbacks, no Optional returns for
// failure states — every failure is a named, testable, log-able error.
//
// CORE-01 enforcement: these cases cover every failure mode that might
// otherwise tempt a caller into a "try again with a fresh estate" fallback:
//   - corruptManifest: the estate exists but is unreadable — NOT absent
//   - keyMismatch: the file is encrypted with a different key — NOT plaintext
//   - estateLocked: another process holds the WAL write lock — NOT quiesced
//   - walNotEmpty: the WAL has content after a truncating checkpoint — NOT ready
// Each case carries enough context to produce an actionable log line without
// including sensitive data (keys, paths that could expose user home dirs beyond
// what is already in the URL).

import Foundation

/// Errors from the community-daemon estate layer.
public enum CommunityDaemonError: Error, Sendable, Equatable {

    // MARK: - CommunityEstateHost errors

    /// The schema version returned by LocusKit migrations was negative.
    /// This indicates an internal LocusKit inconsistency (e.g. a migration
    /// that decremented the version counter), not a corrupt estate file.
    case unexpectedSchemaVersion(Int)

    // MARK: - CommunitySourceEstateAccess errors

    /// `openExclusive()` was called on an already-open connection.
    /// The migration machine must call `close()` before re-opening.
    case alreadyOpen(URL)

    /// The connection is not open, but a SQLite operation was requested.
    /// Indicates a caller logic error (operations called out of order).
    case notOpen(URL)

    /// The estate file is locked by another process.
    /// The `ProviderLock` should prevent this in normal operation; this
    /// case surfaces if the lock is bypassed or the lock file is stale.
    case estateLocked(URL)

    /// The SQLCipher key did not match the estate's encryption.
    /// Possible causes: key rotation without estate re-encryption, wrong
    /// Keychain account, or a plaintext estate opened with a non-nil key.
    case keyMismatch(URL)

    /// The manifest table is absent, unreadable, or carries a malformed value.
    /// The attached string is a diagnostic — NOT the raw SQL error, which could
    /// carry key material; only field names and expected-vs-found summaries.
    case corruptManifest(URL, String)

    /// The WAL file is non-empty after a truncating checkpoint.
    /// Carries the WAL path and its observed byte count for the log.
    case walNotEmpty(URL, Int)

    /// A raw SQLCipher C API call returned a non-SQLITE_OK result code.
    /// `Int32` is the `rc` value from the C call; the `String` is a
    /// sanitized error message (never containing key material).
    case sqliteError(Int32, String)

    /// A manifest query returned zero rows (a required key was missing).
    case missingManifestKey(URL, String)

    /// The estate file does not exist at the expected path.
    ///
    /// Thrown by `requireEstate()` implementations when the caller attempts to
    /// open an estate that has not been created yet. Surfaces the fail-closed
    /// gate: capture, review, and LAN coordinators must not create the estate
    /// file as a side-effect of being called — that responsibility belongs to
    /// the lifecycle coordinator's `estate_create` endpoint.
    case estateAbsent(URL)
}
