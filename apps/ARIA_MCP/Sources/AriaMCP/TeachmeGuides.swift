/// Per-tool usage guides returned when a caller passes `teachme: true`.
///
/// Content is static and hardcoded here; no estate is touched when a guide
/// is returned. The dispatch layer intercepts `teachme: true` before any
/// runner fires, looks up the guide via `guide(for:)`, and wraps it in a
/// `textResult`. Unknown tool names receive a fallback guide directing the
/// caller to `moot_estate_status`.
///
/// Guide anatomy (per Tier 1–5 tools): one-line summary, what it does,
/// when to use it vs siblings, annotated example call, response shape,
/// and two or three common mistakes.
///
/// Generic guides apply to lens, recipe, and vault tools. Migration tools
/// (`moot_run_migration`, `moot_confirm_migration`) receive a specific
/// two-tool workflow note.
enum TeachmeGuides {

    /// Return the usage guide for `toolName`. Never fails — returns a
    /// fallback for unknown names.
    static func guide(for toolName: String) -> String {
        if let specific = specificGuide(for: toolName) {
            return specific
        }
        // Generic guides for non-tier-1-5 surfaces.
        if LensTools.isLensTool(toolName) {
            return lensGuide(toolName)
        }
        if toolName == RecipeTools.runMigrationBenchmarkToolName
            || toolName == RecipeTools.confirmMigrationPromotionToolName
        {
            return migrationGuide(toolName)
        }
        if RecipeTools.isRecipeTool(toolName) {
            return recipeGuide(toolName)
        }
        if VaultTools.isVaultTool(toolName) {
            return vaultGuide(toolName)
        }
        return unknownGuide(toolName)
    }

    // MARK: - Tier 1: Core Memory

    private static let fileMemoryGuide = """
        moot_file_memory — Store a memory in the estate.

        Use this to file any content worth keeping. The server assigns
        classification and embedding; you supply content and location.

        When to use vs siblings:
          - moot_update_memory — when the memory already exists and needs revision
          - moot_write_journal — when filing a timestamped agent diary entry
          - moot_file_fact — when the content is a subject–predicate–object assertion

        Example:
          { "content": "Decided to use actor isolation for all estate writes.",
            "location": "mootx01/architecture",
            "kind": "prose" }

        Response:
          filed memory <uuid>
          room: mootx01/architecture
          lineage: <lineage-uuid>

        Common mistakes:
          - Sending content over 4000 chars as one memory. Prefer smaller
            focused memories — they recall more precisely.
          - Using moot_file_memory to update existing content. Use
            moot_update_memory with the existing id instead.
          - Omitting location. The estate has no structure without it.
        """

    private static let memorySearchGuide = """
        moot_memory_search — Search the estate for memories matching a query.

        Uses hybrid BM25+vector recall. Returns ranked memory rows with
        content previews. This is the primary way to retrieve filed memories.

        When to use vs siblings:
          - moot_estate_map — when browsing structure rather than searching content
          - moot_fact_search — when looking for structured KG assertions
          - moot_read_journal — when retrieving agent diary entries

        Example:
          { "query": "actor isolation concurrency decisions",
            "limit": 10 }

        Response:
          found N memory(s)
          <uuid>  [room]  <content preview…>

        Common mistakes:
          - Using a query over 200 chars. Queries work best as keywords or a
            short question under 50 words. Long queries dilute the semantic signal.
          - Calling without a query arg. Use moot_estate_map to browse structure.
          - Omitting limit when expecting many results; default is 20.
        """

    private static let updateMemoryGuide = """
        moot_update_memory — Apply a named mutation to an existing memory.

        Mutations: confirm, reject, contest, resolve, supersede, revive, accept.
        Use to change a memory's trust state without rewriting its content.

        When to use vs siblings:
          - moot_file_memory — when filing new content (no existing id)
          - moot_confirm_memory — shortcut for mutation=confirm, no note needed
          - moot_withdraw_memory — for soft removal from active circulation

        Example:
          { "id": "abc-123", "mutation": "confirm",
            "note": "Verified against implementation on 2026-06-05." }

        Response:
          updated memory abc-123 (confirm)

        Common mistakes:
          - Using supersede to soft-delete. Use moot_withdraw_memory instead.
          - Calling with an id that does not exist. Verify with moot_memory_search first.
          - Omitting note for contest or resolve mutations; a note is good practice.
        """

