import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

/// Typed v2 similar recall: strict decode and one dispatcher round-trip on a
/// scratch in-memory estate. The estate has no registered corpus, so the lane
/// takes its empty path and the envelope carries zero matches.
@Suite("ARIA v2 similar recall")
struct AriaV2SimilarRecallTests {
    @Test func requestRequiresQueryAndDefaultsLimit() throws {
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2SimilarRecallRequest(arguments: .object(["limit": .integer(5)]))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2SimilarRecallRequest(arguments: .object(["query": .string("x"), "limit": .integer(51)]))
        }
        let request = try AriaV2SimilarRecallRequest(arguments: .object(["query": .string("api timeout")]))
        #expect(request.query == "api timeout")
        #expect(request.limit == 10)
    }

    @Test func dispatcherRoundTripReturnsAResultEnvelope() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "similar-v2")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore(), federate: true)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let response = try await dispatcher.dispatch(name: "moot_recall_similar",
            arguments: .object(["query": .string("api timeout request gives up")]))
        let structured = response.objectValue?["structuredContent"]?.objectValue
        #expect(response.objectValue?["isError"] == .bool(false))
        #expect(structured?["tool"] == .string("moot_recall_similar"))
        #expect(structured?["data"]?.objectValue?["matches"]?.arrayValue != nil)
    }
}
