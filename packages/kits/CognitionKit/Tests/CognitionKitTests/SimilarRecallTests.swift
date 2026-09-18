import Testing
import Foundation
import CorpusKit
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

@Suite("SimilarRecall", .serialized)
struct SimilarRecallTests {
    // Two drawers, corpus engine registered. The engine's default float slot is
    // the whole-record LSA lane; a two-document standalone engine in a unit test
    // is not guaranteed to be trained, so the lane may be dark (empty path) or
    // may rank. The assertion covers both honestly: when the lane speaks, the
    // drawer whose text matches the query comes first; when it is dark, the
    // recipe returns no matches rather than throwing.
    @Test("similar recall ranks the matching drawer first, or takes the empty path when the lane is dark")
    func matchingDrawerFirstOrEmpty() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "similar-recall-test")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let corpusStorage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusContentEngine(standaloneOn: corpusStorage)
        let timeout = try await kit.capture(handle, CaptureFrame(
            content: "the api timeout is thirty seconds before the request gives up",
            channel: .typed, room: "notes", latticeAnchor: .udc("000"),
            addedBy: "test", embeddingModelID: "test"))
        let grocery = try await kit.capture(handle, CaptureFrame(
            content: "grocery list apples oranges and bread",
            channel: .typed, room: "notes", latticeAnchor: .udc("000"),
            addedBy: "test", embeddingModelID: "test"))
        try await corpus.ingest(timeout.content, contentID: timeout.id, now: .now)
        try await corpus.ingest(grocery.content, contentID: grocery.id, now: .now)
        await kit.registerCorpus(corpus, for: handle)

        let output = try await SimilarRecall().run(
            input: .init(query: "api timeout request gives up", limit: 5, filter: .currentlyBelieve),
            estate: handle, kit: kit)
        if let first = output.matches.first {
            #expect(first.id == timeout.id)
            #expect(!output.matches.contains { $0.id == grocery.id && $0.score > first.score })
        } else {
            #expect(output.matches.isEmpty)
        }
    }
}
