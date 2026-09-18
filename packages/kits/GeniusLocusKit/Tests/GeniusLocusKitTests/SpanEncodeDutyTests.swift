// SpanEncodeDutyTests.swift
//
// Three discriminating tests for SpanEncodeDuty per ENCODER_RERANK_CONTRACT
// (W4 brief §Tests, three-test suite):
//
//   1. pump_with_fake_encoder_sets_bit_and_writes_spans
//      Five drawers, fake encoder. After one pump: 5 drawers have bit 27 set
//      and spanVectors returns the expected span counts per Spanner.spans.
//      Failure mode: a drawer encoded twice or a bit set without rows.
//
//   2. encoder_nil_pump_completes_no_rows_bits_stay_clear
//      Encoder is nil. Pump completes, no rows written, one log line, bits
//      stay clear.
//      Failure mode: an error propagates to the governor.
//
//   3. content_write_clears_bit_and_next_pump_reencodes
//      Content write on an encoded drawer clears bit 27; next pump re-encodes.
//      Asserted via the store fake: the second pump writes rows for the
//      reset drawer.
//
// All tests work against the internal `SpanEncodeDuty._encodeBatch` entry
// point via fake `SpanEncodeEstateContext` and `SpanVectorWriter` injections.
// The test boundary is the `SpanDrawerItem` lightweight seam — no real Drawer,
// no real estate, no real encoder.

import Testing
import Foundation
import CorpusKit
import SynapseKit
@testable import GeniusLocusKit

@Suite("SpanEncodeDuty — span-encode drain duty (ENCODER_RERANK_CONTRACT §W4)")
struct SpanEncodeDutyTests {

    @Test("span content version is the persisted FNV-1a UTF-8 value")
    func spanContentVersionUsesFNV1a() {
        #expect(SpanContentVersion.fnv1a64("hello") == "a430d84680aabd0b")
        #expect(SpanContentVersion.fnv1a64("hello") != SpanContentVersion.fnv1a64("hello!"))
    }

