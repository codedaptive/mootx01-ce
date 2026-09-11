// SessionProtocol.swift
//
// Static protocol block appended unconditionally to every
// `moot_estate_status` response. Extracted to its own file so the
// dispatch machinery in ToolDispatch.swift stays focused on routing.
//
// The block is intentionally static: it does not vary by estate and
// its content must be identical across consecutive calls (see test
// `protocolBlockIsStatic`). Update it only when the surface changes.

extension ToolDispatcher {

    /// Static protocol block appended to every `moot_estate_status`
    /// response. Teaches a cold AI client the full ARIA surface protocol
    /// in a single call, without requiring prior knowledge of the surface.
    ///
    /// Content is hardcoded because the protocol is static: it describes
    /// the surface itself, not the estate's contents, so it never varies
    /// by call or by estate state.
    static let ARIASessionProtocol: String = """

    protocol:
      — Call moot_estate_status with teachme:true to receive the orientation guide (no status payload is returned).
      — Call moot_list_lenses to see available cognition tools.
      — Add teachme:true to any tool to learn it before using it.
      — Watch for hint: lines in responses — they contain coaching for better results.
      — Declare a mode with mode:"Recall=Auto" on any call to set the session default; full global-modifiers grammar in moot_help directory.
      — File memories: moot_file_memory (content + subject + location required).
      — Search memories: moot_memory_search (query required).
      — Write journal entries: moot_write_journal after meaningful sessions.
      — Store structured facts: moot_file_fact (subject + predicate + object).
    """

    /// Modes section appended to every `moot_estate_status` response.
    ///
    /// Lists the five advisory mode bundles and their contracts. Static because
    /// the mode roster is built into the server; it does not vary by estate.
    /// Add teachme:true to `moot_estate_status` for the full modes guide.
    static let modesStatusSection: String = {
        let lines = MootMode.allCases.map { "  " + $0.statusLine }
        return """

    modes (advisory bundles — add mode:\"Recall=Auto\" etc. to any call):
    \(lines.joined(separator: "\n"))
      — Modes change session defaults (e.g. Recall=Auto sets answer:auto on search).
      — Add teachme:true to moot_estate_status for variants and decision guidance.
    """
    }()
}
