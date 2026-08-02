import Foundation

/// The AI-client-oriented MCP tool surface.
///
/// Replaces the lexicon-projected (verb × noun) surface with a five-tier
/// AI-agent interface. Tools are named for AI-agent tasks, not internal
/// ARIA grammar pairs. An AI client needs to know how to file a memory,
/// search, link, record a fact, keep a journal, and query estate health —
/// not how the ARIA grammar is structured.
///
/// ## Five tiers
///
/// - **Tier 1 — Core Memory (8):** file, search, get, update, withdraw,
///   erase, confirm, move. The main CRUD surface for memory drawers.
/// - **Tier 2 — Connections (4):** link, review, search outgoing, map incoming.
///   Directed graph edges between memories.
/// - **Tier 3 — Knowledge Graph (4):** file fact, search facts, retire fact,
///   fact timeline. Structured triple assertions on the estate.
/// - **Tier 4 — Journal (2):** write entry, read entries. Agent diary for
///   session continuity.
/// - **Tier 5 — Estate (3):** status, map, reconnect. Estate-level inspection
///   and maintenance.
///
/// Non-tier tools (federation, recipe, lens, vault) are appended after the
/// five tiers and are unchanged in shape from the prior surface.
///
/// ## Internal-infrastructure fields are never surfaced
///
/// `udcCode`, `embeddingModelID`, `latticeAnchor`, `operationalBitmap`,
/// and `provenanceBitmap` do not appear in any tool schema. The server
/// owns those defaults so AI clients never need to know about them.

/// Where a projected tool comes from. The five tiers share `.interface`;
/// non-tier tools keep their distinct cases.
public enum ToolProvenance: Sendable, Equatable {
    /// One of the 20 AI-client interface tools (five tiers).
    case interface
    /// A federation-surface tool that sits above the interface tier.
    case federation
    /// A CognitionKit behaviour-recipe tool.
    case recipe
    /// A VaultKit control-surface tool.
    case vault
}

/// A single tool advertised in `tools/list`.
public struct ProjectedTool: Sendable, Equatable {
    /// MCP tool name, e.g. `"moot_file_memory"`.
    public let name: String
    /// One-line AI-facing description.
    public let description: String
    /// JSON Schema for the tool's argument object.
    public let inputSchema: JSONValue
    /// Where this tool comes from.
    public let provenance: ToolProvenance
}

public enum ToolProjection {

    /// Product namespace prefix on every MCP tool name. Marks the surface
    /// as MOOTx01's so it never collides with another connected MCP server.
    public static let toolNamePrefix = "moot_"

    /// True when the vault MCP tool surface is enabled for the given environment.
    ///
    /// The env var `MOOTX01_VAULT` governs the choice: any value other than
    /// the literal string `"0"` (including absent/empty) means vault is ON.
    /// Default is vault-on.
    ///
    /// Takes an explicit environment dictionary so the logic is testable
    /// without mutating `ProcessInfo.processInfo.environment` (which is
    /// read-only at runtime). Production callers use `vaultEnabled` (no args).
    public static func vaultEnabled(environment: [String: String]) -> Bool {
        environment["MOOTX01_VAULT"] != "0"
    }

    /// True when the vault MCP tool surface is enabled.
    ///
    /// Reads `MOOTX01_VAULT` from the process environment. Any value other than
    /// the literal string `"0"` (including absent/empty) means vault is ON.
    /// The daemon has this variable set from the `mootx01 install --vault-on/--vault-off`
    /// flag at install time (written into the launchd plist EnvironmentVariables
    /// block so it survives restarts). Default is vault-on.
    public static var vaultEnabled: Bool {
        vaultEnabled(environment: ProcessInfo.processInfo.environment)
    }

    /// True when the Anthropic memory_20250818 adapter is enabled.
    /// Opt-in: requires MOOTX01_MEMORY_TOOL=1 (set by `mootx01 enable memory-tool`).
    /// Default (absent or any value ≠ "1") is OFF.
    public static func memoryToolEnabled(environment: [String: String]) -> Bool {
        environment["MOOTX01_MEMORY_TOOL"] == "1"
    }

