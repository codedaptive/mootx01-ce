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
import VectorKit
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

    @Test func huntRejectsInvalidTierAndTopK() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let tierDomain = "tier must be 1, 2, 3, or \"all\""
        for bad: JSONValue in [.integer(0), .integer(4), .integer(-1),
                               .string("2"), .string("typed"), .bool(true)] {
            try await expectInvalidParams(
                dispatcher, tool: "moot_hunt_contradictions",
                args: .object(["tier": bad]), containing: tierDomain)
        }
        let topKDomain = "top_k must be an integer in 1...50"
        for bad: JSONValue in [.integer(0), .integer(51), .integer(-3),
                               .string("5"), .bool(false)] {
            try await expectInvalidParams(
                dispatcher, tool: "moot_hunt_contradictions",
                args: .object(["top_k": bad]), containing: topKDomain)
        }
    }

    // MARK: - legacy pin + appended synthesis digest

    @Test func huntWithoutNewArgsKeepsLegacyReportAndAppendsDigest() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        try await file("the api timeout is 30 seconds", via: dispatcher)
        try await file("the api timeout is 90 seconds", via: dispatcher)
        try await file("Bob lives in Paris", via: dispatcher)

        let hunt = text(of: try await dispatcher.dispatch(
            name: "moot_hunt_contradictions", arguments: .object([:])))

        // The digest is APPENDED: the report splits at the first tier
        // header into legacy portion + digest.
        let splitAt = try #require(hunt.range(of: "TIER 1 — CONTRADICTION (proven)"),
                                   "digest missing from: \(hunt)")
        let legacy = String(hunt[..<splitAt.lowerBound])
        let digest = String(hunt[splitAt.lowerBound...])

        // Legacy pin: exactly today's lines, in today's shapes — and none
        // of the new vocabulary before the split point.
        #expect(legacy.hasPrefix("moot_hunt_contradictions: sweep complete\n"))
        #expect(legacy.contains("\nprobesScanned: "))
        #expect(legacy.contains("\npairsScreened: "))
        #expect(legacy.contains("\nalreadySettled: "))
        #expect(legacy.contains("\nproposed: 1"), "legacy portion: \(legacy)")
        // Benchmark-parser contract: the trimmed "PROPOSED "/"CANDIDATE "
        // prefixes are matched verbatim — the emitter lines are
        // two-space indented and unchanged.
        let proposedLine = try #require(
            legacy.split(separator: "\n").first { $0.hasPrefix("  PROPOSED ") })
        #expect(proposedLine.contains(" contradicts "))
        #expect(proposedLine.contains("score"))
        #expect(proposedLine.contains("tunnel"))
        // Typed section still closes the legacy portion.
        #expect(legacy.contains("\nproven: "))
        #expect(legacy.contains("\ncoverage: "))
        for newToken in ["TIER ", "lane:", "lane_seconds:", "synthesis_wall_seconds:",
                         "conflictTunnelsFiled:"] {
            #expect(!legacy.contains(newToken),
                    "new token \(newToken) leaked into the legacy portion: \(legacy)")
        }

        // Digest shape: all three sections in tier order, per-lane counts,
        // and the dispatch-layer timing lines.
        let t2 = try #require(digest.range(of: "TIER 2 — CONFLICT CANDIDATE"))
        let t3 = try #require(digest.range(of: "TIER 3 — DIVERGENCE"))
        #expect(t2.lowerBound < t3.lowerBound)
        #expect(digest.contains("  lane: fetched "))
        #expect(digest.contains("lane_seconds: hunt="))
        #expect(digest.contains(" synthesis="))
        #expect(digest.contains("synthesis_wall_seconds: "))
        // The planted value-divergent pair is a tier-3 finding.
        let tier3Section = String(digest[t3.lowerBound...])
        #expect(tier3Section.contains("(value_divergence, score "),
                "tier 3 section: \(tier3Section)")
    }

    // MARK: - single-tier purpose search

    @Test func singleTierSearchIsReadOnly() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        try await file("the api timeout is 30 seconds", via: dispatcher)
        try await file("the api timeout is 90 seconds", via: dispatcher)

        let before = try await kit.estate(for: handle).allTunnels().count

        let out = text(of: try await dispatcher.dispatch(
            name: "moot_hunt_contradictions",
            arguments: .object(["tier": .integer(3), "top_k": .integer(10)])))

        // Purpose-search report: its own header, the requested section
        // only, none of the legacy sweep vocabulary, no synthesis-only
        // counts/timing lines.
        #expect(out.hasPrefix("moot_hunt_contradictions: tier 3 search complete\n"))
        #expect(out.contains("TIER 3 — DIVERGENCE"))
        #expect(out.contains("(value_divergence, score "), "tier-3 findings: \(out)")
        for absent in ["sweep complete", "probesScanned:", "  PROPOSED ",
                       "  CANDIDATE ", "TIER 1 —", "TIER 2 —",
                       "lane:", "lane_seconds:", "synthesis_wall_seconds:"] {
            #expect(!out.contains(absent), "unexpected \(absent) in: \(out)")
        }

        // Read-only: no tunnel was filed by the purpose search.
        let after = try await kit.estate(for: handle).allTunnels().count
        #expect(after == before, "single-tier search must not write")

        // Tier 1 runs without a vector store dependency and renders its
        // header even when the typed lane finds nothing.
        let t1 = text(of: try await dispatcher.dispatch(
            name: "moot_hunt_contradictions",
            arguments: .object(["tier": .integer(1)])))
        #expect(t1.hasPrefix("moot_hunt_contradictions: tier 1 search complete\n"))
        #expect(t1.contains("TIER 1 — CONTRADICTION (proven)"))
    }

    // MARK: - dream wiring

    @Test func dreamFilesCandidatesAndAppendsDigest() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        try await file("the api timeout is 30 seconds", via: dispatcher)
        try await file("the api timeout is 90 seconds", via: dispatcher)

        let dream = text(of: try await dispatcher.dispatch(
            name: "moot_dream", arguments: .object([:])))

        // Step 3 (hunter) files the pair; step 3.25's all-tier filing then
        // sees it live and suppresses — visible, counted, deterministic.
        #expect(dream.contains("contradictionsProposed: 1"), "dream: \(dream)")
        let filedLine = try #require(
            dream.split(separator: "\n").first { $0.hasPrefix("conflictTunnelsFiled: ") })
        #expect(filedLine.contains("tier1 0"))
        #expect(filedLine.contains("(suppressed: "), "filed line: \(filedLine)")
        #expect(filedLine.contains("ceilingSkipped: "))

        // The tiered digest rides behind the typed section, through the
        // same shared renderer the hunt tool uses.
        #expect(dream.contains("TIER 1 — CONTRADICTION (proven)"))
        #expect(dream.contains("TIER 2 — CONFLICT CANDIDATE"))
        #expect(dream.contains("TIER 3 — DIVERGENCE"))
        #expect(dream.contains("lane_seconds: propose="))
        #expect(dream.contains("synthesis_wall_seconds: "))
    }

    // MARK: - review ladder

    @Test func reviewLadderEndorseObjectAndUserOnlyActivation() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let a = try await file("Bob lives in Paris", via: dispatcher)
        let b = try await file("Bob lives in Lyon", via: dispatcher)
        let tunnelID = try await fileProposedLink(from: a, to: b, via: dispatcher)

        // accept by a model reviewer is refused at the boundary.
        try await expectInvalidParams(
            dispatcher, tool: "moot_review_tunnel",
            args: .object([
                "tunnel_id": .string(tunnelID),
                "verdict": .string("accept"),
                "reviewed_by": .string("claude"),
            ]),
            containing: "edge activation is user-only")

        // Unknown verdicts and empty reviewer ids are boundary errors too.
        try await expectInvalidParams(
            dispatcher, tool: "moot_review_tunnel",
            args: .object([
                "tunnel_id": .string(tunnelID),
                "verdict": .string("snooze"),
            ]),
            containing: "verdict must be \"accept\", \"reject\", or \"endorse\"")
        try await expectInvalidParams(
            dispatcher, tool: "moot_review_tunnel",
            args: .object([
                "tunnel_id": .string(tunnelID),
                "verdict": .string("endorse"),
                "reviewed_by": .string(""),
            ]),
            containing: "reviewed_by must be a non-empty string")

        // Model endorsement: recorded, lifecycle untouched.
        let endorse = text(of: try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(tunnelID),
                "verdict": .string("endorse"),
                "reviewed_by": .string("claude"),
            ])))
        #expect(endorse.contains("endorsed by claude (distinct endorsers: 1)"),
                "endorse: \(endorse)")
        let endorsed = try #require(
            try await kit.estate(for: handle).getTunnel(id: tunnelID))
        #expect(endorsed.lifecycle == .proposed, "endorse must never activate")

        // Model objection AFTER a model endorsement: contested, stays
        // proposed for user attention.
        let object = text(of: try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(tunnelID),
                "verdict": .string("reject"),
                "reviewed_by": .string("gpt"),
            ])))
        #expect(object.contains("objected by gpt — contested"), "object: \(object)")
        let contested = try #require(
            try await kit.estate(for: handle).getTunnel(id: tunnelID))
        #expect(contested.lifecycle == .proposed)

        // User accept (default reviewed_by) still activates.
        let accept = text(of: try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(tunnelID),
                "verdict": .string("accept"),
            ])))
        #expect(accept.contains("accepted — the contradicts link is now active"))

        // Second proposal: a model objection with NO endorsement on
        // record withdraws (the AI-rejected, reopenable path).
        let c = try await file("the deploy window is Tuesday", via: dispatcher)
        let d = try await file("the deploy window is Friday", via: dispatcher)
        let second = try await fileProposedLink(from: c, to: d, via: dispatcher)
        let solo = text(of: try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(second),
                "verdict": .string("reject"),
                "reviewed_by": .string("claude"),
            ])))
        #expect(solo.contains("objected by claude — withdrawn"), "solo objection: \(solo)")
        let withdrawn = try #require(
            try await kit.estate(for: handle).getTunnel(id: second))
        #expect(withdrawn.lifecycle == .withdrawn)
    }
}
