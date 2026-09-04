// DrainWorkerOwnershipTests.swift — the drain worker never owns its engine.
//
// Releasing the last reference to a mounted CorpusContentEngine (or legacy
// Corpus) deinitializes it and its worker task returns, so nothing indexes
// under an engine no host can reach any more. A host that skips
// `dropIngestQueue` gets the same teardown the explicit path gives. Swift
// twin of the Rust drain_worker_ownership_tests.

import Foundation
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import CorpusKit

@Suite("Drain worker ownership", .serialized)
struct DrainWorkerOwnershipTests {

    /// Poll until `read` returns nil or `limit` elapses. The worker releases
    /// its per-pass reference within one poll interval plus the pass itself,
    /// so a generous limit keeps the assertion free of scheduling noise.
    private func eventuallyNil<T: AnyObject>(
        within limit: Duration = .seconds(5), _ read: () -> T?
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if read() == nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return read() == nil
    }

    private func inMemoryStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    }

    private func mountedEngine() async throws -> CorpusContentEngine {
        let storage = inMemoryStorage()
#if CORPUSKIT_STANDALONE_PASSAGES
        try await storage.migrate(to: CorpusSchemaProfile.standaloneDeclaration(passageIndexing: false))
#else
        try await storage.migrate(to: CorpusSchemaProfile.standaloneDeclaration())
#endif
        let store = CorpusDocumentStore(storage: storage)
        let engine = try await CorpusContentEngine(
            storage: storage,
            configuration: try CorpusContentConfiguration(mode: .standalone, indexUnit: .wholeContent),
            source: store)
        try await engine.mountIngestQueue()
        return engine
    }

    @Test("a released engine with a mounted queue deinitializes")
    func releasedEngineDeinitializes() async throws {
        weak var weakEngine: CorpusContentEngine?
        do {
            let engine = try await mountedEngine()
            weakEngine = engine
            #expect(weakEngine != nil)
        }
        let released = await eventuallyNil { weakEngine }
        #expect(released, "the drain worker must not keep the engine alive after its last reference is released")
    }

    @Test("a released legacy Corpus with a mounted queue deinitializes")
    func releasedCorpusDeinitializes() async throws {
        weak var weakCorpus: Corpus?
        do {
            let corpus = try await Corpus(storage: inMemoryStorage())
            try await corpus.mountIngestQueue()
            weakCorpus = corpus
            #expect(weakCorpus != nil)
        }
        let released = await eventuallyNil { weakCorpus }
        #expect(released, "the encode and import workers must not keep the corpus alive")
    }

    @Test("explicit teardown then release runs both paths without incident")
    func explicitTeardownThenRelease() async throws {
        weak var weakEngine: CorpusContentEngine?
        do {
            let engine = try await mountedEngine()
            await engine.dropIngestQueue()
            weakEngine = engine
        }
        let released = await eventuallyNil { weakEngine }
        #expect(released)
    }
}