    public static var memoryToolEnabled: Bool {
        memoryToolEnabled(environment: ProcessInfo.processInfo.environment)
    }

    /// The complete advertised tool list.
    ///
    /// Order: tier 1–5 interface tools, then federation, recipe, lens, vault.
    /// Every tool schema is wrapped with `withTeachme` so callers can pass
    /// `teachme: true` on any tool to receive its usage guide.
    ///
    /// Vault tools are omitted when `MOOTX01_VAULT=0` (installed with
    /// `--vault-off`). All other tiers are unaffected. See the open 1.0 Vault posture.
    public static func tools() -> [ProjectedTool] {
        tools(environment: ProcessInfo.processInfo.environment)
    }

    /// The complete advertised tool list evaluated against an explicit
    /// environment dictionary. Used by tests that cannot mutate
    /// `ProcessInfo.processInfo.environment` (which is read-only at runtime).
    /// Production code uses `tools()` (no args).
    public static func tools(environment: [String: String]) -> [ProjectedTool] {
        var raw: [ProjectedTool] = []
        // Anthropic memory_20250818 adapter: opt-in via MOOTX01_MEMORY_TOOL=1
        // (mootx01 enable memory-tool sets this in the daemon env).
        if memoryToolEnabled(environment: environment) {
            raw.append(contentsOf: memoryAdapterTools())
        }
        raw.append(contentsOf: coreMemoryTools())
        raw.append(contentsOf: connectionTools())
        raw.append(contentsOf: knowledgeGraphTools())
        raw.append(contentsOf: journalTools())
        raw.append(contentsOf: estateTools())
        raw.append(federationTool())
        raw.append(contentsOf: RecipeTools.tools())
        raw.append(contentsOf: LensTools.tools())
        // Vault tools and the filesystem-importing palace import tool are gated:
        // omitted from tools/list when MOOTX01_VAULT=0 (installed with
        // --vault-off). Default (env absent or any value ≠ "0") is vault-on
        //. `moot_palace_import` is an interface-shaped maintenance
        // tool, but it reads from the local filesystem and opens arbitrary
        // SQLite files, so it carries the same security posture as vault
        // import/export and is hidden under the same gate.
        if vaultEnabled(environment: environment) {
            raw.append(contentsOf: VaultTools.tools())
        } else {
            raw.removeAll { $0.name == "moot_palace_import" }
        }
        // Dataset tools (MX-TAB-7): file, query, stats. Always visible when the
        // estate supports datasets. Not vault-gated (dataset tables are a core storage
        // surface, not a VaultKit feature). Added after vault so the existing
        // tool-count and tier ordering tests stay stable with a simple +3 increment.
        raw.append(contentsOf: DatasetTools.tools())
        // Packet tools (FAB5-I2): file, get, list, lineage. Always visible.
        // Packets are structuredJSON drawers (typed content, not a new noun).
        raw.append(contentsOf: PacketTools.tools())
        return raw.map { tool in
            ProjectedTool(
                name: tool.name,
                description: tool.description,
                inputSchema: withTeachme(tool.inputSchema),
                provenance: tool.provenance
            )
        }
    }

    // MARK: - Anthropic memory_20250818 adapter (M-MEMTOOL-1)

    private static func memoryAdapterTools() -> [ProjectedTool] {
        [memoryTool()]
    }

    // MARK: - Tier 1: Core Memory (9 tools)

