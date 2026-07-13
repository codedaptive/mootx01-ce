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
          - moot_memory_get — when you already have a specific id and need
            the full verbatim content and metadata, not a ranked preview

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

    private static let memoryGetGuide = """
        moot_memory_get — Fetch one memory drawer by id, in full.

        Returns verbatim content (never truncated), room/wing, filed_at and
        event_time, the adjective-axis metadata (state, trust, sensitivity,
        exportability, confirmation), lineage, and a linked-tunnel summary.
        Applies the same default gate as moot_memory_search — a drawer that
        exists but is contested/withdrawn/rejected, untrustworthy, or
        restricted/secret is reported not-found, identical to a genuinely
        absent id. This tool cannot be used to bypass that gate.

        When to use vs siblings:
          - moot_memory_search — when you don't yet have an id, or want a
            ranked set of candidates
          - moot_recollect — when fanning out from a distilled factoid to
            its source memories, not a single known id

        Example:
          { "id": "abc-123" }

        Response:
          memory abc-123
          room: mootx01/architecture  wing: Agentic Memory
          filed_at: 2026-06-05T10:00:00Z
          event_time: 2026-06-05T10:00:00Z
          state: active
          trust: verbatim
          sensitivity: normal
          exportability: private_
          confirmation: unconfirmed
          lineage: <lineage-uuid>
          tunnels: 1
            → def-456  [relates]
          content:
          <verbatim content>

        Common mistakes:
          - Calling with an id that does not exist, or one you have not
            already found via moot_memory_search. Search first.
          - Expecting a found result for a withdrawn/erased/restricted
            drawer. The gate reports it not-found, same as a genuinely
            absent id — this is deliberate, not a bug.
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

        Erase permanently removes the memory. It cannot be recovered.
        SECURITY GATE: confirmed=true is required and the check is enforced
        at the ARIA surface before the substrate is called. An agent that
        receives confirmed=false (or omits confirmed) cannot trigger erasure
        regardless of any other argument. Set confirmed=true only after the
        owner has explicitly reviewed and approved the deletion.

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
          - Calling without confirmed=true. The call is refused immediately.
          - Using erase when withdraw would suffice. Erase is intended for
            compliance-grade deletion.
          - Erasing with a vague reason. The reason is the audit record.
          - Setting confirmed=true without owner review. The gate protects
            against prompt-injection attacks; do not bypass it.
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

        Proposed links: pass "proposed": true to file the link as a
        PROPOSED (agent-derived, unreviewed) edge instead of an active one
        — use this when adjudicating borderline candidates returned by
        moot_hunt_contradictions. The user settles proposed edges with
        moot_review_tunnel.

        Example:
          { "from_id": "abc-123", "to_id": "def-456",
            "kind": "supports", "label": "Evidence for the decision" }

        Adjudication example (borderline contradiction judged genuine):
          { "from_id": "abc-123", "to_id": "def-456",
            "kind": "contradicts", "proposed": true,
            "label": "conflicting timeout values" }

        Response:
          linked abc-123 → def-456 via supports (<tunnel-uuid>)

        Common mistakes:
          - Using the wrong kind. "contradicts" is structural; "relates" is generic.
          - Linking to ids that do not exist. Verify both ids with moot_memory_search.
          - Creating duplicate connections; use moot_connection_search first.
          - Filing an ACTIVE contradicts edge for a pair you merely suspect
            conflicts — use proposed: true so the user gets to review it.
        """

    private static let reviewTunnelGuide = """
        moot_review_tunnel — Settle a PROPOSED connection: accept or reject.

        Proposed edges come from the contradiction hunter (background scout,
        moot_dream sweep, or moot_hunt_contradictions) and from agent-filed
        moot_link_memories proposed:true links. Accept activates the edge;
        reject withdraws it PERMANENTLY — a rejected pair is never
        re-proposed by the hunter.

        Only tunnels currently in the proposed lifecycle are reviewable;
        reviewing an already-settled edge is refused.

        When to use vs siblings:
          - moot_lens_contradiction — to list proposed edges awaiting review
          - moot_link_memories — to create a new edge (proposed or active)

        Examples:
          { "tunnel_id": "<tunnel-uuid>", "verdict": "accept" }
          { "tunnel_id": "<tunnel-uuid>", "verdict": "reject",
            "reason": "not a real conflict — different services" }

        Response:
          moot_review_tunnel: <tunnel-uuid> accepted — the contradicts link is now active.

        Common mistakes:
          - Rejecting to "snooze" a finding. Rejection is durable; the pair
            will never be re-proposed.
          - Reviewing an active or withdrawn tunnel; only proposed ones qualify.
        """

    private static let huntContradictionsGuide = """
        moot_hunt_contradictions — Hunt memory content for contradictions.

        One bounded sweep: finds semantically-near memory pairs via the
        vector index (kNN over embedding engrams), screens each pair with a
        cheap lexical conflict cue (negation asymmetry, same-template value
        divergence, revision markers), then:
          - STRONG findings are persisted as PROPOSED contradicts links
            (agent-derived, unreviewed) — the user settles them with
            moot_review_tunnel.
          - BORDERLINE pairs are RETURNED with content snippets for YOU to
            judge; nothing is persisted for them. If a pair genuinely
            conflicts, record it with moot_link_memories kind=contradicts
            proposed=true.

        Precision over recall by design: the lexical screen only fires on
        clear surface conflict. Paraphrased contradictions surface as
        borderline candidates (or not at all) — your judgment is the
        second stage.

        Requires the vector index — run moot_reindex after bulk import.
        The same sweep runs inside moot_dream and hourly in the resident
        daemon's contradiction scout; this tool is the on-demand form.
        Rejected and already-linked pairs are deduplicated (never
        re-proposed).

        Example (full sweep, deterministic):
          { "probe_limit": 2000, "now": "2026-06-11T00:00:00Z" }

        Response:
          moot_hunt_contradictions: probesScanned=N pairsScreened=N
          PROPOSED <n>: <src-id> contradicts <tgt-id> [cue score] (tunnel <uuid>)
          CANDIDATE <n>: <src-id> vs <tgt-id> [cue score]
            a: <snippet>
            b: <snippet>

        Common mistakes:
          - Running before moot_reindex on a fresh import; the report will
            say the vector index is unavailable and scan nothing.
          - Treating borderline candidates as findings. They are unjudged;
            adjudicate before recording.
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
            "agent": "assistant" }

        Response:
          wrote journal entry for assistant

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
          { "agent": "assistant", "last_n": 5 }

        Response:
          journal for assistant: N entry(s)
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

        Total: 56 tools. All accept teachme. All may return hint.
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

    private static let monitoringStatusGuide = """
        moot_monitoring_status — Read or set the daemon's telemetry monitoring flag.

        Monitoring controls whether the daemon emits server-metrics telemetry on a
        30-second cadence (counters, timing, health signals). The flag is durable:
        it persists across restarts because it is stored in the StatsStore. Changing
        it takes effect on the next telemetry emit interval.

        This tool is a maintenance/admin verb — not one of the nine ARIA grammar
        verbs. It is permission-gated at the `ask` tier because it mutates daemon
        behaviour, not estate content.

        Read path — omit `enabled`:
          { }   → "monitoring: enabled"   (when flag is on)
          { }   → "monitoring: disabled"  (when flag is off)
          { }   → "monitoring: unavailable" (when no telemetry store is wired;
                   e.g. stdio transport, test harness — never fabricated)

        Write path — supply `enabled: bool`:
          { "enabled": true }   → persists flag, echoes "monitoring: enabled"
          { "enabled": false }  → persists flag, echoes "monitoring: disabled"
          Write path also appends "monitoring_source: user" to the response so
          readers can distinguish operator changes from defaults.

        When to use vs siblings:
          - moot_estate_status — for estate-wide statistics; does NOT report
            the monitoring flag.
          - moot_estate_ping — for liveness only; no flag state.

        Common mistakes:
          - Reading "unavailable" as "disabled" — they are distinct. Unavailable
            means no telemetry store is wired, not that monitoring is off.
          - Omitting `estateID` when multiple estates are open. The monitoring
            flag is daemon-global, but the tool resolves the estate for future
            estate-scoped extensions; always pass the target estate when in doubt.
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

        ANTI-SPOOF: requesterEstateID is optional. When omitted the requester
        is always the default (authenticated caller) estate. When supplied it
        must match the default estate's UUID exactly — supplying a different
        UUID is refused to prevent cross-estate identity spoofing.

        When to use vs siblings:
          - moot_memory_search — to search within a single estate
          - moot_estate_status — to inspect a single estate's health

        Example (omit requesterEstateID — the default is used automatically):
          { "filter": "userConfirmed", "limit": 20 }

        Response:
          estate <name> [<uuid>] — grant <uuid>, N row(s)
          <uuid>  [room]  <content preview…>

        Common mistakes:
          - Supplying a requesterEstateID that doesn't match the default estate.
            The call is refused; omit the field instead.
          - Expecting results from estates with no active grant naming you.
            The call is refused cleanly if no grant authorizes access.
        """

    // MARK: - Specific guide lookup

    private static func specificGuide(for name: String) -> String? {
        switch name {
        // Tier 1
        case "moot_file_memory":     return fileMemoryGuide
        case "moot_memory_search":   return memorySearchGuide
        case "moot_memory_get":      return memoryGetGuide
        case "moot_update_memory":   return updateMemoryGuide
        case "moot_withdraw_memory": return withdrawMemoryGuide
        case "moot_erase_memory":    return eraseMemoryGuide
        case "moot_confirm_memory":  return confirmMemoryGuide
        case "moot_move_memory":     return moveMemoryGuide
        // Tier 2
        case "moot_link_memories":     return linkMemoriesGuide
        case "moot_connection_search": return connectionSearchGuide
        case "moot_connection_map":    return connectionMapGuide
        case "moot_review_tunnel":     return reviewTunnelGuide
        // Tier 3
        case "moot_file_fact":     return fileFactGuide
        case "moot_fact_search":   return factSearchGuide
        case "moot_retire_fact":   return retireFactGuide
        case "moot_fact_timeline": return factTimelineGuide
        // Tier 4
        case "moot_write_journal": return writeJournalGuide
        case "moot_read_journal":  return readJournalGuide
        // Tier 5
        case "moot_estate_status":       return estateStatusGuide
        case "moot_estate_map":          return estateMapGuide
        case "moot_estate_ping":         return estatePingGuide
        // Monitoring control (ADR-025 wave 8.2)
        case "moot_monitoring_status":   return monitoringStatusGuide
        // Federation
        case "moot_federated_search": return federatedSearchGuide
        // Recipe (Tier 6) — precise recall has its own guide.
        case "moot_recall_precise":   return preciseRecallGuide
        case "moot_dream":            return dreamGuide
        case "moot_hunt_contradictions": return huntContradictionsGuide

        case "moot_reclassify_fdc":   return reclassifyFDCGuide
        case "moot_palace_import":    return palaceImportGuide
        default: return nil
        }
    }

    private static let dreamGuide = """
        moot_dream — Dream the estate: matrix, dreaming cycle, and a
        contradiction-hunt sweep.

        Three effects:
          1. Rebuilds the co-occurrence/temporal MATRIX TIER from the
             estate's audit log and registers it for recall scoring. The
             matrix is built by dreaming, NOT by capture — so a freshly
             loaded estate scores 0 on the `matrix` recall lane until this
             runs.
          2. Runs one DREAMING CYCLE: mines latent co-occurrence alignments
             into proposals and writes one cycle diary entry.
          3. Runs one CONTRADICTION-HUNT sweep over memory CONTENT: finds
             semantically-near pairs via the vector index, screens them for
             lexical conflict, and persists strong findings as PROPOSED
             contradicts links (review with moot_lens_contradiction,
             settle with moot_review_tunnel).

        HONEST SCOPE — dreaming-cycle proposals (effect 2) are
        USAGE-DRIVEN: mined from recall co-occurrence (which memories the
        estate recalls together, accumulated over use), NOT from memory
        content. A freshly imported estate that has not been recalled
        against yet will legitimately report 0 cycle proposals — that is
        expected, not a fault. Content is examined only by the
        contradiction-hunt sweep (effect 3), which needs the vector index
        (run moot_reindex after bulk import).

        When to use:
          - After bulk-loading an estate, before relying on matrix /
            association recall (moot_recall_precise composition=matrix,
            text+matrix, weighted-all). Run moot_reindex first so the
            hunt sweep has vectors to mine.
          - To trigger an association-mining + contradiction-hunt pass on
            demand rather than waiting for the resident governor's schedule.

        Example (deterministic run):
          { "now": "2026-06-11T00:00:00Z" }

        Response:
          moot_dream: matrix rebuilt, dreaming cycle complete
          consideredCandidates: N
          proposalsEmitted: N
          suppressedDuplicates: N
          belowThreshold: N
          contradictionsProposed: N
          contradictionCandidatesBorderline: N
        """

    // MARK: - Maintenance

    private static let reclassifyFDCGuide = """
        moot_reclassify_fdc — audit or repair stored FDC anchors.

        Recomputes each active memory drawer's FDC lattice anchor from its
        content using the current deterministic classifier. This is the repair
        path after classifier fixes: storage still uses the existing FDC fields,
        but their values can be reset to the current classifier's answer.

        Defaults:
          - apply:false — dry-run only; no estate mutation.
          - mode:suspectOnly — conservative repair candidates only.

        Modes:
          - suspectOnly (default): reports stale false positives that now become
            000, existing 000 anchors that now classify, and stale Q-ID anchors.
            Use this first on a live estate.
          - all: reports every changed active drawer anchor. Use only when the
            operator intentionally wants to reset stored FDC from content; this
            can overwrite manually curated non-sentinel anchors.

        Optional limit:
          - limit:N scans at most N active drawers in this run.

        Examples:
          { "apply": false }
          { "apply": true }
          { "mode": "all", "apply": true }

        Response:
          fdc_reclassify: dry-run|applied
          mode: suspectOnly|all
          scanned: N active drawer(s)
          candidates: N
          would_update|updated: N
          changes:
            <drawer-id>: <old-code> [<old-qid>] -> <new-code> [<new-qid>]

        Common mistakes:
          - Running mode=all before inspecting a dry-run.
          - Expecting the tool to change room/wing placement. It only repairs
            the stored FDC/Q-ID lattice anchor.
          - Treating 000 as a bug. 000 is the intentional unclassified sentinel
            for content the classifier should not force into a knowledge class.
        """

    private static let palaceImportGuide = """
        moot_palace_import — import a MemPalace directly into the estate.

        Reads a MemPalace's three stores (palace/chroma.sqlite3 drawer
        content, tunnels.json cross-wing connections, knowledge_graph.sqlite3
        KG triples) through the idempotent import path. Re-importing an
        unchanged palace writes zero drawers.

        When to use vs siblings:
          - moot_vault_import — when importing a Markdown/Obsidian vault, not a MemPalace
          - moot_file_memory — when adding a single memory, not a bulk corpus

        Optional mode (encode SPEED):
          - mode:foreground (default) — drain the encode queue hard on the
            performance cores.
          - mode:background — drain gently (QoS background) for very large
            imports so it does not saturate the machine.
        The write strategy (bulk transaction vs stream) is chosen automatically
        by source size — you do not control it.

        Post-import (AUTOMATIC — do NOT tell the user to run reindex/dream):
        the import triggers its own indexing in the background. It enqueues the
        encode/index work, the encode drain turns it into the BM25 + vector
        lanes, and then it retrains the corpus embedding-basis on the WHOLE
        import; the resident daemon's dreaming duty builds the association matrix
        on its cadence. (Dreaming's consolidation proposals themselves are
        usage-driven — they accrue as the estate is recalled against, not
        from the imported content itself.) Poll moot_drain_status to watch
        the encode queue converge.

        RECALL LIGHTS UP IN STAGES — this matters for what you can trust right
        after an import: keyword (exact-term) and structured (wing/room) recall
        work almost immediately, but full SEMANTIC / vector recall (meaning-based
        RAG search) is available only AFTER the basis retrain finishes. A
        just-imported term that appears only in a later chunk batch reads
        dense_lane:dark:vocabMiss until the retrain republishes the basis with
        the full vocabulary. So on a fresh import be patient: poll
        moot_drain_status until idle before relying on semantic search over the
        imported memories, and tell the user that deep meaning-based recall over
        a fresh import becomes available shortly after import (tens of seconds to
        a few minutes on a large one), not instantly.

        moot_reindex and moot_dream remain available to re-trigger on
        demand but are NOT a required follow-up step. (Running WITHOUT a resident
        daemon? Then run moot_dream yourself when you want matrix-aware recall /
        distillation — only the resident builds the matrix automatically.)

        Long imports: this call returns only when the import finishes, and a
        large import can run for many minutes. If your client
        supports sub-agents or background execution, run this call in one so
        your main session stays responsive. Live per-record progress goes to
        the server's stderr log, not to this call's response (which carries
        only the summary). To watch the background encode queue converge after
        this call returns, poll moot_drain_status — it reports the encode
        drain's pending + in-flight counts and a draining/idle state.

        Example:
          { "palace_path": "/Users/me/.mempalace" }

        Response:
          palace import complete: <n> written, <n> updated, <n> unchanged,
          <n> tombstoned, <n> tunnels, <n> skipped

        Common mistakes:
          - Reporting recall fully ready the instant the import returns —
            encoding runs in the BACKGROUND after the call; poll
            moot_drain_status until idle before trusting dense recall.
          - Telling the user to run moot_reindex / moot_dream as a required
            step — the import already triggers indexing; they are re-trigger
            tools, not a required follow-up.
          - Pointing palace_path at the inner palace/ directory. Pass the
            ROOT directory that CONTAINS palace/.
          - Trying to choose the write strategy — you can't; it is size-gated
            automatically. You only choose encode SPEED via mode.
        """

    private static let preciseRecallGuide = """
        moot_recall_precise — Recall the EXACT answer above near-duplicates.

        Runs the PreciseRecall recipe: a generous coarse grab (the same
        hybrid BM25+vector lane moot_memory_search uses) re-ranked by
        query-specific precision — the exact match of the query's
        distinctive tokens (numbers, proper nouns). Among look-alikes that
        share every word, the candidate that actually contains the queried
        "46" / "Versailles" / "Q3" rises to the top.

        When to use vs siblings:
          - moot_memory_search — coarse retrieval; high recall, ranks
            near-duplicates interchangeably.
          - moot_recall_precise — when the right answer is one of several
            look-alikes and the distinguishing detail is a number or name.

        Example:
          { "query": "the indemnity was 46 million marks",
            "limit": 10, "pool": 30, "filter": "unconfirmed" }

        Response (same shape as moot_memory_search):
          found N memory(s)
          <id>  [room]  <preview>
          ...

        Common mistakes:
          - Setting pool below limit. It is clamped up to limit so the
            result set never shrinks below a plain coarse grab.
          - Expecting it to find memories moot_memory_search cannot — the
            coarse grab is identical; precise recall only RE-RANKS it.
        """

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

        Reconcile two-step workflow:
          1. moot_vault_reconcile vaultPath=<path> — dry-run: reports added/modified/deleted
             candidates without writing anything to the estate.
          2. moot_vault_reconcile vaultPath=<path> apply=true — apply: imports the added
             and modified candidates into the estate synchronously. Deleted files are
             always reported only; no drawer is expunged.

        Common mistakes:
          - Importing without verifying vault status first.
          - Running reconcile without a prior export; there is nothing to compare.
        """
    }

    private static func unknownGuide(_ name: String) -> String {
        "Unknown tool '\(name)'. Call moot_estate_status (no teachme) for the protocol block, or with teachme:true for the tool orientation guide."
    }
}
