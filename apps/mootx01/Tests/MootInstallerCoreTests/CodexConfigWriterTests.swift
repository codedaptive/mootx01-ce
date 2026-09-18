// CodexConfigWriterTests.swift
//
// Regression coverage for CF-01 Finding #5: Codex's config.toml was
// rewritten with no permission constant at all, leaving it world-readable
// (verified empirically before this fix: a plain `String.write(to:
// atomically:true, encoding:.utf8)` produces mode 0644 under a standard
// umask of 022). These tests exercise CodexConfigWriter directly against
// sandboxed temp directories — no real user files are touched.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("CodexConfigWriter")
struct CodexConfigWriterTests {

    @Test("fresh write produces mode 0600")
    func freshWriteIsOwnerOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")

        try CodexConfigWriter.write("[features]\nmemories = false\n", to: url)

        #expect(try posixMode(at: url) == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "[features]\nmemories = false\n")
    }

    @Test("rewrite of an existing 0600 file keeps 0600")
    func rewriteOfOwnerOnlyStaysOwnerOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")

        try CodexConfigWriter.write("first\n", to: url)
        #expect(try posixMode(at: url) == 0o600)

        try CodexConfigWriter.write("second\n", to: url)

        #expect(try posixMode(at: url) == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "second\n")
    }

    @Test("rewrite narrows a world-readable existing mode to 0600, fixing the pre-fix bug state")
    func rewriteNarrowsWorldReadableExistingMode() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")

        // Simulate the pre-fix bug: a config.toml left world-readable by the
        // old EnableCommand write path (String.write(atomically:) under a
        // standard umask — reproduced empirically as mode 0644).
        FileManager.default.createFile(
            atPath: url.path, contents: Data("orig\n".utf8),
            attributes: [.posixPermissions: 0o644])
        #expect(try posixMode(at: url) == 0o644)

        try CodexConfigWriter.write("rewritten\n", to: url)

        // 0644 & 0600 == 0600 — group/other read bits are stripped. This is
        // a narrowing, not a widening: the "never widen" rule only forbids
        // adding permission bits, and the file is actively insecure before
        // this rewrite.
        #expect(try posixMode(at: url) == 0o600)
    }

    @Test("rewrite never widens a mode narrower than 0600")
    func rewriteNeverWidensNarrowerExistingMode() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")

        // A file the user (or some other tool) left owner-read-only —
        // narrower than the 0600 this writer targets.
        FileManager.default.createFile(
            atPath: url.path, contents: Data("orig\n".utf8),
            attributes: [.posixPermissions: 0o400])
        #expect(try posixMode(at: url) == 0o400)

        try CodexConfigWriter.write("rewritten\n", to: url)

        // 0400 & 0600 == 0400 — the write bit the user didn't have is never
        // added back. A rewrite must never widen an existing mode.
        #expect(try posixMode(at: url) == 0o400)
        #expect(try String(contentsOf: url, encoding: .utf8) == "rewritten\n")
    }

    @Test("no intermediate file survives the write, at any permission")
    func noIntermediateFileSurvives() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")

        try CodexConfigWriter.write("content\n", to: url)
        try CodexConfigWriter.write("content again\n", to: url)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["config.toml"],
                 "the temp file used for the atomic rename must not survive the write")
    }

    @Test("creates parent directories as needed")
    func createsParentDirectories() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/deeper/config.toml")

        try CodexConfigWriter.write("content\n", to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try posixMode(at: url) == 0o600)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-config-writer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func posixMode(at url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attrs[.posixPermissions] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return number.intValue
    }
}
