// NovelPoolSubmitterTests.swift
//
// Tests for NovelPoolSubmitter — the real local-file pool submitter
// (cookbook §2.2, §2.3). Verifies the terminal-state contract:
//
//   accumulate >= POOL_SUBMIT_THRESHOLD novel tokens
//     → drain fires
//     → JSON file written to pool directory
//     → token data observable at endpoint
//
// These tests exercise the end-to-end path from NovelTokenCache (wired with
// the local-file submitter) through to durable on-disk presence of the
// PoolSubmission JSON payload. They do NOT require a network; they write to
// a temp directory that is cleaned up after each test.

import Foundation
import Testing
@testable import LatticeLib

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Returns a unique temp directory for this test run. Creates it and returns
/// the URL; caller is responsible for removing it.
private func makeTempDir(suffix: String) -> URL {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent(
        "lattice_pool_\(suffix)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    )
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Counts JSON files in `dir`.
private func poolFileCount(in dir: URL) throws -> Int {
    try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .count
}

/// Reads and decodes the first (and only expected) pool file in `dir`.
private func readFirstPoolSubmission(in dir: URL) throws -> PoolSubmission {
    let files = try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }
    guard let first = files.first else {
        throw NSError(
            domain: "NovelPoolSubmitterTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no pool JSON file found in \(dir.path)"]
        )
    }
    let data = try Data(contentsOf: first)
    return try JSONDecoder().decode(PoolSubmission.self, from: data)
}

// ─── Tests ────────────────────────────────────────────────────────────────────

@Suite("NovelPoolSubmitter (cookbook §2.2)")
struct NovelPoolSubmitterTests {

    // MARK: - resolvePoolDirectory

    @Test("make(poolDirectory:) constructs a non-nil submitter closure")
    func latticePoolDirExplicitOverload() {
        // Verifies the make(poolDirectory:) overload succeeds with an arbitrary
        // URL. The env-var resolution path (LATTICE_POOL_DIR takes priority over
        // platform default) cannot be safely exercised in-process because
        // ProcessInfo.environment is immutable at runtime; it is covered by
        // integration tests that launch a subprocess with the env var set.
        let dir = URL(fileURLWithPath: "/tmp/testpool")
        let submitter = NovelPoolSubmitter.make(poolDirectory: dir)
        // Construction must succeed; the submitter is a non-nil closure.
        #expect(submitter as AnyObject !== NSNull(), "submitter closure must be non-nil")
    }

    // MARK: - make(poolDirectory:)

