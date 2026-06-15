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
      — Call moot_estate_status with teachme:true for a full orientation guide.
      — Call moot_list_lenses to see available cognition tools.
      — Add teachme:true to any tool to learn it before using it.
      — Watch for hint: lines in responses — they contain coaching for better results.
      — File memories: moot_file_memory (content + location required).
      — Search memories: moot_memory_search (query required).
      — Write journal entries: moot_write_journal after meaningful sessions.
      — Store structured facts: moot_file_fact (subject + predicate + object).
    """
}
