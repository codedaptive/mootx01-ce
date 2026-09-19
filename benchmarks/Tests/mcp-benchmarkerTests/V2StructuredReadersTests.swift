import Testing
import Foundation
@testable import mcp_benchmarker

// V2StructuredReadersTests.swift — unit coverage for the three new v2 typed
// readers added to MCPClient.swift and EncodeBarrier.swift:
//
//   parseToolResult(.mootV2) → drawersWritten, metaStatus
//   parseDrainResult(_:)     → reads drainEntries; falls back to text
//   dreamStatusFromResult(_:)→ reads drainEntries.dreaming; falls back to text
//
// All tests use lightweight in-process fixtures — no live server needed.

// MARK: - Fixture builders

/// Wraps a server's text payload in the MCP content text-block envelope.
private func textResult(_ text: String) -> JSONValue {
    .object(["content": .array([
        .object(["type": .string("text"), "text": .string(text)])
    ])])
}

/// Builds an MCP result carrying `structuredContent` alongside a text block.
private func structuredResult(structured: JSONValue,
                               text: String = "JSON seed import complete.") -> JSONValue {
    .object([
        "content": .array([
            .object(["type": .string("text"), "text": .string(text)])
        ]),
        "structuredContent": structured
    ])
}

/// Builds a minimal `MCPToolResult` with only the specified fields set;
/// the rest take the init defaults (false/nil/[]).
private func makeResult(textBlocks: [String] = [],
                        drawersWritten: Int? = nil,
                        drainEntries: [V2DrainEntry]? = nil,
                        metaStatus: String? = nil) -> MCPToolResult {
    MCPToolResult(
        orderedIDs: [], items: [],
        writeAssignedID: nil,
        textBlocks: textBlocks,
        isError: false,
        refusal: nil,
        withheldBySensitivity: nil,
        drawersWritten: drawersWritten,
        drainEntries: drainEntries,
        metaStatus: metaStatus)
}

// MARK: - Class A: drawersWritten from structuredContent.data.drawers_written

struct V2ImportReceiptTests {

    /// Happy path: structuredContent.data.drawers_written == expected count.
    @Test("drawersWritten: structured receipt decodes correct count")
    func drawersWritten_matchingCount() {
        let sc: JSONValue = .object([
            "data": .object([
                "drawers_written": .number(42),
                "seed_name": .string("test_seed")
            ]),
            "meta": .object(["status": .string("completed")])
        ])
        let result = MCPClient.parseToolResult(structuredResult(structured: sc), format: .mootV2)
        #expect(result.drawersWritten == 42)
        #expect(result.metaStatus == "completed")
    }

    /// Sad path: no structuredContent → drawersWritten is nil so the runner rejects.
    @Test("drawersWritten: absent structuredContent yields nil")
    func drawersWritten_noStructuredContent() {
        let result = MCPClient.parseToolResult(
            textResult("JSON seed import complete."),
            format: .mootV2)
        #expect(result.drawersWritten == nil)
    }

    /// Sad path: count differs from expected — runner can compare and reject.
    @Test("drawersWritten: mismatched count is decoded faithfully for rejection")
    func drawersWritten_wrongCount() {
        let sc: JSONValue = .object([
            "data": .object(["drawers_written": .number(7)]),
            "meta": .object(["status": .string("completed")])
        ])
        let result = MCPClient.parseToolResult(structuredResult(structured: sc), format: .mootV2)
        #expect(result.drawersWritten == 7)
    }

    /// data absent but meta present: drawersWritten nil, metaStatus still decoded.
    @Test("drawersWritten: absent data block still decodes metaStatus from meta")
    func drawersWritten_dataAbsent_metaPresent() {
        let sc: JSONValue = .object([
            "meta": .object(["status": .string("completed")])
        ])
        let result = MCPClient.parseToolResult(structuredResult(structured: sc), format: .mootV2)
        #expect(result.drawersWritten == nil)
        #expect(result.metaStatus == "completed")
    }
}

// MARK: - Class C: parseDrainResult — structured drain_entries + text fallback

struct V2DrainResultTests {

    // -- Structured path (drainEntries present) --

    /// All lanes idle, pending=0 → settled.
    @Test("parseDrainResult: all-idle structured entries → .idle")
    func allIdle_isIdle() {
        let r = makeResult(drainEntries: [
            V2DrainEntry(name: "corpus_encode", state: "idle", pending: 0),
            V2DrainEntry(name: "dreaming", state: "idle", pending: 0)
        ])
        #expect(parseDrainResult(r) == .idle)
    }

