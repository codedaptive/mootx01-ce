/// V2 coaching engine — section 12.5 trigger detection.
///
/// Implements the six coaching triggers from ARIA_MCP_INTERFACE.md §12.5 for
/// the v2 surface. Wire-aligned with Rust `v2/coach.rs`. Both ports must agree
/// on trigger order, trigger conditions, and hint text.
///
/// ## Trigger table (§12.5)
///
/// | Tool                   | Trigger                                         |
/// |------------------------|-------------------------------------------------|
/// | moot_memory_search     | no query, query over 200 chars, or zero results |
/// | moot_file_memory       | content over 4,000 chars or duplicate result    |
/// | moot_erase_memory      | confirmation absent or false                    |
/// | moot_migration_confirm | disqualified branch result                      |
/// | moot_link_memories     | unresolved IDs                                  |
/// | any lens               | zero results                                    |
///
/// Hints never attach to error results (isError:true). First match wins.
///
/// ## Implementation note on confirmation/erase
///
/// The v2 decoder rejects `moot_erase_memory` when `confirmation` is absent
/// or false (returns invalidParams before reaching the coaching path). In
/// practice the confirmation trigger cannot fire on v2 as long as the decoder
/// enforces strict validation. The check is present for spec completeness and
/// will activate if the decoder is ever relaxed.
///
/// Parity: Swift twin of Rust `v2/coach.rs`.
import AriaMCPWire

/// `internal` because `AriaSurfaceRequest` is internal to AriaMCP — this enum
/// is an intra-module helper called only from `ToolDispatch.swift`.
enum AriaV2Coach {

    // MARK: - Entry point

    /// Return a coaching hint for the given v2 tool call and result, or `nil`
    /// when no trigger fires.
    ///
    /// Called at the v2 dispatcher choke point AFTER `recordCall` and the
    /// operation result is available. The first matching trigger wins.
    static func coachingHint(
        request: AriaSurfaceRequest,
        result: JSONValue
    ) -> String? {
        // Hints never attach to error results. isError:true signals a refusal.
        if case .object(let env) = result, case .bool(true) = env["isError"] {
            return nil
        }

        switch request {
        case .memorySearch(let req):
            return hintForMemorySearch(req: req, result: result)
        case .fileMemory(let req):
            return hintForFileMemory(content: req.content, result: result)
        case .eraseMemory(let req):
            return hintForErase(confirmation: req.confirmation)
        case .migrationConfirm:
            return hintForMigrationConfirm(result: result)
        case .linkMemories:
            return hintForLinkMemories(result: result)
        // Any lens (moot_recall_precise, moot_recall_temporal, moot_recall_connected,
        // moot_recall_shaped) routes through recallLens.
        case .recallLens:
            return hintForLensZeroResults(result: result)
        default:
            return nil
        }
    }

    // MARK: - Trigger implementations

    /// moot_memory_search: query over 200 characters, or zero results.
    ///
    /// The "no query" case from §12.5 cannot fire on v2 because the decoder
    /// requires exactly one of `query` or `near`; absence is an invalidParams error
    /// that never reaches the coaching path. The long-query trigger is the
    /// active pre-flight check for moot_memory_search on v2.
    private static func hintForMemorySearch(
        req: AriaV2MemorySearchRequest,
        result: JSONValue
    ) -> String? {
        // Trigger: query over 200 Unicode scalars.
        if let q = req.query, q.unicodeScalars.count > 200 {
            return "Queries over 200 characters reduce recall precision. " +
                   "Try a shorter, focused term — the estate ranks by relevance, " +
                   "so fewer, sharper words usually beat a long description."
        }
        // Trigger: zero results.
        if resultHasEmptyResults(result) {
            return "No memories matched. File content with moot_file_memory first, " +
                   "then search with a focused term."
        }
        return nil
    }

    /// moot_file_memory: content over 4,000 characters or duplicate result.
    private static func hintForFileMemory(content: String, result: JSONValue) -> String? {
        // Trigger: content over 4,000 Unicode scalars (pre-flight on decoded request).
        if content.unicodeScalars.count > 4_000 {
            return "Content over 4,000 characters is harder to recall precisely. " +
                   "Consider splitting into smaller, focused memories so each one " +
                   "surfaces on the right query."
        }
        // Trigger: duplicate result (post-flight on the operation result).
        if resultTextContains(result, "duplicate") || resultTextContains(result, "already filed") {
            return "This content may duplicate an existing memory. " +
                   "Use moot_memory_search to find and review existing entries " +
                   "before filing again."
        }
        return nil
    }

    /// moot_erase_memory: confirmation absent or false.
    ///
    /// In v2 the decoder rejects confirmation:false with invalidParams, so this
    /// trigger cannot fire in practice. The check is present for spec completeness.
    private static func hintForErase(confirmation: Bool) -> String? {
        guard !confirmation else { return nil }
        return "Erase requires confirmation:true. " +
               "Set confirmation to the boolean true to confirm permanent deletion."
    }

    /// moot_migration_confirm: disqualified branch result.
    private static func hintForMigrationConfirm(result: JSONValue) -> String? {
        // A disqualified branch result has a non-empty "disqualified" array in
        // the structuredContent data.
        var hasDisqualified = false
        if case .object(let env) = result,
           case .object(let sc) = env["structuredContent"],
           case .object(let data) = sc["data"],
           case .array(let arr) = data["disqualified"],
           !arr.isEmpty {
            hasDisqualified = true
        }
        let textDisqualified = resultTextContains(result, "disqualified")
        guard hasDisqualified || textDisqualified else { return nil }
        return "One or more migration branches were disqualified. " +
               "Review the estate state with moot_estate_status before retrying " +
               "the migration confirmation."
    }

    /// moot_link_memories: unresolved IDs.
    private static func hintForLinkMemories(result: JSONValue) -> String? {
        guard resultTextContains(result, "unresolved") || resultTextContains(result, "not found")
        else { return nil }
        return "One or more memory IDs could not be resolved. " +
               "Use moot_memory_search to verify the IDs before linking."
    }

    /// Any lens (moot_recall_*): zero results.
    private static func hintForLensZeroResults(result: JSONValue) -> String? {
        guard resultHasEmptyResults(result) else { return nil }
        return "This lens returned zero results. " +
               "Try adjusting your query, or check moot_list_lenses for " +
               "available lens options and their required arguments."
    }

    // MARK: - Result inspection helpers

    /// Returns true when the result's structuredContent data contains an empty
    /// "results" array. Used for moot_memory_search and any-lens triggers.
    private static func resultHasEmptyResults(_ result: JSONValue) -> Bool {
        guard case .object(let env) = result,
              case .object(let sc) = env["structuredContent"],
              case .object(let data) = sc["data"],
              case .array(let arr) = data["results"]
        else { return false }
        return arr.isEmpty
    }

    /// Returns true when `content[0].text` contains the given substring.
    private static func resultTextContains(_ result: JSONValue, _ substring: String) -> Bool {
        guard case .object(let env) = result,
              case .array(let content) = env["content"],
              let first = content.first,
              case .object(let item) = first,
              case .string(let text) = item["text"]
        else { return false }
        return text.contains(substring)
    }
}
