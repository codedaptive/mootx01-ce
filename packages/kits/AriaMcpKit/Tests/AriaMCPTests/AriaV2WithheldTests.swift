import AriaMCPWire
import CorpusKit
import EngramLib
import Foundation
@testable import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SynapseKit
import Testing
@testable import AriaMCP

/// Constant-value float provider: returns the same 384-d vector for every
/// non-empty input. Used to populate the dense lane in tests that do not
/// exercise semantic similarity.
private struct ConstantFloatProvider: EmbeddingProvider, @unchecked Sendable {
    let modelID: String
    let modelVersion = "1.0.0"
    let value: Float

    func embed(_ text: String) async throws -> Engram { .zero }

    func embedFloat(_ text: String) async throws -> [Float] {
        guard !text.isEmpty else { return [] }
        return Array(repeating: value, count: 384)
    }
}

@Suite("Sensitivity-only counts at the shipping v2 door", .serialized)
struct AriaV2WithheldTests {
    @Test func reportWithheldShippingV2() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "withheld-v2")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore(), federate: true)
        var ids: [String] = []
        for index in 0..<5 {
            ids.append(try await kit.capture(handle, CaptureFrame(
                content: "withheld probe document \(index) has distinct useful evidence",
                channel: .typed, room: "r", latticeAnchor: .udc("004"),
                addedBy: "withheld-v2", embeddingModelID: "test-v1", subject: "probe \(index)")).id)
        }
        for leaf in ids.dropFirst() {
            _ = try await kit.captureTunnel(handle, TunnelCaptureFrame(
                sourceWing: "study", sourceRoom: "r", targetWing: "study", targetRoom: "r",
                label: "relates", addedBy: "withheld-v2", sourceDrawerId: ids[0], targetDrawerId: leaf,
                kind: .references))
        }
        // Stale normal tunnels can name drawers subsequently reclassified.
        try await kit.mutate(handle, MutateFrame(rowID: ids[0], kind: .correctSensitivity(.restricted)))
        try await kit.mutate(handle, MutateFrame(rowID: ids[1], kind: .correctSensitivity(.restricted)))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        func count(_ result: JSONValue) -> Int64? {
            result.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["withheldBySensitivity"]?.integerValue
        }
        func data(_ result: JSONValue) -> JSONValue? {
            result.objectValue?["structuredContent"]?.objectValue?["data"]
        }
        func check(_ dispatcher: ToolDispatcher, _ name: String, _ args: [String: JSONValue], _ expected: Int64) async throws {
            let off = try await dispatcher.dispatch(name: name, arguments: .object(args))
            var onArgs = args; onArgs["report_withheld"] = .bool(true)
            let on = try await dispatcher.dispatch(name: name, arguments: .object(onArgs))
            #expect(on.objectValue?["isError"] == .bool(false), "\(name): \(on)")
            #expect(count(off) == nil)
            #expect(count(on) == expected, "\(name): \(on)")
            #expect(data(on) == data(off), "modifier changed rows for \(name)")
            onArgs["report_withheld"] = .bool(false)
            let explicitOff = try await dispatcher.dispatch(name: name, arguments: .object(onArgs))
            #expect(count(explicitOff) == nil)
            #expect(data(explicitOff) == data(off))
        }
        let cases: [(String, [String: JSONValue], Int64)] = [
            ("moot_recall_precise", ["query": .string("withheld probe")], 2),
            ("moot_recall_shaped", ["query": .string("withheld probe")], 2),
            ("moot_recall_connected", ["query": .string("withheld probe")], 2),
            ("moot_recall_distilled", ["query": .string("withheld probe")], 2),
            ("moot_recall_vague", ["query": .string("withheld probe")], 0),
            ("moot_lens_partial_cue", ["anchor_memory_id": .string(ids[2].lowercased())], 2),
            ("moot_lens_trust_synthesis", [:], 2),
            ("moot_lens_keystones", ["wing": .string("study"), "topK": .string("1")], 1),
            ("moot_lens_keystones", ["wing": .string("study"), "topK": .string("5")], 2),
        ]
        for (name, args, expected) in cases { try await check(dispatcher, name, args, expected) }
        try await kit.withdraw(handle, WithdrawFrame(rowID: ids[0], reason: "obsolete"))
        try await check(dispatcher, "moot_lens_keystones", ["wing": .string("study"), "topK": .string("1")], 0)
        let hydrated = try await kit.hydrateWithSensitivityCount(handle, ids: ids,
            frame: RecallFrame(filterChain: []), hydrationLevel: .full)
        #expect(hydrated.withheldBySensitivity == 1)
        #expect(!hydrated.drawers.contains { $0.id == ids[0] || $0.id == ids[1] })
        let explicit = try await kit.hydrateWithSensitivityCount(handle, ids: ids,
            frame: RecallFrame(filterChain: [.sensitivityAtMost(.secret)]), hydrationLevel: .full)
        #expect(explicit.withheldBySensitivity == 0)

        let peerStorage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: peerStorage, owner: owner)
        let peer = try await kit.open(storage: peerStorage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore(), federate: true)
        _ = try await kit.issueGrant(peer, GrantOptions(granteeEstateID: handle.estateUUID,
            scope: .wholeEstate, custodyMode: .mediated, lifetime: .permanent, contentLevel: 48))
        _ = try await kit.capture(peer, CaptureFrame(content: "peer restricted probe", channel: .typed,
            room: "r", latticeAnchor: .udc("004"), addedBy: "withheld-v2", embeddingModelID: "test-v1",
            sensitivity: .restricted))
        try await check(dispatcher.registering(peer), "moot_federated_recall",
            ["filter": .string("unconfirmed"), "hydration_level": .string("full")], 1)

        // A missing required transcript stage remains a refusal even when the
        // modifier is supplied. Its count must not become an existence oracle.
        let transcript = try await dispatcher.dispatch(name: "moot_memory_recall_transcript",
            arguments: .object(["query": .string("withheld probe"), "report_withheld": .bool(true)]))
        #expect(transcript.objectValue?["isError"] == .bool(true))
        #expect(count(transcript) == nil)
        // Exercise successful strict recall through the same production door,
        // with a real serving snapshot and deterministic inference seams.
        let content = "User: withheld transcript probe alpha beta gamma delta\nAssistant: retained evidence epsilon zeta eta theta"
        let drawer = try await kit.capture(handle, CaptureFrame(content: content, channel: .typed,
            room: "r", latticeAnchor: .udc("004"), addedBy: "withheld-v2", embeddingModelID: "test-v1"))
        let corpusStorage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusContentEngine(standaloneOn: corpusStorage,
            models: [.lsa(provider: ConstantFloatProvider(modelID: "test-miniLM-v1", value: 0.05))])
        try await corpus.ingest(content, contentID: drawer.id, now: Date())
        await kit.registerCorpus(corpus, for: handle)
        let vectorStorage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vectorStorage.open(schema: VectorStore.schemaDeclaration)
        let vectors = VectorStore(storage: vectorStorage)
        let record = GeniusLocusKit.defaultEncoderModelRow(isActive: true)
        let encoder = WithheldSpanEncoder(spec: EncoderModelSpec(row: record))
        try await kit.seedDefaultEncoderModelIfAbsent(for: handle)
        await kit.registerSpanEncoder(encoder, for: handle)
        await kit.registerSpanRerank(SpanEncoderQuerySeam(encoder: encoder),
            spanVectors: SynapseSpanVectorReader(store: vectors), for: handle)
        await kit.registerPairScorer(WithheldPairScorer(), for: handle)
        try await vectors.writeSpanVectors(itemID: drawer.id, modelID: record.modelID,
            modelVersion: record.modelVersion, spans: (0..<3).map { index in
                SpanVectorInput(index: UInt32(index), int8: Array(repeating: 1, count: 384), scale: 0.01,
                    startWord: index * 4, endWord: (index + 1) * 4,
                    contentVersion: SpanContentVersion.fnv1a64(content))
            }, filedAt: Date())
        // This recipe already has an explicit sensitivity predicate: Unit 1
        // therefore defines its default-ceiling-only count as zero.
        try await check(dispatcher, "moot_memory_recall_transcript", ["query": .string("withheld transcript probe")], 0)
        let unrelated = try await dispatcher.dispatch(name: "moot_help", arguments: .object(["report_withheld": .bool(true)]))
        #expect(count(unrelated) == nil)
        #expect(AriaV2SelectedCatalog.registry(environment: [:]).operations.allSatisfy {
            $0.inputSchema.objectValue?["properties"]?.objectValue?["report_withheld"] == nil
        })
        try AriaV2CapabilityDigestTests().selectedCatalogDigestSharedVector()
        try SessionProtocolTests().globalModifiersHelpByteIdentity()

        // Wing A excludes otherwise-matching restricted candidates in wing B.
        // Adding the same restricted content inside A then increments only A.
        let wingArguments: [String: JSONValue] = [
            "query": .string("connected wing probe"), "wing": .string("Withheld A")]
        for (wing, sensitivity) in [("Withheld A", AdjectiveSensitivity.normal), ("Withheld B", .restricted)] {
            _ = try await kit.capture(handle, CaptureFrame(content: "connected wing probe evidence",
                channel: .typed, room: "r", latticeAnchor: .udc("004"), addedBy: "withheld-v2",
                embeddingModelID: "test-v1", sensitivity: sensitivity, wing: wing))
        }
        try await check(dispatcher, "moot_recall_connected", wingArguments, 0)
        _ = try await kit.capture(handle, CaptureFrame(content: "connected wing probe evidence",
            channel: .typed, room: "r", latticeAnchor: .udc("004"), addedBy: "withheld-v2",
            embeddingModelID: "test-v1", sensitivity: .restricted, wing: "Withheld A"))
        try await check(dispatcher, "moot_recall_connected", wingArguments, 1)
    }
}

private struct WithheldSpanEncoder: SpanEncoder {
    let spec: EncoderModelSpec
    func encodeQuery(_ text: String) async throws -> [Float] {
        Array(repeating: Float(1) / Float(384).squareRoot(), count: 384)
    }
    func encodeSpans(_ spans: [String]) async throws -> [[Float]] {
        spans.map { _ in Array(repeating: Float(1) / Float(384).squareRoot(), count: 384) }
    }
}

private struct WithheldPairScorer: PairScorer {
    let profile: CrossEncoderProfile = .minilmL6
    var backend: String { "withheld-test" }
    func score(query: String, spans: [String]) async throws -> [Float] {
        Array(repeating: 1, count: spans.count)
    }
}
