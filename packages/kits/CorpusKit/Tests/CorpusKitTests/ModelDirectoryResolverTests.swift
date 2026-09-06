// ModelDirectoryResolverTests.swift
//
// Tests for ModelDirectoryResolver.
//
// Three discriminating tests:
//
//  1. resolverFindsFixtureBundle — resolver finds the test fixture directory
//     via the test bundle and passes vocab.txt sha256 verification.
//     Failure mode: a stale model loads silently (wrong directory returned
//     despite mismatched vocab).
//
//  2. corruptedVocabReturnsNil — a vocab.txt with wrong content returns nil
//     and does not hand back a URL for the corrupted directory.
//     Failure mode: a tampered or stale vocab silently passes verification.
//
//  3. missingDirectoryReturnsNil — a model ID with no matching directory
//     in either slot returns nil without crashing or logging an error.
//     Failure mode: resolver crashes or returns a non-existent URL.
//
// The test bundle fixture at Tests/Fixtures/encoder-models/minilm-l6-v2-w60/
// contains the real vocab.txt (231 KB, sha256-pinned) and a placeholder
// MiniLM-L6-v2.mlmodelc directory. The real 90 MB CoreML bundle is not
// committed; the .mlmodelc placeholder lets the resolver confirm directory
// presence without the full binary artifact.

import Testing
import Foundation
@testable import CorpusKitProviders

@Suite("ModelDirectoryResolver")
struct ModelDirectoryResolverTests {

    // MARK: - Helpers

    /// A temporary data directory that does NOT contain a downloaded model
    /// (the 1.2 download slot stays empty throughout these tests).
    private func emptyDataDirectory() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("moot-resolver-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - Tests

    /// Resolver finds the fixture directory in the test bundle and passes
    /// vocab.txt sha256 verification.
    ///
    /// Failure mode: a stale model loads silently — the resolver would return
    /// a URL to a directory whose vocab.txt has the wrong sha256.
    @Test func resolverFindsFixtureBundle() throws {
        let dataDir = try emptyDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        // The test bundle's resource path contains the fixture directory at:
        // Fixtures/encoder-models/minilm-l6-v2-w60/
        // It is declared via .copy("../Fixtures") in the test target's
        // resources block (see Package.swift changes in this commit).
        let bundle = Bundle.module

        let result = ModelDirectoryResolver.encoderModelDirectory(
            for: "minilm-l6-v2-w60",
            dataDirectory: dataDir,
            bundle: bundle
        )

        #expect(result != nil, "resolver must return a URL for the test fixture bundle")
        if let url = result {
            let vocabPath = url.appendingPathComponent("vocab.txt")
            #expect(FileManager.default.fileExists(atPath: vocabPath.path),
                    "returned URL must point to a directory containing vocab.txt")
        }
    }

    /// A corrupted vocab.txt (wrong bytes) causes the resolver to return nil
    /// instead of handing back the directory with bad vocab content.
    ///
    /// Failure mode: resolver returns a URL despite sha256 mismatch,
    /// causing the encoder to tokenise with a wrong vocabulary.
    @Test func corruptedVocabReturnsNil() throws {
        // Build a data directory whose download slot has a corrupted vocab.txt.
        // The resolver looks in dataDirectory/models/<modelID>/ (slot 1).
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moot-corrupt-\(UUID().uuidString)", isDirectory: true)
        // Construct the full slot-1 model directory path.
        let modelDir = dataDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("minilm-l6-v2-w60", isDirectory: true)
        let mlmodelcDir = modelDir.appendingPathComponent("MiniLM-L6-v2.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: mlmodelcDir, withIntermediateDirectories: true)
        // Write corrupted vocab — any bytes that differ from the real sha256.
        let badVocab = Data("not-a-real-vocab".utf8)
        try badVocab.write(to: modelDir.appendingPathComponent("vocab.txt"))

        defer { try? FileManager.default.removeItem(at: dataDir) }

        // Pass Bundle.main as the bundle: it does not contain a minilm-l6-v2-w60
        // directory during swift test runs, so the resolver tries slot 1 only
        // and must reject it due to the bad sha256.
        let result = ModelDirectoryResolver.encoderModelDirectory(
            for: "minilm-l6-v2-w60",
            dataDirectory: dataDir,
            bundle: Bundle.main
        )

        #expect(result == nil,
                "resolver must return nil when vocab.txt sha256 does not match")
    }

    /// An unknown model ID returns nil without crashing.
    ///
    /// Failure mode: resolver crashes or returns a URL to a non-existent
    /// directory when handed an unrecognised model identifier.
    @Test func unknownModelIDReturnsNil() throws {
        let dataDir = try emptyDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let result = ModelDirectoryResolver.encoderModelDirectory(
            for: "nonexistent-model-v99",
            dataDirectory: dataDir,
            bundle: Bundle.module
        )

        #expect(result == nil,
                "resolver must return nil for an unrecognised model ID")
    }
}
