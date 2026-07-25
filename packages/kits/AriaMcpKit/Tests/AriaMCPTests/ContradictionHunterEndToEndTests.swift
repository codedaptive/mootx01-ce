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
import LocusKit
import CorpusKit
import VectorKit
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

    @Test func fullJourney_dream_lens_review_link_dedup() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // ── 1. Plant a contradictory pair + neighbours on a fresh estate.
        try await file("the api timeout is 30 seconds", via: dispatcher)
        try await file("the api timeout is 90 seconds", via: dispatcher)
        let bobID = try await file("Bob lives in Paris", via: dispatcher)
        let budgetID = try await file("quarterly budget review notes", via: dispatcher)

        // ── 2. moot_dream runs the hunt sweep: the planted value-divergent
        // pair persists as a PROPOSED contradicts tunnel via the corpus lane.
        let dream = try await dispatcher.dispatch(
            name: "moot_dream", arguments: .object([:]))
        let dreamText = text(of: dream)
        #expect(dreamText.contains("contradictionsProposed: 1"), "dream output: \(dreamText)")

        // ── 3. The lens surfaces it BY DEFAULT, flagged unreviewed.
        var lens = text(of: try await dispatcher.dispatch(
            name: "moot_lens_contradiction", arguments: .object([:])))
        #expect(lens.contains("proposed (agent-derived, unreviewed)"), "lens output: \(lens)")
        let proposedLine = try #require(
            lens.split(separator: "\n").first { $0.contains("[proposed") })
        let huntTunnelID = try #require(tunnelID(fromLensLine: String(proposedLine)))

        // ── 4. Accept: the edge becomes active and the flag disappears,
        // but the pair stays listed (confirmed tier).
        let accept = text(of: try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(huntTunnelID),
                "verdict": .string("accept"),
            ])))
        #expect(accept.contains("accepted"))
        lens = text(of: try await dispatcher.dispatch(
            name: "moot_lens_contradiction", arguments: .object([:])))
        #expect(lens.contains("(tunnel \(huntTunnelID))"))
        #expect(!lens.contains("[proposed"))

        // A settled tunnel cannot be re-reviewed.
        let rereview = text(of: try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(huntTunnelID),
                "verdict": .string("reject"),
            ])))
        #expect(rereview.contains("moot_review_tunnel:"))
        #expect(!rereview.contains("rejected —"), "settled tunnel must refuse re-review: \(rereview)")

        // ── 5. The on-demand sweep never re-proposes the settled pair.
        let hunt = text(of: try await dispatcher.dispatch(
            name: "moot_hunt_contradictions", arguments: .object([:])))
        #expect(hunt.contains("moot_hunt_contradictions: sweep complete"))
        #expect(hunt.contains("alreadySettled: 1"), "hunt output: \(hunt)")
        #expect(hunt.contains("proposed: 0"))

        // ── 6. Agent adjudication path: record a judged conflict as a
        // PROPOSED link, see it flagged in the lens, then reject it —
        // rejection withdraws it from the lens and settles the pair durably.
        let link = text(of: try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(bobID),
                "to_id": .string(budgetID),
                "kind": .string("contradicts"),
                "proposed": .bool(true),
            ])))
        #expect(link.contains("[proposed — review via moot_review_tunnel]"), "link output: \(link)")

        lens = text(of: try await dispatcher.dispatch(
            name: "moot_lens_contradiction", arguments: .object([:])))
        let linkLine = try #require(
            lens.split(separator: "\n").first { $0.contains("[proposed") })
        let linkTunnelID = try #require(tunnelID(fromLensLine: String(linkLine)))

        let reject = text(of: try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(linkTunnelID),
                "verdict": .string("reject"),
                "reason": .string("not a real conflict"),
            ])))
        #expect(reject.contains("rejected"))
        lens = text(of: try await dispatcher.dispatch(
            name: "moot_lens_contradiction", arguments: .object([:])))
        #expect(!lens.contains("(tunnel \(linkTunnelID))"),
                "withdrawn edge must leave the lens: \(lens)")

        // ── 7. Dedup is durable across BOTH settle outcomes: a second full
        // sweep proposes nothing new (accepted pair + rejected pair).
        let secondHunt = text(of: try await dispatcher.dispatch(
            name: "moot_hunt_contradictions", arguments: .object([:])))
        #expect(secondHunt.contains("proposed: 0"), "second hunt: \(secondHunt)")
    }
}
