// ArtifactDatabaseProbeTests.swift — gate tests for estateDatabasePath(in:).
//
// Suite map:
//
//   ArtifactDatabaseProbe
//     A: root layout    — estate.sqlite at the root → non-nil path
//     B: nested layout  — databases/default/estate.sqlite (Rust-built) → non-nil path
//     C: absent         — neither path exists → nil (refusal gate)
//
// Run with:
//   swift test --scratch-path .build-probe --filter ArtifactDatabaseProbe
//
// These three cases are the discriminating gate for the Task-1 routing change:
// the inline two-condition check in ArtifactRecallRunner was replaced with a
// call to estateDatabasePath(in:). Case B (nested layout) is the key
// discriminator — the old inline check was identical; the helper just owns
// the logic in one place now.

import Foundation
import Testing
@testable import mcp_benchmarker

@Suite("ArtifactDatabaseProbe")
struct ArtifactDatabaseProbeTests {

    /// Make a scratch directory that does NOT contain estate.sqlite anywhere.
    private func makeEmptyDir() throws -> URL {
        let dir = URL(fileURLWithPath:
            "/tmp/artifact-db-probe-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Create an empty file at the given path, creating intermediate directories.
    private func touch(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    // MARK: - Case A: root layout

    /// Swift-built artifacts keep estate.sqlite at the root.
    /// estateDatabasePath must return a non-nil path ending in "estate.sqlite".
    @Test("root layout: estate.sqlite at root resolves to non-nil")
    func rootLayoutResolves() throws {
        let dir = try makeEmptyDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try touch(at: dir.appendingPathComponent("estate.sqlite").path)

        let result = estateDatabasePath(in: dir)
        #expect(result != nil, "root-layout estate.sqlite must resolve to a non-nil path")
        #expect(result?.hasSuffix("estate.sqlite") == true,
                "resolved path must end in estate.sqlite")
    }

    // MARK: - Case B: nested layout (discriminating case)

    /// Rust-built artifacts keep estate.sqlite at databases/default/estate.sqlite.
    /// This is the layout that the old inline check in ArtifactRecallRunner and
    /// artifact_recall.rs also handled; the helper must resolve it.
    @Test("nested layout: databases/default/estate.sqlite resolves to non-nil")
    func nestedLayoutResolves() throws {
        let dir = try makeEmptyDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let nestedPath = dir
            .appendingPathComponent("databases")
            .appendingPathComponent("default")
            .appendingPathComponent("estate.sqlite").path
        try touch(at: nestedPath)

        let result = estateDatabasePath(in: dir)
        #expect(result != nil, "nested-layout estate.sqlite must resolve to a non-nil path")
        #expect(result?.hasSuffix("estate.sqlite") == true,
                "resolved path must end in estate.sqlite")
    }

    // MARK: - Case C: absent (refusal gate — helper level)

    /// When neither layout exists the helper returns nil.
    /// This tests the helper in isolation; the call-site gate
    /// (ArtifactCallSiteGateTests.askArtifactQuestionsRefusesWhenEstateMissing)
    /// verifies the error message askArtifactQuestions builds from this nil.
    @Test("absent: neither layout exists returns nil")
    func absentReturnsNil() throws {
        let dir = try makeEmptyDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = estateDatabasePath(in: dir)
        #expect(result == nil,
                "absent estate.sqlite (both layouts) must return nil")
    }
}

// ── Call-site gate ─────────────────────────────────────────────────────────
// Gates the fail-fast guard at askArtifactQuestions rather than just the
// helper. The guard fires before serve launches, so no binary or live
// estate is needed.
//
// What makes this go red: removing the guard
//   guard estateDatabasePath(in: estateDir) != nil else { throw ... }
// from askArtifactQuestions causes the call to proceed past the guard and
// fail later (ENOENT from id-map load or a serve-launch failure), and
// NEITHER of those errors contains "no estate.sqlite in", so the message
// assertions both fail.

@Suite("ArtifactCallSiteGate")
struct ArtifactCallSiteGateTests {

    private func makeEmptyDir() throws -> URL {
        let dir = URL(fileURLWithPath:
            "/tmp/artifact-callsite-gate-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("askArtifactQuestions refuses estate dir with no estate.sqlite")
    func askArtifactQuestionsRefusesWhenEstateMissing() async throws {
        let dir = try makeEmptyDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No estate.sqlite anywhere under dir — both root and nested layouts absent.
        let config = ArtifactRecallConfig(
            dataset: .locomo,
            targetScale: .benchAggregate,
            estateDir: nil,
            catalogPath: nil,
            questionsPath: dir.appendingPathComponent("questions.jsonl"),
            scope: .estate,
            idPrefix: "",
            limit: 0,
            topK: 5,
            outPath: dir.appendingPathComponent("report.json"),
            mootBinaryPath: "/dev/null"
        )
        do {
            _ = try await askArtifactQuestions(estateDir: dir, questions: [], config: config)
            Issue.record("expected MCPError for missing estate.sqlite; got success")
        } catch let error as MCPError {
            #expect(error.description.contains("no estate.sqlite in"),
                    "message must contain 'no estate.sqlite in' — got: \(error.description)")
            #expect(error.description.contains(dir.path),
                    "message must contain the estate directory path — got: \(error.description)")
        } catch {
            Issue.record("unexpected error type \(type(of: error)): \(error)")
        }
    }
}
