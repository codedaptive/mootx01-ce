// ContradictionHunterEndToEndTests.swift
//
// The user's own repro, end to end through the MCP tool surface: file
// contradictory memories on an estate wired the way production wires it
// (Corpus + shared VectorStore, chunk-keyed vector rows), dream, see the
// hunter's PROPOSED edge in the contradiction lens, settle it with
// moot_review_tunnel, file an agent-adjudicated proposed link with
// moot_link_memories proposed:true, and prove settled pairs never
// re-propose. This is the journey that motivated the hunter build: a
// fresh estate with planted contradictions must surface them.

import Testing
import Foundation
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import CorpusKit
import SynapseKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Contradiction hunter — MCP end to end", .serialized)
struct ContradictionHunterEndToEndTests {

    /// Extract the text payload from a `textResult` JSONValue.
    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    /// Pull the tunnel UUID out of a lens line shaped
    /// `  <src> contradicts <tgt> (tunnel <id>)[ …flag]`.
    private func tunnelID(fromLensLine line: String) -> String? {
        guard let range = line.range(of: "(tunnel ") else { return nil }
        let tail = line[range.upperBound...]
        guard let close = tail.firstIndex(of: ")") else { return nil }
        return String(tail[..<close])
    }

    /// Production wiring shape (EstateLifecycle.wireSubstores .glk): one
    /// storage, a Corpus whose SHARED VectorStore is the registered store,
    /// vector rows keyed by chunk UUID under the corpus's own modelID. The
    /// token-bag provider stands in for the distributional ensemble: shared
    /// tokens pull sentences together in engram space, which is the
    /// property the hunter's kNN mining needs (the default `.deterministic`
    /// whole-text hash has no such property).
    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "hunter-e2e")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())

        let tokenBag: @Sendable (String) async throws -> [Float] = { text in
            var acc = [Float](repeating: 0, count: 32)
            let tokens = text.lowercased().split(
                whereSeparator: { !$0.isLetter && !$0.isNumber })
            for token in tokens {
                var h: UInt64 = 14_695_981_039_346_656_037
                for byte in token.utf8 {
                    h = (h ^ UInt64(byte)) &* 1_099_511_628_211
                }
                for i in 0..<32 {
                    h = h &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    acc[i] += (Float(h >> 40) / Float(1 << 24)) * 2 - 1
                }
            }
            return acc
        }
        let provider = FloatSimHashEmbeddingProvider(
            modelID: "hunt-token-bag-v1", modelVersion: "1.0",
            projectionSeed: 0xC0FF_EE00, inference: tokenBag)
        // Stamp the GLK 1.1 estate format, mirroring ServeCommand's GLKMigrationCatalog.prepare
        // call between kit.open and kit.wireGLKSubstores in production. Fresh-estate fast path.
        _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle)
        // Shared-content 1.1: canonical wiring seam with the test's custom
        // token-bag provider — constructs the attached engine over the
        // LocusKit adapter and registers engine + shared VectorStore.
        try await kit.wireGLKSubstores(
            for: handle, backingStorage: storage,
            embeddingModels: [.randomIndexing(provider: provider)])

        return (ToolDispatcher(kit: kit, handle: handle), kit, handle)
    }

    /// File a memory through the tool surface and return its drawer id
    /// (from the `filed memory <id>` response line). `impatient: true`
    /// inlines the corpus encode (chunk + vector rows land before the call
    /// returns) — the same guarantee `moot_reindex` provides for bulk
    /// imports.
    @discardableResult
    private func file(
        _ content: String, via dispatcher: ToolDispatcher
    ) async throws -> String {
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(content),
                "subject": .string(String(content.prefix(120))),
                "location": .string("work/notes"),
                "impatient": .bool(true),
            ]))
        let body = text(of: result)
        #expect(body.contains("filed memory"), "file output: \(body)")
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        let id = firstLine.split(separator: " ").last.map(String.init) ?? ""
        #expect(!id.isEmpty, "could not extract drawer id from: \(firstLine)")
        return id
    }
}
