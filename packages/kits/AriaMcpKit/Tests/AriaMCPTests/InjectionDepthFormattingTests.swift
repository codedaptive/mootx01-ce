// InjectionDepthFormattingTests.swift
//
// Verifies the injection-depth formatting applied to `_distilled` recall hits
// in `moot_memory_search` per DISTILLATION_DESIGN.md §2.5.
//
// Three confidence bands are tested with mock DistilledHeader values constructed
// directly from the `[DIST|…]` wire format. A non-distilled control case and
// a malformed-content case verify the unchanged fall-through path.

import Testing
import Foundation
import SubstrateML
import LocusKit
@testable import AriaMCP

@Suite("Injection depth formatting")
struct InjectionDepthFormattingTests {

    // MARK: - Helpers

    /// Build a `[DIST|…]` content string and parse it into a `DistilledHeader`.
    private func makeHeader(
        conf: Float32,
        src: Int = 5,
        snr: Float32 = 4.0,
        delta: String = "STATIC",
        prose: String = "The sky is blue."
    ) -> DistilledHeader? {
        let content = "[DIST|conf=\(String(format: "%.2f", conf))|src=\(src)|snr=\(String(format: "%.1f", snr))|delta=\(delta)] \(prose)"
        return DistilledHeader.parse(content)
    }

    // MARK: - factoidOnly (conf >= 0.7)

    @Test func factoidOnlyReturnsProseOnly() throws {
        let header = try #require(makeHeader(conf: 0.85, prose: "Paris is the capital of France."))
        let result = ToolDispatcher.injectionDepthFormatted(header: header, drawerID: "drawer-001")
        #expect(result == "Paris is the capital of France.")
        #expect(!result.contains("[distilled"))
    }

    @Test func factoidOnlyAtExactBoundary() throws {
        let header = try #require(makeHeader(conf: 0.70, prose: "Water boils at 100 °C."))
        let result = ToolDispatcher.injectionDepthFormatted(header: header, drawerID: "drawer-002")
        #expect(result == "Water boils at 100 °C.")
        #expect(!result.contains("[distilled"))
    }

    // MARK: - factoidWithMeta (conf in [0.4, 0.7))

    @Test func factoidWithMetaAppendsCountAndConfidence() throws {
        let header = try #require(makeHeader(conf: 0.55, src: 7, prose: "Mount Everest is the tallest mountain."))
        let result = ToolDispatcher.injectionDepthFormatted(header: header, drawerID: "drawer-003")
        #expect(result.hasPrefix("Mount Everest is the tallest mountain."))
        #expect(result.contains("[distilled from 7 memories, conf=0.55]"))
        #expect(!result.contains("sources:"))
    }

    @Test func factoidWithMetaAtLowerBoundary() throws {
        let header = try #require(makeHeader(conf: 0.40, src: 3, prose: "Gravity pulls objects down."))
        let result = ToolDispatcher.injectionDepthFormatted(header: header, drawerID: "drawer-004")
        #expect(result.contains("[distilled from 3 memories, conf=0.40]"))
    }

    // MARK: - factoidWithProvenance (conf < 0.4)

    @Test func factoidWithProvenanceAppendsConfAndDrawerID() throws {
        let header = try #require(makeHeader(conf: 0.30, prose: "Some uncertain factoid."))
        let drawerID = "bfc1e2d3-4567-89ab-cdef-000000000001"
        let result = ToolDispatcher.injectionDepthFormatted(header: header, drawerID: drawerID)
        #expect(result.hasPrefix("Some uncertain factoid."))
        #expect(result.contains("[distilled, conf=0.30, sources: \(drawerID)]"))
        #expect(!result.contains("memories"))
    }

    @Test func factoidWithProvenanceJustBelowMeta() throws {
        let header = try #require(makeHeader(conf: 0.39, prose: "Another low-confidence factoid."))
        let drawerID = "test-drawer-low-conf"
        let result = ToolDispatcher.injectionDepthFormatted(header: header, drawerID: drawerID)
        #expect(result.contains("[distilled, conf=0.39, sources: test-drawer-low-conf]"))
    }

    // MARK: - Non-distilled and malformed fall-through

