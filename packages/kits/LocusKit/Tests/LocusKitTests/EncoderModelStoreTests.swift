// EncoderModelStoreTests.swift
//
// The span-encoder registry (ENCODER_RERANK_CONTRACT §2). Twin of Rust
// `encoder_model_store_tests.rs`.
//
// Failure modes pinned:
//   1. `active()` is nil on a fresh estate and returns the one row with
//      is_active = 1 after activation; activating a second model demotes
//      the first (never two active rows).
//   2. `activate` clears bit 27 on every drawer that carried it, in the
//      same call, so the duty re-encodes under the new model. A port that
//      flips is_active without touching drawers leaves stale span rows
//      described as current.
//   3. Activating an unregistered id throws.

import Testing
import Foundation
import PersistenceKit
@testable import LocusKit

@Suite("EncoderModelStore")
struct EncoderModelStoreTests {

    private func spec(_ modelID: String, window: Int) -> EncoderModelRow {
        EncoderModelRow(modelID: modelID, modelVersion: "r1", dim: 384,
                         queryPrefix: "", docPrefix: "", pooling: .mean,
                         tokenizerHash: "sha256-of-vocab", windowWords: window,
                         overlapDivisor: 2, maxSpans: 32, maxSequence: 256)
    }

    @Test("upsert, activate, and read back the single active row")
    func upsertActivateReadBack() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let storage = TestStorage.sqlite(url)
        _ = try await DrawerStore(storage: storage)
        let registry = EncoderModelStore(storage: storage)
        #expect(try await registry.active() == nil, "fresh estate: no active encoder")

        try await registry.upsert(spec("minilm-l6-v2-w60", window: 60))
        try await registry.upsert(spec("minilm-l6-v2-w150", window: 150))
        #expect(try await registry.active() == nil, "upsert never activates by itself")
        #expect(try await registry.all().count == 2)

        try await registry.activate(modelID: "minilm-l6-v2-w60")
        let active = try #require(try await registry.active())
        #expect(active.modelID == "minilm-l6-v2-w60")
        #expect(active.isActive && active.windowWords == 60 && active.pooling == .mean)

        try await registry.activate(modelID: "minilm-l6-v2-w150")
        let activeIDs = try await registry.all().filter(\.isActive).map(\.modelID)
        #expect(activeIDs == ["minilm-l6-v2-w150"], "exactly one active row after a switch")

        // An upsert of the active row keeps its identity and refreshes its fields.
        let refreshed = EncoderModelRow(modelID: "minilm-l6-v2-w150", modelVersion: "r2", dim: 384,
                                         queryPrefix: "", docPrefix: "", pooling: .mean,
                                         tokenizerHash: "sha256-of-vocab", windowWords: 150,
                                         overlapDivisor: 2, maxSpans: 32, maxSequence: 256, isActive: true)
        try await registry.upsert(refreshed)
        #expect(try await registry.active()?.modelVersion == "r2")

        await #expect(throws: LocusKitError.self) {
            try await registry.activate(modelID: "bge-small-en-v15-w60")
        }
        await #expect(throws: LocusKitError.self) {
            try await registry.upsert(spec("", window: 60))
        }
    }

    @Test("activation clears bit 27 estate-wide")
    func activationClearsSpanIndex() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let storage = TestStorage.sqlite(url)
        let store = try await DrawerStore(storage: storage)
        let registry = EncoderModelStore(storage: storage)
        try await registry.upsert(spec("minilm-l6-v2-w60", window: 60))
        try await registry.upsert(spec("bge-small-en-v15-w60", window: 60))
        try await registry.activate(modelID: "minilm-l6-v2-w60")

        let ids = [TestStorage.tid("span-a"), TestStorage.tid("span-b")]
        for id in ids {
            try await store.addDrawer(sampleDrawer(id: id))
        }
        _ = try await store.setSpanIndexed(drawerId: ids[0])
        #expect(try await store.countSpanIndexDebt() == 1, "one indexed, one still owed")

        let cleared = try await registry.activate(modelID: "bge-small-en-v15-w60")
        #expect(cleared == 1, "only the drawer that carried bit 27 is written")
        for id in ids {
            let d = try #require(try await store.getDrawer(id: id))
            #expect(!d.isSpanIndexed, "\(id): bit 27 must clear on activation")
        }
        #expect(try await store.countSpanIndexDebt() == 2, "the whole estate is owed again")
    }

    /// Minimal valid drawer for the registry tests.
    private func sampleDrawer(id: String) -> Drawer {
        Drawer(id: id, content: "content to span",
               parentNodeId: TestStorage.tid("room-span"),
               addedBy: "bilby", filedAt: Date(timeIntervalSince1970: 1_700_000_000),
               embeddingModelID: "test-v1", udcCode: "001")
    }
}
