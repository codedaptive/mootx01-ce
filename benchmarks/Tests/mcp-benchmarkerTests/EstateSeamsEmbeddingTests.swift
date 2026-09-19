// EstateSeamsEmbeddingTests.swift — unit tests for the embedding-provider
// seam family in EstateSeams.swift.
//
// ALL suites that call setenv/unsetenv on MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER
// live here, nested under a single .serialized parent (EmbeddingSeamFamily).
// Swift Testing runs different top-level suites concurrently even when each
// suite is individually .serialized; a shared parent .serialized prevents the
// setenv/unsetenv races that occur when the three sibling suites run in
// different threads across concurrent invocations.
//
// Suite map:
//
//   EmbeddingSeamFamily (.serialized parent — prevents cross-suite env races)
//   │
//   ├── ProvisionEmbeddingProviderSeam
//   │     A: env unset          — provisionEmbeddingProviderSeam is a no-op
//   │     B: valid id           — writes embedding_provider row
//   │     C: unknown id         — throws before touching SQLite
//   │
//   ├── VerifyEmbeddingProviderSeam
//   │     D: env unset          — verifyEmbeddingProviderSeam is a no-op
//   │     E: env set, key match — verify is a no-op; manifest unchanged
//   │     F: env set, key absent — HARD ERROR naming estate path
//   │     G: env set, mismatch   — HARD ERROR naming expected and stored values
//   │
//   ├── AssertEmbeddingProviderCacheDirIsolation
//   │     H: env unset                      — no-op for any path
//   │     I: env set, path contains model id — no-op
//   │     J: env set, path contains model id as subpath — no-op
//   │     K: env set, default cache path    — HARD ERROR naming path and model id
//   │     L: env set, unrelated path        — HARD ERROR naming model id
//   │
//   └── EstateCacheSeamPropagation
//         A+B: seam failure propagates with MCPError message;
//              scratch directory is removed before the throw
//         C:   mechanics failure (corrupt manifest.json) remains a soft miss
//
//   preprovisionEmbeddingSlot: NOT tested here — it requires a real mootx01
//   binary to bootstrap estate.sqlite. See manual smoke recipe in EstateSeams.swift
//   (MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER header section).

import Darwin   // setenv / unsetenv
import Foundation
import SQLite3
import Testing
@testable import mcp_benchmarker

// MARK: - Shared helpers

