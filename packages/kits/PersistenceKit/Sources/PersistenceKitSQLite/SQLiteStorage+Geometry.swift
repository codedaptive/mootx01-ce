// SQLiteStorage+Geometry.swift
//
// Geometry-normalization surface operation for SQLiteStorage.
//
// Adds the `normalizeGeometry()` StorageMaintenance method, a module-internal
// `SQLiteConnection.reopenAfterGeometrySwap()` helper, and the full repair
// sequence on `SQLiteBackend`.
//
// Zero diff on SQLiteStorage.swift and SQLiteConnection.swift: all geometry code
// lives here in the same PersistenceKitSQLite module, giving full access to the
// `internal` members of both types without touching those files.

import Foundation
import SQLCipher
import PersistenceKit
import OSLog

// MARK: - SQLiteStorage: normalizeGeometry (StorageMaintenance override)

extension SQLiteStorage {
    /// Delegate geometry normalization to the backend actor.
    /// Overrides the default no-op from the StorageMaintenance extension.
    public func normalizeGeometry() async throws -> GeometryNormalizationReport {
        try await backend.normalizeGeometry()
    }
}

// MARK: - SQLiteBackend: geometry normalization

extension SQLiteBackend {

    private static let logger = Logger(
        subsystem: "com.mootx01.kit", category: "PersistenceKitSQLite")

    /// Detect and repair foreign SQLite geometry (nonzero reserved-bytes-per-page).
    ///
    /// The SQLCipher `attachFunc` heuristic (sqlite3.c `sqlcipherCodecAttach`)
    /// inspects `sqlite3BtreeGetRequestedReserve(db->aDb[0].pBt)`: when the main
    /// database has nonzero reserve bytes (file header byte 20 ≠ 0, as set by
    /// Apple's SEE-provisioned `/usr/bin/sqlite3` for per-page IVs), it calls
    /// `sqlcipherCodecAttach(nKey=0)` even for keyless ATTACHes. This fails with
    /// SQLITE_ERROR "unable to open database", blocking VACUUM and all maintenance.
    ///
    /// Repair sequence (V3 chain, proven):
    ///   1. WAL checkpoint (TRUNCATE) — consolidate all data in the main file.
    ///   2. Create a fresh sibling file at `<url>.geo_normalize_tmp.sqlite3`.
    ///   3. `ATTACH '<sibling>' AS heal KEY '';` — the empty-string KEY sets nKey=0
    ///      at the application layer, bypassing the heuristic that fires for codec
    ///      nKey=0 on the already-decoded main schema.
    ///   4. `SELECT sqlcipher_export('heal');` — copy all content to the sibling.
    ///   5. `DETACH heal;`
    ///   6. Verify sibling header byte 20 == 0.
    ///   7. Atomic `rename()` — replace the original file with the sibling.
    ///   8. Reopen the connection on the normalized file.
    ///   9. Remove any stale -wal/-shm sidecars from the pre-swap path.
    ///
    /// Mode-3 (fullDatabase) estates are skipped: SQLCipher manages their reserve
    /// bytes for per-page authentication; normalizing them would corrupt the estate.
    func normalizeGeometry() throws -> GeometryNormalizationReport {
        // Skip encrypted estates — their reserve bytes belong to SQLCipher.
        guard encryptionConfig.mode != .fullDatabase else {
            return .noOp()
        }

        let started = Date()
        let reserve = Self.readReserveBytes(at: connection.url)
        guard reserve != 0 else {
            // Already at reserve=0 — nothing to do.
            return .noOp()
        }

        Self.logger.info(
            "geometry normalization: reserve=\(reserve) at \(self.connection.url.lastPathComponent, privacy: .private) — starting repair")

        // Step 1: checkpoint WAL so all committed pages are in the main file.
        try connection.exec("PRAGMA wal_checkpoint(TRUNCATE);")

        // Step 2: create the sibling destination file.
        let siblingURL = connection.url
            .deletingLastPathComponent()
            .appendingPathComponent(
                connection.url.deletingPathExtension().lastPathComponent
                + ".geo_normalize_tmp.sqlite3"
            )
        // Best-effort: remove a stale sibling left by a prior interrupted run.
        try? FileManager.default.removeItem(at: siblingURL)

        // Step 3-5: export through the empty-key ATTACH escape hatch.
        // KEY '' (empty string) sets nKey=0 at the application layer. This is
        // distinct from the codec path that fires when the main database has
        // nonzero reserve: the codec path is rejected; the application-layer empty
        // key is accepted and creates a standard plaintext ATTACH.
        let siblingSQL = sqlQuoted(siblingURL.path)
        try connection.exec("ATTACH \(siblingSQL) AS heal KEY '';")
        try connection.exec("SELECT sqlcipher_export('heal');")
        try connection.exec("DETACH heal;")

        // Step 6: verify the sibling has reserve=0.
        let siblingReserve = Self.readReserveBytes(at: siblingURL)
        guard siblingReserve == 0 else {
            try? FileManager.default.removeItem(at: siblingURL)
            throw StorageError.backendError(
                underlying: "geometry normalization: sibling has unexpected reserve=\(siblingReserve)")
        }

        // Step 7: close the connection before the atomic rename.
        // After close(), handle == nil. From this point any error is fatal to the
        // estate's connection; best-effort recovery below.
        connection.close()

        // Atomic rename: replaces the original (reserve=12) with the sibling (reserve=0).
        // POSIX rename() is atomic on the same filesystem — safe against crash halfway.
        let renameRC = rename(siblingURL.path, connection.url.path)
        guard renameRC == 0 else {
            let err = errno
            // Best-effort: try to put the sibling back if rename failed.
            try? FileManager.default.moveItem(at: siblingURL, to: connection.url)
            throw StorageError.backendError(
                underlying: "geometry normalization: rename errno=\(err)")
        }

        // Step 8: reopen the connection on the normalized file.
        try connection.reopenAfterGeometrySwap()

        // Step 9: remove stale WAL and SHM files from the original path.
        // These sidecars belong to the pre-swap connection and are now orphaned.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: connection.url.path + suffix)
        }

