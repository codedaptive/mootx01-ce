// EstateEncryptionMigrator.swift
//
// CE-1.0.35-08: the machinery behind `mootx01 upgrade`'s offer to encrypt a
// plaintext default estate. This is the highest-risk surface in the 1.0.35
// set — a bug here costs someone their memories — so the design invariant is
// stated once, here, and every function below serves it:
//
//   EVERY FAILURE PATH LEAVES A WORKING ESTATE AT THE CANONICAL PATH.
//
// The clone is PHYSICAL, via SQLCipher's sqlcipher_export() over an ATTACHed
// encrypted database — never a logical re-import through the capture seam. A
// logical clone would mint new row ids and lose trace rows, fingerprints, and
// the Merkle rollup, and would force a full re-encode. sqlcipher_export()
// copies every table, index, and trigger byte-for-byte at the row level, so
// the encrypted copy is the same estate, not a re-telling of it.
//
// This file talks to the raw sqlite3 C API (vendored SQLCipher amalgamation)
// on purpose: PersistenceKitSQLite's connection type is internal, and the
// migration needs ATTACH/DETACH and count queries on files it must never
// route through the substrate's open path (which has side effects like WAL
// conversion and permission stamping). The amalgamation registers
// sqlcipher_export() as an auto-extension, so it is available on every
// connection with no manual registration.

import Foundation
import SQLCipher

#if os(macOS)

public enum EstateEncryptionMigrator {

    // MARK: - Errors

    /// Why a migration step refused or failed. Messages never carry key
    /// material: the ATTACH statement embeds the key hex, so raw SQL is
    /// deliberately excluded from every error path.
    public enum MigrationError: Error, CustomStringConvertible, Equatable {
        /// The source file is not a readable plaintext SQLite database.
        /// Migrating anything else is refused outright.
        case sourceNotPlaintext(path: String)
        /// A sqlite3 call failed. `step` names the operation, not the SQL.
        case sqlite(step: String, detail: String)

        public var description: String {
            switch self {
            case let .sourceNotPlaintext(path):
                return "refusing to migrate \(path): it is not a readable plaintext SQLite database"
            case let .sqlite(step, detail):
                return "estate encryption \(step) failed: \(detail)"
            }
        }
    }

    // MARK: - Raw-connection helpers

    /// Lowercase hex of the raw 32-byte estate key, for `KEY "x'<hex>'"`.
    /// Never log or embed the result in errors.
    static func keyHex(_ key: Data) -> String {
        key.map { String(format: "%02x", $0) }.joined()
    }

    /// Escape a path for embedding in a single-quoted SQL string literal.
    static func sqlQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Open a raw sqlite3 connection.
    ///
    /// CREATE is included because ATTACHed databases inherit the main
    /// connection's open flags, and the export's ATTACH must be able to
    /// create the encrypted destination. The hazard CREATE would normally
    /// carry — silently minting an empty database over a missing estate —
    /// is closed by the caller: every migration entry point classifies the
    /// source with `detectEstateFileState` first and refuses anything that
    /// is not an existing readable plaintext database.
    static func openRaw(path: String, keyHex: String? = nil) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db = handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (rc \(rc))"
            sqlite3_close(handle)
            throw MigrationError.sqlite(step: "open", detail: detail)
        }
        if let keyHex {
            // Keyed exactly like SQLiteConnection: raw 32 bytes as the cipher
            // key, no passphrase KDF. Executed without embedding the SQL in
            // any error so key hex never leaks.
            if sqlite3_exec(db, "PRAGMA key = \"x'\(keyHex)'\";", nil, nil, nil) != SQLITE_OK {
                let detail = String(cString: sqlite3_errmsg(db))
                sqlite3_close_v2(db)
                throw MigrationError.sqlite(step: "keying", detail: detail)
            }
        }
        return db
    }

    /// Run one statement, mapping failure to `MigrationError`. `step` is the
    /// human name reported on failure; the SQL itself is never reported.
    static func exec(_ db: OpaquePointer, sql: String, step: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let detail = errMsg.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errMsg { sqlite3_free(errMsg) }
            throw MigrationError.sqlite(step: step, detail: detail)
        }
    }

    /// Remove a database file and its `-wal`/`-shm` siblings, best-effort.
    static func removeDatabase(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(at: url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + suffix))
        }
    }

    // MARK: - Part 2: the clone

    /// Clone the plaintext estate at `source` into a NEW encrypted database
    /// at `destination`, keyed with `key`, via `sqlcipher_export()`.
    ///
    /// The destination must not exist yet; it is created by the ATTACH and
    /// removed again (with siblings) on any failure, so a failed export
    /// leaves no partial ciphertext behind. The source is opened read-write
    /// (sqlite requires it for the WAL checkpoint) but its content is never
    /// modified.
    public static func exportEncryptedCopy(from source: URL, to destination: URL, key: Data) throws {
        // Refuse anything that is not a readable plaintext database. The
        // caller already checked; check again here because this function is
        // public and the cost of migrating garbage is unbounded.
        guard EstateKeyProvider.detectEstateFileState(at: source) == .plaintext else {
            throw MigrationError.sourceNotPlaintext(path: source.path)
        }

        let db = try openRaw(path: source.path)
        defer { sqlite3_close_v2(db) }

        do {
            // Fold the WAL into the main file first so the plaintext original
            // that later goes to the Trash is self-contained, and so no
            // sibling files carry rows the main file lacks.
            try exec(db, sql: "PRAGMA wal_checkpoint(TRUNCATE);", step: "checkpoint")
            // ATTACH creates the encrypted destination; sqlcipher_export
            // copies every table, index, and trigger into it row-by-row.
            try exec(
                db,
                sql: "ATTACH \(sqlQuoted(destination.path)) AS encrypted KEY \"x'\(keyHex(key))'\";",
                step: "attach")
            try exec(db, sql: "SELECT sqlcipher_export('encrypted');", step: "export")
            try exec(db, sql: "DETACH encrypted;", step: "detach")
        } catch {
            // No partial ciphertext may outlive a failed export.
            removeDatabase(at: destination)
            throw error
        }
    }
}

#endif