/// Create a scratch directory with a minimal estate.sqlite that includes a
/// manifest table, optionally pre-populated with an embedding_provider row.
private func makeScratchEstate(
    prefix: String,
    embeddingProviderValue: String? = nil
) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let dbPath = dir.appendingPathComponent("estate.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db,
                          SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        throw MCPError(description: "test helper: cannot create \(dbPath)")
    }
    defer { sqlite3_close(db) }

    // Minimal manifest schema — mirrors the real LocusKit schema.
    let ddl = "CREATE TABLE IF NOT EXISTS manifest(key TEXT PRIMARY KEY, value TEXT)"
    guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
        throw MCPError(description:
            "test helper: CREATE TABLE failed: \(String(cString: sqlite3_errmsg(db)))")
    }

    if let value = embeddingProviderValue {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO manifest(key, value) VALUES('embedding_provider', ?1)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPError(description:
                "test helper: INSERT prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        // SQLITE_TRANSIENT: SQLite copies the bound text immediately.
        sqlite3_bind_text(stmt, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MCPError(description:
                "test helper: INSERT failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
    return dir
}

/// Read the manifest value for `key` from estate.sqlite in `dir`.
private func readManifestValue(in dir: URL, key: String) throws -> String? {
    let dbPath = dir.appendingPathComponent("estate.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw MCPError(description: "test helper: cannot read \(dbPath)")
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = "SELECT value FROM manifest WHERE key = ?1"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw MCPError(description: "test helper: prepare failed")
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return String(cString: sqlite3_column_text(stmt, 0))
}

// MARK: - Seam-propagation test helpers

/// Build a minimal cache entry for seam-propagation tests.
///
/// - `estateDB`: path to an `estate.sqlite` that is placed inside the entry's
///   `estate/` directory. Callers supply the db to control what the seam sees.
/// - Returns the cache entry URL. Caller is responsible for teardown.
private func makeSeamTestCacheEntry(
    prefix: String,
    estateDB: URL
) throws -> URL {
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-cache-\(UUID().uuidString)")
    let entry = cacheRoot.appendingPathComponent("run/unit")
    let estateDir = entry.appendingPathComponent("estate")
    try FileManager.default.createDirectory(at: estateDir, withIntermediateDirectories: true)

    // Place the caller-supplied estate.sqlite inside estate/.
    try FileManager.default.copyItem(
        at: estateDB,
        to: estateDir.appendingPathComponent("estate.sqlite"))

    // Write an empty manifest.json so provenance check and mechanics succeed.
    let emptyManifest: [[String: String]] = []
    let manifestData = try JSONEncoder().encode(emptyManifest)
    try manifestData.write(to: entry.appendingPathComponent("manifest.json"))

    // Write a valid artifact.json provenance using a detached scratch so
    // saveEstateCacheEntry can snapshot it correctly.
    let detachedScratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-scratch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: detachedScratch) }
    try FileManager.default.createDirectory(at: detachedScratch, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: estateDB,
        to: detachedScratch.appendingPathComponent("estate.sqlite"))

    let blankManifest: [[String: String]] = []
    saveEstateCacheEntry(
        estateScratchDir: detachedScratch,
        manifest: blankManifest,
        provenance: seamTestProvenance(),
        to: entry)
    return entry
}

/// Minimal SQLite database with a `manifest` table but no `embedding_provider` row.
///
/// `verifyEmbeddingProviderSeam` opens `estate.sqlite` and queries:
///   SELECT value FROM manifest WHERE key = 'embedding_provider'
/// A manifest table without that row triggers the hard-error path in
/// verifyEmbeddingProviderSeam (SQLITE_ROW not returned → throw MCPError
/// naming the missing key).
private func makeSeamTestEstateDB(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-estate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let dbPath = dir.appendingPathComponent("estate.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db,
                          SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        throw MCPError(description: "test helper: cannot create \(dbPath)")
    }
    defer { sqlite3_close(db) }

    // Minimal manifest schema — mirrors the real LocusKit schema.
    let ddl = "CREATE TABLE IF NOT EXISTS manifest(key TEXT PRIMARY KEY, value TEXT)"
    guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
        throw MCPError(description:
            "test helper: CREATE TABLE failed: \(String(cString: sqlite3_errmsg(db)))")
    }
    // No embedding_provider row — this is the condition that triggers the
    // hard error in verifyEmbeddingProviderSeam.
    return dir.appendingPathComponent("estate.sqlite")
}

/// Provenance fixture for seam-propagation tests.
private func seamTestProvenance() -> ArtifactProvenance {
    ArtifactProvenance(
        formatVersion: artifactFormatVersion,
        benchmark: "lme", variant: "s", seed: 3,
        encodeBarrier: "drain", estatePosture: "plaintext-optout",
        seedPath: "batch",
        corpusDigest: "cafebabe", embeddingModels: ["binary-default"],
        mootx01Version: "1.1", protocolVersion: "v0.1", markersPresent: true,
        estateSchemaVersion: "1.0")
}

// MARK: - EmbeddingSeamFamily (.serialized parent)

/// Parent suite that forces all embedding-seam env tests to run serially.
///
/// setenv(3)/unsetenv(3) are not thread-safe; they mutate the process-global
/// environment. Swift Testing runs top-level suites concurrently, so separate
/// top-level `.serialized` suites in different files still race on a shared env
/// variable. Nesting all three suites under ONE `.serialized` parent prevents
/// any concurrent execution among them — the parent's serialization constraint
/// applies to all descendants.
@Suite("EmbeddingSeamFamily", .serialized)
struct EmbeddingSeamFamilyTests {

    // MARK: - ProvisionEmbeddingProviderSeam

    /// Tests for `provisionEmbeddingProviderSeam` (the BUILD-WINDOW write path).
    @Suite("ProvisionEmbeddingProviderSeam")
    struct ProvisionEmbeddingProviderSeamTests {

        private let envKey = "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER"

        // ── A: unset env is a no-op ──────────────────────────────────────────

        @Test("Unset env: seam is a no-op and manifest is not touched")
        func unsetEnvIsNoop() throws {
            // Guard: if the env var is somehow set in the host environment
            // (e.g. a parent benchmark process), unset it for this test.
            let wasSet = ProcessInfo.processInfo.environment[envKey] != nil
            if wasSet { unsetenv(envKey) }
            defer { if wasSet { setenv(envKey, "", 1) } }

            let scratch = try makeScratchEstate(prefix: "prov-noop")
            defer { try? FileManager.default.removeItem(at: scratch) }

            // provisionEmbeddingProviderSeam must be a no-op when env is unset.
            try provisionEmbeddingProviderSeam(into: scratch)

            let value = try readManifestValue(in: scratch, key: "embedding_provider")
            #expect(value == nil,
                "embedding_provider must be absent when env var is unset")
        }

        // ── B: valid id writes the key ────────────────────────────────────────

        @Test("apple-nl-v1: seam writes embedding_provider into manifest")
        func validIDWritesKey() throws {
            setenv(envKey, "apple-nl-v1", 1)
            defer { unsetenv(envKey) }

            let scratch = try makeScratchEstate(prefix: "prov-valid")
            defer { try? FileManager.default.removeItem(at: scratch) }

            try provisionEmbeddingProviderSeam(into: scratch)

            let stored = try readManifestValue(in: scratch, key: "embedding_provider")
            #expect(stored == "apple-nl-v1",
                "manifest must carry embedding_provider=apple-nl-v1 after seam runs")
        }

        // ── C: unknown id throws ────────────────────────────────────────────

        @Test("Unknown id: seam throws MCPError without writing manifest")
        func unknownIDThrows() throws {
            setenv(envKey, "some-unknown-provider-v99", 1)
            defer { unsetenv(envKey) }

            let scratch = try makeScratchEstate(prefix: "prov-unknown")
            defer { try? FileManager.default.removeItem(at: scratch) }

            var threw = false
            do {
                try provisionEmbeddingProviderSeam(into: scratch)
            } catch {
                threw = true
                let description = String(describing: error)
                // Error must name the rejected id so the operator knows what to fix.
                #expect(description.contains("some-unknown-provider-v99"),
                    "error should mention the rejected id; got: \(description)")
            }
            #expect(threw, "provisionEmbeddingProviderSeam must throw for unknown id")

            // Manifest must be untouched — no embedding_provider row written.
            let value = try readManifestValue(in: scratch, key: "embedding_provider")
            #expect(value == nil,
                "manifest must be untouched when seam throws on unknown id")
        }
    }

    // MARK: - VerifyEmbeddingProviderSeam

    /// Tests for `verifyEmbeddingProviderSeam` (the RESTORE-PATH read-and-compare).
    ///
    /// A restored estate MUST already carry the matching key — it was built with
    /// the slot wired. A restore-time write would mislabel the arm (no vectors
    /// for the slot exist). This seam reads and compares; it never writes.
    @Suite("VerifyEmbeddingProviderSeam")
    struct VerifyEmbeddingProviderSeamTests {

        private let envKey = "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER"

        // ── D: unset env is a no-op ───────────────────────────────────────────

        @Test("Unset env: verify seam is a no-op, manifest not touched")
        func unsetEnvIsNoop() throws {
            let wasSet = ProcessInfo.processInfo.environment[envKey] != nil
            if wasSet { unsetenv(envKey) }
            defer { if wasSet { setenv(envKey, "", 1) } }

            // Scratch has no embedding_provider key — verify should be a no-op.
            let scratch = try makeScratchEstate(prefix: "verify-noop")
            defer { try? FileManager.default.removeItem(at: scratch) }

            // Must not throw, must not write anything.
            try verifyEmbeddingProviderSeam(in: scratch)

            let value = try readManifestValue(in: scratch, key: "embedding_provider")
            #expect(value == nil,
                "embedding_provider must remain absent when env var is unset")
        }

        // ── E: env set, key matches — no-op, no write ────────────────────────

        @Test("apple-nl-v1 match: verify seam is a no-op and does not modify manifest")
        func matchingKeyIsNoop() throws {
            setenv(envKey, "apple-nl-v1", 1)
            defer { unsetenv(envKey) }

            // Scratch pre-populated with the correct key.
            let scratch = try makeScratchEstate(
                prefix: "verify-match",
                embeddingProviderValue: "apple-nl-v1")
            defer { try? FileManager.default.removeItem(at: scratch) }

            // Must not throw.
            try verifyEmbeddingProviderSeam(in: scratch)

            // Must not have changed the value.
            let value = try readManifestValue(in: scratch, key: "embedding_provider")
            #expect(value == "apple-nl-v1",
                "manifest value must remain apple-nl-v1 after verify on a matching estate")
        }

        // ── F: env set, key absent — HARD ERROR ──────────────────────────────

        @Test("Key absent: verify seam throws MCPError naming the estate path")
        func absentKeyThrows() throws {
            setenv(envKey, "apple-nl-v1", 1)
            defer { unsetenv(envKey) }

            // Scratch has no embedding_provider key — verify must hard-fail.
            let scratch = try makeScratchEstate(prefix: "verify-absent")
            defer { try? FileManager.default.removeItem(at: scratch) }

            var threw = false
            do {
                try verifyEmbeddingProviderSeam(in: scratch)
            } catch {
                threw = true
                let msg = String(describing: error)
                // Error must name the estate path so the operator knows which unit failed.
                #expect(msg.contains(scratch.path),
                    "error should name the estate path; got: \(msg)")
                // Error must say the key is absent / estate not built with the slot.
                #expect(msg.contains("no embedding_provider key") || msg.contains("not built"),
                    "error should say the key is absent; got: \(msg)")
            }
            #expect(threw, "verifyEmbeddingProviderSeam must throw when embedding_provider is absent")
        }

        // ── G: env set, key present but different — HARD ERROR ───────────────

        @Test("Key mismatch: verify seam throws MCPError naming both values")
        func mismatchedKeyThrows() throws {
            setenv(envKey, "apple-nl-v1", 1)
            defer { unsetenv(envKey) }

            // Scratch has a DIFFERENT provider — simulates a wrong-provider cache entry.
            let scratch = try makeScratchEstate(
                prefix: "verify-mismatch",
                embeddingProviderValue: "some-other-provider-v2")
            defer { try? FileManager.default.removeItem(at: scratch) }

            var threw = false
            do {
                try verifyEmbeddingProviderSeam(in: scratch)
            } catch {
                threw = true
                let msg = String(describing: error)
                // Error must name both the expected and stored values.
                #expect(msg.contains("apple-nl-v1"),
                    "error should name the expected model id; got: \(msg)")
                #expect(msg.contains("some-other-provider-v2"),
                    "error should name the stored (mismatched) value; got: \(msg)")
            }
            #expect(threw, "verifyEmbeddingProviderSeam must throw on a provider mismatch")

            // The manifest must not have been modified — the seam is read-only.
            let value = try readManifestValue(in: scratch, key: "embedding_provider")
            #expect(value == "some-other-provider-v2",
                "manifest must be unmodified after a verify-path error")
        }
    }

    // MARK: - AssertEmbeddingProviderCacheDirIsolation

    /// Tests for `assertEmbeddingProviderCacheDirIsolation` (the cache-dir name gate).
    ///
    /// When MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER is set and the cache is in
    /// use, the cache dir path MUST contain the model-id string. Provisioned and
    /// default estates must never share a cache dir — a mixed cache poisons every
    /// future cross-arm comparison.
    @Suite("AssertEmbeddingProviderCacheDirIsolation")
    struct AssertEmbeddingProviderCacheDirIsolationTests {

        private let envKey = "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER"

        // ── H: env unset — no-op ─────────────────────────────────────────────

        @Test("Unset env: cache-dir gate is a no-op for any path")
        func unsetEnvIsNoop() throws {
            let wasSet = ProcessInfo.processInfo.environment[envKey] != nil
            if wasSet { unsetenv(envKey) }
            defer { if wasSet { setenv(envKey, "", 1) } }

            // A default-style path that would fail when the env is set.
            let cacheDir = URL(fileURLWithPath: "/tmp/estate-cache")
            // Must not throw when env is unset.
            try assertEmbeddingProviderCacheDirIsolation(cacheDir: cacheDir)
        }

        // ── I: env set, path contains model id — no-op ───────────────────────

        @Test("Path contains model id: cache-dir gate is a no-op")
        func pathContainsModelID() throws {
            setenv(envKey, "apple-nl-v1", 1)
            defer { unsetenv(envKey) }

            let cacheDir = URL(fileURLWithPath: "/tmp/estate-cache-apple-nl-v1")
            // Must not throw — the cache dir is correctly namespaced.
            try assertEmbeddingProviderCacheDirIsolation(cacheDir: cacheDir)
        }

        // ── J: env set, model id appears as a subpath component — no-op ──────

        @Test("Path contains model id as subpath component: cache-dir gate is a no-op")
        func pathContainsModelIDAsSubpath() throws {
            setenv(envKey, "apple-nl-v1", 1)
            defer { unsetenv(envKey) }

            let cacheDir = URL(fileURLWithPath: "/Volumes/bench/runs/apple-nl-v1/estate-cache")
            try assertEmbeddingProviderCacheDirIsolation(cacheDir: cacheDir)
        }

        // ── K: env set, default cache path — HARD ERROR ──────────────────────

        @Test("Default cache path: gate throws MCPError naming path and model id")
        func defaultPathThrows() throws {
            setenv(envKey, "apple-nl-v1", 1)
            defer { unsetenv(envKey) }

            let cacheDir = URL(fileURLWithPath: "/tmp/estate-cache")
            var threw = false
            do {
                try assertEmbeddingProviderCacheDirIsolation(cacheDir: cacheDir)
            } catch {
                threw = true
                let msg = String(describing: error)
                // Error must name the model id so the operator knows what to add.
                #expect(msg.contains("apple-nl-v1"),
                    "error should name the required model id; got: \(msg)")
                // Error must name the offending path so the operator knows which flag to fix.
                #expect(msg.contains("/tmp/estate-cache"),
                    "error should name the rejected cache path; got: \(msg)")
            }
            #expect(threw,
                "assertEmbeddingProviderCacheDirIsolation must throw when path lacks the model id")
        }

        // ── L: env set, unrelated path — HARD ERROR ──────────────────────────

        @Test("Unrelated path: gate throws naming both path and model id")
        func unrelatedPathThrows() throws {
            setenv(envKey, "apple-nl-v1", 1)
            defer { unsetenv(envKey) }

            let cacheDir = URL(fileURLWithPath: "/Volumes/bench/runs/default-estate-cache")
            var threw = false
            do {
                try assertEmbeddingProviderCacheDirIsolation(cacheDir: cacheDir)
            } catch {
                threw = true
                let msg = String(describing: error)
                #expect(msg.contains("apple-nl-v1"),
                    "error should name the required model id; got: \(msg)")
            }
            #expect(threw,
                "assertEmbeddingProviderCacheDirIsolation must throw when model id is not in path")
        }
    }

    // MARK: - EstateCacheSeamPropagation

    /// Tests for the two-stage split in `restoreEstateCacheEntry`:
    /// mechanics failures are soft misses, seam failures are hard errors.
    ///
    /// Nested here so all setenv/unsetenv calls on
    /// MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER are covered by the parent
    /// EmbeddingSeamFamily .serialized constraint, preventing cross-suite races
    /// with the sibling suites above.
    @Suite("EstateCacheSeamPropagation")
    struct EstateCacheSeamPropagationTests {

        private let embeddingProviderKey = "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER"

        // ── A+B: seam failure propagates; scratch is cleaned up ─────────────────

        /// A: restoreEstateCacheEntry throws when MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER
        ///    is set and the restored estate has no embedding_provider key in its manifest.
        ///
        /// The error message must name the missing key so operators know to rebuild
        /// the artifacts with the slot pre-wired.
        ///
        /// B: the copied scratch directory must not exist after the throw, proving
        ///    that the seam-failure path cleans up the copy before rethrowing. A
        ///    stranded copy leaks key material in encrypted modes.
        @Test("Seam failure propagates with MCPError; scratch is removed before throw")
        func seamFailurePropagatesAndScratchIsRemoved() throws {
            // Set the env var that arms verifyEmbeddingProviderSeam.
            setenv(embeddingProviderKey, "apple-nl-v1", 1)
            defer { unsetenv(embeddingProviderKey) }

            // Build a cache entry whose estate.sqlite has a manifest table but
            // no embedding_provider row — this is the cheapest way to trigger the
            // "absent key is a HARD ERROR" path in verifyEmbeddingProviderSeam.
            let estateDB = try makeSeamTestEstateDB(prefix: "seam-prop-a")
            defer { try? FileManager.default.removeItem(
                at: estateDB.deletingLastPathComponent()) }

            let entry = try makeSeamTestCacheEntry(
                prefix: "seam-prop-a",
                estateDB: estateDB)
            defer { try? FileManager.default.removeItem(
                at: entry.deletingLastPathComponent().deletingLastPathComponent()) }

            // The scratch factory creates a real directory and records the path
            // so test B can verify it was removed after the seam throw.
            var capturedScratchPath: URL? = nil
            let factory: () throws -> URL = {
                let s = FileManager.default.temporaryDirectory
                    .appendingPathComponent("seam-prop-scratch-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
                capturedScratchPath = s
                return s
            }

            // --- Test A: the call must THROW, not return nil. ---
            var caughtError: Error? = nil
            do {
                let _: (URL, [[String: String]])? = try restoreEstateCacheEntry(
                    from: entry,
                    expectedProvenance: seamTestProvenance(),
                    verifyEmbeddingProvider: true,
                    scratchDirFactory: factory)
                Issue.record("restoreEstateCacheEntry must throw on seam failure, not return a value")
            } catch {
                caughtError = error
            }
            #expect(caughtError != nil, "restoreEstateCacheEntry must throw when a seam fails")

            // Error message must name the missing key — "It threw something" does
            // not discriminate between a seam error and a mechanics error.
            let errorDescription = caughtError.map { String(describing: $0) } ?? ""
            #expect(errorDescription.contains("has no embedding_provider key"),
                "error must name the missing embedding_provider key; got: \(errorDescription)")

            // --- Test B: the scratch must be gone after the throw. ---
            let scratchPath = try #require(capturedScratchPath,
                "scratchDirFactory must have been called before the throw")
            #expect(!FileManager.default.fileExists(atPath: scratchPath.path),
                "scratch directory must be removed after a seam throw to prevent key-material leak; path still exists: \(scratchPath.path)")
        }

        // ── C: mechanics failure remains a soft miss ──────────────────────────────

        /// restoreEstateCacheEntry returns nil (no throw) when manifest.json is
        /// corrupt. Restore-mechanics failures are indistinguishable from a
        /// transiently corrupted cache entry — the caller builds fresh.
        ///
        /// The copied scratch must be absent after the soft miss: Stage 1 removes
        /// it when manifest decode fails, preventing key material from being
        /// stranded outside guarded teardown.
        @Test("Corrupt manifest.json is a soft miss (returns nil, does not throw); scratch is removed")
        func corruptManifestIsSoftMiss() throws {
            // Guard: make sure the embedding seam is NOT armed so mechanics-only
            // behaviour is isolated. An armed embedding seam would throw (Stage 2),
            // obscuring the Stage 1 mechanics miss we're testing.
            let wasSet = ProcessInfo.processInfo.environment[embeddingProviderKey] != nil
            if wasSet { unsetenv(embeddingProviderKey) }
            defer { if wasSet { setenv(embeddingProviderKey, "", 1) } }

            // Build a cache entry with a valid estate.sqlite.
            let estateDB = try makeSeamTestEstateDB(prefix: "seam-prop-c")
            defer { try? FileManager.default.removeItem(
                at: estateDB.deletingLastPathComponent()) }

            let entry = try makeSeamTestCacheEntry(
                prefix: "seam-prop-c",
                estateDB: estateDB)
            defer { try? FileManager.default.removeItem(
                at: entry.deletingLastPathComponent().deletingLastPathComponent()) }

            // Overwrite manifest.json with invalid JSON — this is the mechanics
            // failure. After provenance passes and the estate is copied, the
            // JSONDecoder will throw, which Stage 1 catches, removes the scratch,
            // and converts to nil.
            try "THIS IS NOT JSON !!!".write(
                to: entry.appendingPathComponent("manifest.json"),
                atomically: true, encoding: .utf8)

            let scratchDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("seam-prop-c-scratch-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratchDir) }

            // The call must NOT throw — mechanics failures are soft misses.
            var didThrow = false
            var result: (URL, [[String: String]])? = nil
            do {
                result = try restoreEstateCacheEntry(
                    from: entry,
                    expectedProvenance: seamTestProvenance(),
                    verifyEmbeddingProvider: false) {
                    try FileManager.default.createDirectory(
                        at: scratchDir, withIntermediateDirectories: true)
                    return scratchDir
                }
            } catch {
                didThrow = true
            }
            #expect(!didThrow,
                "restoreEstateCacheEntry must NOT throw on a mechanics failure (corrupt manifest.json)")
            #expect(result == nil,
                "restoreEstateCacheEntry must return nil on a mechanics failure")

            // The copied scratch must be absent: Stage 1 removes it when manifest
            // decode fails, so no key material is stranded outside guarded teardown.
            #expect(!FileManager.default.fileExists(atPath: scratchDir.path),
                "Stage 1 must remove the copied scratch after a manifest failure; path still exists: \(scratchDir.path)")
        }
    }
}
