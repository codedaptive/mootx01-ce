// EncoderActivationTests.swift
//
// The `"encoder"` value of the `embedding_provider` manifest key and its
// failure contract: a device without the model directory (the default
// resolver) and a directory whose vocabulary hashes wrong both leave the
// estate with no encoder, log once, and never throw out of the open path;
// the Corpus ensemble stays the five-signal default. Plus the two companion
// manifest keys and their defaults.
//
// Failure modes: a factory error escaping `wireSubstores` (the provision
// would throw), the encoder being appended to the ensemble as if it were a
// provider, or a malformed `encoder_head` breaking the open instead of
// falling back to the default.
//
// Storage: SQLite so the manifest key written in one lifecycle survives the
// close + re-provision that runs `wireSubstores` again (same pattern as
// EmbeddingProviderConsumptionTests). `lifetime: .ephemeral` keeps Ed25519
// identities out of the real Keychain.

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitSQLite
@testable import GeniusLocusKit

private func scratchURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("glk-encoder-act-\(UUID().uuidString).sqlite3")
}

private func sqliteStorageAt(_ url: URL) throws -> any Storage {
    try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: url, busyTimeout: 5.0)))
}

private func glkParams(estateName: String) -> EstateProvisionParams {
    EstateProvisionParams(
        estateName: estateName,
        kind: .glk,
        zoomWindowLow: 1,
        zoomWindowHigh: 10,
        frameworkProfile: "KnowledgeWork",
        syncMode: .none,
        lifetime: .ephemeral)
}

/// Resolver that points every model id at one fixed directory.
private struct FixedDirectoryResolver: ModelDirectoryResolving {
    let directory: URL
    func encoderModelDirectory(for modelID: String) -> URL? { directory }
}

@Suite("Encoder activation — constants")
struct EncoderActivationConstantTests {

    @Test("provider id and manifest keys are the wire strings")
    func wireStrings() {
        #expect(GeniusLocusKit.encoderProviderID == "encoder")
        #expect(GeniusLocusKit.encoderHeadMetaKey == "encoder_head")
        #expect(GeniusLocusKit.encoderBatchMetaKey == "encoder_batch")
        #expect(GeniusLocusKit.encoderHeadMetaKey != GeniusLocusKit.embeddingProviderMetaKey)
    }

    @Test("defaults are head 30 and batch 64 off iOS")
    func defaults() {
        #expect(GeniusLocusKit.defaultEncoderHead == 30)
#if os(iOS)
        #expect(GeniusLocusKit.defaultEncoderBatch == 16)
#else
        #expect(GeniusLocusKit.defaultEncoderBatch == 64)
#endif
    }
}

@Suite("Encoder activation — failure contract and manifest keys", .serialized)
struct EncoderActivationEstateTests {

    @Test("encoder provisioned without a model directory: no encoder, ensemble untouched, no throw")
    func noModelDirectory() async throws {
        let kit = GeniusLocusKit()
        let url = scratchURL()
        let owner = OwnerCredentials(ownerIdentifier: "encoder-act-nodir")
        let params = glkParams(estateName: "EncoderNoDirEstate")

        let handle1 = try await kit.provision(storage: try sqliteStorageAt(url), owner: owner, params: params)
        try await kit.provisionEmbeddingProvider(GeniusLocusKit.encoderProviderID, for: handle1)
        try await kit.close(handle1)

        // Re-provision runs wireSubstores → applyProvisionedEmbeddingProvider
        // → activateSpanEncoder with the default (nil) resolver.
        let handle2 = try await kit.provision(storage: try sqliteStorageAt(url), owner: owner, params: params)
        #expect(await kit.registeredSpanEncoder(for: handle2) == nil)
        let corpus = try #require(await kit.corpusKits[handle2])
        let modelIDs = await corpus.providerGenerations().map(\.modelID)
        // The ensemble is the default dense ensemble exactly — Random Indexing
        // alone while the dense families are dark (contract sheet §13) — and
        // the encoder is never a member of it.
        #if MOOTX01_DENSE_FAMILIES
        #expect(modelIDs == ["random-indexing-v1", "ppmi-v1", "lsa-v1", "nmf-v1", "fdc-v1"],
                "the encoder is never an ensemble member, got \(modelIDs)")
        #else
        #expect(modelIDs == ["random-indexing-v1"],
                "the encoder is never an ensemble member, got \(modelIDs)")
        #endif
        try await kit.close(handle2)
    }

    @Test("encoder provisioned with a wrong-vocab directory: factory error stays inside the lifecycle")
    func hashMismatchDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-encoder-act-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\n".utf8).write(to: dir.appendingPathComponent("vocab.txt"))

        let kit = GeniusLocusKit()
        await kit.setModelDirectoryResolver(FixedDirectoryResolver(directory: dir))
        let url = scratchURL()
        let owner = OwnerCredentials(ownerIdentifier: "encoder-act-hash")
        let params = glkParams(estateName: "EncoderHashEstate")

        let handle1 = try await kit.provision(storage: try sqliteStorageAt(url), owner: owner, params: params)
        try await kit.provisionEmbeddingProvider(GeniusLocusKit.encoderProviderID, for: handle1)
        try await kit.close(handle1)

        // The resolver returns the directory; the factory throws
        // tokenizerMismatch; the lifecycle swallows it (one log line).
        let handle2 = try await kit.provision(storage: try sqliteStorageAt(url), owner: owner, params: params)
        #expect(await kit.registeredSpanEncoder(for: handle2) == nil)
        try await kit.close(handle2)
    }

    @Test("encoder_head / encoder_batch round-trip, malformed values fall back to defaults")
    func manifestKeys() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "encoder-act-keys")
        let handle = try await kit.provision(
            storage: try sqliteStorageAt(scratchURL()), owner: owner,
            params: glkParams(estateName: "EncoderKeysEstate"))

        #expect(await kit.provisionedEncoderHead(for: handle) == GeniusLocusKit.defaultEncoderHead)
        #expect(await kit.provisionedEncoderBatch(for: handle) == GeniusLocusKit.defaultEncoderBatch)

        try await kit.provisionEncoderHead(45, for: handle)
        try await kit.provisionEncoderBatch(8, for: handle)
        #expect(await kit.provisionedEncoderHead(for: handle) == 45)
        #expect(await kit.provisionedEncoderBatch(for: handle) == 8)

        // A malformed or non-positive value never breaks a read: default.
        let estate = try await kit.estate(for: handle)
        try await estate.setMeta(key: GeniusLocusKit.encoderHeadMetaKey, value: "thirty")
        try await estate.setMeta(key: GeniusLocusKit.encoderBatchMetaKey, value: "0")
        #expect(await kit.provisionedEncoderHead(for: handle) == GeniusLocusKit.defaultEncoderHead)
        #expect(await kit.provisionedEncoderBatch(for: handle) == GeniusLocusKit.defaultEncoderBatch)
        try await kit.close(handle)
    }
}
