// KeylessConformanceTests.swift
//
// Conformance suite pinning "SQLCipher keyless == stock SQLite" behaviour.
// These tests serve as the acceptance gate for any future SQLCipher vendor bump:
// a keyless open must produce a standard SQLite file (magic + zero reserve bytes),
// ATTACH with KEY '' must succeed, VACUUM must succeed, and SQLiteStorage.mergeShard
// must use KEY '' internally on its plaintext branch.
//
// Background: sqlite3.c:131181 (attachFunc) fires sqlcipherCodecAttach when the
// SQLITE_NULL branch detects reserve>0 on the main database — this causes a
// plaintext ATTACH to fail on any host where the main database has reserve bytes
// (e.g. Apple's /usr/bin/sqlite3, which creates databases with reserve=12).
// KEY '' sidesteps this entirely: the SQLITE_TEXT/BLOB branch skips codec
// attachment when nKey=0 (sqlite3.c:131171: `if(nKey && zKey)`), regardless of
// the main database's reserve geometry.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
import SQLCipher

// MARK: - Helpers

/// Create a SQLite database at the given URL and execute SQL, then close.
/// Uses the raw SQLCipher C API (no kit layer) to produce a bare database file.
private func createRawSQLiteFile(at url: URL, sql: String) throws {
    var db: OpaquePointer?
    let rc = sqlite3_open(url.path, &db)
    defer { sqlite3_close(db) }
    guard rc == SQLITE_OK, let db else {
        throw StorageError.backendError(underlying: "createRawSQLiteFile open failed rc=\(rc)")
    }
    var errMsg: UnsafeMutablePointer<CChar>?
    let rc2 = sqlite3_exec(db, sql, nil, nil, &errMsg)
    if rc2 != SQLITE_OK {
        let msg = errMsg.map { String(cString: $0) } ?? "exec failed"
        sqlite3_free(errMsg)
        throw StorageError.backendError(underlying: msg)
    }
}

// MARK: - Conformance Suite

@Suite("SQLCipher keyless conformance")
struct KeylessConformanceTests {

    /// A keyless SQLCipher database must be byte-compatible with stock SQLite:
    /// header magic "SQLite format 3\0" at bytes 0–15, and reserve-per-page = 0
    /// at byte 20 (SQLCipher only sets reserve > 0 on encrypted databases to
    /// accommodate the per-page IV+HMAC overhead).
    @Test("keyless db: header magic bytes 0–15 and zero reserve at byte 20")
    func keyless_db_header_magic_and_reserve_zero() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyless-magic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("test.sqlite")

        // Open and close a keyless database — no PRAGMA key, no encryption.
        try createRawSQLiteFile(at: dbURL, sql: "CREATE TABLE sentinel (id TEXT PRIMARY KEY)")

        let data = try Data(contentsOf: dbURL)
        #expect(data.count >= 21, "Database file must be at least 21 bytes (got \(data.count))")

        // SQLite file-format §1.2: bytes 0–15 are the magic header string.
        let magic = Array(data[0..<16])
        let expected = Array("SQLite format 3\0".utf8)
        #expect(magic == expected, "First 16 bytes must be the SQLite magic header (keyless SQLCipher must be stock-SQLite-compatible)")

