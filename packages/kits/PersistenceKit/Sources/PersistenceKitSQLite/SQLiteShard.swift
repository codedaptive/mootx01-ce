// SQLiteShard — the EXT-4 shard-write + keyed-merge primitives.
//
// Ingest best-practices §8 EXT-4: parallel bulk-import workers each write
// their slice's rows into a PRIVATE shard SQLite file; the single writer then
// merges each shard into the estate with one `ATTACH ... KEY` +
// `INSERT ... SELECT ... ORDER BY` per table — SQLite copies the rows
// internally (no per-row statement/bind from app code), and key-ordered
// arrival gives the destination b-tree append-locality (fewer page writes and
// SQLCipher page-crypto ops than random-order per-row upserts).
//
// KEY DISCIPLINE (the reason this lives in the kit, not app code): the shard
// is encrypted with the SAME full-database key as the estate, applied from the
// estate's `EstateConfiguration` at open — the key never crosses the kit
// boundary. Rust twin: `IngestPostingsShard` + `attach_with_install_key` +
// `InvertedIndexStore::merge_shard`.

import Foundation
import PersistenceKit

/// A parallel worker's private shard database: create → exec DDL → bulk
/// insert (one transaction, prepared statement, caller pre-sorts rows for
/// b-tree append order) → close. Single-use; creating over an existing file
/// truncates it (a stale shard from a crashed import is dead weight).
public final class SQLiteShard {
    let connection: SQLiteConnection
    public let url: URL

    /// Open a fresh shard at `url`, keyed with the estate configuration's
    /// full-database key (no-op for unencrypted estates).
    public init(url: URL, configuration: EstateConfiguration) throws {
        try? FileManager.default.removeItem(at: url)
        self.url = url
        self.connection = try SQLiteConnection(
            url: url,
            busyTimeout: 5,
            keyHex: configuration.encryptionConfig.fullDatabaseKeyHex
        )
    }

    /// Execute shard DDL (CREATE TABLE ...).
    public func exec(_ sql: String) throws {
        try connection.exec(sql)
    }

    /// Bulk-insert rows into a shard table: ONE transaction, one prepared
    /// statement re-bound per row. Callers pre-sort rows by the table's
    /// primary key so the shard b-tree builds in append order.
    public func insert(table: String, columns: [String], rows: [[TypedValue]]) throws {
        guard !rows.isEmpty else { return }
        try validateSQLIdentifier(table)
        for c in columns { try validateSQLIdentifier(c) }
        let cols = columns.map { "\"\($0)\"" }.joined(separator: ", ")
        let ph = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let stmt = try connection.prepare(
                "INSERT OR REPLACE INTO \"\(table)\" (\(cols)) VALUES (\(ph))")
            defer { stmt.finalize() }
            for row in rows {
                stmt.resetForReuse()
                for (i, v) in row.enumerated() {
                    try stmt.bind(v, at: Int32(i + 1))
                }
                _ = try stmt.step()
            }
            try connection.exec("COMMIT")
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    /// Close the shard connection (call after the last insert, before merge).
    public func close() {
        connection.close()
    }

    /// Best-effort removal of a merged (or abandoned) shard file and its
    /// WAL/SHM sidecars.
    public static func removeFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }
}

extension SQLiteStorage {
    /// Merge a shard database into this estate in ONE pass: attach the shard
    /// (keyed with this estate's own full-database key — kit-internal), run the
    /// caller's copy statements inside one transaction, commit, detach. Copy
    /// statements reference the shard as `shard.<table>`, e.g.
    /// `INSERT OR REPLACE INTO iix_termfreqs SELECT ... FROM shard.iix_termfreqs ORDER BY term, item_id`.
    public func mergeShard(url: URL, copySQL: [String]) async throws {
        try await backend.mergeShard(
            url: url,
            copySQL: copySQL,
            keyHex: configuration.encryptionConfig.fullDatabaseKeyHex
        )
    }
}

extension SQLiteBackend {
    /// Actor-isolated shard merge — see `SQLiteStorage.mergeShard`. ATTACH
    /// cannot run inside a transaction, so the bracket is attach → BEGIN
    /// IMMEDIATE → copy → COMMIT → DETACH (detach always runs).
    func mergeShard(url: URL, copySQL: [String], keyHex: String?) throws {
        // The hex is produced from raw key bytes ([0-9a-f] only — safe to
        // interpolate as the raw-key literal; a BOUND key parameter would take
        // SQLCipher's passphrase-KDF path and derive a DIFFERENT key). The
        // shard path is bound, never interpolated.
        let keyLiteral: String
        if let hex = keyHex, !hex.isEmpty, hex.allSatisfy({ $0.isHexDigit }) {
            keyLiteral = "\"x'\(hex)'\""
        } else {
            keyLiteral = "''"
        }
        let attach = try connection.prepare("ATTACH DATABASE ?1 AS shard KEY \(keyLiteral)")
        defer { attach.finalize() }
        try attach.bind(.text(url.path), at: 1)
        _ = try attach.step()
        defer { try? connection.exec("DETACH DATABASE shard") }
        try connection.exec("BEGIN IMMEDIATE")
        do {
            for sql in copySQL {
                try connection.exec(sql)
            }
            try connection.exec("COMMIT")
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }
}
