/// Inspects a completed tool call and returns a coaching hint when a
/// suboptimal call pattern is detected.
///
/// `hint(name:args:resultText:)` is called in `ToolDispatcher.dispatch`
/// after the runner returns, before the result is sent back to the client.
/// When a trigger condition is satisfied, the returned string is appended to
/// the result text as `\nhint: <message>`. Nil means no hint is warranted.
///
/// Hint injection applies only to successful (isError == false) results;
/// error results are never annotated by the caller in `dispatch`.
///
/// Eleven trigger conditions mirror Rust `coaching_engine.rs` exactly.
/// The first matching trigger wins; the rest are skipped.
enum CoachingEngine {

    /// Return a coaching hint for the completed call, or nil if none applies.
    ///
    /// - Parameters:
    ///   - name: The tool name that was dispatched.
    ///   - args: The raw argument map received by dispatch.
    ///   - resultText: The text content of the runner's successful result.
    static func hint(
        name: String,
        args: [String: JSONValue],
        resultText: String
    ) -> String? {
        // Trigger 1: long query — moot_memory_search with query > 200 chars
        if name == "moot_memory_search" {
            if let query = args["query"]?.stringValue, query.count > 200 {
                return "queries over 200 characters may reduce recall precision; try a shorter, more specific phrase"
            }
        }

        // Trigger 2: no results — moot_memory_search returned 0 hits
        if name == "moot_memory_search", resultText.contains("found 0 memory") {
            return "no memories matched — try moot_estate_status to check estate contents, or broaden the query"
        }

        // Trigger 3: filed memory — suggest confirming it
        if name == "moot_file_memory", resultText.contains("filed memory") {
            return "memory filed — call moot_confirm_memory with this ID to mark it as user-verified"
        }

        // Trigger 4: empty estate — moot_estate_status shows drawers: 0
        if name == "moot_estate_status", resultText.contains("drawers: 0") {
            return "estate is empty — start with moot_file_memory to store your first memory"
        }

        // Trigger 5: empty journal — moot_read_journal returned 0 entries
        if name == "moot_read_journal", resultText.contains("0 entry(s)") {
            return "no journal entries found — use moot_write_journal to record session notes"
        }

        // Trigger 6: no outgoing connections — moot_connection_search returned 0
        if name == "moot_connection_search", resultText.contains(": 0") {
            return "no outgoing connections found — use moot_link_memories to create typed relationships between memories"
        }

        // Trigger 7: empty fact store — moot_fact_search with no query returned 0
        if name == "moot_fact_search",
           resultText.hasPrefix("facts: 0"),
           args["query"] == nil {
            return "no facts in this estate — use moot_file_fact to store subject-predicate-object knowledge"
        }

        // Trigger 8: many facts — moot_fact_timeline with >= 20 entries
        if name == "moot_fact_timeline",
           let count = parseTimelineCount(resultText),
           count >= 20 {
            return "large fact timeline — consider using moot_retire_fact to remove outdated facts and keep the knowledge graph current"
        }

        // Trigger 9: connection map empty — moot_connection_map returned 0
        if name == "moot_connection_map", resultText.contains(": 0") {
            return "no incoming connections found — use moot_link_memories to build the association graph"
        }

        // Trigger 10: tunnel-graph lens 0 results — keystones/constellation
        // operate on drawer-to-drawer edges; "0 result" means no tunnel edges
        // exist, not 0 memories.
        if (name == "moot_lens_keystones" || name == "moot_lens_constellation"),
           resultText.contains("0 result") {
            return "no tunnel connections found in this wing — these lenses require linked memories; use moot_link_memories to connect memories and then re-run this lens"
        }

        // Trigger 11: generic lens tool 0 results — any other moot_lens_* tool.
        if name.hasPrefix("moot_lens_"), resultText.contains("0 result") {
            return "lens results are thin — try scope: active for a broader search"
        }

        return nil
    }

    // MARK: - Helpers

    /// Parse the fact count from a fact-timeline result header.
    /// Matches "fact timeline: N" or "fact timeline for ...: N".
    private static func parseTimelineCount(_ text: String) -> Int? {
        guard let firstLine = text.split(separator: "\n").first else { return nil }
        guard let colonIndex = firstLine.lastIndex(of: ":") else { return nil }
        let afterColon = firstLine[firstLine.index(after: colonIndex)...]
            .trimmingCharacters(in: .whitespaces)
        return Int(afterColon)
    }
}
