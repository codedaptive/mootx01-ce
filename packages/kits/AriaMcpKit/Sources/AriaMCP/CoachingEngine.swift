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
        switch name {
        case "moot_memory_search":
            return memorySearchHint(args: args, resultText: resultText)
        case "moot_file_memory":
            return fileMemoryHint(args: args, resultText: resultText)
        case "moot_erase_memory":
            return eraseMemoryHint(args: args)
        case "moot_confirm_migration":
            return confirmMigrationHint(resultText: resultText)
        case "moot_link_memories":
            return linkMemoriesHint(resultText: resultText)
        case "moot_lens_keystones", "moot_lens_constellation":
            // These lenses operate on the tunnel graph (drawer-to-drawer edges),
            // not on memory count. "0 result" here means no tunnel edges exist
            // — not 0 memories. The generic lensHint message is wrong for this
            // case, so we provide a tunnel-specific message instead.
            return tunnelGraphLensHint(name: name, resultText: resultText)
        default:
            // Any other lens tool with a thin result.
            if LensTools.isLensTool(name) {
                return lensHint(resultText: resultText)
            }
            return nil
        }
    }

    // MARK: - Per-tool hint logic

    /// Coaching hints for `moot_memory_search`.
    ///
    /// Three triggers: query too long, no query provided, zero results returned.
    private static func memorySearchHint(
        args: [String: JSONValue],
        resultText: String
    ) -> String? {
        // No query argument — caller may not understand semantic retrieval.
        guard let query = args["query"]?.stringValue else {
            return "Use `query` for semantic retrieval. To browse estate structure, use `moot_estate_map` instead."
        }
        // Query too long — long queries dilute the semantic embedding signal.
        if query.count > 200 {
            return "Queries work best as keywords or a short question under 50 words. Long queries dilute the semantic signal."
        }
        // Zero results — help caller broaden or verify the location exists.
        if resultText.contains("0 memory") {
            return "No results. Try broader terms, or check `moot_estate_map` to confirm the location exists."
        }
        return nil
    }

    /// Coaching hints for `moot_file_memory`.
    ///
    /// Two triggers: content over 4000 chars, result says content already exists.
    private static func fileMemoryHint(
        args: [String: JSONValue],
        resultText: String
    ) -> String? {
        if let content = args["content"]?.stringValue, content.count > 4000 {
            return "Consider splitting into smaller memories — content under 500 words recalls more precisely."
        }
        if resultText.contains("already exists") {
            return "This content is already filed. Use `moot_update_memory` with the existing id to revise it."
        }
        return nil
    }

    /// Coaching hint for `moot_erase_memory`.
    ///
    /// Fires when `confirmed` is absent or false — reminds the caller that erase is
    /// irreversible and `moot_withdraw_memory` is the recoverable alternative.
    private static func eraseMemoryHint(args: [String: JSONValue]) -> String? {
        let confirmed = args["confirmed"]?.boolValue ?? false
        if !confirmed {
            return "Erase is irreversible. Pass `confirmed: true` to proceed, or use `moot_withdraw_memory` for recoverable removal."
        }
        return nil
    }

    /// Coaching hint for `moot_confirm_migration`.
    ///
    /// Fires when the result indicates a branch was disqualified.
    private static func confirmMigrationHint(resultText: String) -> String? {
        if resultText.contains("disqualified") {
            return "This branch was disqualified by `moot_run_migration`. Promote only branches from the rankings list."
        }
        return nil
    }

    /// Coaching hint for `moot_link_memories`.
    ///
    /// Fires when the result text contains "isError" — one or both IDs were
    /// not found and the result carries an error payload.
    private static func linkMemoriesHint(resultText: String) -> String? {
        if resultText.contains("isError") {
            return "One or both memory IDs not found. Use `moot_memory_search` to locate the correct IDs first."
        }
        return nil
    }

    /// Coaching hint for any lens tool when the result is thin.
    ///
    /// Fires when the result text contains "0 result" — the lens matched no
    /// memories and broader scope may help.
    private static func lensHint(resultText: String) -> String? {
        if resultText.contains("0 result") {
            return "Only 0 memories matched this scope — lens results may be thin. Try `scope: active` for a fuller picture."
        }
        return nil
    }

    /// Coaching hint for tunnel-graph lenses (keystones, constellation).
    ///
    /// These lenses operate on the drawer-to-drawer tunnel graph, NOT on
    /// memory count. "0 result" means no tunnel edges exist in this wing —
    /// the wing may have memories but lacks connections between them.
    ///
    /// The generic lensHint message is wrong here because:
    ///   1. It claims "Only 0 memories" — the wing may have many memories.
    ///   2. It suggests `scope: active` — scope does not affect tunnel topology.
    private static func tunnelGraphLensHint(name: String, resultText: String) -> String? {
        if resultText.contains("0 result") {
            return "No tunnel connections found in this wing. \(name.contains("keystones") ? "Keystones" : "Constellation") requires linked memories — use `moot_link_memories` to connect memories and then re-run this lens."
        }
        return nil
    }
}
