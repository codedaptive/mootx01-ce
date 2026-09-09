// TieredContradictionSurfaceTests.swift
//
// MXE-CT3 P3 — the MCP surface over the tiered contradiction lanes:
// moot_hunt_contradictions tier/top_k modes, the appended tiered
// synthesis digest, the dream wiring (candidate filing + digest), and
// the moot_review_tunnel review ladder (endorse / model-objection /
// user-only activation).
//
// The legacy-report pin lives here too: with the new args ABSENT the
// hunt report's legacy portion (everything before the first TIER
// header) must be exactly today's report — the benchmark parser
// matches the trimmed "PROPOSED "/"CANDIDATE " prefixes and the count
// lines, so no new line may appear before the typed section ends.

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

@Suite("Tiered contradiction MCP surface", .serialized)
struct TieredContradictionSurfaceTests {

    /// Extract the text payload from a `textResult` JSONValue.
    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    /// Same production wiring shape as ContradictionHunterEndToEndTests:
    /// Corpus + shared VectorStore, token-bag provider so shared tokens
    /// pull sentences together in engram space (the property kNN mining
    /// needs).
    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "tiered-surface")
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
            modelID: "tiered-token-bag-v1", modelVersion: "1.0",
            projectionSeed: 0xC0FF_EE00, inference: tokenBag)
        _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle)
        try await kit.wireGLKSubstores(
            for: handle, backingStorage: storage,
            embeddingModels: [.randomIndexing(provider: provider)])

        return (ToolDispatcher(kit: kit, handle: handle), kit, handle)
    }

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
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        let id = firstLine.split(separator: " ").last.map(String.init) ?? ""
        #expect(!id.isEmpty, "could not extract drawer id from: \(firstLine)")
        return id
    }

    /// File a proposed contradicts link and return the tunnel id parsed
    /// from the `linked … (<id>) [proposed …]` response line.
    private func fileProposedLink(
        from a: String, to b: String, via dispatcher: ToolDispatcher
    ) async throws -> String {
        let link = text(of: try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(a),
                "to_id": .string(b),
                "kind": .string("contradicts"),
                "proposed": .bool(true),
            ])))
        #expect(link.contains("[proposed"), "link output: \(link)")
        guard let open = link.lastIndex(of: "("),
              let close = link[open...].firstIndex(of: ")")
        else {
            Issue.record("no tunnel id in link output: \(link)")
            return ""
        }
        return String(link[link.index(after: open)..<close])
    }

    /// Expect `dispatch` to throw invalidParams whose message contains
    /// `fragment` (boundary-validation contract: the error names the
    /// valid domain).
    private func expectInvalidParams(
        _ dispatcher: ToolDispatcher, tool: String, args: JSONValue,
        containing fragment: String
    ) async throws {
        do {
            _ = try await dispatcher.dispatch(name: tool, arguments: args)
            Issue.record("expected invalidParams (\(fragment)) from \(tool) \(args)")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
            #expect(error.message.contains(fragment),
                    "message was: \(error.message)")
        }
    }

    // MARK: - hunt arg validation

    // MARK: - legacy pin + appended synthesis digest

    // MARK: - single-tier purpose search

    // MARK: - dream wiring

    // MARK: - review ladder
}
