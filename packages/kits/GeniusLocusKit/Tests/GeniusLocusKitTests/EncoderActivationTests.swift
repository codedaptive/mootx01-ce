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
import CorpusKitProviders
import SynapseKit
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

/// Resolver that records every model id requested and returns nil (no
/// model directory on this device). Used to prove activation read the
/// seeded row id rather than the floor model id.
private final class SpyResolver: ModelDirectoryResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [String] = []

    var requested: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requested
    }

    func encoderModelDirectory(for modelID: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        _requested.append(modelID)
        return nil
    }
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

    @Test("provision writes the default encoder key; an estate that names a provider keeps it")
    func provisionDefaultEncoder() async throws {
        let kit = GeniusLocusKit()
        let url = scratchURL()
        let owner = OwnerCredentials(ownerIdentifier: "encoder-act-default")
        let params = glkParams(estateName: "EncoderDefaultEstate")

        // A fresh provision is born with the encoder as its recall stage.
        let handle = try await kit.provision(storage: try sqliteStorageAt(url), owner: owner, params: params)
        #expect(try await kit.provisionedEmbeddingProvider(for: handle) == GeniusLocusKit.encoderProviderID)
        // Idempotent: a second call writes nothing.
        #expect(try await kit.provisionDefaultEncoderIfAbsent(for: handle) == false)
        // An estate that names another provider is never overwritten.
        try await kit.provisionEmbeddingProvider("apple-nl-v1", for: handle)
        #expect(try await kit.provisionDefaultEncoderIfAbsent(for: handle) == false)
        #expect(try await kit.provisionedEmbeddingProvider(for: handle) == "apple-nl-v1")
        // A cleared key is absent again and the default returns.
        try await kit.provisionEmbeddingProvider("", for: handle)
        #expect(try await kit.provisionDefaultEncoderIfAbsent(for: handle) == true)
        #expect(try await kit.provisionedEmbeddingProvider(for: handle) == GeniusLocusKit.encoderProviderID)
        try await kit.close(handle)
    }

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
        // plus the LSA whole-record float provider (GENIUSLOCUSKIT_SPEC 3.32.0)
        // — and the encoder is never a member of it.
        #expect(modelIDs == ["random-indexing-v1", "lsa-v1"],
                "the encoder is never an ensemble member, got \(modelIDs)")
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

    @Test("provision seeds the active encoder_models row and activation reads it")
    func provisionSeedsTheActiveEncoderRowAndActivatesUnderIt() async throws {
        // SpyResolver records which model ids activation requests; returns nil
        // so no model loads (tests the seeding path, not the encoder load path).
        let spy = SpyResolver()
        let kit = GeniusLocusKit()
        await kit.setModelDirectoryResolver(spy)
        let url = scratchURL()
        let owner = OwnerCredentials(ownerIdentifier: "encoder-act-seed")
        let storage = try sqliteStorageAt(url)

        let handle = try await kit.provision(storage: storage, owner: owner,
                                             params: glkParams(estateName: "EncoderSeedEstate"))

        // The seam seeds the bundled row as the active entry at open.
        let registry = EncoderModelStore(storage: storage)
        let activeRow = try await registry.active()
        #expect(activeRow?.modelID == EncoderModelSeed.modelID)
        #expect(activeRow?.isActive == true)

        // Activation asked the resolver for the seeded row's id, not the
        // floor model (minilm-l6-v2-w60), proving it read the seeded row.
        #expect(spy.requested == [EncoderModelSeed.modelID])

        // Spy returns nil: no model directory, so no encoder and no rerank stage.
        #expect(await kit.isSpanRerankRegistered(for: handle) == false)
        #expect(await kit.registeredSpanEncoder(for: handle) == nil)

        // Capture one drawer; assert the VectorStore has no span rows yet
        // (the span-encode standing signal has not run).
        let frame = CaptureFrame(content: "encoder seed test content", channel: .typed,
                                 room: "encoder-seed-tests", latticeAnchor: .udc("000"),
                                 addedBy: "encoder-seed-tests", embeddingModelID: "test-v1")
        let drawer = try await kit.capture(handle, frame)
        let vectors = try #require(await kit.registeredVectorStore(for: handle))
        let spanRows = try await vectors.spanVectors(itemIDs: [drawer.id],
                                                     modelID: EncoderModelSeed.modelID)
        #expect(spanRows.isEmpty)

        // Seeding is idempotent: the active row already exists.
        let wasSeeded = try await kit.seedDefaultEncoderModelIfAbsent(for: handle)
        #expect(wasSeeded == false)
        #expect(try await registry.all().count == 1)

        try await kit.close(handle)
    }

    @Test("serve open path seeds the encoder row through wireGLKSubstores")
    func serveOpenPathSeedsThroughWireGLKSubstores() async throws {
        let url = scratchURL()
        let owner = OwnerCredentials(ownerIdentifier: "encoder-seed-serve")

        // LocusOnly provision so the encoder key is NOT written (the provision
        // path gates on params.kind != .locusOnly). This mimics the first-run
        // state of an estate provisioned before the encoder was configured.
        let kit1 = GeniusLocusKit()
        let locusParams = EstateProvisionParams(
            estateName: "EncoderServeSeedEstate",
            kind: .locusOnly,
            zoomWindowLow: 1, zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none, lifetime: .ephemeral)
        let h1 = try await kit1.provision(storage: try sqliteStorageAt(url), owner: owner,
                                          params: locusParams)
        try await kit1.close(h1)

        // Serve open path: open + provisionDefaultEncoderIfAbsent + wireGLKSubstores.
        let kit2 = GeniusLocusKit()
        let storage2 = try sqliteStorageAt(url)
        let handle = try await kit2.open(storage: storage2, owner: owner,
                                         identityKeyStore: InMemoryEstateIdentityKeyStore())

        // Write the encoder key (ServeCommand does this on first run).
        let keyWritten = try await kit2.provisionDefaultEncoderIfAbsent(for: handle)
        #expect(keyWritten == true)

        // The registry is empty before wiring: no row has been seeded yet.
        let registry = EncoderModelStore(storage: storage2)
        #expect(try await registry.active() == nil)

        // Wire substores: activateSpanEncoderIfProvisioned runs and seeds the row.
        try await kit2.wireGLKSubstores(for: handle, backingStorage: storage2)

        // After wiring the bundled row is present as the active entry.
        let activeRow = try await registry.active()
        #expect(activeRow?.modelID == EncoderModelSeed.modelID)

        try await kit2.close(handle)
    }

    /// Runs only where the Arctic CoreML directory exists (`MOOT_ENCODER_MODEL_DIR`
    /// names it): the seeded row loads, the rerank stage registers on the fresh
    /// estate, and a captured drawer still has no span rows until the span-encode
    /// signal runs. Skipped elsewhere; the report records whether it ran.
    @Test("a real model directory registers the rerank stage on a fresh estate",
          .enabled(if: ProcessInfo.processInfo.environment["MOOT_ENCODER_MODEL_DIR"] != nil))
    func realModelRegistersTheRerankStage() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOOT_ENCODER_MODEL_DIR"])
        let kit = GeniusLocusKit()
        await kit.setModelDirectoryResolver(FixedDirectoryResolver(directory: URL(fileURLWithPath: path, isDirectory: true)))
        let storage = try sqliteStorageAt(scratchURL())
        let owner = OwnerCredentials(ownerIdentifier: "encoder-act-real")
        let handle = try await kit.provision(storage: storage, owner: owner,
                                             params: glkParams(estateName: "EncoderRealModelEstate"))
        #expect(try await EncoderModelStore(storage: storage).active()?.modelID == EncoderModelSeed.modelID)
        #expect(await kit.isSpanRerankRegistered(for: handle) == true)
        let frame = CaptureFrame(content: "encoder real model test content", channel: .typed,
                                 room: "encoder-real-tests", latticeAnchor: .udc("000"),
                                 addedBy: "encoder-real-tests", embeddingModelID: "test-v1")
        let drawer = try await kit.capture(handle, frame)
        let vectors = try #require(await kit.registeredVectorStore(for: handle))
        #expect(try await vectors.spanVectors(itemIDs: [drawer.id], modelID: EncoderModelSeed.modelID).isEmpty)
        try await kit.close(handle)
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
