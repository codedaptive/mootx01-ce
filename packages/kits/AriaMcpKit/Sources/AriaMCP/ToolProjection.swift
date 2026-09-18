import AriaMCPWire

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
/// - **Tier 5 — Estate (10):** status, map, ping, plus monitoring and the
///   maintenance family (reindex, drain_status, reclassify_fdc,
///   timing_report; palace_import + json_import vault-gated). Estate-level
///   inspection and maintenance.
///
/// Non-tier tools (federation, recipe, lens, vault, dataset) are
/// appended after the five tiers.
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
    /// A community-contract tool (Wave A1b: moot_community_* namespace).
    /// These tools are dispatched through CommunityToolHandler rather than
    /// through ToolDispatcher; no GeniusLocusKit actor is required.
    case community
    /// A tool supplied by an authenticated product attached to the resident
    /// daemon. Product tools are never present on the ordinary HTTP lane.
    case product
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
    /// JSON Schema for the tool's `structuredContent` result payload,
    /// advertised in `tools/list` as `outputSchema` (the MCP-sanctioned
    /// structured-result mechanism). `nil` for text-only tools — the key
    /// is then omitted from the wire entry entirely, so tools that never
    /// declared a schema are byte-identical to before this field existed.
    public let outputSchema: JSONValue?
    /// Optional MCP execution hints. V1 projections leave this absent so their
    /// wire representation remains unchanged; the selected v2 registry derives
    /// it from the operation's stable identity and declared effect.
    public let annotations: JSONValue?

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        provenance: ToolProvenance,
        outputSchema: JSONValue? = nil,
        annotations: JSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.provenance = provenance
        self.outputSchema = outputSchema
        self.annotations = annotations
    }
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

    /// True when the Apple subject rider should auto-enable at serve
    /// (rider-default ruling, 2026-08-02: ON by default). Any value of
    /// `MOOTX01_SUBJECT_RIDER` other than the literal "0" — including
    /// absent — means on; `mootx01 install --subject-rider-off` writes
    /// the "0" into the daemon's launchd env (the MOOTX01_VAULT
    /// pattern). The rider still requires the on-device model: the
    /// serve layer tolerates unavailability and continues.
    public static func subjectRiderEnabled(environment: [String: String]) -> Bool {
        environment["MOOTX01_SUBJECT_RIDER"] != "0"
    }

    public static var subjectRiderEnabled: Bool {
        subjectRiderEnabled(environment: ProcessInfo.processInfo.environment)
    }

    /// The complete advertised tool list.
    ///
    /// Order: tier 1–5 interface tools, then federation, recipe, lens, vault.
    /// Every tool schema carries the v2 input schema defined in the ARIA v2 catalog.
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
        // The v2 catalog contains only operations whose typed handlers are
        // executable in this build. The memory_20250818 adapter is appended
        // when the opt-in flag is present; it is classified per-command in
        // ToolMutationInventory.frozenReadCommands rather than by tool name.
        var result = AriaV2SelectedCatalog.registry(environment: environment).projectedTools
        if memoryToolEnabled(environment: environment) {
            result += memoryAdapterTools()
        }
        return result
    }

    // MARK: - Anthropic memory_20250818 adapter (M-MEMTOOL-1)

    private static func memoryAdapterTools() -> [ProjectedTool] {
        [memoryTool()]
    }

    // MARK: - Schema helpers

    /// Inject an optional `mode` property into an object schema.
    ///
    /// Applied to every tool in `tools()` so the `mode` argument is
    /// advertised in every tool's inputSchema and recognized by
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

    /// Array-of-strings schema (PR-03: the memory_get `ids` batch arg).
    static func arraySchema(_ description: String, itemDescription: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object([
                "type": .string("string"),
                "description": .string(itemDescription),
            ]),
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

    /// Whether a public name is callable in this binary's selected surface.
    /// The v2 surface has no hidden routes: a name is dispatchable only if the
    /// v2 catalog advertises it.
    static func admitsDispatch(name: String, environment: [String: String]) -> Bool {
        tools(environment: environment).contains(where: { $0.name == name })
    }
}