    private static let withdrawMemoryGuide = """
        moot_withdraw_memory — Soft-remove a memory from active circulation.

        Withdrawal is reversible. The memory is tombstoned and excluded from
        search results but can be recovered. Use when content is stale but
        might be needed again.

        When to use vs siblings:
          - moot_erase_memory — for permanent deletion (irreversible)
          - moot_update_memory with mutation=reject — when contesting correctness

        Example:
          { "id": "abc-123", "reason": "Superseded by updated architecture decision." }

        Response:
          withdrew memory abc-123

        Common mistakes:
          - Using moot_erase_memory when moot_withdraw_memory is sufficient.
            Erase is permanent; withdrawal is recoverable.
          - Withdrawing without a reason. The reason aids future agents interpreting
            the estate's history.
        """

    private static let eraseMemoryGuide = """
        moot_erase_memory — Hard-erase a memory permanently. Irreversible.

        Erase permanently removes the memory. It cannot be recovered. Requires
        both a reason and confirmed=true as an explicit safety gate.

        When to use vs siblings:
          - moot_withdraw_memory — when removal should be recoverable
          - moot_update_memory with mutation=reject — when marking as incorrect

        Example:
          { "id": "abc-123",
            "reason": "Contains PII that must not be retained.",
            "confirmed": true }

        Response:
          erased memory abc-123

        Common mistakes:
          - Calling without confirmed=true. The call will fail.
          - Using erase when withdraw would suffice. Erase is intended for
            compliance-grade deletion.
          - Erasing with a vague reason. The reason is the audit record.
        """

    private static let confirmMemoryGuide = """
        moot_confirm_memory — Mark a memory as user-confirmed.

        Shortcut for moot_update_memory with mutation=confirm. Use when a
        memory has been reviewed and verified correct.

        When to use vs siblings:
          - moot_update_memory — when applying any other mutation kind
          - moot_file_memory — when filing a new memory

        Example:
          { "id": "abc-123", "note": "Checked against source doc on 2026-06-05." }

        Response:
          confirmed memory abc-123

        Common mistakes:
          - Confirming without reading the content. Confirmation is a trust signal.
          - Calling on an already-confirmed memory. Check with moot_memory_search
            first if unsure.
        """

    private static let moveMemoryGuide = """
        moot_move_memory — Move a memory to a different location.

        Reanchors the memory's room to a new location hint. Use when a memory
        was filed in the wrong place or when the estate's structure has been
        reorganised.

        When to use vs siblings:
          - moot_file_memory — when filing new content
          - moot_update_memory — when changing trust state, not location

        Example:
          { "id": "abc-123", "location": "mootx01/engineering" }

        Response:
          moved memory abc-123 to mootx01/engineering

        Common mistakes:
          - Moving to an extremely general location like "misc". Prefer specific
            subject-matter paths.
          - Moving without checking where the memory should go; use moot_estate_map
            to survey the estate structure first.
        """

    // MARK: - Tier 2: Connections

    private static let linkMemoriesGuide = """
        moot_link_memories — Create a directed connection between two memories.

        Creates a typed tunnel from the source memory to the target. Connections
        build the estate's knowledge graph structure.

        Relationship kinds: relates, precedes, contradicts, supports, refines,
        exemplifies, extends.

        When to use vs siblings:
          - moot_file_fact — for structured subject–predicate–object assertions
          - moot_connection_search — to see what a memory already points to

        Example:
          { "from_id": "abc-123", "to_id": "def-456",
            "kind": "supports", "label": "Evidence for the decision" }

        Response:
          linked abc-123 → def-456 via supports (<tunnel-uuid>)

        Common mistakes:
          - Using the wrong kind. "contradicts" is structural; "relates" is generic.
          - Linking to ids that do not exist. Verify both ids with moot_memory_search.
          - Creating duplicate connections; use moot_connection_search first.
        """

    private static let connectionSearchGuide = """
        moot_connection_search — Find all connections going out from a memory.

        Returns non-tombstoned tunnels where this memory is the source —
        what this memory points to.

        When to use vs siblings:
          - moot_connection_map — for incoming connections (what points here)
          - moot_link_memories — to create a new connection

        Example:
          { "from_id": "abc-123" }

        Response:
          connections from abc-123: N
          <tunnel-uuid>  → <target-id>  [label]

        Common mistakes:
          - Confusing search (outgoing) with map (incoming).
          - Expecting content previews; this returns tunnel metadata, not memory content.
        """

