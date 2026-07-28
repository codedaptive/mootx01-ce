// EstateCacheTests.swift — unit tests for EstateCache.swift.
//
// Covers:
//   - Cache key correctness (variant suffix, seed, barrier, fingerprint, unit-ID sanitization)
//   - Binary fingerprint: unknown for nonexistent binary; format for real binary
//   - defaultCacheDir: under outDir or under cwd
//   - save + restore round-trip: manifest decodes correctly, estate contents preserved
//   - Isolation guarantee: modifying the restored scratch does not affect the cache entry
//   - Cache miss: restoreEstateCacheEntry returns nil when entry absent
//   - Partial hit: restoreEstateCacheEntry returns nil when estate/ present but manifest.json absent
//   - Guard-prefix preservation: restored scratch still has the expected prefix

import Foundation
import Testing
@testable import mcp_benchmarker

// MARK: - Cache key construction

@Suite("EstateCacheEntryURL")
struct EstateCacheEntryURLTests {

    let baseDir = URL(fileURLWithPath: "/tmp/lme07-cache-test")

    @Test("No-variant benchmark produces expected path components")
    func noVariantPath() {
        let entry = estateCacheEntryURL(
            cacheDir: baseDir,
            benchmark: "lmeb",
            variant: "",
            seed: 42,
            encodeBarrier: .drain,
            binaryFingerprint: "aabbcc_1234",
            posture: .plaintextOptOut,
            unitID: "query-001"
        )
        let runKey = entry.deletingLastPathComponent().lastPathComponent
        #expect(runKey == "lmeb-seed42-barrier_drain-bin_aabbcc_1234-estate_plaintext-optout")
        #expect(entry.lastPathComponent == "query-001")
    }

    @Test("With-variant benchmark includes variant in run-key")
    func withVariantPath() {
        let entry = estateCacheEntryURL(
            cacheDir: baseDir,
            benchmark: "lme",
            variant: "s",
            seed: 99,
            encodeBarrier: .impatient,
            binaryFingerprint: "ff00_800",
            posture: .plaintextOptOut,
            unitID: "q-99"
        )
        let runKey = entry.deletingLastPathComponent().lastPathComponent
        #expect(runKey == "lme-s-seed99-barrier_impatient-bin_ff00_800-estate_plaintext-optout")
        #expect(entry.lastPathComponent == "q-99")
    }

    @Test("Unit ID with filesystem-unsafe characters is sanitized")
    func unitIDSanitization() {
        let entry = estateCacheEntryURL(
            cacheDir: baseDir,
            benchmark: "locomo",
            variant: "",
            seed: 1,
            encodeBarrier: .none,
            binaryFingerprint: "abc_def",
            posture: .plaintextOptOut,
            unitID: "conv/with:special?chars"
        )
        let safeID = entry.lastPathComponent
        #expect(!safeID.contains("/"))
        #expect(!safeID.contains(":"))
        #expect(!safeID.contains("?"))
    }

    @Test("Different fingerprints produce different run keys")
    func differentFingerprintsDifferentKeys() {
        let entry1 = estateCacheEntryURL(
            cacheDir: baseDir, benchmark: "lme", variant: "", seed: 0,
            encodeBarrier: .drain, binaryFingerprint: "aaa_111", posture: .plaintextOptOut, unitID: "q1"
        )
        let entry2 = estateCacheEntryURL(
            cacheDir: baseDir, benchmark: "lme", variant: "", seed: 0,
            encodeBarrier: .drain, binaryFingerprint: "bbb_222", posture: .plaintextOptOut, unitID: "q1"
        )
        #expect(entry1 != entry2)
    }

    @Test("Different seeds produce different run keys")
    func differentSeedsDifferentKeys() {
        let entry1 = estateCacheEntryURL(
            cacheDir: baseDir, benchmark: "lme", variant: "", seed: 10,
            encodeBarrier: .drain, binaryFingerprint: "fp_x", posture: .plaintextOptOut, unitID: "q1"
        )
        let entry2 = estateCacheEntryURL(
            cacheDir: baseDir, benchmark: "lme", variant: "", seed: 20,
            encodeBarrier: .drain, binaryFingerprint: "fp_x", posture: .plaintextOptOut, unitID: "q1"
        )
        #expect(entry1 != entry2)
    }
}

