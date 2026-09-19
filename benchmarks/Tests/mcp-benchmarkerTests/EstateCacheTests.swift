// EstateCacheTests.swift — unit tests for EstateCache.swift.
//
// Covers:
//   - Cache key correctness (variant suffix, seed, barrier, posture, seed
//     path, unit-ID sanitization; B3: no binary fingerprint)
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


/// Shared provenance fixture for cache round-trip tests (B2). Fields are
/// arbitrary but consistent — restore validates them against what save wrote.
private func testProvenance(seed: UInt64 = 7) -> ArtifactProvenance {
    ArtifactProvenance(
        formatVersion: artifactFormatVersion,
        benchmark: "lme", variant: "s", seed: seed,
        encodeBarrier: "drain", estatePosture: "plaintext-optout",
        seedPath: "batch",
        corpusDigest: "deadbeef", embeddingModels: ["binary-default"],
        mootx01Version: "1.1", protocolVersion: "v0.1", markersPresent: true,
        estateSchemaVersion: "1.0")
}

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
            posture: .plaintextTransient,
            seedPath: .batch, unitID: "query-001"
        )
        let runKey = entry.deletingLastPathComponent().lastPathComponent
        #expect(runKey == "lmeb-seed42-barrier_drain-estate_plaintext-optout-seedpath_batch")
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
            posture: .plaintextTransient,
            seedPath: .batch, unitID: "q-99"
        )
        let runKey = entry.deletingLastPathComponent().lastPathComponent
        #expect(runKey == "lme-s-seed99-barrier_impatient-estate_plaintext-optout-seedpath_batch")
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
            posture: .plaintextTransient,
            seedPath: .batch, unitID: "conv/with:special?chars"
        )
        let safeID = entry.lastPathComponent
        #expect(!safeID.contains("/"))
        #expect(!safeID.contains(":"))
        #expect(!safeID.contains("?"))
    }

    @Test("Identical run config produces the same key across product rebuilds (B3)")
    func identicalConfigSameKey() {
        // B3: the binary fingerprint is retired from the key — a product
        // rebuild must NOT invalidate artifacts. Two identical configs map to
        // the same entry; staleness is detected by the artifact.json
        // provenance manifest instead (validated hard on restore).
        let entry1 = estateCacheEntryURL(
            cacheDir: baseDir, benchmark: "lme", variant: "", seed: 0,
            encodeBarrier: .drain, posture: .plaintextTransient,
            seedPath: .batch, unitID: "q1"
        )
        let entry2 = estateCacheEntryURL(
            cacheDir: baseDir, benchmark: "lme", variant: "", seed: 0,
            encodeBarrier: .drain, posture: .plaintextTransient,
            seedPath: .batch, unitID: "q1"
        )
        #expect(entry1 == entry2)
    }

    @Test("Different seeds produce different run keys")
    func differentSeedsDifferentKeys() {
        let entry1 = estateCacheEntryURL(
            cacheDir: baseDir, benchmark: "lme", variant: "", seed: 10,
            encodeBarrier: .drain, posture: .plaintextTransient,
            seedPath: .batch, unitID: "q1"
        )
        let entry2 = estateCacheEntryURL(
            cacheDir: baseDir, benchmark: "lme", variant: "", seed: 20,
            encodeBarrier: .drain, posture: .plaintextTransient,
            seedPath: .batch, unitID: "q1"
        )
        #expect(entry1 != entry2)
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
        saveEstateCacheEntry(estateScratchDir: fakeScratch, manifest: manifest, provenance: testProvenance(), to: cacheEntry)

        // Verify cache entry directory was written.
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: cacheEntry.appendingPathComponent("estate").path))
        #expect(fm.fileExists(atPath: cacheEntry.appendingPathComponent("manifest.json").path))

        // Restore.
        let restoreTarget = try tmpDir(prefix: "lme07-restore-target")
        defer { try? FileManager.default.removeItem(at: restoreTarget) }

        let restored: (URL, [TestManifestEntry])? = try restoreEstateCacheEntry(
            from: cacheEntry,
            expectedProvenance: testProvenance(),
            verifyEmbeddingProvider: false) {
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
        let result: (URL, [TestManifestEntry])? = try? restoreEstateCacheEntry(
            from: missingEntry,
            expectedProvenance: testProvenance(),
            verifyEmbeddingProvider: false) {
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
        let result: (URL, [TestManifestEntry])? = try? restoreEstateCacheEntry(
            from: partialEntry,
            expectedProvenance: testProvenance(),
            verifyEmbeddingProvider: false) {
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

        saveEstateCacheEntry(estateScratchDir: fakeScratch, manifest: manifest, provenance: testProvenance(), to: cacheEntry)

        let restoreTarget = try tmpDir(prefix: "lme07-isolation-restore")
        defer { try? FileManager.default.removeItem(at: restoreTarget) }

        let restored: (URL, [TestManifestEntry])? = try restoreEstateCacheEntry(
            from: cacheEntry,
            expectedProvenance: testProvenance(),
            verifyEmbeddingProvider: false) {
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

    @Test("Different postures produce different run keys")
    func posturePartitionsCacheKey() {
        let base = URL(fileURLWithPath: "/tmp/posture-key-test")
        let plain = estateCacheEntryURL(
            cacheDir: base, benchmark: "lme", variant: "s", seed: 1,
            encodeBarrier: .drain,
            posture: .plaintextTransient,
            seedPath: .batch, unitID: "q1")
        let enc = estateCacheEntryURL(
            cacheDir: base, benchmark: "lme", variant: "s", seed: 1,
            encodeBarrier: .drain,
            posture: .encryptedEphemeral,
            seedPath: .batch, unitID: "q1")
        #expect(plain != enc,
                "plaintext and encrypted estates are different bytes; keys must differ")
    }

}

// MARK: - B2 artifact provenance

@Suite("ArtifactProvenanceTests")
struct ArtifactProvenanceTests {

    private func tmpDir(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func savedEntry(provenance: ArtifactProvenance) throws -> URL {
        let cacheRoot = try tmpDir(prefix: "b2-prov-cache")
        let fakeScratch = try tmpDir(prefix: "b2-prov-scratch")
        try "x".write(to: fakeScratch.appendingPathComponent("sentinel.txt"),
                      atomically: true, encoding: .utf8)
        let entry = cacheRoot.appendingPathComponent("run/unit")
        saveEstateCacheEntry(
            estateScratchDir: fakeScratch,
            manifest: [TestManifestEntry(uuid: "u", label: "l")],
            provenance: provenance, to: entry)
        return entry
    }


    @Test("matching provenance restores; mootx01_version difference is advisory")
    func matchRestoresVersionAdvisory() throws {
        let entry = try savedEntry(provenance: testProvenance())
        // Same declared inputs, DIFFERENT binary version: must still restore —
        // a retrieval-logic rebuild does not alter estate bytes (B3's point).
        var expected = testProvenance()
        expected = ArtifactProvenance(
            formatVersion: expected.formatVersion, benchmark: expected.benchmark,
            variant: expected.variant, seed: expected.seed,
            encodeBarrier: expected.encodeBarrier, estatePosture: expected.estatePosture,
            seedPath: expected.seedPath,
            corpusDigest: expected.corpusDigest,
            embeddingModels: expected.embeddingModels,
            mootx01Version: "9.9", protocolVersion: expected.protocolVersion,
            markersPresent: expected.markersPresent,
            estateSchemaVersion: expected.estateSchemaVersion)
        let restoreTarget = try tmpDir(prefix: "b2-prov-restore")
        let restored: (URL, [TestManifestEntry])? = try restoreEstateCacheEntry(
            from: entry,
            expectedProvenance: expected,
            verifyEmbeddingProvider: false) { restoreTarget }
        #expect(restored != nil)
    }

    @Test("mismatched corpus digest HARD-FAILS (throws, not a silent miss)")
    func mismatchThrows() throws {
        let entry = try savedEntry(provenance: testProvenance())
        var bad = testProvenance()
        bad = ArtifactProvenance(
            formatVersion: bad.formatVersion, benchmark: bad.benchmark,
            variant: bad.variant, seed: bad.seed, encodeBarrier: bad.encodeBarrier,
            estatePosture: bad.estatePosture, seedPath: bad.seedPath,
            corpusDigest: "0000000000", embeddingModels: bad.embeddingModels,
            mootx01Version: bad.mootx01Version, protocolVersion: bad.protocolVersion,
            markersPresent: bad.markersPresent,
            estateSchemaVersion: bad.estateSchemaVersion)
        #expect(throws: ArtifactProvenanceError.self) {
            let _: (URL, [TestManifestEntry])? = try restoreEstateCacheEntry(
                from: entry,
                expectedProvenance: bad,
                verifyEmbeddingProvider: false) {
                URL(fileURLWithPath: "/tmp/should-not-be-created")
            }
        }
    }

    @Test("mismatched estate_schema_version HARD-FAILS (schema era mismatch is incompatible)")
    func schemaVersionMismatchThrows() throws {
        let entry = try savedEntry(provenance: testProvenance())
        // Build expected provenance with a different schema version — simulates
        // an artifact from a future schema era being restored on a v1.0 run.
        let wrongSchema = ArtifactProvenance(
            formatVersion: artifactFormatVersion,
            benchmark: "lme", variant: "s", seed: 7,
            encodeBarrier: "drain", estatePosture: "plaintext-optout",
            seedPath: "batch",
            corpusDigest: "deadbeef", embeddingModels: ["binary-default"],
            mootx01Version: "1.1", protocolVersion: "v0.1", markersPresent: true,
            estateSchemaVersion: "2.0")  // wrong schema era
        #expect(throws: ArtifactProvenanceError.self) {
            let _: (URL, [TestManifestEntry])? = try restoreEstateCacheEntry(
                from: entry,
                expectedProvenance: wrongSchema,
                verifyEmbeddingProvider: false) {
                URL(fileURLWithPath: "/tmp/should-not-be-created")
            }
        }
    }

    @Test("absent artifact.json HARD-FAILS (unverifiable never validates)")
    func absentManifestThrows() throws {
        let entry = try savedEntry(provenance: testProvenance())
        try FileManager.default.removeItem(at: entry.appendingPathComponent("artifact.json"))
        #expect(throws: ArtifactProvenanceError.self) {
            let _: (URL, [TestManifestEntry])? = try restoreEstateCacheEntry(
                from: entry,
                expectedProvenance: testProvenance(),
                verifyEmbeddingProvider: false) {
                URL(fileURLWithPath: "/tmp/should-not-be-created")
            }
        }
    }
}

// MARK: - Cache mode semantics

@Suite("EstateCacheMode")
struct EstateCacheModeTests {

    @Test("require mode reads the cache; off does not; error names the entry and the remedy")
    func requireModeSemantics() {
        #expect(EstateCacheMode.require.readsCache)
        #expect(EstateCacheMode.reuse.readsCache)
        #expect(!EstateCacheMode.off.readsCache)
        let err = ArtifactRequiredError(entryPath: "/tmp/x/entry")
        #expect(err.description.contains("/tmp/x/entry"))
        #expect(err.description.contains("never builds"))
        #expect(err.description.contains("--estate-cache reuse"))
    }
}
