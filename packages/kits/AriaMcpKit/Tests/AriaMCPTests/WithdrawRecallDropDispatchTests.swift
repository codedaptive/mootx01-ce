// WithdrawRecallDropDispatchTests.swift
//
// ARIA dispatch-level force-test A (Swift), the parity peer of the Rust
// packages/kits/AriaMcpKit/rust/tests/dispatch_tests.rs::withdraw_memory_removes_from_-
// unconfirmed_set: an IMPATIENT (inline-ingest) file_memory followed by
// withdraw_memory, then a default moot_memory_search returns the content NO
// LONGER (found 0 / absent).
//
// This is the end-to-end proof of the frame-faithful recall drop at the ARIA
// surface: the withdrawn drawer's corpus chunk persists (withdraw does not
// expunge the corpus), so the BM25 lane still returns it as a candidate — but
// the default recall frame (`.currentlyBelieve` implied) excludes the
// `.withdrawn` (Cluster B) drawer via the frame-aware drawerIndex, so it is
// DROPPED, not surfaced as a nil-drawer phantom. Impatient ingest makes the
// corpus populated at search time deterministically (defeats the prior
// timing-mask where the encode worker had not yet ingested).
//
// The dispatch tool's `filter` arg has no state-axis override (decodeFilter
// accepts only unconfirmed/userConfirmed/exportable/contained), so the
// frame-override proof (force-test B) lives at the GLK level, not here.

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

@Suite("Withdraw → recall drop at the ARIA dispatch surface", .serialized)
struct WithdrawRecallDropDispatchTests {

    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    /// Replicate AriaMCPMain's in-memory estate wiring with semantic recall
    /// (Corpus + VectorStore on the same storage), the production in-memory path.
    private func openWired() async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-withdraw-drop-owner")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        // Stamp the GLK 1.1 estate format, mirroring ServeCommand's GLKMigrationCatalog.prepare
        // call between kit.open and kit.wireGLKSubstores in production. Fresh-estate fast path.
        _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle)
        // Shared-content 1.1: the canonical wiring seam constructs the
        // ATTACHED-mode CorpusContentEngine over the LocusKit-backed adapter
        // and registers engine + shared VectorStore (same path AriaMCPMain
        // and provision use).
        try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
        return ToolDispatcher(kit: kit, handle: handle)
    }

    @Test func withdrawnMemoryAbsentFromDefaultSearch() async throws {
        let dispatcher = try await openWired()

        // Impatient file → inline corpus ingest, immediately searchable.
        let content = "withdraw target content marmalade quasar threnody"
        let filed = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(content),
                "subject": .string(String(content.prefix(120))),
                "location": .string("lab"),
                "impatient": .bool(true),
            ]))
        let id = try #require(
            filed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["memory_id"]?.stringValue)

        // Precondition: the active memory is searchable.
        let pre = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("marmalade quasar threnody")]))
        let preRows = pre.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue ?? []
        #expect(preRows.contains { $0.objectValue?["memory_id"] == .string(id) },
            "active memory must surface before withdrawal; got: \(pre)")

        // Withdraw — soft-removes from active circulation (state → .withdrawn).
        let withdrawn = try await dispatcher.dispatch(
            name: "moot_withdraw_memory",
            arguments: .object(["memory_id": .string(id)]))
        #expect(withdrawn.objectValue?["isError"] == .bool(false),
            "withdraw must succeed; got: \(withdrawn)")

        // Default search must NOT surface the withdrawn memory: the BM25 candidate
        // is dropped by the frame-aware drawerIndex (it failed the implied
        // `.currentlyBelieve` filter). Assert the id is absent.
        let post = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("marmalade quasar threnody")]))
        let postRows = post.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue ?? []
        #expect(!postRows.contains { $0.objectValue?["memory_id"] == .string(id) },
            "withdrawn memory must NOT appear in default search (frame-faithful drop); got: \(post)")
    }
}