    private static let connectionMapGuide = """
        moot_connection_map — Find all connections pointing to a memory.

        Returns non-tombstoned tunnels where this memory is the target —
        what points at this memory.

        When to use vs siblings:
          - moot_connection_search — for outgoing connections (what this points to)
          - moot_memory_search — to find memories by content

        Example:
          { "to_id": "abc-123" }

        Response:
          connections to abc-123: N
          <tunnel-uuid>  <source-id> →  [label]

        Common mistakes:
          - Confusing map (incoming) with search (outgoing).
          - Calling on an id with no connections; no results is a valid outcome.
        """

    // MARK: - Tier 3: Knowledge Graph

    private static let fileFactGuide = """
        moot_file_fact — Assert a structured knowledge-graph fact.

        Files a subject–predicate–object triple into the estate's KG. Facts
        are structured assertions distinct from memory drawers.

        When to use vs siblings:
          - moot_file_memory — for free-form content
          - moot_fact_search — to retrieve existing facts
          - moot_link_memories — for structural connections between memory rows

        Example:
          { "subject": "MCP-INT-02", "predicate": "implements",
            "object": "teachme protocol", "source_id": "abc-123" }

        Response:
          filed fact <uuid>: [MCP-INT-02] implements [teachme protocol]

        Common mistakes:
          - Filing the same triple twice; use moot_fact_search to check first.
          - Using file_fact for content storage. Facts are for structured triples;
            use moot_file_memory for prose.
          - Omitting source_id when there is a supporting memory.
        """

    private static let factSearchGuide = """
        moot_fact_search — Search knowledge-graph facts.

        Pass a query string to filter by substring match across subject,
        predicate, and object. Omit query to return all active facts.

        When to use vs siblings:
          - moot_fact_timeline — to see retired facts and full history
          - moot_memory_search — to search free-form memory content
          - moot_estate_status — for a high-level estate summary

        Example (filtered):
          { "query": "Alice" }    — returns facts where Alice appears
          { "query": "knows" }   — returns facts with predicate "knows"

        Example (all facts):
          {}   (or omit entirely for default estate)

        Response:
          facts matching "Alice": N
          <uuid>  [Alice] knows [Bob]

        Common mistakes:
          - Expecting fuzzy semantic matching; this is substring only.
            Use moot_memory_search for semantic retrieval.
          - Passing a complex sentence as query; use a single keyword
            like a name or relationship type for best results.
        """

    private static let retireFactGuide = """
        moot_retire_fact — Retire (invalidate) a KG fact.

        Marks the fact as retired; it no longer appears in moot_fact_search
        results but remains in the timeline for audit purposes.

        When to use vs siblings:
          - moot_fact_search — to find the id to retire
          - moot_fact_timeline — to review retired facts

        Example:
          { "id": "fact-uuid-123" }

        Response:
          retired fact fact-uuid-123

        Common mistakes:
          - Retiring without knowing the fact id; use moot_fact_search first.
          - Retiring a memory row id; this tool targets KG fact rows only.
        """

    private static let factTimelineGuide = """
        moot_fact_timeline — Read KG facts in chronological order.

        Returns facts with their filed timestamps. Use to trace how the
        estate's structured knowledge evolved over time.

        When to use vs siblings:
          - moot_fact_search — for active facts only (no timestamps in header)
          - moot_file_fact — to add a new fact

        Example:
          { }   (no arguments required beyond optional estateID)

        Response:
          fact timeline: N active
          <iso8601>  <uuid>  [subject] predicate [object]

        Common mistakes:
          - Expecting retired facts to be excluded; timeline includes all states.
          - Using when only active facts are needed; prefer moot_fact_search.
        """

    // MARK: - Tier 4: Journal

    private static let writeJournalGuide = """
        moot_write_journal — Write a diary entry to the agent journal.

        Use for session continuity — record decisions, observations, and
        reasoning steps. Entries are retrievable by agent name.

        When to use vs siblings:
          - moot_file_memory — for content that belongs in the estate's memory
            store rather than the agent diary
          - moot_read_journal — to retrieve prior entries

        Example:
          { "entry": "Decided to implement teachme as a pre-check in dispatch
            before any runner fires. Cleaner than per-tool interception.",
            "agent": "mcp-agent" }

        Response:
          wrote journal entry for mcp-agent

        Common mistakes:
          - Filing session context into moot_file_memory; use the journal for
            agent continuity and the memory store for estate knowledge.
          - Omitting agent; the default is "mcp-agent" and may not match your
            identity across sessions.
        """

