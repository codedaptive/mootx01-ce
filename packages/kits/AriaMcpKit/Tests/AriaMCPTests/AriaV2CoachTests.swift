/// V2 coaching engine tests — section 12.5 trigger coverage.
///
/// Two-pronged strategy:
///
///   1. Direct calls to `AriaV2Coach.coachingHint(request:result:)` (internal,
///      accessible via @testable import) for all triggers. Synthetic result
///      envelopes are constructed in-line.
///
///   2. `AriaV2Envelope` function tests for ordering (hint before coaching block)
///      and the 512-scalar clamp boundary (hint appended AFTER the clamped body).
///
/// ## Note on the erase confirmation:false trigger
///
/// `AriaV2EraseMemoryRequest.init(arguments:)` throws when `confirmation` is
/// false, so `AriaSurfaceRequest.eraseMemory` cannot carry `confirmation: false`
/// from outside the module. This trigger is covered by the Rust unit tests in
/// `rust/src/v2/coach.rs`. The Swift guard (`hintForErase(confirmation:)`) is
/// identical logic; it is reached only through the internal code path and is
/// architecturally prevented from firing on the v2 surface while the decoder
/// enforces strict validation.
import Foundation
import Testing
@testable import AriaMCP

// ---------------------------------------------------------------------------
// Helpers shared across all direct-coach tests
// ---------------------------------------------------------------------------

/// Minimal non-error v2 success result envelope.
private func successResult(text: String) -> JSONValue {
    .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        "structuredContent": .object(["data": .object([:]), "meta": .object([:])]),
        "isError": .bool(false),
    ])
}

/// Success envelope with an empty "results" array in structuredContent.data.
private func emptyResultsResult() -> JSONValue {
    .object([
        "content": .array([.object(["type": .string("text"), "text": .string("no results")])]),
        "structuredContent": .object(["data": .object(["results": .array([])]), "meta": .object([:])]),
        "isError": .bool(false),
    ])
}

/// Error envelope (isError:true).
private func errorResult(message: String) -> JSONValue {
    .object([
        "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
        "structuredContent": .object(["error": .object(["code": .string("test"), "message": .string(message)])]),
        "isError": .bool(true),
    ])
}