        // SQLite file-format §1.2: byte 20 is reserved space per page.
        // SQLCipher uses reserve > 0 only for encrypted databases; keyless must be 0.
        let reservePerPage = data[20]
        #expect(reservePerPage == 0, "Reserve bytes per page must be 0 for a keyless SQLCipher database (found \(reservePerPage))")
    }

    /// ATTACH with explicit KEY '' must succeed against a plain (keyless) SQLite
    /// database. This pins the safe path through the attachFunc SQLITE_TEXT/BLOB
    /// branch (sqlite3.c:131171) where nKey=0 causes sqlcipherCodecAttach to be
    /// skipped entirely, regardless of the main database's reserve geometry.
    @Test("ATTACH KEY '' succeeds on keyless database")
    func keyless_attach_key_empty_string_succeeds() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyless-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shardURL = dir.appendingPathComponent("shard.sqlite")
        let mainURL = dir.appendingPathComponent("main.sqlite")

        // Build a source shard with one table.
        try createRawSQLiteFile(at: shardURL, sql: "CREATE TABLE items (id TEXT PRIMARY KEY, label TEXT NOT NULL)")

        // Open main connection via raw C API and ATTACH the shard with KEY ''.
        var mainDB: OpaquePointer?
        let openRC = sqlite3_open(mainURL.path, &mainDB)
        defer { sqlite3_close(mainDB) }
        #expect(openRC == SQLITE_OK, "Main database open must succeed")
        guard let mainDB else { return }

        // This SQL matches what SQLiteShard.swift:126 emits on the plaintext
        // branch (keyLiteral = "''"). Test paths are temp-dir paths without
        // apostrophes so interpolation is safe here.
        let attachSQL = "ATTACH DATABASE '\(shardURL.path)' AS shard KEY ''"
        var attachErr: UnsafeMutablePointer<CChar>?
        let attachRC = sqlite3_exec(mainDB, attachSQL, nil, nil, &attachErr)
        let attachMsg = attachErr.map { String(cString: $0) }
        sqlite3_free(attachErr)
        #expect(attachRC == SQLITE_OK, "ATTACH KEY '' must succeed on keyless shard; rc=\(attachRC) msg=\(attachMsg ?? "<nil>")")

        // Verify the attached table is visible through the attached schema.
        var stmt: OpaquePointer?
        let prepRC = sqlite3_prepare_v2(mainDB, "SELECT COUNT(*) FROM shard.items", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        #expect(prepRC == SQLITE_OK, "Prepare SELECT on attached shard must succeed; rc=\(prepRC)")
        guard prepRC == SQLITE_OK else { return }
        let stepRC = sqlite3_step(stmt)
        #expect(stepRC == SQLITE_ROW, "SELECT COUNT(*) must return a row; rc=\(stepRC)")
        // Table exists and is accessible — count is 0 (empty), which is the correct
        // proof that the attached schema is visible.
        let count = sqlite3_column_int(stmt, 0)
        #expect(count == 0, "Attached shard table must be accessible; got count=\(count)")
    }

    /// VACUUM on a keyless SQLCipher database must succeed. This verifies that
    /// the page reclamation path works without a codec installed — VACUUM rebuilds
    /// the database file in place and would fail if the codec tried to decrypt pages
    /// that were never encrypted.
    @Test("VACUUM succeeds on keyless SQLCipher database")
    func keyless_vacuum_succeeds() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyless-vacuum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("test.sqlite")

        // Create a database with data, then delete to give VACUUM something to reclaim.
        try createRawSQLiteFile(
            at: dbURL,
            sql: "CREATE TABLE t (x TEXT); INSERT INTO t VALUES ('a'); DELETE FROM t"
        )

        // Reopen and run VACUUM on the keyless database.
        var db: OpaquePointer?
        let openRC = sqlite3_open(dbURL.path, &db)
        defer { sqlite3_close(db) }
        #expect(openRC == SQLITE_OK, "Reopen for VACUUM must succeed")
        guard let db else { return }
        var vacErr: UnsafeMutablePointer<CChar>?
        let vacRC = sqlite3_exec(db, "VACUUM", nil, nil, &vacErr)
        let vacMsg = vacErr.map { String(cString: $0) }
        sqlite3_free(vacErr)
        #expect(vacRC == SQLITE_OK, "VACUUM must succeed on keyless SQLCipher database; rc=\(vacRC) msg=\(vacMsg ?? "<nil>")")
    }

    /// SQLiteStorage.mergeShard on a plaintext (unencrypted) estate must use
    /// KEY '' internally, routing through the safe SQLITE_TEXT/BLOB branch.
    /// If this test fails, it means the attachFunc heuristic fired and rejected
    /// the ATTACH — a SQLCipher vendor regression or a key-selection logic bug
    /// in SQLiteShard.swift.
    @Test("mergeShard plaintext branch uses KEY '' — no codec rejection")
    func merge_shard_plaintext_branch_uses_key_empty_string() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyless-mergeshard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shardURL = dir.appendingPathComponent("shard.sqlite")
        let mainURL = dir.appendingPathComponent("main.sqlite")

        // Build a bare shard file (no kit metadata — copySQL is empty so no tables
        // from the shard are accessed during the merge).
        try createRawSQLiteFile(at: shardURL, sql: "CREATE TABLE sentinel (id TEXT)")

        // Open a keyless target estate (no encryption config → keyHex = nil →
        // SQLiteShard.swift selects keyLiteral = "''" on the plaintext branch).
        let target = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: mainURL, busyTimeout: 5.0)
        ))
        try await target.open(schema: SchemaDeclaration(
            kitID: "MergeShardConf",
            version: 1,
            tables: []
        ))

        // An empty copySQL exercises ATTACH + BEGIN IMMEDIATE + COMMIT + DETACH
        // without executing any copy statements. If ATTACH fails (codec rejection),
        // this call throws and the test fails — that is the pin.
        try await target.mergeShard(url: shardURL, copySQL: [])
    }
}
