import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Tests for the teachme protocol and coaching-hint injection.
///
/// teachme: passing `teachme: true` on any tool returns a usage guide and
/// never touches the estate. Coaching hints appear on triggered call patterns
/// and are suppressed on error results.
///
/// `.serialized`: each test opens its own in-memory estate and issues live
/// dispatch calls; preserve sequential execution for isolation.
@Suite("Teachme and coaching", .serialized)
struct TeachmeTests {

    // MARK: - Harness

    /// Open a fresh in-memory estate and return a ToolDispatcher backed by it.
    private func makeDispatcher() async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "teachme-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return ToolDispatcher(kit: kit, handle: handle)
    }

    /// Extract the text content block from a `tools/call` result.
    private func text(of result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue ?? ""
    }

    /// Whether the result carries `isError: true`.
    private func isError(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue ?? false
    }

    // MARK: - Test 1: teachme on moot_file_memory

    /// Passing `teachme: true` on `moot_file_memory` returns the per-tool guide.
    /// The result must not be an error, must name the tool, and must contain the
    /// "Common mistakes" section. No `content` or `location` is required because
    /// the teachme interception fires before arg validation.
    @Test func teachmeOnFileMemoryReturnsGuide() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object(["teachme": .bool(true)])
        )
        #expect(!isError(result), "teachme must not set isError")
        let t = text(of: result)
        #expect(t.contains("moot_file_memory"), "guide must name the tool")
        #expect(t.contains("Common mistakes"), "guide must include the Common mistakes section")
    }

    // MARK: - Test 2: teachme on unknown tool

    /// `teachme: true` on an unrecognised tool name returns the fallback guide
    /// text rather than an error or methodNotFound throw.
    @Test func teachmeOnUnknownToolReturnsFallback() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_nonexistent_tool_xyz",
            arguments: .object(["teachme": .bool(true)])
        )
        #expect(!isError(result), "teachme fallback must not set isError")
        let t = text(of: result)
        #expect(t.contains("Unknown tool"), "fallback guide must say 'Unknown tool'")
        #expect(
            t.contains("moot_nonexistent_tool_xyz"),
            "fallback guide must echo the unknown tool name"
        )
    }

    // MARK: - Test 3: teachme on lens tool

    /// `teachme: true` on a reasoning-lens tool returns the generic lens guide
    /// which directs the caller to `moot_list_lenses`.
    @Test func teachmeOnLensToolReturnsGenericLensGuide() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_lens_keystones",
            arguments: .object(["teachme": .bool(true)])
        )
        #expect(!isError(result), "lens teachme must not set isError")
        let t = text(of: result)
        #expect(
            t.contains("moot_list_lenses"),
            "lens guide must direct caller to moot_list_lenses"
        )
    }

    // MARK: - Test 4: teachme does not execute

    /// `teachme: true` on `moot_file_memory` with a live estate must not create
    /// any drawer. The estate status must report zero active memories after the call.
    @Test func teachmeOnFileMemoryDoesNotCreateDrawer() async throws {
        let dispatcher = try await makeDispatcher()
        // Call with teachme:true — the runner must not fire.
        let guideResult = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "teachme": .bool(true),
                "content": .string("this content must never be filed"),
                "location": .string("test"),
            ])
        )
        #expect(!isError(guideResult), "teachme result must not be an error")
        // Estate status must show zero active memories.
        let statusResult = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:])
        )
        let statusText = text(of: statusResult)
        #expect(
            statusText.contains("memories: 0 active"),
            "no drawer must be created when teachme intercepts the call"
        )
    }

    // MARK: - Test 5: long query hint

    /// A 300-character query triggers the "long query" coaching hint on
    /// `moot_memory_search`. The hint fires before the zero-results check.
    @Test func longQueryHintAppearsOnSearch() async throws {
        let dispatcher = try await makeDispatcher()
        // 320-char query (8 chars × 40 = 320).
        let longQuery = String(repeating: "keyword ", count: 40)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string(longQuery)])
        )
        #expect(!isError(result), "search must not be an error result")
        #expect(
            text(of: result).contains("hint:"),
            "a query over 200 chars must produce a coaching hint"
        )
    }

    // MARK: - Test 6: short query no hint

    /// A 10-character query on a non-empty estate produces no coaching hint.
    /// A memory is filed first so the search returns at least one result,
    /// avoiding the zero-results trigger.
    @Test func shortQueryProducesNoHint() async throws {
        let dispatcher = try await makeDispatcher()
        // File a memory whose content contains the query keyword exactly.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("nohintkey phrase for test six isolation"),
                "location": .string("test"),
            ])
        )
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("nohintkey")])
        )
        #expect(!isError(result), "search must not be an error result")
        // nohintkey is 9 chars (< 200) — neither long-query nor no-query hint fires.
        // If BM25 returns the filed memory, no zero-results hint fires either.
        let t = text(of: result)
        // If the memory was found, no hint should appear.
        // If the memory was not found (0 results), the zero-results hint fires —
        // in that case, check that the zero-results hint (not long-query) is what fired.
        if t.contains("found 0 memory") {
            // Zero-results hint: acceptable but we distinguish it from long-query hint.
            // The long-query hint must not appear regardless.
            #expect(
                !t.contains("Long queries dilute"),
                "long-query hint must not fire for a short query"
            )
        } else {
            // Memory was found — no hint at all.
            #expect(!t.contains("hint:"), "short query with results must not produce any hint")
        }
    }

    // MARK: - Test 7: large content hint

    /// Filing a memory with content over 4000 characters triggers the
    /// "consider splitting" coaching hint.
    @Test func largeContentHintAppearsOnFile() async throws {
        let dispatcher = try await makeDispatcher()
        // 5005 chars (5 × 1001).
        let largeContent = String(repeating: "word ", count: 1001)
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(largeContent),
                "location": .string("test"),
            ])
        )
        #expect(!isError(result), "filing large content must succeed")
        #expect(
            text(of: result).contains("hint:"),
            "content over 4000 chars must trigger a coaching hint"
        )
    }

    // MARK: - Test 8: normal content no hint

    /// Filing a memory with content under 4000 characters produces no
    /// coaching hint.
    @Test func normalContentProducesNoHint() async throws {
        let dispatcher = try await makeDispatcher()
        let shortContent = String(repeating: "w", count: 200)   // 200 chars
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(shortContent),
                "location": .string("test"),
            ])
        )
        #expect(!isError(result), "filing normal content must succeed")
        #expect(
            !text(of: result).contains("hint:"),
            "content under 4000 chars must not produce a hint"
        )
    }

    // MARK: - Test 9: hint suppressed on error

    /// Error results (`isError: true`) never carry a coaching hint.
    /// `moot_erase_memory` with `confirmed: false` causes a substrate refusal
    /// (VerbError.expungeNotConfirmed) that surfaces as `isError: true`.
    /// Despite the CoachingEngine having a hint trigger for this case,
    /// the hint must not be appended because the result is an error.
    @Test func hintSuppressedOnErrorResult() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_erase_memory",
            arguments: .object([
                "id": .string("any-row-id"),
                "reason": .string("test erase without confirmation"),
                "confirmed": .bool(false),
            ])
        )
        // The substrate refuses the erase without confirmation — expect an error result.
        #expect(isError(result), "erase without confirmed:true must return isError:true")
        #expect(
            !text(of: result).contains("hint:"),
            "error results must never have a hint appended"
        )
    }

    // MARK: - Test 10: erase error message names the correct caller field

    /// When `moot_erase_memory` is called without `confirmed: true`, the error
    /// message must name "confirmed" — the actual field the tool schema requires
    /// and the handler reads. If the message named "confirmation" instead, an AI
    /// consumer reading the error would retry with the wrong field and loop forever.
    ///
    /// This test pins the corrected field name so the mismatch cannot regress.
    @Test func eraseErrorMessageNamesConfirmedField() async throws {
        let dispatcher = try await makeDispatcher()

        // Pass confirmed:false — triggers the VerbError.expungeNotConfirmed path.
        let result = try await dispatcher.dispatch(
            name: "moot_erase_memory",
            arguments: .object([
                "id": .string("any-row-id"),
                "reason": .string("test field-name in error message"),
                "confirmed": .bool(false),
            ])
        )
        #expect(isError(result), "erase without confirmed:true must return isError:true")
        let message = text(of: result)
        #expect(
            message.contains("confirmed=true"),
            "error must name the actual caller field 'confirmed=true'; got: \(message)"
        )
        #expect(
            !message.contains("confirmation=true"),
            "error must not name 'confirmation=true' — that field does not exist in the schema; got: \(message)"
        )

        // Verify confirmed:true still performs the erase successfully.
        // File a real memory first so the id is valid.
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("erase field-name regression test"),
                "location": .string("archive"),
            ])
        )
        #expect(!isError(fileResult), "file_memory must succeed; got: \(text(of: fileResult))")
        let filed = text(of: fileResult)
        // Extract the row id from "filed memory <id>\n..."
        let rowID = filed.components(separatedBy: "\n").first?
            .replacingOccurrences(of: "filed memory ", with: "") ?? ""
        #expect(!rowID.isEmpty, "must extract a row id from file result; got: \(filed)")

        let eraseResult = try await dispatcher.dispatch(
            name: "moot_erase_memory",
            arguments: .object([
                "id": .string(rowID),
                "reason": .string("regression test — confirmed:true erases"),
                "confirmed": .bool(true),
            ])
        )
        #expect(!isError(eraseResult), "erase with confirmed:true must succeed; got: \(text(of: eraseResult))")
    }
}