/// Success envelope with the given text in content[0].text.
private func textResult(text: String) -> JSONValue {
    successResult(text: text)
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

@Suite("AriaV2Coach §12.5 trigger coverage")
struct AriaV2CoachTests {

    // -----------------------------------------------------------------------
    // isError guard
    // -----------------------------------------------------------------------

    /// A coaching hint must never attach to an isError:true result.
    /// The guard fires before any trigger check, so the request type is irrelevant.
    @Test
    func isErrorGuardReturnsNilRegardlessOfTrigger() throws {
        // Long-query request that would fire a hint on a success result.
        let longQuery = String(repeating: "a", count: 201)
        let request = AriaSurfaceRequest.memorySearch(
            try AriaV2MemorySearchRequest(arguments: .object(["query": .string(longQuery)]))
        )
        let result = errorResult(message: "deliberate test error")
        #expect(
            AriaV2Coach.coachingHint(request: request, result: result) == nil,
            "coachingHint must return nil for isError:true regardless of the trigger"
        )
    }

    // -----------------------------------------------------------------------
    // moot_memory_search — long-query trigger
    // -----------------------------------------------------------------------

    @Test
    func memorySearchLongQueryHintFires() throws {
        let longQuery = String(repeating: "x", count: 201)
        let request = AriaSurfaceRequest.memorySearch(
            try AriaV2MemorySearchRequest(arguments: .object(["query": .string(longQuery)]))
        )
        let result = successResult(text: "memory search response")
        let hint = try #require(
            AriaV2Coach.coachingHint(request: request, result: result),
            "Long-query trigger must produce a hint"
        )
        #expect(
            hint.contains("200 characters") || hint.contains("shorter"),
            "Long-query hint must mention the 200-character threshold; got: \(hint)"
        )
    }

    // -----------------------------------------------------------------------
    // moot_memory_search — zero-results trigger
    // -----------------------------------------------------------------------

    @Test
    func memorySearchZeroResultsHintFires() throws {
        // A short query means the long-query trigger does not fire; zero results do.
        let request = AriaSurfaceRequest.memorySearch(
            try AriaV2MemorySearchRequest(arguments: .object(["query": .string("short")]))
        )
        let result = emptyResultsResult()
        let hint = try #require(
            AriaV2Coach.coachingHint(request: request, result: result),
            "Zero-results trigger must produce a hint"
        )
        #expect(
            hint.contains("No memories matched") || hint.contains("moot_file_memory"),
            "Zero-results hint must guide toward filing content; got: \(hint)"
        )
    }

    // -----------------------------------------------------------------------
    // moot_file_memory — large-content trigger
    // -----------------------------------------------------------------------

    @Test
    func fileMemoryLargeContentHintFires() throws {
        let largeContent = String(repeating: "y", count: 4_001)
        let request = AriaSurfaceRequest.fileMemory(
            try AriaV2FileMemoryRequest(arguments: .object([
                "content": .string(largeContent),
                "subject": .string("Test subject."),
                "location": .string("default"),
            ]))
        )
        let result = successResult(text: "filed memory")
        let hint = try #require(
            AriaV2Coach.coachingHint(request: request, result: result),
            "Large-content trigger must produce a hint"
        )
        #expect(
            hint.contains("4,000") || hint.contains("splitting"),
            "Large-content hint must mention 4,000 characters or splitting; got: \(hint)"
        )
    }

    // -----------------------------------------------------------------------
    // moot_migration_confirm — disqualified branch result
    // -----------------------------------------------------------------------

    @Test
    func migrationConfirmDisqualifiedTextTriggersHint() throws {
        let winnerID = UUID()
        let request = AriaSurfaceRequest.migrationConfirm(
            try AriaV2ConfirmMigrationRequest(arguments: .object([
                "winner_branch_id": .string(winnerID.uuidString),
            ]))
        )
        // A result whose text contains "disqualified" matches the trigger.
        let result = textResult(text: "Two branches were disqualified during migration.")
        let hint = try #require(
            AriaV2Coach.coachingHint(request: request, result: result),
            "Disqualified-branch trigger must produce a hint"
        )
        #expect(
            hint.contains("disqualified") || hint.contains("moot_estate_status"),
            "Disqualified hint must reference the condition or the recovery tool; got: \(hint)"
        )
    }

    // -----------------------------------------------------------------------
    // moot_link_memories — unresolved IDs trigger
    // -----------------------------------------------------------------------

    @Test
    func linkMemoriesUnresolvedTextTriggersHint() throws {
        let fromID = UUID()
        let toID = UUID()
        let request = AriaSurfaceRequest.linkMemories(
            try AriaV2LinkMemoriesRequest(arguments: .object([
                "from_id": .string(fromID.uuidString),
                "to_id": .string(toID.uuidString),
                "relationship": .string("relates"),
            ]))
        )
        // A result whose text contains "unresolved" matches the trigger.
        let result = textResult(text: "One or more memory IDs are unresolved.")
        let hint = try #require(
            AriaV2Coach.coachingHint(request: request, result: result),
            "Unresolved-IDs trigger must produce a hint"
        )
        #expect(
            hint.contains("unresolved") || hint.contains("moot_memory_search"),
            "Unresolved hint must reference the condition or the recovery tool; got: \(hint)"
        )
    }

    // -----------------------------------------------------------------------
    // Any lens — zero-results trigger
    // -----------------------------------------------------------------------

    @Test
    func recallLensZeroResultsTriggersHint() throws {
        let request = AriaSurfaceRequest.recallLens(
            try AriaV2RecallLensRequest(
                tool: "moot_recall_precise",
                arguments: .object(["query": .string("test query")])
            )
        )
        let result = emptyResultsResult()
        let hint = try #require(
            AriaV2Coach.coachingHint(request: request, result: result),
            "Lens zero-results trigger must produce a hint"
        )
        #expect(
            hint.contains("zero results") || hint.contains("moot_list_lenses"),
            "Lens zero-results hint must guide toward lens inspection; got: \(hint)"
        )
    }

    // -----------------------------------------------------------------------
    // First-match-wins
    //
    // A query over 200 characters AND zero results would satisfy two triggers.
    // The first trigger in §12.5 order is the long-query check inside
    // hintForMemorySearch. It must fire; the zero-results trigger must not.
    // -----------------------------------------------------------------------

    @Test
    func firstMatchWinsLongQueryBeatsZeroResults() throws {
        let longQuery = String(repeating: "z", count: 201)
        let request = AriaSurfaceRequest.memorySearch(
            try AriaV2MemorySearchRequest(arguments: .object(["query": .string(longQuery)]))
        )
        // An empty-results envelope: if zero-results fires, we get the file hint.
        let result = emptyResultsResult()
        let hint = try #require(
            AriaV2Coach.coachingHint(request: request, result: result),
            "First-match-wins: at least one trigger must fire"
        )
        // The long-query hint mentions the 200-character threshold; the zero-results
        // hint mentions "No memories matched" or "moot_file_memory". Confirm the
        // long-query hint text is present (first match) and the zero-results text
        // is absent.
        let isLongQueryHint = hint.contains("200 characters") || hint.contains("shorter")
        let isZeroResultsHint = hint.contains("No memories matched")
        #expect(isLongQueryHint, "Long-query hint must be the winner; got: \(hint)")
        #expect(!isZeroResultsHint, "Zero-results hint must not fire when long-query hint already won; got: \(hint)")
    }

    // -----------------------------------------------------------------------
    // Ordering: hint line appears BEFORE the coaching block in content[0].text
    //
    // Tests AriaV2Envelope directly: apply a hint to a base result, then apply
    // a coaching block. Verify the positions in the resulting text.
    // -----------------------------------------------------------------------

    @Test
    func hintPrecedesCoachingBlockInText() {
        let base = successResult(text: "operation result")
        let hintText = "Use a shorter query for better results."
        let coachBlock = "--- coaching block ---"

        // Hint applied first, then coaching block (the order the dispatcher uses).
        let withHint = AriaV2Envelope.applyHint(hintText, to: base)
        let withBoth = AriaV2Envelope.applyCoachingBlock(coachBlock, to: withHint)

        guard case .object(let env) = withBoth,
              case .array(let content) = env["content"],
              let first = content.first,
              case .object(let item) = first,
              case .string(let text) = item["text"] else {
            Issue.record("Could not extract content[0].text from result")
            return
        }

        let hintLine = "hint: " + hintText
        guard let hintPos = text.range(of: hintLine),
              let blockPos = text.range(of: coachBlock) else {
            Issue.record("Expected both hint and coaching block in text; text was: \(text)")
            return
        }
        #expect(
            hintPos.lowerBound < blockPos.lowerBound,
            "Hint line must precede the coaching block; text: \(text)"
        )
    }

    // -----------------------------------------------------------------------
    // 512-scalar clamp boundary
    //
    // A body longer than 512 Unicode scalars is clamped by AriaV2Envelope.success.
    // A hint appended afterward survives UNCLAMPED. Test the two functions
    // in sequence to verify the invariant.
    // -----------------------------------------------------------------------

    @Test
    func bodyClampedHintSurvivesUnclamped() {
        // Construct a 513-scalar body and compact it.
        let longBody = String(repeating: "a", count: 513)
        let clamped = AriaV2Envelope.compactText(longBody)
        #expect(clamped.unicodeScalars.count == 512, "compactText must clamp to exactly 512 scalars")

        // Build a result with the already-clamped text.
        let base = successResult(text: clamped)
        let hintText = "hint text that survives the clamp"
        let withHint = AriaV2Envelope.applyHint(hintText, to: base)

        guard case .object(let env) = withHint,
              case .array(let content) = env["content"],
              let first = content.first,
              case .object(let item) = first,
              case .string(let text) = item["text"] else {
            Issue.record("Could not extract content[0].text")
            return
        }

        // The combined text must exceed 512 scalars (because the hint is appended
        // after the 512-scalar body) and must contain the full hint line.
        #expect(
            text.unicodeScalars.count > 512,
            "Combined text must exceed 512 scalars after hint is appended"
        )
        #expect(
            text.contains("hint: " + hintText),
            "Full hint line must survive unclamped; text: \(text)"
        )
        // structuredContent["hint"] must also be set.
        if case .object(let sc) = env["structuredContent"],
           case .string(let hintField) = sc["hint"] {
            #expect(hintField == hintText, "structuredContent[\"hint\"] must equal the hint text")
        } else {
            Issue.record("structuredContent[\"hint\"] is missing")
        }
    }
}
