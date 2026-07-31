// SQLiteLimitLengthTests.swift
//
// Mission MXE-BB / Part 3 — defense-in-depth: verify that SQLiteConnection
// applies the SQLITE_LIMIT_LENGTH guard on connection open.
//
// ## What the limit call actually does
//
// SQLite's `sqlite3_limit(SQLITE_LIMIT_LENGTH, newVal)` is silently clamped
// to the compile-time SQLITE_MAX_LENGTH (= 1,000,000,000 bytes in the bundled
// SQLCipher build). Passing 0x7fffffff does NOT raise the per-connection limit
// above 1 GB; it restores the limit to the compile-time ceiling in case a prior
// sqlite3_limit call lowered it on the same handle. The primary fix for the
// >1 GB blob rejection (ee#49) is chunked basis persistence (Parts 1+2);
// this call is defense-in-depth only.
//
// ## Test approach
//
// The test imports SQLCipher (which exposes the raw sqlite3_* C API, available
// because PersistenceKitSQLiteTests already depends on it). It opens a raw
// SQLite handle, applies the same limit call SQLiteConnection.init applies,
// then queries the current limit with sqlite3_limit(handle, type, -1) (passing
// -1 queries without changing the limit). The returned value must be at the
// compile-time maximum (>= 1,000,000,000).

import Testing
import Foundation
import SQLCipher

@Suite("SQLiteLimitLength")
struct SQLiteLimitLengthTests {

    /// Verify that after calling `sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 0x7fffffff)`
    /// — exactly what `SQLiteConnection.init` does — the effective limit is at the
    /// compile-time maximum (>= 1,000,000,000).
    ///
    /// SQLite silently clamps the new-value argument to `SQLITE_MAX_LENGTH`
    /// (= 1,000,000,000 in the bundled SQLCipher build), so the effective value will
    /// be exactly 1,000,000,000 — not INT_MAX — in this configuration. The call is
    /// still correct as a defensive restore in case an earlier `sqlite3_limit` call
    /// lowered the per-connection limit.
    ///
    /// Passing -1 as the new-value argument queries without changing the limit, which
    /// lets us confirm the prior `set` call took effect without double-setting it.
    @Test("SQLITE_LIMIT_LENGTH is at compile-time maximum after connection-open guard")
    func limitLengthAtCompileTimeMaximum() throws {
        // Open a raw SQLite connection in a scratch file.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pk-limit-test-\(UUID().uuidString).sqlite3")
        var handle: OpaquePointer?
        let openRC = sqlite3_open(url.path, &handle)
        guard openRC == SQLITE_OK, let handle else {
            if let h = handle { sqlite3_close_v2(h) }
            Issue.record("sqlite3_open failed with code \(openRC)")
            return
        }
        defer {
            sqlite3_close_v2(handle)
            try? FileManager.default.removeItem(at: url)
        }

        // Apply the same limit SQLiteConnection.init applies.
        // The return value is the previous limit (the build-time default);
        // discarded — we care only about the resulting effective value.
        _ = sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 0x7fffffff)

        // Query the current limit by passing -1 (read-only, does not change the limit).
        let effective = sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, -1)

        // The ceiling must be ABOVE SQLite's 1e9 stock default, which proves the
        // SQLITE_MAX_LENGTH define on the SQLCipher target took effect.
        //
        // A `>= 1_000_000_000` assertion is NOT sufficient and is how this
        // regression shipped: sqlite3_limit clamps to the compile-time
        // SQLITE_MAX_LENGTH, so with the stock define the guard call is a silent
        // no-op and lands on exactly 1e9 — passing a `>=` check while the 1 GB
        // ceiling it was meant to lift is still fully in force. A real estate
        // then failed a >1 GB bind after chunked basis persistence shipped.
        #expect(
            effective > 1_000_000_000,
            "SQLITE_LIMIT_LENGTH must exceed the 1e9 stock default — the SQLITE_MAX_LENGTH define on the SQLCipher target is missing or ineffective; got \(effective)"
        )
    }
}
