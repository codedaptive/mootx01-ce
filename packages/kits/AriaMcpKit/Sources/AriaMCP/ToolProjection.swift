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
/// - **Tier 1 — Core Memory (7):** file, search, update, withdraw, erase,
///   confirm, move. The main CRUD surface for memory drawers.
/// - **Tier 2 — Connections (3):** link, search outgoing, map incoming.
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
    /// One of the 19 AI-client interface tools (five tiers).
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
    /// Default is vault-on per ADR-015.
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
    /// block so it survives restarts). Default is vault-on per ADR-015.
    public static var vaultEnabled: Bool {
        vaultEnabled(environment: ProcessInfo.processInfo.environment)
    }

    /// The complete advertised tool list.
    ///
    /// Order: tier 1–5 interface tools, then federation, recipe, lens, vault.
    /// Every tool schema is wrapped with `withTeachme` so callers can pass
    /// `teachme: true` on any tool to receive its usage guide.
    ///
    /// Vault tools are omitted when `MOOTX01_VAULT=0` (installed with
    /// `--vault-off`). All other tiers are unaffected. See ADR-015.
    public static func tools() -> [ProjectedTool] {
        tools(environment: ProcessInfo.processInfo.environment)
    }

    /// The complete advertised tool list evaluated against an explicit
    /// environment dictionary. Used by tests that cannot mutate
    /// `ProcessInfo.processInfo.environment` (which is read-only at runtime).
    /// Production code uses `tools()` (no args).
    public static func tools(environment: [String: String]) -> [ProjectedTool] {
        var raw: [ProjectedTool] = []
        raw.append(contentsOf: coreMemoryTools())
        raw.append(contentsOf: connectionTools())
        raw.append(contentsOf: knowledgeGraphTools())
        raw.append(contentsOf: journalTools())
        raw.append(contentsOf: estateTools())
        raw.append(federationTool())
        raw.append(contentsOf: RecipeTools.tools())
        raw.append(contentsOf: LensTools.tools())
        // Vault tools are gated: omitted from tools/list when MOOTX01_VAULT=0.
        // Default (env absent or any value ≠ "0") is vault-on (ADR-015).
        if vaultEnabled(environment: environment) {
            raw.append(contentsOf: VaultTools.tools())
        }
        return raw.map { tool in
            ProjectedTool(
                name: tool.name,
                description: tool.description,
                inputSchema: withTeachme(tool.inputSchema),
                provenance: tool.provenance
            )
        }
    }

    // MARK: - Tier 1: Core Memory (7 tools)

    private static func coreMemoryTools() -> [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_file_memory",
                description: "File a new memory into the estate. Provide the content and a location hint (free-form string describing subject matter). The server chooses structural coordinates and infrastructure fields.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "content": stringSchema("The text content to remember."),
                        "location": stringSchema("Subject-matter location hint (e.g. \"project/alpha\", \"meeting notes\"). Used for retrieval organisation."),
                        "sensitivity": stringSchema("Optional sensitivity: normal (default), elevated, restricted, secret. Omit to use the default; null is invalid."),
                        "exportability": stringSchema("Optional exportability tier at capture time: private (default — not visible to filter:exportable) or public (immediately visible to filter:exportable recall). Use moot_update_memory with mutation=correctExportability(public) to promote an existing private memory. Drawers born public are immediately returned by filter:exportable searches. Omit to use the default; null is invalid."),
                        "kind": stringSchema("Optional content kind: prose (default), code, transcript, list, structuredJSON, imageCaption. Omit to use the default; null is invalid."),
                        "event_time": stringSchema("Optional ISO8601 event time for historical ingestion. Omit for streaming capture (defaults to now); null is invalid."),
                        "impatient": booleanSchema("Optional. When true, the memory is encoded for semantic search INLINE before the write returns, so it is immediately recallable by BM25/vector search at the cost of a slower write. When false (default), the write returns immediately and encoding happens in the background. Omit to use the default; null is invalid."),
                    ],
                    required: ["content", "location"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_memory_search",
                description: "Search the estate for memories matching a query. Uses hybrid BM25+vector recall. Returns ranked memory rows with content and metadata. Best for broad or time-ordered retrieval; use ordering:byRelevanceDesc for relevance-ranked results. Each result includes a discrimination signal (high/medium/low) indicating whether the ranking is trustworthy. Low discrimination on small corpora is expected until the embedding encoder lands (v1.1 planned feature) — in that case prefer moot_recall_precise for precision retrieval.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "query": stringSchema("Natural-language search query."),
                        "limit": integerSchema("Max results to return (default 20). Omit to use the default; null is invalid."),
                        "filter": stringSchema("Optional filter: unconfirmed, userConfirmed, exportable, contained. Omit for ordinary recall: active/trustworthy/elevated-or-lower memories across any confirmation state. null is invalid."),
                        "explain": booleanSchema("Return per-hit explanation blocks when true. Omit to use the default; null is invalid."),
                        "scoring": stringSchema("Scoring strategy: raw, rrf, matrixAware (default). Omit to use the default; null is invalid."),
                        "ordering": stringSchema("Result ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc, byRelevanceDesc. byRelevanceDesc routes to the scored recall pipeline (unionBest) whose results are ranked by relevance score — this is the recommended ordering when relevance matters. Omit to use the default; null is invalid."),
                    ],
                    required: ["query"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_update_memory",
                description: "Apply a named mutation to an existing memory. Belief mutations: confirm, reject, contest, resolve, supersede, revive, accept. Exportability mutations: correctExportability(public) promotes a private memory to public (visible to filter:exportable), correctExportability(private) revokes public status.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "id": stringSchema("Memory row identifier."),
                        "mutation": stringSchema("Mutation kind: confirm, reject, contest, resolve, supersede, revive, accept, correctExportability(public), correctExportability(private)."),
                        "note": stringSchema("Optional free-text note recorded with the mutation."),
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
                description: "Move a memory to a different location within the estate (reanchor).",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "id": stringSchema("Memory row identifier."),
                        "location": stringSchema("New location hint (free-form string; server resolves to structural coordinates)."),
                    ],
                    required: ["id", "location"]
                )),
                provenance: .interface
            ),
        ]
    }

    // MARK: - Tier 2: Connections (3 tools)

    private static func connectionTools() -> [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_link_memories",
                description: "Create a directed connection (tunnel) between two memories. Supports typed relationships.",
                inputSchema: withEstateID(objectSchema(
                    properties: [
                        "from_id": stringSchema("Source memory row identifier."),
                        "to_id": stringSchema("Target memory row identifier."),
                        "kind": stringSchema("Relationship kind: relates, precedes, contradicts, supports, refines, exemplifies, extends."),
                        "label": stringSchema("Optional free-form label for the connection. Defaults to the kind string."),
                    ],
                    required: ["from_id", "to_id", "kind"]
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

    private static func knowledgeGraphTools() -> [ProjectedTool] {
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

    private static func journalTools() -> [ProjectedTool] {
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

    // MARK: - Tier 5: Estate (3 tools) + Maintenance (1 tool)

    private static func estateTools() -> [ProjectedTool] {
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
                description: "Return the estate's structural map: all wings and rooms, with memory counts per location.",
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
                    "requesterEstateID": stringSchema("UUID of the requesting (caller) estate; the grant gate is evaluated against it. Must name an open estate."),
                    "filter": stringSchema("Filter kind: unconfirmed, userConfirmed, exportable, contained. Omit for ordinary recall across any confirmation state. null is invalid."),
                    "limit": integerSchema("Max rows per estate to return. Omit for no explicit cap; null is invalid."),
                    "ordering": stringSchema("Ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc. Omit to use the default; null is invalid."),
                    "hydrationLevel": stringSchema("Hydration: structured (default), full, bitmapOnly. Omit to use the default; null is invalid."),
                ],
                required: ["requesterEstateID"]
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
}