// MARK: - Binary fingerprint

@Suite("MootBinaryFingerprint")
struct MootBinaryFingerprintTests {

    @Test("Nonexistent binary returns 'unknown'")
    func nonexistentBinary() {
        let fp = mootBinaryFingerprint("/tmp/no-such-binary-lme07test-\(UUID().uuidString)")
        #expect(fp == "unknown")
    }

    @Test("Real binary returns hex_hex format")
    func realBinaryFormat() throws {
        // Use /bin/echo as a stable binary that always exists.
        let fp = mootBinaryFingerprint("/bin/echo")
        guard fp != "unknown" else {
            // /bin/echo might be unavailable in some sandboxed environments — skip.
            return
        }
        let parts = fp.split(separator: "_")
        #expect(parts.count == 2)
        // Both parts must be non-empty hex strings (at least one digit).
        for part in parts {
            #expect(!part.isEmpty)
            let isHex = part.allSatisfy { $0.isHexDigit }
            #expect(isHex, "Part '\(part)' should be a hex string")
        }
    }
}

// MARK: - Default cache directory

@Suite("DefaultCacheDir")
struct DefaultCacheDirTests {

    @Test("When outDir is provided, cache dir is outDir/estate-cache")
    func underOutDir() {
        let outDir = URL(fileURLWithPath: "/tmp/lme07-out-test")
        let cacheDir = defaultCacheDir(outDir: outDir)
        #expect(cacheDir.path == "/tmp/lme07-out-test/estate-cache")
    }

    @Test("When outDir is nil, cache dir is cwd/estate-cache")
    func underCwd() {
        let cacheDir = defaultCacheDir(outDir: nil)
        let cwd = FileManager.default.currentDirectoryPath
        #expect(cacheDir.path == "\(cwd)/estate-cache")
    }
}

// MARK: - Save + restore round-trip

// Minimal Codable struct that mirrors a manifest entry for testing purposes.
private struct TestManifestEntry: Codable, Equatable {
    let uuid: String
    let label: String
}

@Suite("EstateCacheRoundTrip")
struct EstateCacheRoundTripTests {

    private func tmpDir(prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("save + restore preserves manifest and estate contents")
    func saveRestoreRoundTrip() throws {
        let cacheRoot = try tmpDir(prefix: "lme07-cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        // Create a fake estate scratch directory with a sentinel file.
        let fakeScratch = try tmpDir(prefix: "lme07-scratch")
        defer { try? FileManager.default.removeItem(at: fakeScratch) }
        let sentinelURL = fakeScratch.appendingPathComponent("sentinel.txt")
        try "hello-from-estate".write(to: sentinelURL, atomically: true, encoding: .utf8)

        let manifest: [TestManifestEntry] = [
            TestManifestEntry(uuid: "uuid-1", label: "turn-0"),
            TestManifestEntry(uuid: "uuid-2", label: "turn-1"),
        ]

        let cacheEntry = cacheRoot.appendingPathComponent("run-key/unit-1")

        // Save.
        saveEstateCacheEntry(estateScratchDir: fakeScratch, manifest: manifest, to: cacheEntry)

        // Verify cache entry directory was written.
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: cacheEntry.appendingPathComponent("estate").path))
        #expect(fm.fileExists(atPath: cacheEntry.appendingPathComponent("manifest.json").path))

        // Restore.
        let restoreTarget = try tmpDir(prefix: "lme07-restore-target")
        defer { try? FileManager.default.removeItem(at: restoreTarget) }

        let restored: (URL, [TestManifestEntry])? = restoreEstateCacheEntry(
            from: cacheEntry, expectedPosture: .encryptedDefault) {
            restoreTarget
        }

        let (restoredScratch, restoredManifest) = try #require(restored, "expected a cache hit")
        #expect(restoredManifest == manifest)

        // Estate contents preserved.
        let restoredSentinel = restoredScratch.appendingPathComponent("sentinel.txt")
        let content = try String(contentsOf: restoredSentinel, encoding: .utf8)
        #expect(content == "hello-from-estate")
    }