    // Internal (not private) so TeachmeGuides can derive per-tier counts at
    // runtime; the guide's tallies stay in sync with the registry automatically.
    static func coreMemoryTools() -> [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_file_memory",
                description: "File a new memory into the estate. Provide the content, a one-sentence subject, and a location hint (free-form string describing subject matter). The server chooses structural coordinates and infrastructure fields.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "content": stringSchema("The text content to remember."),
                        "subject": stringSchema("REQUIRED. One sentence (≤120 chars) stating what this memory asserts. Write it for the NEXT AI that will scan it in a result list — telegraphic register, entities and claims front-loaded, no narrative framing. It is returned in recall rows, never searched. Example: \"Quarterly planning moved to Thursday; Sarah sends invites Monday.\""),
                        "location": stringSchema("Subject-matter location hint (e.g. \"project/alpha\", \"meeting notes\"). Maps to the room coordinate; used for retrieval organisation. Omit wing to use the default wing (\"Agentic Memory\")."),
                        "wing": stringSchema("Optional wing name to route this memory into a specific wing. When absent, defaults to \"Agentic Memory\" (the AI's working memory wing). Example: \"Source Corpus\" for imported source material. null is invalid."),
                        "sensitivity": stringSchema("Optional sensitivity: normal (default), elevated, restricted, secret. Omit to use the default; null is invalid."),
                        "exportability": stringSchema("Optional exportability tier at capture time: private (default — not visible to filter:exportable) or public (immediately visible to filter:exportable recall). Use moot_update_memory with mutation=correctExportability(public) to promote an existing private memory. Drawers born public are immediately returned by filter:exportable searches. Omit to use the default; null is invalid."),
                        "kind": stringSchema("Optional content kind: prose (default), code, transcript, list, structuredJSON, imageCaption. Omit to use the default; null is invalid."),
                        "event_time": stringSchema("Optional ISO8601 event time for historical ingestion. Omit for streaming capture (defaults to now); null is invalid."),
                        "impatient": booleanSchema("Optional. When true, the memory is encoded for semantic search INLINE before the write returns, so it is immediately recallable by BM25/vector search at the cost of a slower write. When false (default), the write returns immediately and encoding happens in the background. Omit to use the default; null is invalid."),
                    ],
                    required: ["content", "subject", "location"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_memory_search",
                description: "Search the estate for memories matching a query. Uses hybrid BM25+vector recall. Returns ranked memory rows with content and metadata. Best for broad or time-ordered retrieval; use ordering:byRelevanceDesc for relevance-ranked results. Each result includes a discrimination signal (high/medium/low) — a relative-gap confidence estimate of how clearly the top result separates from the rest, with a saturation discount when the semantic lane is dark. Low discrimination on small estates is expected for broad or associative searches; prefer moot_recall_precise for precision retrieval.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "query": stringSchema("Natural-language search query."),
                        "limit": integerSchema("Max results to return (default 20). Omit to use the default; null is invalid."),
                        "filter": stringSchema("Optional filter: unconfirmed, userConfirmed, exportable, contained, pinned. Omit for ordinary recall: active/trustworthy/elevated-or-lower memories across any confirmation state. \"pinned\" constrains to user-pinned drawers (rooms without a pinned drawer are pruned from the search). null is invalid."),
                        "wing": stringSchema("Optional wing name to scope recall to a single wing. Omit to search across all wings. Example: \"Agentic Memory\", \"Source Corpus\". null is invalid."),
                        "media_type": stringSchema("Optional media type filter: voice (drawers captured with voice audio, bit 13), image (drawers from or carrying an image, bit 14). Composable with filter and wing. Omit to search all media types. null is invalid."),
                        "explain": booleanSchema("Return per-hit explanation blocks when true. Omit to use the default; null is invalid."),
                        "scoring": stringSchema("Scoring strategy: raw, rrf, matrixAware (default). Omit to use the default; null is invalid."),
                        "ordering": stringSchema("Result ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc, byRelevanceDesc. byRelevanceDesc routes to the scored recall pipeline (unionBest) whose results are ranked by relevance score — this is the recommended ordering when relevance matters. Omit to use the default; null is invalid."),
                    ],
                    required: ["query"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_memory_list",
                description: "List all memory drawer IDs in a wing, optionally filtered by room. Structural enumeration — no semantic query needed. Use this to inventory a wing's contents, find specific drawers for move/update, or verify import placement. Returns each drawer's ID, room, and an 80-char content preview. Capped at 200 results. filter:missing_subject enumerates subject-debt rows (id-only, no preview) for interactive backfill via moot_update_memory mutation=setSubject.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "wing": stringSchema("Wing name to list (required). Example: \"Agentic Memory\", \"CodexSecurity\"."),
                        "room": stringSchema("Optional room name to narrow within the wing. Omit to list all rooms in the wing."),
                        "filter": stringSchema("Optional filter: missing_subject — only live drawers with no subject line, listed id-only (the subject-debt backfill enumerator). Omit to list all drawers with previews. null is invalid."),
                    ],
                    required: ["wing"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_memory_get",
                description: "Fetch one memory drawer by id, in full — verbatim content, room/wing, capture time, and adjective-axis metadata (state/trust/sensitivity/exportability/confirmation), plus a linked-tunnel summary. Applies the same default gate as moot_memory_search (active/trustworthy/elevated-or-lower); a drawer that exists but fails that gate is reported not-found, same as a genuinely absent id. Use moot_memory_search first to find an id, then this tool for the full record.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "id": stringSchema("Memory row identifier (drawer UUID)."),
                    ],
                    required: ["id"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_update_memory",
                description: "Apply a named mutation to an existing memory. Belief mutations: confirm, reject, contest, resolve, supersede, revive, accept. Exportability mutations: correctExportability(public) promotes a private memory to public (visible to filter:exportable), correctExportability(private) revokes public status. Subject mutation: setSubject writes or replaces the memory's one-sentence subject line (pass the text in the `subject` argument) — the backfill/correction path for subject-debt rows found via moot_memory_list filter:missing_subject.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "id": stringSchema("Memory row identifier."),
                        "mutation": stringSchema("Mutation kind: confirm, reject, contest, resolve, supersede, revive, accept, correctExportability(public), correctExportability(private), setSubject."),
                        "note": stringSchema("Optional free-text note recorded with the mutation."),
                        "subject": stringSchema("Required for mutation=setSubject, ignored otherwise: one sentence (≤120 chars) in the AI-facing register — telegraphic, entities and claims front-loaded. Returned in recall rows, never searched."),
                    ],
                    required: ["id", "mutation"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_withdraw_memory",
                description: "Withdraw a memory from active circulation (soft removal; reversible).",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "id": stringSchema("Memory row identifier."),
                        "reason": stringSchema("Optional free-text reason."),
                    ],
                    required: ["id"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_erase_memory",
                description: "Hard-erase a memory permanently. Irreversible. Requires explicit confirmation.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "id": stringSchema("Memory row identifier."),
                        "reason": stringSchema("Required justification for the erasure."),
                        "confirmed": booleanSchema("Must be true to proceed; erasure is irreversible."),
                    ],
                    required: ["id", "reason", "confirmed"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_confirm_memory",
                description: "Mark a memory as user-confirmed (shortcut for moot_update_memory with mutation=confirm).",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "id": stringSchema("Memory row identifier."),
                        "note": stringSchema("Optional confirmation note."),
                    ],
                    required: ["id"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_move_memory",
                description: "Move a memory to a different location within the estate (reanchor). Supports cross-wing moves via the optional `wing` argument.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "id": stringSchema("Memory row identifier."),
                        "location": stringSchema("New location hint (free-form string; server resolves to room coordinate)."),
                        "wing": stringSchema("Optional target wing name for cross-wing moves. When supplied, the memory is moved to this wing AND the given location. When absent, only the room changes and the wing stays unchanged. Example: \"Professional\", \"Personal\". null is invalid."),
                    ],
                    required: ["id", "location"]
                )),
                provenance: .interface
            ),
        ]
    }

    // MARK: - Tier 2: Connections (4 tools)

    // Internal so TeachmeGuides can derive per-tier counts at runtime.
    static func connectionTools() -> [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_link_memories",
                description: "Create a directed connection (tunnel) between two memories. Supports typed relationships.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "from_id": stringSchema("Source memory row identifier."),
                        "to_id": stringSchema("Target memory row identifier."),
                        "kind": stringSchema("Relationship kind (default: relates). Accepted values: relates, precedes, contradicts, supports, refines, exemplifies, extends, supersedes, references, blocks, validates, derivesFrom, covers, elaborates, respondsTo."),
                        "label": stringSchema("Optional free-form label for the connection. Defaults to the kind string."),
                        "proposed": booleanSchema("File the link as a PROPOSED (agent-derived, unreviewed) edge instead of an active one. Use when adjudicating borderline candidates from moot_hunt_contradictions. The user settles it via moot_review_tunnel. Default false."),
                    ],
                    required: ["from_id", "to_id", "kind"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_review_tunnel",
                description: "Settle a PROPOSED connection (e.g. an agent-derived contradiction from the hunter): accept activates it, reject withdraws it. Rejected pairs are never re-proposed. Only tunnels in the proposed lifecycle are reviewable.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "tunnel_id": stringSchema("Tunnel identifier (shown by moot_lens_contradiction and moot_hunt_contradictions)."),
                        "verdict": stringSchema("\"accept\" to activate the link, \"reject\" to withdraw it permanently."),
                        "reason": stringSchema("Optional note explaining the verdict."),
                    ],
                    required: ["tunnel_id", "verdict"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_connection_search",
                description: "Find all connections going out from a memory (what this memory points to).",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "from_id": stringSchema("Source memory row identifier."),
                    ],
                    required: ["from_id"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_connection_map",
                description: "Find all connections pointing to a memory (what points at this memory). Returns the estate's tunnel graph for the target's wing.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "to_id": stringSchema("Target memory row identifier."),
                    ],
                    required: ["to_id"]
                )),
                provenance: .interface
            ),
        ]
    }

    // MARK: - Tier 3: Knowledge Graph (4 tools)

    // Internal so TeachmeGuides can derive per-tier counts at runtime.
    static func knowledgeGraphTools() -> [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_file_fact",
                description: "Assert a structured knowledge-graph fact (subject–predicate–object triple) into the estate.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "subject": stringSchema("The entity this fact is about."),
                        "predicate": stringSchema("The relationship or property being asserted."),
                        "object": stringSchema("The value or target entity."),
                        "source_id": stringSchema("Memory drawer id that grounds this fact (provenance). If omitted, the server infers the source as the ingest channel that asserted it — a fact always traces back to a source, never unanchored."),
                    ],
                    required: ["subject", "predicate", "object"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_fact_search",
                description: "Search knowledge-graph facts by subject, predicate, or object. Omit query to return all active facts.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "query": stringSchema("Optional search string. Matched as a substring against subject, predicate, and object fields. Omit to return all active facts."),
                        "subject_exact": stringSchema("Optional exact, case-sensitive subject filter."),
                        "predicate_exact": stringSchema("Optional exact, case-sensitive predicate filter."),
                        "object_exact": stringSchema("Optional exact, case-sensitive object filter."),
                        "source_id_exact": stringSchema("Optional exact provenance source filter."),
                        "limit": integerSchema("Maximum rows to return (default 100, maximum 500)."),
                    ],
                    required: []
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_retire_fact",
                description: "Retire (invalidate) a knowledge-graph fact by its row identifier.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "id": stringSchema("KG fact row identifier."),
                    ],
                    required: ["id"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_fact_timeline",
                description: "Read all knowledge-graph facts in chronological order, including retired ones, to trace how the estate's structured knowledge evolved. Each row is tagged with its lifecycle state (active or retired). Optional entity filter narrows results to facts whose subject or object contains the given string.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "entity": stringSchema("Optional entity name to filter by (subject or object substring match, case-insensitive). Omit to return the full history."),
                    ],
                    required: []
                )),
                provenance: .interface
            ),
        ]
    }

    // MARK: - Tier 4: Journal (2 tools)

    // Internal so TeachmeGuides can derive per-tier counts at runtime.
    static func journalTools() -> [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_write_journal",
                description: "Write a diary entry to the agent journal for session continuity. Use for recording decisions, observations, and reasoning steps.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "entry": stringSchema("Journal entry text."),
                        "agent": stringSchema("Optional agent name. Defaults to the server-assigned MCP agent identity."),
                    ],
                    required: ["entry"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_read_journal",
                description: "Read recent journal entries for an agent. Use to restore session context across turns.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "agent": stringSchema("Agent name to read entries for. Omit to read entries for the current MCP agent."),
                        "last_n": integerSchema("Number of most-recent entries to return (default 10)."),
                    ],
                    required: []
                )),
                provenance: .interface
            ),
        ]
    }

    // MARK: - Tier 5: Estate (3 tools) + Maintenance + Monitoring (8 total; palace_import vault-gated)

    // Internal so TeachmeGuides can derive per-tier counts at runtime.
    // Returns 8 tools including moot_palace_import. tools() removes palace_import
    // from the result when vault is off; the remaining 7 are always present.
    static func estateTools() -> [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_estate_status",
                description: "Return a summary of the estate: memory count, wing list, KG fact count, and sync health.",
                inputSchema: withEstateID(objectSchema(
                    properties: [:],
                    required: []
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_estate_map",
                description: "Return the estate's structural map: all wings and rooms, with memory counts per location. Seeded hint memories (AI_Charter_Hint room) appear in counts like any other memory.",
                inputSchema: withEstateID(objectSchema(
                    properties: [:],
                    required: []
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_estate_ping",
                description: "Ping the estate to confirm the server process and estate handle are live. Returns immediately with no estate scan. Use to verify connectivity before a sequence of operations.",
                inputSchema: withEstateID(objectSchema(
                    properties: [:],
                    required: []
                )),
                provenance: .interface
            ),
            // Monitoring control — sibling to moot_estate_status.
            // Read/write the daemon's telemetry monitoring flag via the injected
            // MonitoringControl seam. "absent enabled" = read path (no mutation);
            // "present enabled" = write path (persists flag + monitoring_source=user).
            // Reports "unavailable" when no stats store is wired (stdio, test
            // harnesses, provision-less contexts) — never fabricates state.
            ProjectedTool(
                name: "moot_monitoring_status",
                description: "Read or set the daemon's telemetry monitoring flag. Absent `enabled`: reports current monitoring state (enabled / disabled / unavailable). Present `enabled`: persists the new flag and reports the effective state after the write. Monitoring controls whether server-metrics telemetry is emitted on a 30-second cadence. Reports 'monitoring: unavailable' when no telemetry store is wired (stdio mode, test contexts) — never fabricates enabled/disabled.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "enabled": booleanSchema("Optional: the monitoring flag to set. Omit to read the current state without mutating it. true enables telemetry emission; false disables it."),
                    ],
                    required: []
                )),
                provenance: .interface
            ),
            // Maintenance / admin tool — NOT one of the nine ARIA grammar verbs.
            // Backfills BM25/vector indexes for drawers captured before the dual-path
            // intake wiring landed (or after an index loss). Enqueues encode jobs for
            // all active drawers not already in the Corpus BundleStore; encoding runs
            // asynchronously via the background drain worker. Idempotent: already-
            // indexed drawers are skipped. Returns a count of drawers enqueued.
            ProjectedTool(
                name: "moot_reindex",
                description: "Maintenance: enqueue encode jobs for all memories not yet in the BM25/vector index. Use after a fresh import or to recover from an index loss. Encoding is asynchronous — returns immediately with a count of memories enqueued. Idempotent: already-indexed memories are skipped.",
                inputSchema: withEstateID(objectSchema(
                    properties: [:],
                    required: []
                )),
                provenance: .interface
            ),
            // Maintenance / admin tool — NOT one of the nine ARIA grammar verbs.
            // Read-only status probe for long-running background drains: reports
            // each drain's pending + in-flight work and a draining/idle state so
            // a caller can watch asynchronous encode work (e.g. after an import)
            // converge. Lightweight — no orientation block — and safe to poll.
            ProjectedTool(
                name: "moot_drain_status",
                description: "Maintenance: report long-running background drains and their progress. Returns each drain's pending and in-flight job counts plus a draining/idle state; the corpus encode drain also reports its live encoded-chunk count. Read-only and lightweight — safe to poll repeatedly while a drain settles (e.g. after moot_palace_import or moot_reindex). Today the only drain is the corpus encode/ingest queue.",
                inputSchema: withEstateID(objectSchema(
                    properties: [:],
                    required: []
                )),
                provenance: .interface
            ),
            // Maintenance / admin tool — NOT one of the nine ARIA grammar verbs.
            // Recomputes stored FDC lattice anchors with the current deterministic
            // classifier. Dry-run by default. `mode: suspectOnly` restricts changes
            // to stale false positives/empty anchors; `mode: all` intentionally
            // rewrites every changed active drawer anchor from content.
            ProjectedTool(
                name: "moot_reclassify_fdc",
                description: "Maintenance: audit or repair stored FDC lattice anchors using the current deterministic classifier. Default is a dry-run in mode \"suspectOnly\", which reports likely stale/polluted anchors without writing. Pass apply=true to write repairs. Pass mode=\"all\" only when intentionally resetting every changed active drawer's stored FDC anchor from content; this can overwrite manually curated anchors. Output reports drawer IDs and old/new anchors, not memory content.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "apply": booleanSchema("Optional. false (default) is dry-run; true writes candidate anchor changes through the audited reanchor path."),
                        "mode": stringSchema("Optional repair scope: \"suspectOnly\" (default, conservative repair of likely stale false positives/empty anchors) or \"all\" (reset every changed active drawer anchor from content)."),
                        "limit": integerSchema("Optional maximum active drawers to scan for this run. Omit to scan the full active estate."),
                    ],
                    required: []
                )),
                provenance: .interface
            ),
            // Direct palace import — bypasses NoteIR, reads three MemPalace
            // stores directly (palace/chroma.sqlite3, tunnels.json,
            // knowledge_graph.sqlite3). All four import guards are applied
            // (tombstone, content-idempotent dedup, sensitivity floor,
            // tunnel signature dedup). Idempotent: re-importing the same
            // palace returns zero written/updated counts.
            ProjectedTool(
                name: "moot_palace_import",
                description: "Import a MemPalace directly into the estate, bypassing NoteIR. Reads palace/chroma.sqlite3 (drawer content), tunnels.json (cross-wing connections), and knowledge_graph.sqlite3 (KG triples) from palace_path. Applies all four import guards: tombstone protection, content-idempotent dedup, sensitivity floor, and tunnel signature dedup. Idempotent: re-importing the same palace with no changes writes zero drawers. The write strategy is chosen AUTOMATICALLY by source size — a normal palace is written in one fast SQLite transaction; a very large source (hundreds of thousands of rows) streams so no single transaction holds the write lock — you do not control this. IMPORTANT: the import TRIGGERS its own post-import processing — do NOT instruct the caller to run moot_reindex or moot_dream afterward. On completion the import enqueues the encode/index work (BM25 + vector lanes) and rolls up the Merkle tree; the resident daemon's encode-drain worker and the governor's dreaming duty then finish indexing, classification, and the association matrix in the background (dreaming's consolidation proposals themselves are usage-driven and accrue as the estate is recalled against, not from the imported content). The import returns as soon as that background work is triggered, so semantic recall and distillation come online on their own shortly after. Poll moot_drain_status to watch the encode queue converge. (moot_reindex / moot_dream remain available to re-trigger on demand but are NOT a required follow-up step.) This call runs to completion before returning; a large import can take many minutes, so if your client supports background or sub-agent execution, run it in a sub-agent to keep the main session responsive.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "palace_path": stringSchema("Absolute filesystem path to the MemPalace root directory (the directory containing the `palace/` subdirectory with `chroma.sqlite3`)."),
                        "mode": stringSchema("Optional encode SPEED for the background encoding that follows the import: \"foreground\" (default) drains the encode queue hard on the performance cores; \"background\" yields for very large imports so the drain does not saturate the machine. This sets SPEED only — the write strategy (bulk transaction vs stream) is chosen automatically by source size, not by this argument. Omit to use the default (foreground)."),
                    ],
                    required: ["palace_path"]
                )),
                provenance: .interface
            ),
        ]
    }

    // MARK: - Federation tool

    /// The federated-search tool descriptor. Has no `(verb, noun)` pair;
    /// dispatched by name. Fans across locally-open estates the requester
    /// is entitled to read.
    public static func federationTool() -> ProjectedTool {
        ProjectedTool(
            name: ToolDispatcher.federatedSearchToolName,
            description: "Grant-authorized cross-estate federated search: fans across the locally-open estates the requester is entitled to read and returns per-estate contributions, each narrowed to its grant's scope.",
            inputSchema: objectSchema(
                properties: [
                    // requesterEstateID is now OPTIONAL (Item 2 hardening): omit to use the
                    // default estate. When supplied it must match the default estate exactly;
                    // supplying a different UUID is refused to prevent cross-estate spoofing.
                    "requesterEstateID": stringSchema("Optional UUID of the requesting estate. Omit to use the default (authenticated caller) estate. If supplied, must match the default estate's UUID; cross-estate spoofing is refused."),
                    "filter": stringSchema("Filter kind: unconfirmed, userConfirmed, exportable, contained. Omit for ordinary recall across any confirmation state. null is invalid."),
                    "limit": integerSchema("Max rows per estate to return. Omit for no explicit cap; null is invalid."),
                    "ordering": stringSchema("Ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc. Omit to use the default; null is invalid."),
                    "hydrationLevel": stringSchema("Hydration: structured (default), full, bitmapOnly. Omit to use the default; null is invalid."),
                ],
                required: []
            ),
            provenance: .federation
        )
    }

    // MARK: - Schema helpers

    /// Inject an optional `teachme` property into an object schema.
    /// Parallel to `withEstateID` — applied in `tools()` after all per-tool
    /// schemas are built. Callers pass `true` to receive a usage guide for
    /// the tool rather than executing it; the dispatch layer intercepts this
    /// before any runner fires.
    static func withTeachme(_ schema: JSONValue) -> JSONValue {
        guard case .object(var object) = schema,
              case .object(var properties)? = object["properties"] else {
            return schema
        }
        properties["teachme"] = booleanSchema(
            "Pass true to receive a usage guide for this tool instead of executing it."
        )
        object["properties"] = .object(properties)
        return .object(object)
    }

    /// Inject an optional `estateID` property into an object schema.
    /// Never required — omitting it targets the default estate.
    static func withEstateID(_ schema: JSONValue) -> JSONValue {
        guard case .object(var object) = schema,
              case .object(var properties)? = object["properties"] else {
            return schema
        }
        properties["estateID"] = stringSchema(
            "Optional UUID of the open estate to target. Omit for the default estate."
        )
        object["properties"] = .object(properties)
        return .object(object)
    }

    static func objectSchema(
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    static func stringSchema(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
        ])
    }

    static func integerSchema(_ description: String) -> JSONValue {
        .object([
            "type": .string("integer"),
            "description": .string(description),
        ])
    }

    static func booleanSchema(_ description: String) -> JSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(description),
        ])
    }

    // MARK: - Accepted arg key extraction (used by dispatch layer for unknown-arg hint)

    /// Returns the set of argument key names declared in `toolName`'s inputSchema
    /// `properties` dict. Includes `estateID` and `teachme` for tools that
    /// advertise them (all tools get `teachme`; interface/recipe/lens tools get
    /// `estateID`). Returns nil when the tool name is unknown — the dispatch layer
    /// skips the unrecognized-arg check when the tool is unrecognized (it will
    /// fail with methodNotFound before the hint logic runs).
    static func acceptedArgKeys(for toolName: String) -> Set<String>? {
        // Uses the default environment (reads MOOTX01_VAULT / MOOTX01_MEMORY_TOOL
        // from ProcessInfo). Vault tools only appear in the list when vault is
        // enabled, so their schemas are only checked when vault is on — matching
        // the dispatch gate that gates vault tool calls the same way.
        guard let tool = tools().first(where: { $0.name == toolName }) else { return nil }
        guard case .object(let schema) = tool.inputSchema,
              case .object(let properties)? = schema["properties"] else {
            return []
        }
        return Set(properties.keys)
    }
}