        let elapsed = Date().timeIntervalSince(started)
        Self.logger.info(
            "geometry normalization: complete in \(String(format: "%.3f", elapsed))s for \(self.connection.url.lastPathComponent, privacy: .private)")

        return GeometryNormalizationReport(
            normalized: true,
            reserveBytesBefore: reserve,
            durationSeconds: elapsed)
    }

    /// Read the SQLite 3 file-header reserved-bytes-per-page field (byte 20).
    /// Returns 0 when the file is absent, too short, or unreadable — treating
    /// any unreadable estate as already-normalized (safe: VACUUM will surface the
    /// real error when it runs).
    private static func readReserveBytes(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 100 else {
            return 0
        }
        // SQLite file format 3 §1.3.8: offset 20 = "Reserved space per page."
        // Valid range 0–255. Apple's SEE sqlite3 sets this to 12 for per-page IVs.
        return Int(data[20])
    }

    /// SQL single-quote-escape a file path for use in ATTACH … AS … syntax.
    /// Matches the pattern from EstateEncryptionMigrator.sqlQuoted.
    private func sqlQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

// MARK: - SQLiteConnection: reopen after geometry swap

extension SQLiteConnection {

    /// Reopen the connection after the geometry-normalization atomic file swap.
    ///
    /// Precondition: `close()` has been called (handle == nil). The file at
    /// `url` is the freshly-renamed normalized sibling.
    ///
    /// Replicates the setup pragmas from `init` without the symlink guard (the
    /// file was just created by us) and without the keyHex PRAGMA (geometry
    /// normalization only runs on plaintext estates). `applyDataProtection` is
    /// private static on SQLiteConnection and unreachable from this file; the
    /// two-line logic is reproduced inline here.
    func reopenAfterGeometrySwap() throws {
        precondition(handle == nil, "reopenAfterGeometrySwap: connection must be closed first")

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var newHandle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &newHandle, flags, nil)
        guard rc == SQLITE_OK, let newHandle else {
            let msg = newHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "reopen failed"
            sqlite3_close(newHandle)
            throw StorageError.backendError(
                underlying: "geometry reopen: \(msg)")
        }
        handle = newHandle

        // Data Protection: completeUntilFirstUserAuthentication. Mirrors the logic
        // in the private `applyDataProtection(to:)` on SQLiteConnection — reproduced
        // inline because private is file-scoped in Swift and unreachable from here.
        let dpAttributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        try? FileManager.default.setAttributes(dpAttributes, ofItemAtPath: url.path)

        // 0600 permissions on the normalized file (owner read/write only).
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
        }

        // Re-run setup pragmas — mirrors SQLiteConnection.init after the key PRAGMA.
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA wal_autocheckpoint = 1000;")
        try exec("PRAGMA busy_timeout = \(Int(busyTimeout * 1000));")
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA mmap_size = 2147483648;")

        // Raise SQLITE_LIMIT_LENGTH to the compile-time maximum (matching SQLiteConnection.init
        // comment: eliminates multi-GB heap allocations for vector BLOBs on large estates).
        _ = sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 0x7ffffffd)
    }
}
