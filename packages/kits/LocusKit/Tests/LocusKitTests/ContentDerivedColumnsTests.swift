// ContentDerivedColumnsTests.swift
//
// ssc_facts and the span index bit (Encoder Rerank Program §5, §6). Twin of
// the Rust in-memory suite section "Content-derived columns and the span
// index bit" case-for-case.
//
// Failure modes pinned:
//   1. A fresh row carries no facts and bit 27 clear, so it IS span-index
//      debt; a port whose debt predicate reads the wrong bit returns nothing.
//   2. setSSCFacts / setSpanIndexed round-trip; the second setSpanIndexed is
//      a no-op; empty facts are rejected.
//   3. Expunge scrubs ssc_facts and clears bit 27 with the content: a port
//      that clears bit 19 alone leaves stale span rows described as current.

import Testing
import Foundation
import PersistenceKit
@testable import LocusKit

@Suite("Content-derived columns and span index")
struct ContentDerivedColumnsTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func sampleDrawer(id: String, content: String = "some content") -> Drawer {
        Drawer(id: id, content: content,
               parentNodeId: TestStorage.tid("room-derived"),
               addedBy: "bilby", filedAt: now, embeddingModelID: "test-v1", udcCode: "001")
    }

    @Test("a fresh row has no facts and is span-index debt")
    func freshRowIsDebt() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }
        let id = TestStorage.tid("dr1")
        try await store.addDrawer(sampleDrawer(id: id))
        let loaded = try #require(try await store.getDrawer(id: id))
        #expect(loaded.sscFacts == nil)
        #expect(!loaded.isSpanIndexed)
        #expect(try await store.countSpanIndexDebt() == 1)
        #expect(try await store.spanIndexDebtBatch(limit: 10).map(\.id) == [id])
    }

    @Test("ssc_facts and the span index bit write and read back")
    func factsAndSpanIndexRoundTrip() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }
        let id = TestStorage.tid("dr2")
        try await store.addDrawer(sampleDrawer(id: id, content: "meeting moved thursday"))
        #expect(try await store.setSSCFacts("kind: meeting, when: thursday", for: id) == 1)
        #expect(try await store.setSpanIndexed(drawerId: id) == 1)
        #expect(try await store.setSpanIndexed(drawerId: id) == 0, "already set: no write")
        let loaded = try #require(try await store.getDrawer(id: id))
        #expect(loaded.sscFacts == "kind: meeting, when: thursday")
        #expect(loaded.isSpanIndexed)
        #expect(loaded.operationalBitmap & DrawerFeatureFlags.spanIndexed.rawValue == 1 << 27)
        #expect(try await store.countSpanIndexDebt() == 0)
        // Content and lifecycle untouched by derived-column writes.
        #expect(loaded.content == "meeting moved thursday")
        #expect(loaded.tombstonedAt == nil)
        // The structured projection carries the facts without the body.
        let structured = try #require(try await store.getDrawers(ids: [id], hydrationLevel: .structured).first)
        #expect(structured.sscFacts == "kind: meeting, when: thursday" && structured.content == "")
        // Clearing the facts is an explicit nil write.
        #expect(try await store.setSSCFacts(nil, for: id) == 1)
        #expect(try await store.getDrawer(id: id)?.sscFacts == nil)
        await #expect(throws: LocusKitError.self) { try await store.setSSCFacts("", for: id) }
        #expect(try await store.setSSCFacts("x", for: TestStorage.tid("missing")) == 0)
    }

    @Test("expunge clears facts and the span index bit with the content")
    func expungeClearsFactsAndSpanIndex() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }
        let id = TestStorage.tid("dr4")
        try await store.addDrawer(sampleDrawer(id: id, content: "derivable content"))
        _ = try await store.setSSCFacts("kind: note", for: id)
        _ = try await store.setSpanIndexed(drawerId: id)
        _ = try await store.expungeGated(drawerId: id, changedBy: "alice",
                                         reason: "erasure covers derived columns",
                                         now: now.addingTimeInterval(1))
        let after = try #require(try await store.getDrawer(id: id))
        #expect(after.content == "")
        #expect(after.sscFacts == nil)
        #expect(!after.isSpanIndexed, "bit 27 must clear with the content")
    }
}
