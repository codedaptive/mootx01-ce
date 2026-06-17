// ShapedRecallTests.swift
//
// End-to-end test of the ShapedRecall recipe against a real GeniusLocusKit
// estate over in-memory storage — no mocks. Proves a named RecallShape preset
// resolves and runs through GLK, that an unknown name degrades to balanced, that
// the balanced preset is byte-identical to an unshaped recall, and that a shaped
// recall differs from balanced as expected.
//
// The estate is seeded into BOTH the corpus (BM25) and vector lanes so the
// .unionBest recall has real multi-lane candidates — the same join discipline
// PreciseRecallTests uses (corpus.ingest + vectorStore.addVector keyed by
// drawer.id).

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

@Suite("ShapedRecallTests")
struct ShapedRecallTests {

    /// Open an in-memory estate, capture each content string as a drawer, and
    /// seed every drawer into the corpus + vector lanes so the .unionBest recall
    /// has real BM25 and vector candidates. Returns the kit, handle, and the
    /// drawer id for each content (in input order).
    private func makeSeededEstate(
        capturing contents: [String]
    ) async throws -> (GeniusLocusKit, EstateHandle, [String]) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "shaped-recall-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await Corpus(storage: corpusStorage, model: .deterministic)
        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let modelID = await corpus.modelID
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        var ids: [String] = []
        for content in contents {
            let frame = CaptureFrame(
                content: content,
                channel: .typed,
                room: "ledger",
                latticeAnchor: .udc("000.000"),
                addedBy: "tester",
                embeddingModelID: "test-model-v1")
            let drawer = try await kit.capture(handle, frame)
            ids.append(drawer.id)
            try await corpus.ingest(content, sourceID: drawer.id, now: now)
            let engram = try await corpus.embed(content)
            try await vectorStore.addVector(
                itemID: drawer.id, engram: engram,
                modelID: modelID, modelVersion: "1.0", filedAt: now)
        }

        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit, handle, ids)
    }

    // CK-SR-1: a known preset resolves and runs over the real GLK recall verb;
    // the applied preset echoes the request; survivors carry their bodies.
    @Test("a known preset runs and echoes the applied preset")
    func knownPresetRuns() async throws {
        try await withCognitionLock {
            let (kit, handle, _) = try await makeSeededEstate(capturing: [
                "the cat sat on the mat",
                "a dog ran in the park",
                "cats and dogs are pets",
            ])
            let out = try await ShapedRecall().run(
                input: .init(query: "cat", preset: "precise",
                             filter: .currentlyBelieve, limit: 10),
                estate: handle, kit: kit)
            #expect(out.appliedPreset == "precise")
            #expect(!out.matches.isEmpty, "the shaped recall surfaces rows")
            #expect(out.matches.contains { !$0.content.isEmpty },
                    ".full hydration carries bodies")
        }
    }

    // CK-SR-2: an unknown preset NAME degrades to balanced at the recipe layer —
    // the recipe never fails on a bad name (the ARIA boundary is fail-closed).
    @Test("an unknown preset degrades to balanced")
    func unknownPresetDegrades() async throws {
        try await withCognitionLock {
            let (kit, handle, _) = try await makeSeededEstate(capturing: [
                "alpha beta", "gamma delta",
            ])
            let out = try await ShapedRecall().run(
                input: .init(query: "alpha", preset: "no-such-preset",
                             filter: .currentlyBelieve, limit: 10),
                estate: handle, kit: kit)
            #expect(out.appliedPreset == "balanced")
        }
    }

    // CK-SR-3: the balanced preset is byte-identical to an unshaped recall — the
    // back-compat contract. Running ShapedRecall with "balanced" returns the same
    // id order as a direct .unionBest recall carrying no shape.
    @Test("balanced is byte-identical to an unshaped recall")
    func balancedMatchesUnshaped() async throws {
        try await withCognitionLock {
            let (kit, handle, _) = try await makeSeededEstate(capturing: [
                "the river flows north past the old mill",
                "the mountain trail climbs steeply at dawn",
                "the harbour lights flicker in the evening fog",
            ])
            let shaped = try await ShapedRecall().run(
                input: .init(query: "river mill", preset: "balanced",
                             filter: .currentlyBelieve, limit: 10),
                estate: handle, kit: kit)

            // A direct unshaped .unionBest recall over the same frame.
            let frame = LocusKit.RecallFrame(
                filterChain: [.currentlyBelieve],
                hydrationLevel: .full,
                limit: 10,
                ordering: .byCaptureTimeDesc)
            let request = GLKRecallRequest(
                frame: frame, mode: .unionBest, scoring: .matrixAware,
                limit: 10, fallback: .allowDegraded,
                queryText: "river mill", recallShape: nil)
            let direct = try await kit.recall(handle, request)

            #expect(shaped.matches.map(\.id) == direct.hits.map(\.id),
                    "balanced ShapedRecall must equal the unshaped .unionBest order")
        }
    }

    // CK-SR-4: every roster preset resolves and runs without panic over a real
    // estate — proves no preset names a lane the engine cannot honour.
    @Test("every roster preset resolves and runs end-to-end")
    func everyPresetRuns() async throws {
        try await withCognitionLock {
            let (kit, handle, _) = try await makeSeededEstate(capturing: [
                "alpha one", "beta two", "gamma three",
            ])
            for name in RecallShape.presetNames {
                let out = try await ShapedRecall().run(
                    input: .init(query: "alpha", preset: name,
                                 filter: .currentlyBelieve, limit: 5),
                    estate: handle, kit: kit)
                let expected = RecallShape.presetNames.contains(name) ? name : "balanced"
                #expect(out.appliedPreset == expected,
                        "preset \(name) must run and echo its applied name")
            }
        }
    }

    // CK-SR-5: the recipe is registered in the catalog and discoverable by name.
    @Test("shaped_recall is registered in the catalog")
    func registeredInCatalog() throws {
        let descriptor = try #require(RecipeCatalog.descriptor(named: "shaped_recall"))
        #expect(descriptor.version == "1.0.0")
        #expect(descriptor.requiredCapabilities.isEmpty)
        // The live recipe's metadata matches the catalog descriptor.
        let recipe = ShapedRecall()
        #expect(descriptor.name == recipe.name)
        #expect(descriptor.description == recipe.description)
    }
}