    @Test("restore returns nil on miss (entry absent)")
    func restoreReturnsNilOnMiss() {
        let missingEntry = URL(fileURLWithPath: "/tmp/lme07-no-such-entry-\(UUID().uuidString)")
        let result: (URL, [TestManifestEntry])? = restoreEstateCacheEntry(
            from: missingEntry, expectedPosture: .plaintextOptOut) {
            URL(fileURLWithPath: "/tmp/should-not-be-created")
        }
        #expect(result == nil)
    }

    @Test("restore returns nil when estate/ present but manifest.json absent")
    func restoreReturnsNilOnPartialHit() throws {
        let partialEntry = try tmpDir(prefix: "lme07-partial")
        defer { try? FileManager.default.removeItem(at: partialEntry) }
        // Write estate/ but not manifest.json.
        try FileManager.default.createDirectory(
            at: partialEntry.appendingPathComponent("estate"),
            withIntermediateDirectories: true
        )
        let result: (URL, [TestManifestEntry])? = restoreEstateCacheEntry(
            from: partialEntry, expectedPosture: .plaintextOptOut) {
            URL(fileURLWithPath: "/tmp/should-not-be-created")
        }
        #expect(result == nil)
    }

    @Test("isolation guarantee: modifying restored scratch does not affect cache entry")
    func isolationGuarantee() throws {
        let cacheRoot = try tmpDir(prefix: "lme07-isolation-cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let fakeScratch = try tmpDir(prefix: "lme07-isolation-scratch")
        defer { try? FileManager.default.removeItem(at: fakeScratch) }
        let originalFileURL = fakeScratch.appendingPathComponent("original.txt")
        try "original-content".write(to: originalFileURL, atomically: true, encoding: .utf8)

        let manifest: [TestManifestEntry] = [TestManifestEntry(uuid: "u1", label: "l1")]
        let cacheEntry = cacheRoot.appendingPathComponent("run/unit")

        saveEstateCacheEntry(estateScratchDir: fakeScratch, manifest: manifest, to: cacheEntry)

        let restoreTarget = try tmpDir(prefix: "lme07-isolation-restore")
        defer { try? FileManager.default.removeItem(at: restoreTarget) }

        let restored: (URL, [TestManifestEntry])? = restoreEstateCacheEntry(
            from: cacheEntry, expectedPosture: .encryptedDefault) {
            restoreTarget
        }
        let (restoredScratch, _) = try #require(restored)

        // Mutate the restored scratch.
        let mutatedFile = restoredScratch.appendingPathComponent("original.txt")
        try "mutated-content".write(to: mutatedFile, atomically: true, encoding: .utf8)

        // The cache original must be unchanged.
        let cacheOriginal = cacheEntry.appendingPathComponent("estate/original.txt")
        let cacheContent = try String(contentsOf: cacheOriginal, encoding: .utf8)
        #expect(cacheContent == "original-content",
                "cache entry must not be modified by query-run mutations")
    }
}

// MARK: - Posture in cache key + restore assert (FIX-HARNESS-20260727)

@Suite("EstateCachePosture")
struct EstateCachePostureTests {

    private func tmpDir(prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Different postures produce different run keys")
    func posturePartitionsCacheKey() {
        let base = URL(fileURLWithPath: "/tmp/posture-key-test")
        let plain = estateCacheEntryURL(
            cacheDir: base, benchmark: "lme", variant: "s", seed: 1,
            encodeBarrier: .drain, binaryFingerprint: "fp",
            posture: .plaintextOptOut, unitID: "q1")
        let enc = estateCacheEntryURL(
            cacheDir: base, benchmark: "lme", variant: "s", seed: 1,
            encodeBarrier: .drain, binaryFingerprint: "fp",
            posture: .encryptedDefault, unitID: "q1")
        #expect(plain != enc,
                "plaintext and encrypted estates are different bytes; keys must differ")
    }