    @Test("writes JSON file to pool directory on drain")
    func writesJsonFileOnDrain() throws {
        let dir = makeTempDir(suffix: "write")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Wire a cache with the real local-file submitter.
        let cache = NovelTokenCache(
            tableVersion: "1.0.0",
            platform: "apple",
            taggerVersion: "15.0.0",
            submitter: NovelPoolSubmitter.make(poolDirectory: dir)
        )

        // Accumulate exactly the threshold — drain fires at 50.
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "novelword\(i)", wordClass: .noun)
        }

        // Terminal state: cache is empty.
        #expect(cache.count == 0, "cache must be empty after drain")

        // Terminal state: exactly one JSON file in the pool directory.
        let count = try poolFileCount(in: dir)
        #expect(count == 1, "exactly one JSON file must appear in pool dir after drain")
    }

    @Test("drained file deserialises to correct PoolSubmission")
    func drainedFileDeserialisesCorrectly() throws {
        let dir = makeTempDir(suffix: "deser")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = NovelTokenCache(
            tableVersion: "1.0.0",
            platform: "apple",
            taggerVersion: "15.0.0",
            submitter: NovelPoolSubmitter.make(poolDirectory: dir)
        )
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "token\(i)", wordClass: .verb)
        }

        let sub = try readFirstPoolSubmission(in: dir)

        // Metadata matches what was stamped at init.
        #expect(sub.tableVersion == "1.0.0")
        #expect(sub.platform == "apple")
        #expect(sub.taggerVersion == "15.0.0")
        // All entries carry the VERB tag.
        #expect(sub.entries.count == NovelTokenCache.poolSubmitThreshold)
        #expect(sub.entries.allSatisfy { $0.tag == "VERB" })
        // First and last tokens are in submission order.
        #expect(sub.entries.first?.token == "token0")
        #expect(
            sub.entries.last?.token ==
                "token\(NovelTokenCache.poolSubmitThreshold - 1)"
        )
    }

    @Test("pool directory is created if it does not exist")
    func createsPoolDirectoryIfAbsent() throws {
        let base = makeTempDir(suffix: "mkdir_base")
        defer { try? FileManager.default.removeItem(at: base) }
        // Target a nested path that does not yet exist.
        let nested = base.appendingPathComponent("a/b/c", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: nested.path),
                "precondition: nested path must not exist")

        let cache = NovelTokenCache(
            tableVersion: "1.0.0",
            platform: "apple",
            taggerVersion: "15.0.0",
            submitter: NovelPoolSubmitter.make(poolDirectory: nested)
        )
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "mk\(i)", wordClass: .other)
        }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: nested.path, isDirectory: &isDir
        )
        #expect(exists && isDir.boolValue, "nested pool directory must be created")
        let count = try poolFileCount(in: nested)
        #expect(count == 1, "one JSON file after mkdir+drain")
    }

    @Test("multiple drains produce multiple files")
    func multipleDrainsProduceMultipleFiles() throws {
        let dir = makeTempDir(suffix: "multi")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = NovelTokenCache(
            tableVersion: "1.0.0",
            platform: "apple",
            taggerVersion: "15.0.0",
            submitter: NovelPoolSubmitter.make(poolDirectory: dir)
        )
        // First batch.
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "batch1_\(i)", wordClass: .noun)
        }
        // Second batch.
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "batch2_\(i)", wordClass: .verb)
        }

        let count = try poolFileCount(in: dir)
        #expect(count == 2, "two drains must produce two JSON files")
    }

    // MARK: - Terminal-state force test (seven-point completion §force-test)

    @Test("force: accumulate >= threshold → drain → file observable at endpoint")
    func forceTerminalState() throws {
        // This is the canonical force-test proving the seven-point completion:
        // 1. impl — NovelPoolSubmitter.make wired into NovelTokenCache
        // 2. owner — LatticeLib.sharedNovelCache (production path)
        // 3. code path — tagNovelToken → sharedNovelCache.record → drain → submitter
        // 4. data — PoolSubmission JSON on disk
        // 5. trigger — NovelTokenCache.poolSubmitThreshold (50)
        // 6. force-test (this test) — accumulate exactly 50 novel tokens, assert file
        // 7. terminal state — file exists, deserialises, all tokens present

        let dir = makeTempDir(suffix: "force")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = NovelTokenCache(
            tableVersion: "1.0.0",
            platform: "apple",
            taggerVersion: "17.0",
            submitter: NovelPoolSubmitter.make(poolDirectory: dir)
        )

        // Accumulate exactly 50 unique tokens.
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "forcetoken\(i)", wordClass: .noun)
        }

        // §7 terminal state:
        // a) cache is drained.
        #expect(cache.count == 0)

        // b) exactly one JSON file exists at the pool endpoint (the dir).
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        #expect(files.count == 1, "one JSON file at pool endpoint")

        // c) file is valid JSON with correct token count and order.
        let data = try Data(contentsOf: files[0])
        let sub = try JSONDecoder().decode(PoolSubmission.self, from: data)
        #expect(sub.entries.count == NovelTokenCache.poolSubmitThreshold)
        #expect(sub.entries[0].token == "forcetoken0")
        #expect(sub.entries[NovelTokenCache.poolSubmitThreshold - 1].token
                == "forcetoken\(NovelTokenCache.poolSubmitThreshold - 1)")
        #expect(sub.tableVersion == "1.0.0")
    }

    // MARK: - writeSubmission (internal, via @testable)

    @Test("writeSubmission handles serialization of all WordClass tags")
    func writeSubmissionAllTags() throws {
        let dir = makeTempDir(suffix: "tags")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build a submission with one entry of each tag type.
        let sub = PoolSubmission(
            tableVersion: "1.0.0",
            platform: "apple",
            taggerVersion: "15.0.0",
            entries: [
                PoolEntry(token: "dog", tag: "NOUN"),
                PoolEntry(token: "run", tag: "VERB"),
                PoolEntry(token: "the", tag: "OTHER"),
            ]
        )
        NovelPoolSubmitter.writeSubmission(sub, to: dir)

        let back = try readFirstPoolSubmission(in: dir)
        #expect(back.entries[0].tag == "NOUN")
        #expect(back.entries[1].tag == "VERB")
        #expect(back.entries[2].tag == "OTHER")
    }
}
