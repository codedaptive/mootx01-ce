import Testing
import Foundation
import CorpusKit
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

@Suite("TranscriptRecall", .serialized)
struct TranscriptRecallTests {
    @Test("strict transcript recall with no active rerank source exposes no generic matches")
    func unavailableDoesNotReturnFusedMatches() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "transcript-recall-test")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let corpusStorage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusContentEngine(standaloneOn: corpusStorage)
        let drawer = try await kit.capture(handle, CaptureFrame(
            content: "speaker: bring the file to tomorrow's review",
            channel: .typed, room: "session", latticeAnchor: .udc("000"),
            addedBy: "test", embeddingModelID: "test"))
        try await corpus.ingest(drawer.content, contentID: drawer.id, now: .now)
        await kit.registerCorpus(corpus, for: handle)

        let output = try await TranscriptRecall().run(
            input: .init(query: "file review", filter: .currentlyBelieve), estate: handle, kit: kit)
        #expect(output.outcome.status == .unavailable)
        #expect(output.matches.isEmpty)
    }
}
