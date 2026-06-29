// NovelPoolOptInGateTests.swift
//
// Tests for the pool opt-in gate added to LatticeLib.sharedNovelCache.
//
// SECURITY FIX (planned hardening 2026-06-28): the previous sharedNovelCache
// wired NovelPoolSubmitter.makeDefault() unconditionally, writing novel
// tokens in plaintext JSON to the Application Support directory for all
// deployments regardless of whether the pool was intentionally configured.
//
// The fix gates the real submitter on LATTICE_POOL_DIR being explicitly set.
// Without that opt-in the submitter is a no-op; novel tokens are not
// written to disk in unconfigured deployments.
//
// These tests verify the gate behavior at the NovelTokenCache injection level:
// a cache built with a no-op submitter (the new default) must NOT write files
// even after reaching the drain threshold, while one built with a real
// submitter DOES write.

import Foundation
import Testing
@testable import LatticeLib

/// Returns a unique temp directory for this test run.
private func makeTempDir(label: String) -> URL {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent(
        "pool_optin_\(label)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    )
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("NovelPoolOptInGate")
struct NovelPoolOptInGateTests {

    // MARK: - No-op submitter: no files written

    /// When built with a no-op submitter (the new gate behaviour for the
    /// unset-env case), draining at the threshold must NOT write any files.
    ///
    /// This mirrors the expected behaviour of sharedNovelCache when
    /// LATTICE_POOL_DIR is unset: novel tokens are accumulated and drained
    /// through the no-op submitter, never touching the filesystem.
    @Test func noop_submitter_writes_no_files() {
        let tmpDir = makeTempDir(label: "noop")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Inject a no-op submitter — this is what sharedNovelCache uses
        // when LATTICE_POOL_DIR is unset.
        let cache = NovelTokenCache(
            tableVersion: "test-v1",
            platform: "apple",
            taggerVersion: "hmm-viterbi-3",
            submitter: { _ in }
        )

        // Record enough entries to trigger a drain.
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "noop_token_\(i)", wordClass: .noun)
        }

        // The tmp dir should still be empty — no-op means no file writes.
        let files = (try? FileManager.default.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil
        )) ?? []
        #expect(files.isEmpty,
                "no-op submitter must not write files; found: \(files.map(\.lastPathComponent))")
        // Cache must have drained (count back to 0).
        #expect(cache.count == 0,
                "cache must drain to 0 after reaching threshold")
    }

    // MARK: - Real submitter: files written on drain

    /// When built with the real local-file submitter (opt-in via a pool dir),
    /// draining at the threshold MUST write a JSON file.
    ///
    /// This confirms the real submitter path still works after the gate
    /// change — opting in via LATTICE_POOL_DIR or an explicit pool dir must
    /// continue to produce observable pool files.
    @Test func real_submitter_writes_file_on_drain() throws {
        let tmpDir = makeTempDir(label: "real")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let cache = NovelTokenCache(
            tableVersion: "test-v1",
            platform: "apple",
            taggerVersion: "hmm-viterbi-3",
            submitter: NovelPoolSubmitter.make(poolDirectory: tmpDir)
        )

        // Record exactly the threshold; the drain fires at the threshold.
        for i in 0..<NovelTokenCache.poolSubmitThreshold {
            cache.record(token: "real_token_\(i)", wordClass: .noun)
        }

        // One JSON file must exist in the pool dir.
        let files = try FileManager.default.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        #expect(files.count == 1,
                "real submitter must write exactly one JSON file on drain; found: \(files.count)")
        #expect(cache.count == 0,
                "cache must drain to 0 after reaching threshold")
    }
}