    private static let readJournalGuide = """
        moot_read_journal — Read recent journal entries for an agent.

        Retrieves the most recent N diary entries for the named agent.
        Use at session start to restore context from prior turns.

        When to use vs siblings:
          - moot_write_journal — to add a new entry
          - moot_memory_search — to search the broader memory store

        Example:
          { "agent": "mcp-agent", "last_n": 5 }

        Response:
          journal for mcp-agent: N entry(s)
          [<iso8601>]  <entry preview…>

        Common mistakes:
          - Not calling at session start. Reading prior journal entries
            restores context that would otherwise be missing.
          - Using the wrong agent name; entries are keyed by exact name.
        """

    // MARK: - Tier 5: Estate

    private static let estateStatusGuide = """
        moot_estate_status — Estate overview and session orientation.

        Cold-start sequence for a new session:
          1. moot_estate_status          — this call; get counts + protocol
          2. moot_list_lenses            — see all cognition tools
          3. moot_memory_search          — start retrieving
          4. moot_file_memory            — start storing

        Tier 1 — Core Memory (7 tools):
          moot_file_memory, moot_memory_search, moot_update_memory,
          moot_withdraw_memory, moot_erase_memory, moot_confirm_memory,
          moot_move_memory

        Tier 2 — Connections (3 tools):
          moot_link_memories, moot_connection_search, moot_connection_map

        Tier 3 — Knowledge Graph (4 tools):
          moot_file_fact, moot_fact_search, moot_retire_fact, moot_fact_timeline

        Tier 4 — Journal (2 tools):
          moot_write_journal, moot_read_journal

        Tier 5 — Estate (3 tools):
          moot_estate_status, moot_estate_map, moot_estate_ping

        Tier 6 — Cognition (18 tools):
          moot_synthesize, moot_list_lenses, and 16 moot_lens_* tools.
          Call moot_list_lenses for the full menu.

        Tier 7 — Migration (2 tools):
          moot_run_migration, moot_confirm_migration

        Tier 8 — Vault (4 tools):
          moot_vault_export, moot_vault_import, moot_vault_status,
          moot_vault_reconcile

        Tier 9 — Federation (1 tool):
          moot_federated_search

        Teaching mechanism:
          Add teachme:true to any tool call to receive a usage guide instead
          of executing. No estate touch occurs.

        Coaching mechanism:
          Watch for hint: lines appended to successful responses. These appear
          when the server detects a suboptimal call pattern.

        Total: 44 tools. All accept teachme. All may return hint.
        """

    private static let estateMapGuide = """
        moot_estate_map — Return the estate's structural map.

        Lists all wings and rooms with memory counts per location. Use to
        understand the estate's organisation before filing or searching.

        When to use vs siblings:
          - moot_estate_status — for a high-level summary without wing detail
          - moot_memory_search — to search content within a known location

        Example:
          { }   (no arguments required)

        Response:
          estate map: <name>
            wing/
              room: N
              room: N

        Common mistakes:
          - Using map when status is sufficient. Map shows structure; status
            shows counts.
          - Not using map before filing; knowing the estate's structure helps
            choose the right location.
        """

    private static let estatePingGuide = """
        moot_estate_ping — Ping the estate to confirm the server is live.

        ARIA_MCP is a long-running stdio process. The estate handle is either
        open (registered at startup) or not. There is no transient disconnection
        state — if the server process is running, the estate is available.
        This tool resolves the handle only; no drawer scan is performed.

        When to use vs siblings:
          - moot_estate_status — for estate statistics (memory count, wings,
            KG facts). Heavier; use when you need the data, not just liveness.
          - moot_estate_map — for structural map of wings and rooms.

        Example:
          { }   (no arguments required)

        Response:
          pong: estate <name> [<uuid>] is live

        Common mistakes:
          - Calling this expecting it to fix a broken connection. If the
            estate is not open, the server process needs restarting —
            no MCP tool can do that.
          - Using this as a health check before every call. Call it only
            when you genuinely need to confirm liveness.
        """

