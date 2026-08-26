// CommunitySourceEstateAccess.swift
//
// Production SourceEstateAccess for the census identity tier.
//
// Wave A1a: the first production conformer of SourceEstateAccess.
// DefaultEstateMigrator uses SourceEstateAccess for:
//   - openExclusive: quiesce the source estate (exclusive lock; no new writers)
//   - checkpointTruncate: fold WAL into main, truncate WAL to zero
//   - verifyEmptyWAL: file-level proof the WAL is empty (absence-of-error ≠ proof)
//   - readIdentity: read estate_uuid, schema_version, anchor counts
//   - close: release the exclusive lock and close the connection
//   - verifyReadOnlyOpen: open destination read-only, run integrity_check, read identity
//
// WHY RAW SQLCipher API:
// SQLiteConnection (PersistenceKitSQLite) is internal to its module.
// SQLiteStorage exposes a high-level `async Storage` surface but does not expose
// `PRAGMA locking_mode=EXCLUSIVE`, `PRAGMA wal_checkpoint(TRUNCATE)`, or raw
// prepared-statement reads of arbitrary tables. This conformer needs all three,
// so it reaches below the high-level API by importing SQLCipher (exported from
// the PersistenceKit package) and using the C API directly.
//
// KEY DISCIPLINE:
// The 32-byte raw key is injected as `Data?` at construction — nil for plaintext
// estates, non-nil for SQLCipher full-database-encrypted estates. This module
// never touches the Keychain; the caller (census observer, test) supplies the key.
// The hex conversion (`map { String(format: "%02x", $0) }.joined()`) stays local
// to the two sites that need it (exclusive open, verifyReadOnlyOpen) and the
// hex string is never logged or stored.
//
// CORE-01 enforcement:
// openExclusive does NOT pass SQLITE_OPEN_CREATE — the file MUST exist.
// Creating a new file would violate CORE-01 (empty path ≠ permission to replace).

import Foundation
import OSLog
import SQLCipher
import MootDaemonProvider

private let log = Logger(subsystem: "com.mootx01", category: "CommunitySourceEstateAccess")