    @Test("Restore preserves the plaintext marker (marker travels with the snapshot)")
    func restorePreservesPlaintextPosture() throws {
        let cacheRoot = try tmpDir(prefix: "posture-cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        // Snapshot a scratch dir that carries the marker (as a real plaintext
        // scratch estate would).
        let fakeScratch = try tmpDir(prefix: "posture-scratch")
        defer { try? FileManager.default.removeItem(at: fakeScratch) }
        try applyScratchPosture(.plaintextOptOut, to: fakeScratch)

        let manifest = [TestManifestEntry(uuid: "u1", label: "l1")]
        let cacheEntry = cacheRoot.appendingPathComponent("run/unit")
        saveEstateCacheEntry(estateScratchDir: fakeScratch, manifest: manifest, to: cacheEntry)

        let restoreTarget = try tmpDir(prefix: "posture-restore")
        defer { try? FileManager.default.removeItem(at: restoreTarget) }
        let restored: (URL, [TestManifestEntry])? = restoreEstateCacheEntry(
            from: cacheEntry, expectedPosture: .plaintextOptOut) {
            restoreTarget
        }
        let (restoredScratch, _) = try #require(restored, "expected a cache hit")
        #expect(scratchHasOptOutMarker(in: restoredScratch),
                "the no-encrypt marker must travel with the snapshot and be present after restore")
    }

    @Test("Posture mismatch on restore is treated as a miss (marker absent, plaintext expected)")
    func mismatchMarkerAbsentIsMiss() throws {
        let cacheRoot = try tmpDir(prefix: "posture-mismatch-a")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        // Snapshot WITHOUT a marker (an encrypted-posture estate).
        let fakeScratch = try tmpDir(prefix: "posture-mismatch-scratch-a")
        defer { try? FileManager.default.removeItem(at: fakeScratch) }

        let manifest = [TestManifestEntry(uuid: "u1", label: "l1")]
        let cacheEntry = cacheRoot.appendingPathComponent("run/unit")
        saveEstateCacheEntry(estateScratchDir: fakeScratch, manifest: manifest, to: cacheEntry)

        let restoreTarget = try tmpDir(prefix: "posture-mismatch-restore-a")
        defer { try? FileManager.default.removeItem(at: restoreTarget) }
        let restored: (URL, [TestManifestEntry])? = restoreEstateCacheEntry(
            from: cacheEntry, expectedPosture: .plaintextOptOut) {
            restoreTarget
        }
        #expect(restored == nil,
                "restoring a marker-less snapshot for a plaintext run must be a miss, never a silently encrypted estate")
    }

    @Test("Posture mismatch on restore is treated as a miss (marker present, encrypted expected)")
    func mismatchMarkerPresentIsMiss() throws {
        let cacheRoot = try tmpDir(prefix: "posture-mismatch-b")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let fakeScratch = try tmpDir(prefix: "posture-mismatch-scratch-b")
        defer { try? FileManager.default.removeItem(at: fakeScratch) }
        try applyScratchPosture(.plaintextOptOut, to: fakeScratch)

        let manifest = [TestManifestEntry(uuid: "u1", label: "l1")]
        let cacheEntry = cacheRoot.appendingPathComponent("run/unit")
        saveEstateCacheEntry(estateScratchDir: fakeScratch, manifest: manifest, to: cacheEntry)

        let restoreTarget = try tmpDir(prefix: "posture-mismatch-restore-b")
        defer { try? FileManager.default.removeItem(at: restoreTarget) }
        let restored: (URL, [TestManifestEntry])? = restoreEstateCacheEntry(
            from: cacheEntry, expectedPosture: .encryptedDefault) {
            restoreTarget
        }
        #expect(restored == nil,
                "restoring a plaintext snapshot for an encrypted run must be a miss")
    }
}