    // MARK: - Federation

    private static let federatedSearchGuide = """
        moot_federated_search — Grant-authorized cross-estate federated search.

        Fans across locally-open estates the requester is entitled to read.
        Each estate's contribution is narrowed to its grant's scope.

        When to use vs siblings:
          - moot_memory_search — to search within a single estate
          - moot_estate_status — to inspect a single estate's health

        Example:
          { "requesterEstateID": "<uuid-of-your-estate>",
            "filter": "userConfirmed", "limit": 20 }

        Response:
          estate <name> [<uuid>] — grant <uuid>, N row(s)
          <uuid>  [room]  <content preview…>

        Common mistakes:
          - Omitting requesterEstateID; it is required for grant evaluation.
          - Expecting results from estates with no active grant naming you.
            The call is refused cleanly if no grant authorizes access.
        """

    // MARK: - Specific guide lookup

    private static func specificGuide(for name: String) -> String? {
        switch name {
        // Tier 1
        case "moot_file_memory":     return fileMemoryGuide
        case "moot_memory_search":   return memorySearchGuide
        case "moot_update_memory":   return updateMemoryGuide
        case "moot_withdraw_memory": return withdrawMemoryGuide
        case "moot_erase_memory":    return eraseMemoryGuide
        case "moot_confirm_memory":  return confirmMemoryGuide
        case "moot_move_memory":     return moveMemoryGuide
        // Tier 2
        case "moot_link_memories":     return linkMemoriesGuide
        case "moot_connection_search": return connectionSearchGuide
        case "moot_connection_map":    return connectionMapGuide
        // Tier 3
        case "moot_file_fact":     return fileFactGuide
        case "moot_fact_search":   return factSearchGuide
        case "moot_retire_fact":   return retireFactGuide
        case "moot_fact_timeline": return factTimelineGuide
        // Tier 4
        case "moot_write_journal": return writeJournalGuide
        case "moot_read_journal":  return readJournalGuide
        // Tier 5
        case "moot_estate_status":    return estateStatusGuide
        case "moot_estate_map":       return estateMapGuide
        case "moot_estate_ping":      return estatePingGuide
        // Federation
        case "moot_federated_search": return federatedSearchGuide
        default: return nil
        }
    }

    // MARK: - Generic guides

    private static func lensGuide(_ name: String) -> String {
        """
        \(name) — Reasoning lens tool.

        Call moot_list_lenses for a full list of cognition tools and their descriptions.
        Each lens applies a different analytical frame to the estate's memories.

        Example:
          { "wing": "mootx01" }   (arguments vary by lens — see moot_list_lenses)

        Common mistakes:
          - Not calling moot_list_lenses first to understand which lens fits.
          - Expecting moot_memory_search results; lens tools apply analysis,
            not keyword retrieval.
        """
    }

    private static func migrationGuide(_ name: String) -> String {
        """
        \(name) — Migration tool.

        This is a migration tool. Call moot_run_migration first, then
        moot_confirm_migration to promote the winner.

        Workflow:
          1. moot_run_migration — benchmark candidate approaches
          2. moot_confirm_migration — promote the winning branch

        Common mistakes:
          - Calling moot_confirm_migration without moot_run_migration.
            Only branches from the rankings list can be promoted.
          - Running migration on a production estate without testing first.
        """
    }

    private static func recipeGuide(_ name: String) -> String {
        """
        \(name) — CognitionKit recipe tool.

        Call moot_list_lenses for a full list of cognition tools and their descriptions.

        Common mistakes:
          - Calling a recipe tool without understanding its output shape.
            Use teachme:true on moot_list_lenses for orientation.
        """
    }

    private static func vaultGuide(_ name: String) -> String {
        """
        \(name) — Vault control tool.

        Vault tools manage estate export, import, and reconciliation.

        Workflow:
          - moot_vault_export — export the estate to an archive
          - moot_vault_import — import a previously exported archive
          - moot_vault_status — check the vault archive state
          - moot_vault_reconcile — detect drift between live estate and archive

        Common mistakes:
          - Importing without verifying vault status first.
          - Running reconcile without a prior export; there is nothing to compare.
        """
    }

    private static func unknownGuide(_ name: String) -> String {
        "Unknown tool '\(name)'. Call moot_estate_status with teachme:true for a full orientation guide."
    }
}