    /// Any lane draining → .draining.
    @Test("parseDrainResult: one draining lane in structured entries → .draining")
    func oneDraining_isDraining() {
        let r = makeResult(drainEntries: [
            V2DrainEntry(name: "corpus_encode", state: "draining", pending: 5),
            V2DrainEntry(name: "dreaming", state: "idle", pending: 0)
        ])
        #expect(parseDrainResult(r) == .draining)
    }

    /// Any lane with pending > 0 (even when state="idle") → .draining.
    @Test("parseDrainResult: pending > 0 with state=idle → .draining")
    func pendingPositive_isDraining() {
        let r = makeResult(drainEntries: [
            V2DrainEntry(name: "corpus_encode", state: "idle", pending: 3)
        ])
        #expect(parseDrainResult(r) == .draining)
    }

    /// Empty entries array → .noLanes.
    @Test("parseDrainResult: empty drain entries array → .noLanes")
    func emptyEntries_isNoLanes() {
        let r = makeResult(drainEntries: [])
        #expect(parseDrainResult(r) == .noLanes)
    }

    // -- Unrecognised state word (structured path) --

    /// Unrecognised state word "wedged" on the structured path → .unparseable,
    /// not .idle. Covers EncodeBarrier.swift:258 (the structured fallback branch).
    @Test("parseDrainResult: unrecognised state word in structured entry → .unparseable")
    func unknownStateWord_isUnparseable() {
        let r = makeResult(drainEntries: [
            V2DrainEntry(name: "corpus_encode", state: "wedged", pending: 0)
        ])
        #expect(parseDrainResult(r) == .unparseable,
                "unrecognised state must yield .unparseable, not any other case")
        #expect(parseDrainResult(r) != .idle,
                "unrecognised state must not be misclassified as .idle")
    }

    // -- Text fallback (drainEntries nil) --

    @Test("parseDrainResult: nil drainEntries falls back to text parsing (idle)")
    func textFallback_idle() {
        let r = makeResult(
            textBlocks: ["drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0, encoded_chunks: 100"],
            drainEntries: nil)
        #expect(parseDrainResult(r) == .idle)
    }

    @Test("parseDrainResult: nil drainEntries falls back to text parsing (draining)")
    func textFallback_draining() {
        let r = makeResult(
            textBlocks: ["drains: 1\n  corpus_encode: draining \u{2014} pending: 7, in_flight: 1, encoded_chunks: 50"],
            drainEntries: nil)
        #expect(parseDrainResult(r) == .draining)
    }
}

// MARK: - Class B: dreamStatusFromResult — structured + text fallback

struct V2DreamStatusTests {

    /// Dreaming lane idle, pending=0 → settled.
    @Test("dreamStatusFromResult: dreaming lane idle → settled")
    func dreamingIdle_settled() {
        let r = makeResult(drainEntries: [
            V2DrainEntry(name: "corpus_encode", state: "idle", pending: 0),
            V2DrainEntry(name: "dreaming", state: "idle", pending: 0)
        ], metaStatus: "completed")
        let status = dreamStatusFromResult(r)
        #expect(status.settled == true)
        #expect(status.pending == 0)
    }

    /// Dreaming lane draining, pending > 0 → not settled.
    @Test("dreamStatusFromResult: dreaming lane draining → not settled")
    func dreamingDraining_notSettled() {
        let r = makeResult(drainEntries: [
            V2DrainEntry(name: "dreaming", state: "draining", pending: 12)
        ])
        let status = dreamStatusFromResult(r)
        #expect(status.settled == false)
        #expect(status.pending == 12)
    }

    /// No dreaming lane in entries → settled (default DreamStatus).
    @Test("dreamStatusFromResult: no dreaming lane in entries → settled")
    func noDreamingLane_settled() {
        let r = makeResult(drainEntries: [
            V2DrainEntry(name: "corpus_encode", state: "idle", pending: 0)
        ], metaStatus: "completed")
        let status = dreamStatusFromResult(r)
        #expect(status.settled == true)
        #expect(status.pending == 0)
    }

    /// drainEntries nil → falls back to text parsing (dreaming lane draining).
    @Test("dreamStatusFromResult: nil drainEntries falls back to text (not settled)")
    func textFallback_draining() {
        let r = makeResult(
            textBlocks: [
                "drains: 2\n" +
                "  corpus_encode: idle \u{2014} pending: 0, in_flight: 0, encoded_chunks: 100\n" +
                "  dreaming: draining \u{2014} pending: 5, in_flight: 2, encoded_chunks: 0"
            ],
            drainEntries: nil)
        let status = dreamStatusFromResult(r)
        #expect(status.settled == false)
        #expect(status.pending == 5)
    }
}