/// Production `SourceEstateAccess` conformer for the census identity tier.
///
/// Provides raw SQLite-semantic access to a source estate file via the
/// SQLCipher C API. Used by `DefaultEstateMigrator` to quiesce the source
/// (exclusive open + truncating WAL checkpoint), read its identity (UUID,
/// schema version, anchor counts), and verify the copy (read-only open +
/// integrity check).
///
/// ## Concurrency
/// Actor-isolated. The `sqlite3*` handle is accessed only on this actor's
/// executor. All operations are synchronous C API calls that complete without
/// external blocking; actor serialization prevents concurrent handle access.
///
/// ## Key injection
/// `keyBytes: Data?` is nil for plaintext estates, 32 bytes for SQLCipher
/// full-database-encrypted estates. Never logs key material.
public actor CommunitySourceEstateAccess: SourceEstateAccess {

    // MARK: - Injected state

    /// Absolute path to the estate's main `.sqlite` file.
    private let estateURL: URL

    /// Raw SQLCipher key bytes, or `nil` for plaintext estates.
    /// 32 bytes for Mode 3 / FullDatabase key. Never stored as hex.
    private let keyBytes: Data?

    // MARK: - Actor-isolated connection state

    /// The open SQLite connection, or `nil` when closed.
    /// Non-nil only between `openExclusive()` and `close()`.
    private var handle: OpaquePointer?

    // MARK: - Init

    /// Create an access object for the estate at `estateURL`.
    ///
    /// - Parameters:
    ///   - estateURL: Absolute path to the estate's `.sqlite` file.
    ///   - keyBytes: 32-byte SQLCipher key for encrypted estates, or `nil`
    ///     for plaintext estates. This module never derives or stores the key.
    public init(estateURL: URL, keyBytes: Data?) {
        self.estateURL = estateURL
        self.keyBytes = keyBytes
    }

    // MARK: - SourceEstateAccess

    /// Open the estate file EXCLUSIVELY — no other writer may hold the WAL lock.
    ///
    /// Uses `PRAGMA locking_mode=EXCLUSIVE` and a lightweight read to
    /// acquire the WAL write lock before returning. Once held, no other connection
    /// can acquire a write lock until `close()` releases it.
    ///
    /// Does NOT pass `SQLITE_OPEN_CREATE` (CORE-01: an empty path is not
    /// permission to create a new estate). If the file does not exist, the open
    /// fails with `.sqliteError(SQLITE_CANTOPEN, ...)`.
    ///
    /// Throws `CommunityDaemonError.alreadyOpen` if called a second time
    /// without an intervening `close()`.
    public func openExclusive() async throws {
        guard handle == nil else {
            // The migration machine must call close() before re-opening.
            throw CommunityDaemonError.alreadyOpen(estateURL)
        }

        // READWRITE only — no CREATE (CORE-01). Fail if the file does not exist.
        let flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        var newHandle: OpaquePointer?
        let rc = sqlite3_open_v2(estateURL.path, &newHandle, flags, nil)
        guard rc == SQLITE_OK, let h = newHandle else {
            let msg = newHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            sqlite3_close(newHandle)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                throw CommunityDaemonError.estateLocked(estateURL)
            }
            throw CommunityDaemonError.sqliteError(rc, "exclusive open: \(msg)")
        }

        // Apply the encryption key BEFORE any other access so SQLCipher can
        // decrypt page 1 (which contains the database schema). If this fails,
        // the key does not match the estate's encryption — a fail-closed condition.
        if let keyBytes = keyBytes {
            // Raw key (not passphrase): `PRAGMA key = "x'<hex>'"` uses the
            // 32 bytes directly as the cipher key, bypassing the KDF.
            // The hex string is computed inline and never stored or logged.
            let keyHex = keyBytes.map { String(format: "%02x", $0) }.joined()
            let keySql = "PRAGMA key = \"x'\(keyHex)'\";"
            let keyRc = sqlite3_exec(h, keySql, nil, nil, nil)
            if keyRc != SQLITE_OK {
                // Do NOT include the key in the error — only the URL.
                sqlite3_close(h)
                throw CommunityDaemonError.keyMismatch(estateURL)
            }
        }

        // Set locking mode to EXCLUSIVE: after the first subsequent read, this
        // connection will hold the WAL write lock for its entire lifetime,
        // preventing any other writer from opening the estate.
        let lockRc = sqlite3_exec(h, "PRAGMA locking_mode=EXCLUSIVE;", nil, nil, nil)
        if lockRc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(h))
            sqlite3_close(h)
            throw CommunityDaemonError.sqliteError(lockRc, "locking_mode=EXCLUSIVE: \(msg)")
        }

        // Acquire the lock by issuing a lightweight read. PRAGMA locking_mode=EXCLUSIVE
        // does not immediately claim the WAL write lock — the first read or write does.
        // A schema read is cheap and acquires the necessary lock without modifying data.
        let readRc = sqlite3_exec(h, "SELECT count(*) FROM sqlite_master;", nil, nil, nil)
        if readRc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(h))
            sqlite3_close(h)
            if readRc == SQLITE_BUSY || readRc == SQLITE_LOCKED {
                throw CommunityDaemonError.estateLocked(estateURL)
            }
            throw CommunityDaemonError.sqliteError(readRc, "lock acquisition read: \(msg)")
        }

        self.handle = h
        log.debug("exclusive open acquired: \(self.estateURL.lastPathComponent)")
    }

    /// Run `PRAGMA wal_checkpoint(TRUNCATE)`.
    ///
    /// Folds all WAL frames into the main database file and truncates the WAL
    /// file to zero bytes. Requires the exclusive connection from `openExclusive()`.
    ///
    /// The returned `log` and `checkpointed` values from `sqlite3_wal_checkpoint_v2`
    /// are logged at debug level; a non-OK result code throws.
    public func checkpointTruncate() async throws {
        let h = try requireOpen()
        var walFrameCount: Int32 = 0
        var checkpointedFrames: Int32 = 0
        // SQLITE_CHECKPOINT_TRUNCATE: checkpoint all frames, then truncate the
        // WAL file to zero bytes. Requires that no other reader is open — the
        // exclusive lock from openExclusive() ensures this.
        let rc = sqlite3_wal_checkpoint_v2(
            h, nil, SQLITE_CHECKPOINT_TRUNCATE, &walFrameCount, &checkpointedFrames
        )
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(h))
            throw CommunityDaemonError.sqliteError(rc, "PRAGMA wal_checkpoint(TRUNCATE): \(msg)")
        }
        log.debug(
            "checkpoint TRUNCATE: walFrames=\(walFrameCount) checkpointed=\(checkpointedFrames) file=\(self.estateURL.lastPathComponent)"
        )
    }

    /// Positive proof the WAL is empty: the WAL file must be absent or zero bytes.
    ///
    /// Absence of an error is NOT proof of emptiness (KONG-2 conservatism).
    /// This method explicitly stats the WAL file and fails if it has content.
    ///
    /// A missing WAL file is the expected state after a successful TRUNCATE
    /// checkpoint on an exclusive connection.
    public func verifyEmptyWAL() async throws {
        let walURL = URL(fileURLWithPath: estateURL.path + "-wal")

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: walURL.path)
        } catch {
            // WAL file absent: this is the expected success state after TRUNCATE.
            return
        }

        let size = (attrs[.size] as? Int) ?? 0
        guard size == 0 else {
            // Non-empty WAL: the checkpoint did not drain all frames, or the
            // WAL was written by another connection after the checkpoint.
            throw CommunityDaemonError.walNotEmpty(walURL, size)
        }
    }

    /// Read the estate's identity from the manifest table.
    ///
    /// Queries:
    ///   - `manifest WHERE key='estate_uuid'` → UUID
    ///   - `manifest WHERE key='schema_version'` → version string
    ///   - `COUNT(*) FROM drawers` → anchor count
    ///   - `COUNT(*) FROM kg_facts` → anchor count
    ///
    /// Fails closed if any required field is absent or malformed.
    public func readIdentity() async throws -> CensusIdentity {
        let h = try requireOpen()
        return try readIdentityFrom(h, url: estateURL)
    }

    /// Close the estate. After this call, no open authority exists for it.
    ///
    /// Idempotent: calling `close()` on an already-closed access object is a no-op.
    public func close() async throws {
        guard let h = handle else { return }
        sqlite3_close(h)
        self.handle = nil
        log.debug("closed: \(self.estateURL.lastPathComponent)")
    }

    /// Open the COPIED database at `destination` read-only, run
    /// `PRAGMA integrity_check`, and return its identity.
    ///
    /// The destination is NEVER opened with write access or `SQLITE_OPEN_CREATE`.
    /// If the file does not exist, throws `.sqliteError(SQLITE_CANTOPEN, ...)`.
    public func verifyReadOnlyOpen(destination: URL) async throws -> CensusIdentity {
        // READONLY | no CREATE: fail if the file doesn't exist.
        let flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        var verifyHandle: OpaquePointer?
        let rc = sqlite3_open_v2(destination.path, &verifyHandle, flags, nil)
        guard rc == SQLITE_OK, let h = verifyHandle else {
            let msg = verifyHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(verifyHandle)
            throw CommunityDaemonError.sqliteError(rc, "read-only open of destination: \(msg)")
        }
        defer { sqlite3_close(h) }

        // Apply the encryption key on the read-only handle before any reads.
        if let keyBytes = keyBytes {
            let keyHex = keyBytes.map { String(format: "%02x", $0) }.joined()
            let keySql = "PRAGMA key = \"x'\(keyHex)'\";"
            let keyRc = sqlite3_exec(h, keySql, nil, nil, nil)
            if keyRc != SQLITE_OK {
                throw CommunityDaemonError.keyMismatch(destination)
            }
        }

        // integrity_check(1): ask SQLite to verify page checksums. The `(1)` limit
        // stops after the first error, which is enough for a fail/pass signal.
        // A non-OK sqlite3_exec result (not SQLITE_OK from the statement machinery)
        // indicates a driver-level failure, not a logical integrity failure.
        // For logical failures (e.g. "corruption detected at page N"), SQLite
        // returns SQLITE_OK from exec but surfaces the result in the callback;
        // we use a callback to capture the integrity_check output.
        var integrityOK = true
        let integrityRc = sqlite3_exec(
            h,
            "PRAGMA integrity_check(1);",
            { context, _, values, _ -> Int32 in
                // The callback is called once per result row. A clean database
                // returns one row: "ok". Any other value is a failure.
                guard let context, let vals = values, let first = vals[0] else {
                    return SQLITE_OK
                }
                let result = String(cString: first)
                if result != "ok" {
                    // Store the failure signal in the context pointer (reinterpreted
                    // as a Bool pointer that we control).
                    let ptr = context.assumingMemoryBound(to: Bool.self)
                    ptr.pointee = false
                }
                return SQLITE_OK
            },
            &integrityOK,
            nil
        )
        if integrityRc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(h))
            throw CommunityDaemonError.sqliteError(integrityRc, "integrity_check exec: \(msg)")
        }
        guard integrityOK else {
            throw CommunityDaemonError.sqliteError(
                SQLITE_CORRUPT,
                "integrity_check reported corruption in destination copy"
            )
        }

        return try readIdentityFrom(h, url: destination)
    }

    // MARK: - Private helpers

    /// Fail if there is no open connection.
    private func requireOpen() throws -> OpaquePointer {
        guard let h = handle else {
            throw CommunityDaemonError.notOpen(estateURL)
        }
        return h
    }

    /// Read the identity block from an already-open `sqlite3*` handle.
    ///
    /// Used by both `readIdentity()` (on the exclusive source connection) and
    /// `verifyReadOnlyOpen(destination:)` (on the read-only destination connection).
    private func readIdentityFrom(_ h: OpaquePointer, url: URL) throws -> CensusIdentity {
        // Read estate_uuid — the estate's true identity.
        let estateUUIDString = try querySingleString(
            h, url: url,
            sql: "SELECT value FROM manifest WHERE key='estate_uuid' LIMIT 1;",
            field: "estate_uuid"
        )
        guard let estateUUID = UUID(uuidString: estateUUIDString) else {
            throw CommunityDaemonError.corruptManifest(
                url, "estate_uuid is not a valid UUID: \(estateUUIDString)"
            )
        }

        // Read schema_version — carried in the manifest as a human-readable
        // string (e.g. "1.1" for the LocusKit estate format version).
        // The CensusIdentity.schemaVersion is UInt64; we encode "major.minor"
        // as `(major << 16) | minor` for stable numeric comparison.
        let schemaVersionString = try querySingleString(
            h, url: url,
            sql: "SELECT value FROM manifest WHERE key='schema_version' LIMIT 1;",
            field: "schema_version"
        )
        let schemaVersion: UInt64 = try parseSchemaVersion(schemaVersionString, url: url)

        // Read anchor counts for receipt binding and post-copy verification.
        let drawerCount = try queryRowCount(h, url: url, table: "drawers")
        let kgFactCount = try queryRowCount(h, url: url, table: "kg_facts")

        return CensusIdentity(
            estateIdentifier: estateUUID,
            schemaVersion: schemaVersion,
            anchorCounts: ["drawers": drawerCount, "kg_facts": kgFactCount]
        )
    }

    /// Query a single string value using a prepared statement.
    ///
    /// Throws `CommunityDaemonError.missingManifestKey` if the query returns
    /// zero rows (a required manifest key is absent).
    private func querySingleString(
        _ h: OpaquePointer,
        url: URL,
        sql: String,
        field: String
    ) throws -> String {
        var stmt: OpaquePointer?
        let prepRc = sqlite3_prepare_v2(h, sql, -1, &stmt, nil)
        guard prepRc == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(h))
            throw CommunityDaemonError.sqliteError(prepRc, "prepare for \(field): \(msg)")
        }
        defer { sqlite3_finalize(s) }

        let stepRc = sqlite3_step(s)
        guard stepRc == SQLITE_ROW else {
            if stepRc == SQLITE_DONE {
                throw CommunityDaemonError.missingManifestKey(url, field)
            }
            let msg = String(cString: sqlite3_errmsg(h))
            throw CommunityDaemonError.sqliteError(stepRc, "step for \(field): \(msg)")
        }

        guard let raw = sqlite3_column_text(s, 0) else {
            throw CommunityDaemonError.corruptManifest(url, "\(field) value is NULL")
        }
        return String(cString: raw)
    }

    /// Count rows in `table` using `COUNT(*)`.
    private func queryRowCount(
        _ h: OpaquePointer,
        url: URL,
        table: String
    ) throws -> UInt64 {
        // Table name is controlled by this module (never user input), so
        // interpolation is safe. No SQL injection vector.
        let sql = "SELECT COUNT(*) FROM \"\(table)\";"
        var stmt: OpaquePointer?
        let prepRc = sqlite3_prepare_v2(h, sql, -1, &stmt, nil)
        guard prepRc == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(h))
            throw CommunityDaemonError.sqliteError(prepRc, "prepare COUNT for \(table): \(msg)")
        }
        defer { sqlite3_finalize(s) }

        let stepRc = sqlite3_step(s)
        guard stepRc == SQLITE_ROW else {
            let msg = String(cString: sqlite3_errmsg(h))
            throw CommunityDaemonError.sqliteError(stepRc, "step COUNT for \(table): \(msg)")
        }
        // sqlite3_column_int64 returns 0 for NULL; COUNT(*) never returns NULL.
        return UInt64(max(0, sqlite3_column_int64(s, 0)))
    }

    /// Parse a schema version string to UInt64.
    ///
    /// Accepts two formats:
    ///   - Plain integer (e.g. `"13"`) → returned as-is.
    ///   - "major.minor" (e.g. `"1.1"`) → encoded as `(major << 16) | minor`.
    ///     LocusKit's canonical manifest stores "1.1" as the estate-format version.
    private func parseSchemaVersion(_ s: String, url: URL) throws -> UInt64 {
        if let i = UInt64(s) {
            return i
        }
        let parts = s.split(separator: ".")
        if parts.count == 2, let major = UInt64(parts[0]), let minor = UInt64(parts[1]) {
            // Encode as (major << 16) | minor for stable ordering.
            // This encoding is used consistently across CommunitySourceEstateAccess
            // instances so cross-instance comparisons are meaningful.
            return (major << 16) | minor
        }
        throw CommunityDaemonError.corruptManifest(url, "unparseable schema_version: \(s)")
    }
}
