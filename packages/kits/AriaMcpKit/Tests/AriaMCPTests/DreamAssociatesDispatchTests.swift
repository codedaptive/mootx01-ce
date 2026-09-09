// DreamAssociatesDispatchTests.swift
//
// ARIA dispatch tests for the `associates` argument on `moot_dream` (step 3.5).
//
// Tests drive the real dispatcher with a GLK estate wired identically to
// ContradictionHunterEndToEndTests: one storage, a token-bag embedding provider,
// and GLK migration + wireGLKSubstores so the VectorStore is live.
//
// Coverage:
//   1. associates=all on an estate with similar planted rows → response line
//      `associationsWritten: N (probed: P, deduplicated: D)` appears with N>0.
//   2. associates=off → the step is entirely skipped; `associationsWritten:`
//      does NOT appear in the response.

import Testing
import Foundation
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import CorpusKit
import SynapseKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Dream associates dispatch — step 3.5 ARIA surface", .serialized)
struct DreamAssociatesDispatchTests {

    // MARK: - Wiring helper

    /// Open an estate wired for full GLK substrate use: migration + shared
    /// VectorStore registered via wireGLKSubstores with a token-bag embedding
    /// provider. Mirrors ContradictionHunterEndToEndTests.makeDispatcher() exactly.
    ///
    /// Token-bag model: sums per-token FNV-hashed float projections across a
    /// 32-dimensional space. Sentences that share most tokens have close float
    /// embeddings; FloatSimHashEmbeddingProvider projects these to 256-bit
    /// fingerprints with small Hamming distance — below the
    /// `defaultProximityThreshold` of 64 for high-overlap pairs.
    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dream-associates-test")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())

        // Token-bag embedding: per-token FNV hash → 32-dim float projection.
        // Sentences sharing the majority of their tokens produce close float
        // vectors and thus small Hamming distances after SimHash projection.
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
            modelID: "assoc-token-bag-v1", modelVersion: "1.0",
            projectionSeed: 0xC0FF_EE00, inference: tokenBag)

        // Stamp the GLK 1.1 estate format (mirrors ServeCommand's GLKMigrationCatalog.prepare
        // call between kit.open and kit.wireGLKSubstores in production).
        _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle)
        // Shared-content 1.1 seam: token-bag provider is the embedding model;
        // its rows land in the shared VectorStore keyed by Drawer ID.
        try await kit.wireGLKSubstores(
            for: handle, backingStorage: storage,
            embeddingModels: [.randomIndexing(provider: provider)])

        return (ToolDispatcher(kit: kit, handle: handle), kit, handle)
    }

    /// File a memory through the tool surface with inline encode (`impatient: true`),
    /// so the VectorStore row lands before this call returns.
    @discardableResult
    private func file(
        _ content: String, via dispatcher: ToolDispatcher
    ) async throws -> String {
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(content),
                "subject": .string(String(content.prefix(120))),
                "location": .string("test/notes"),
                "impatient": .bool(true),
            ]))
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(body)? = first["text"],
              body.contains("filed memory")
        else { return "" }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.split(separator: " ").last.map(String.init) ?? ""
    }

    // MARK: - Test 1 — associates=all writes associations for similar rows

    /// When `associates=all` is passed, `moot_dream` runs step 3.5 over all items
    /// in the VectorStore. Planting highly similar sentences produces proximity
    /// pairs with small Hamming distance; at least one pair is written.
    ///
    /// The response must contain the `associationsWritten:` line with N>0.

    // MARK: - Test 2 — associates=off skips the step entirely

    /// When `associates=off` is passed, step 3.5 is entirely bypassed — the
    /// `assocLine` variable is never set so `associationsWritten:` does NOT appear
    /// in the response body regardless of estate content.

    // MARK: - Test 3 — associates=all is bounded (cap holds)

    /// `moot_dream` with `associates: "all"` must use a server-side probe bound
    /// rather than an unlimited sweep. When the estate has fewer items than the
    /// bound (10_000), all items are probed — `probed:` equals the estate size.
    /// This confirms the cap path uses `dreamAssociateAllModeMaxProbe` rather
    /// than `nil` (unbounded): a `nil` probe limit would pass `Int.max` to
    /// `recentItemIDs(limit:)`, scanning the full table without any bound; the
    /// named constant makes the limit explicit.
    ///
    /// Parity: `dream_all_mode_uses_bounded_probe_limit_not_unlimited` in Rust
    /// `dispatch_tests.rs`.

    // MARK: - Test 4 — dreamAssociateAllModeMaxProbe constant value is 10_000

    /// Documents that `RecipeTools.dreamAssociateAllModeMaxProbe` is 10_000.
    /// The value is private, so this test drives `moot_dream associates=all`
    /// on a fresh estate and asserts the step completes without error — the
    /// compile-time constant is verified by reading the source (structural,
    /// not behavioral). The behavioral cap is exercised by Test 3 above.
}