    @Test("indexed old, absent, or malformed span sets are repair debt")
    func indexedStaleSpanSetsRequireRepair() {
        let content = "legacy transcript"
        let expected = SpanContentVersion.fnv1a64(content)
        let valid = SpanVectorRow(
            index: 0, int8: [1, 2], scale: 0.5,
            startWord: 0, endWord: 2, contentVersion: expected)
        #expect(!SpanContentVersion.requiresRepair(
            content: content, expectedDimension: 2, maxSpans: 3,
            rows: [valid], hasMalformedRows: false))
        #expect(SpanContentVersion.requiresRepair(
            content: content, expectedDimension: 2, maxSpans: 3,
            rows: [SpanVectorRow(index: 0, int8: [1, 2], scale: 0.5,
                                 startWord: 0, endWord: 2, contentVersion: "old-content-hash")],
            hasMalformedRows: false))
        #expect(SpanContentVersion.requiresRepair(
            content: content, expectedDimension: 2, maxSpans: 3,
            rows: [SpanVectorRow(index: 0, int8: [1, 2, 3], scale: 0.5,
                                 startWord: 0, endWord: 2, contentVersion: expected)],
            hasMalformedRows: false))
        #expect(SpanContentVersion.requiresRepair(
            content: content, expectedDimension: 2, maxSpans: 3,
            rows: [SpanVectorRow(index: 0, int8: [1, 2], scale: .nan,
                                 startWord: 0, endWord: 2, contentVersion: expected)],
            hasMalformedRows: false))
        #expect(SpanContentVersion.requiresRepair(
            content: content, expectedDimension: 2, maxSpans: 3,
            rows: [SpanVectorRow(index: 0, int8: [1, 2], scale: 0.5,
                                 startWord: 0, endWord: 3, contentVersion: expected)],
            hasMalformedRows: false))
        #expect(SpanContentVersion.requiresRepair(
            content: content, expectedDimension: 2, maxSpans: 3,
            rows: [], hasMalformedRows: false))
        #expect(SpanContentVersion.requiresRepair(
            content: content, expectedDimension: 2, maxSpans: 3,
            rows: [valid], hasMalformedRows: true))
    }

    // MARK: - Fake encoder

    /// Fake SpanEncoder that returns deterministic float vectors.
    /// Float values are arbitrary — cross-port matching is not required
    /// per ENC-COMMON_BRIEF; span counts and bit-27 semantics must match.
    private struct FakeEncoder: SpanEncoder {
        let spec: EncoderModelSpec

        init(windowWords: Int = 3, maxSpans: Int = 4) {
            spec = EncoderModelSpec(
                modelID: "fake-model",
                modelVersion: "v1",
                dim: 4,
                queryPrefix: "Q:",
                docPrefix: "D:",
                pooling: .mean,
                tokenizerHash: "abc123",
                windowWords: windowWords,
                overlapDivisor: 2,
                maxSpans: maxSpans,
                maxSequence: 512)
        }

        func encodeQuery(_ text: String) async throws -> [Float] {
            return [0.5, -0.5, 0.25, -0.25]
        }

        func encodeSpans(_ spans: [String]) async throws -> [[Float]] {
            // One 4-dim unit vector per span — deterministic, non-zero.
            return spans.map { _ in [0.5, -0.5, 0.25, -0.25] }
        }
    }

    // MARK: - Fake writer (captures written rows)

    private actor FakeWriter: SpanVectorWriter {
        private(set) var written: [(itemID: String, spans: [SpanVectorInput])] = []

        func writeSpanVectors(
            itemID: String,
            modelID: String,
            modelVersion: String,
            spans: [SpanVectorInput]
        ) async throws {
            written.append((itemID: itemID, spans: spans))
        }

        func callCount() -> Int { written.count }
        func spanCount(for id: String) -> Int {
            written.filter { $0.itemID == id }.map { $0.spans.count }.reduce(0, +)
        }
    }

    // MARK: - Fake estate context (protocol seam; no real estate)

    private actor FakeContext: SpanEncodeEstateContext {
        // Each entry: (id, content, indexed)
        private(set) var entries: [(id: String, content: String, indexed: Bool)]

        init(items: [(id: String, content: String)]) {
            self.entries = items.map { (id: $0.id, content: $0.content, indexed: false) }
        }

        func pendingSpanEncodeBatch(limit: Int) async throws -> [SpanDrawerItem] {
            // Return up to `limit` items with bit 27 clear (indexed == false).
            return entries
                .filter { !$0.indexed }
                .prefix(limit)
                .map { SpanDrawerItem(id: $0.id, content: $0.content) }
        }

        func setSpanIndexed(drawerID: String, indexed: Bool, now: Date) async throws {
            guard let i = entries.firstIndex(where: { $0.id == drawerID }) else { return }
            entries[i] = (id: drawerID, content: entries[i].content, indexed: indexed)
        }

        func isIndexed(_ id: String) -> Bool {
            entries.first { $0.id == id }?.indexed ?? false
        }

        /// Simulate a content write: clears the indexed flag for one drawer.
        /// This mirrors the capture path — every content write clears bit 27
        /// in the same statement that bumps `content_hash` (contract §5).
        func clearBit27(for id: String) {
            guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[i] = (id: id, content: entries[i].content, indexed: false)
        }

        // The drawer state the liveness recheck sees, when it differs from
        // the pending snapshot: `.some(nil)` = erased (missing or
        // tombstoned), `.some(text)` = rewritten. Drawers without an entry
        // read back their snapshot content. `pendingSpanEncodeBatch`
        // deliberately ignores this map: it models the snapshot taken
        // BEFORE the erase or rewrite landed.
        private var liveOverrides: [String: String?] = [:]

        /// Erase `id` after the pending snapshot: the recheck sees no drawer.
        func eraseAfterSnapshot(_ id: String) {
            liveOverrides[id] = .some(nil)
        }

        /// Rewrite `id` after the pending snapshot: the recheck sees `content`.
        func rewriteAfterSnapshot(_ id: String, content: String) {
            liveOverrides[id] = .some(content)
        }

        func liveSpanEncodeContent(drawerID: String) async throws -> String? {
            if let overridden = liveOverrides[drawerID] { return overridden }
            return entries.first { $0.id == drawerID }?.content
        }
    }

    // MARK: - Helpers

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func fiveItems() -> [(id: String, content: String)] {
        (0..<5).map { i in
            (id: "drawer-\(i)",
             content: "hello world foo bar baz qux quux corge grault \(i)")
        }
    }

    // MARK: - Counting encoder (ADR-028 E1)

    /// A fake encoder that counts its `encodeSpans` calls and throws when a
    /// span text carries the word `poison`, so a batch holding one bad
    /// drawer fails as a batch and only that drawer fails on its own.
    private final class CountingEncoder: SpanEncoder, @unchecked Sendable {
        let spec: EncoderModelSpec
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }

        init() {
            spec = EncoderModelSpec(
                modelID: "counting-model", modelVersion: "v1", dim: 4,
                queryPrefix: "Q:", docPrefix: "D:", pooling: .mean,
                tokenizerHash: "abc123", windowWords: 3, overlapDivisor: 2,
                maxSpans: 4, maxSequence: 512)
        }

        struct Poisoned: Error {}

        func encodeQuery(_ text: String) async throws -> [Float] { [0.5, -0.5, 0.25, -0.25] }

        func encodeSpans(_ spans: [String]) async throws -> [[Float]] {
            lock.withLock { _calls += 1 }
            if spans.contains(where: { $0.contains("poison") }) { throw Poisoned() }
            return spans.map { _ in [0.5, -0.5, 0.25, -0.25] }
        }
    }

    @Test("ADR-028 E1: one encoder call covers every pending drawer in the batch")
    func batchEncodesWithOneEncoderCall() async throws {
        let context = FakeContext(items: fiveItems())
        let writer = FakeWriter()
        let encoder = CountingEncoder()

        let result = try await SpanEncodeDuty._encodeBatch(
            context: context, encoder: encoder, writer: writer, limit: 64, now: t0)

        #expect(result.encoded == 5)
        #expect(result.failed == 0)
        #expect(encoder.calls == 1, "the batch is one round trip through the encoder")
        #expect(await writer.callCount() == 5, "the vectors are dealt back to every drawer")
    }

    @Test("ADR-028 E1: a failed batch falls back per drawer and only the bad drawer fails")
    func batchFailureFallsBackPerDrawer() async throws {
        var items = fiveItems()
        items[2] = (id: "drawer-2", content: "this drawer holds poison words for the encoder")
        let context = FakeContext(items: items)
        let writer = FakeWriter()
        let encoder = CountingEncoder()

        let result = try await SpanEncodeDuty._encodeBatch(
            context: context, encoder: encoder, writer: writer, limit: 64, now: t0)

        #expect(result.encoded == 4, "the four clean drawers are encoded on their own")
        #expect(result.failed == 1, "the poisoned drawer alone fails")
        #expect(encoder.calls == 6, "one batch call, then one call per drawer")
        #expect(await context.isIndexed("drawer-2") == false, "bit 27 stays clear for retry")
        #expect(await writer.spanCount(for: "drawer-2") == 0)
        #expect(await writer.callCount() == 4)
    }

    // MARK: - Test 1: pump with fake encoder sets bit 27 and writes spans

    @Test("pump with fake encoder: 5 drawers encoded, bit 27 set, span rows written")
    func pumpWithFakeEncoderSetsBitAndWritesSpans() async throws {
        let items = fiveItems()
        let context = FakeContext(items: items)
        let writer = FakeWriter()
        let encoder = FakeEncoder(windowWords: 3, maxSpans: 4)

        // One pump: all five items are pending (bit 27 clear).
        let result = try await SpanEncodeDuty._encodeBatch(
            context: context,
            encoder: encoder,
            writer: writer,
            limit: 64,
            now: t0)

        // Contract: all five encoded, zero skipped, zero failed.
        #expect(result.encoded == 5,
            "all 5 drawers must be encoded in one pump")
        #expect(result.skipped == 0, "no empty-content drawers → zero skipped")
        #expect(result.failed == 0, "fake encoder never throws → zero failed")

        // Bit 27 must be set on all five drawers.
        for i in 0..<5 {
            let id = "drawer-\(i)"
            let indexed = await context.isIndexed(id)
            #expect(indexed, "drawer \(id) must have bit 27 set after encoding")
        }

        // Span rows must have been written (call count = 5, one per drawer).
        let callCount = await writer.callCount()
        #expect(callCount == 5, "writer must have been called once per drawer")

        // Verify span count ≥ 1 for a non-empty drawer (Spanner.spans governs exact count).
        let spanCount = await writer.spanCount(for: "drawer-0")
        #expect(spanCount >= 1, "at least one span must be written for a non-empty drawer")

        // Second pump: all bits set, nothing pending.
        // Failure mode: a drawer encoded twice would have bit 27 set from the
        // first pump, so pending returns zero — result2 must be all-zero.
        let result2 = try await SpanEncodeDuty._encodeBatch(
            context: context,
            encoder: encoder,
            writer: writer,
            limit: 64,
            now: t0)
        #expect(result2.encoded == 0,
            "second pump must encode 0 (all bits already set)")
    }

    // MARK: - Test 2: encoder nil — pump completes, no rows, bits stay clear

    @Test("encoder nil: pump completes silently, no rows written, bits stay clear")
    func encoderNilPumpCompletesNoRowsBitsClear() async throws {
        let context = FakeContext(items: fiveItems())
        let writer = FakeWriter()

        // Encoder is nil: duty must skip without error (failure mode: throws).
        let result = try await SpanEncodeDuty._encodeBatch(
            context: context,
            encoder: nil,   // nil encoder
            writer: writer,
            limit: 64,
            now: t0)

        #expect(result.encoded == 0, "nil encoder → zero encoded")
        #expect(result.skipped == 0, "nil encoder → zero skipped (early return)")
        #expect(result.failed == 0, "nil encoder → zero failed (early return)")

        let callCount = await writer.callCount()
        #expect(callCount == 0, "nil encoder → no rows written")

        // Bits must stay clear (retry on next pump when encoder becomes available).
        for i in 0..<5 {
            let id = "drawer-\(i)"
            let indexed = await context.isIndexed(id)
            #expect(!indexed, "drawer \(id) must not have bit 27 set when encoder is nil")
        }
    }

    // MARK: - Test 3: content write clears bit 27 and next pump re-encodes

    @Test("content write clears bit 27 and next pump re-encodes the drawer")
    func contentWriteClearsBitAndNextPumpReencodes() async throws {
        let context = FakeContext(items: fiveItems())
        let writer = FakeWriter()
        let encoder = FakeEncoder(windowWords: 3, maxSpans: 4)

        // First pump: encode all five drawers.
        _ = try await SpanEncodeDuty._encodeBatch(
            context: context, encoder: encoder, writer: writer, limit: 64, now: t0)

        // All five must be indexed after the first pump.
        for i in 0..<5 {
            let indexed = await context.isIndexed("drawer-\(i)")
            #expect(indexed, "drawer-\(i) must be indexed after first pump")
        }

        let callsAfterFirstPump = await writer.callCount()
        #expect(callsAfterFirstPump == 5)

        // Simulate a content write on drawer-2: clears bit 27.
        // This mirrors what the capture path does when new content arrives.
        await context.clearBit27(for: "drawer-2")

        let bit27AfterClear = await context.isIndexed("drawer-2")
        #expect(!bit27AfterClear, "bit 27 must be clear after simulated content write")

        // Second pump: only drawer-2 is pending.
        let result2 = try await SpanEncodeDuty._encodeBatch(
            context: context, encoder: encoder, writer: writer, limit: 64, now: t0)

        #expect(result2.encoded == 1, "second pump must re-encode the 1 cleared drawer")
        #expect(result2.skipped == 0)
        #expect(result2.failed == 0)

        let callsAfterSecondPump = await writer.callCount()
        #expect(callsAfterSecondPump == 6,
            "6 total write calls: 5 from first pump + 1 re-encode from second pump")

        // Bit 27 must be re-set on drawer-2.
        let bit27AfterReencode = await context.isIndexed("drawer-2")
        #expect(bit27AfterReencode, "bit 27 must be set again after re-encode")
    }

    // MARK: - Test 4: in-flight erase — no span write, bit 27 stays clear

    /// Liveness recheck: a drawer erased between the pending read and the
    /// span write gets NO span rows and keeps bit 27 clear; its four
    /// untouched siblings are encoded. Pre-fix the duty wrote rows for all
    /// five (an erased drawer's content-derived spans recreated after the
    /// erase). Twin of Rust `in_flight_erase_skips_span_write_and_keeps_bit_clear`.
    @Test("in-flight erase: the erased drawer gets no span write and bit 27 stays clear")
    func inFlightEraseSkipsSpanWrite() async throws {
        let context = FakeContext(items: fiveItems())
        await context.eraseAfterSnapshot("drawer-2")
        let writer = FakeWriter()
        let encoder = FakeEncoder(windowWords: 3, maxSpans: 4)

        let result = try await SpanEncodeDuty._encodeBatch(
            context: context, encoder: encoder, writer: writer, limit: 64, now: t0)

        #expect(result.encoded == 4, "the four live drawers are encoded")
        #expect(result.skipped == 1, "the erased drawer is skipped, not failed")
        #expect(result.failed == 0)
        let callCount = await writer.callCount()
        #expect(callCount == 4, "no span write for the erased drawer")
        let erasedSpans = await writer.spanCount(for: "drawer-2")
        #expect(erasedSpans == 0, "drawer-2 must have no span rows written")
        let indexed = await context.isIndexed("drawer-2")
        #expect(!indexed, "bit 27 stays clear on drawer-2")
    }

    // MARK: - Test 5: in-flight rewrite — stale spans are not written

    /// Liveness recheck: a drawer rewritten between the pending read and the
    /// span write gets no rows from the STALE text and keeps bit 27 clear
    /// (the next pump encodes the current text). Pre-fix the duty wrote the
    /// old text's spans and set bit 27, freezing a stale span set under a
    /// content version the drawer no longer has. Twin of Rust
    /// `in_flight_rewrite_skips_stale_span_write`.
    @Test("in-flight rewrite: the stale span set is not written and bit 27 stays clear")
    func inFlightRewriteSkipsSpanWrite() async throws {
        let context = FakeContext(items: [
            (id: "drawer-1", content: "alpha beta gamma delta epsilon zeta"),
            (id: "drawer-2", content: "one two three four five six seven"),
        ])
        await context.rewriteAfterSnapshot("drawer-2", content: "entirely different words now here")
        let writer = FakeWriter()
        let encoder = FakeEncoder(windowWords: 3, maxSpans: 4)

        let result = try await SpanEncodeDuty._encodeBatch(
            context: context, encoder: encoder, writer: writer, limit: 64, now: t0)

        #expect(result.encoded == 1)
        #expect(result.skipped == 1, "the rewritten drawer is skipped this pump")
        #expect(result.failed == 0)
        let callCount = await writer.callCount()
        #expect(callCount == 1)
        let staleSpans = await writer.spanCount(for: "drawer-2")
        #expect(staleSpans == 0, "drawer-2 must not receive the stale span set")
        let indexed = await context.isIndexed("drawer-2")
        #expect(!indexed, "bit 27 stays clear on drawer-2")
    }
}