    @Test func nonDistilledContentParsesToNil() {
        // Content without [DIST| prefix: DistilledHeader.parse returns nil.
        // The caller in runMemorySearch falls through to the plain preview path.
        let plain = "Just a regular memory without any distillation header."
        #expect(DistilledHeader.parse(plain) == nil)
    }

    @Test func emptyContentParsesToNil() {
        #expect(DistilledHeader.parse("") == nil)
    }

    @Test func partialDistPrefixParsesToNil() {
        // "[DIST" without closing pipe — not a valid header
        let bad = "[DISTno-pipe] prose"
        #expect(DistilledHeader.parse(bad) == nil)
    }

    // MARK: - Room discrimination (non-_distilled)

    /// Verifies the room discrimination gate for a non-`_distilled` drawer.
    ///
    /// In the production loop, the `if room == "_distilled"` guard short-circuits
    /// before `DistilledHeader.parse()` is called. This test exercises the parse
    /// path for DIST-prefixed content in a non-_distilled room to confirm the
    /// parse function itself is not the gate — the room check is.
    ///
    /// The production else-branch for any room != "_distilled" (or failed parse)
    /// produces `hit.drawer?.content.prefix(120) ?? "(not hydrated)"` — the
    /// format unchanged from before this mission. This is integration-verified
    /// by the existing semantic recall tests (DurableSemanticRecallTests,
    /// InMemorySemanticRecallTests) which exercise the full dispatch path with
    /// non-distilled rooms.
    @Test func distHeaderContentInNonDistilledRoomParsesNormally() {
        // A valid DIST-prefixed string parses regardless of what the caller's room
        // field says. The room check in the dispatch loop is the guard, not this function.
        let distContent = "[DIST|conf=0.85|src=5|snr=6.0|delta=STATIC] Some prose."
        let header = DistilledHeader.parse(distContent)
        // parse returns non-nil — confirms the room check must be done at the call site
        #expect(header != nil)
        // The formatted result would be prose-only (conf=0.85 >= 0.7)
        if let h = header {
            let result = ToolDispatcher.injectionDepthFormatted(header: h, drawerID: "arch-001")
            #expect(result == "Some prose.")
        }
    }

    // MARK: - Preview cap (secfix-p1-ariamcp)

    @Test func factoidOnlyLongProseIsCappedAt300Chars() throws {
        // A prose string longer than 300 chars must be truncated to exactly 300.
        let longProse = String(repeating: "A", count: 500)
        let header = try #require(makeHeader(conf: 0.85, prose: longProse))
        let result = ToolDispatcher.injectionDepthFormatted(header: header, drawerID: "cap-001")
        #expect(result.count == 300)
        #expect(!result.contains("[distilled"))
    }

    @Test func factoidOnlyShortProseIsNotTruncated() throws {
        // Prose shorter than 300 chars must be returned verbatim.
        let shortProse = "The boiling point of water is 100 °C at 1 atm."
        let header = try #require(makeHeader(conf: 0.85, prose: shortProse))
        let result = ToolDispatcher.injectionDepthFormatted(header: header, drawerID: "cap-002")
        #expect(result == shortProse)
    }

    @Test func factoidWithMetaLongProseIsCapped() throws {
        let longProse = String(repeating: "B", count: 600)
        let header = try #require(makeHeader(conf: 0.55, src: 3, prose: longProse))
        let result = ToolDispatcher.injectionDepthFormatted(header: header, drawerID: "cap-003")
        let lines = result.components(separatedBy: "\n")
        // First line = capped prose (300 Bs)
        #expect(lines[0].count == 300)
        // Second line = meta annotation
        #expect(lines[1].contains("[distilled from 3 memories, conf=0.55]"))
    }

    @Test func factoidWithProvenanceLongProseIsCapped() throws {
        let longProse = String(repeating: "C", count: 400)
        let drawerID = "cap-004"
        let header = try #require(makeHeader(conf: 0.25, prose: longProse))
        let result = ToolDispatcher.injectionDepthFormatted(header: header, drawerID: drawerID)
        let lines = result.components(separatedBy: "\n")
        #expect(lines[0].count == 300)
        #expect(lines[1].contains("[distilled, conf=0.25, sources: \(drawerID)]"))
    }

    @Test func distilledProseCappedAtConstant() throws {
        // Verify that the constant value itself is 300 (not accidentally changed).
        #expect(ToolDispatcher.distilledProseCap == 300)
    }
}
