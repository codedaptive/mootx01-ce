---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-06-05
version: v0.8
package: ARIA_MCP
languages: [swift]   # access surface, implemented in Swift
relates_to:
  - ARIA_MCP_SPEC_v0.2.md  (the behavioral contract; MCP-INT-01 adds §11 AI-client surface)
  - GENIUSLOCUSKIT_SPEC_v0.8.md  (the estate verb surface tools dispatch to)
purpose: |
  Public API surface of ARIA_MCP — the MCP server that exposes
  GeniusLocusKit estates over Model Context Protocol. Documents the JSON-RPC
  transport, the JSONValue wire type, the five-tier AI-client tool surface, the
  multi-estate tool dispatcher, the teachme guide engine, the coaching hint
  engine, and the server loop. Updated by MCP-INT-01 to replace the
  lexicon-projected surface with an AI-client-oriented interface; updated by
  MCP-INT-02 to add per-tool usage guides and coaching hints; updated by
  MCP-INT-03 to add the static protocol block to estate_status and the full
  cognition menu to moot_list_lenses.
  The companion SPEC carries the behavioral contracts.

  TRANSPORT NOTE (v0.2.1 spec correction, 2026-06-07): the types documented
  here — `StdioServer` and the newline-delimited JSON-RPC loop — are the
  *implemented* surface and are the **fallback** transport (PoC, testing,
  migrations). Per ARIA_MCP_SPEC §5/§17 the **primary** mode is the resident
  loopback HTTP MCP server, which is not yet implemented; when it lands it sits
  behind the same `ARIA_MCPDispatcher` (handlers unchanged) and this interface
  gains the HTTP server type alongside `StdioServer`. The resident server also
  hosts the Brain pump (dream trigger) and the telemetry self-report; both are
  documented in the SPEC and wired in the resident executable, not in the
  `AriaMCP` JSON-RPC library.
---

# ARIA_MCP Interface

## § 1 — Package layout

**Swift:** `apps/ARIA_MCP/`

- `Sources/AriaMCP/` — the `AriaMCP` library: JSON-RPC envelope + error
  codes (`JSONRPC.swift`), the `JSONValue` wire type (`JSONValue.swift`),
  OSLog/stderr logging (`Logging.swift`), the server dispatcher + stdio
  loop (`Server.swift`), the five-tier tool projection (`ToolProjection.swift`),
  the estate dispatcher + interface runners (`ToolDispatch.swift`),
  per-tool usage guide strings (`TeachmeGuides.swift`),
  coaching-hint trigger logic (`CoachingEngine.swift`),
  CognitionKit recipe tools (`RecipeTools.swift`), reasoning-lens tools
  (`LensTools.swift`), vault control tools (`VaultTools.swift`).
- `Sources/aria-mcp/` — the `aria-mcp` executable (`AriaMCPMain.swift`):
  opens an estate and runs the stdio loop.
- `Tests/AriaMCPTests/`
- `Package.swift` — depends on GeniusLocusKit, LocusKit, PersistenceKit,
  NeuronKit, CognitionKit (path deps under `../../packages/`).

**Rust:** `apps/ARIA_MCP/rust/` — a wire-contract peer of the Swift server.
The Rust binary is a parity sibling; the shipped runtime is the Swift binary —
the `mootx01` executable target in `installer/Package.swift`, which links the
`AriaMCP` library and runs `mootx01 serve` (the default subcommand on macOS).
The Rust binary
links the same 44-tool surface backed by the Rust kit stack (genius-locus-kit,
locus-kit, vault-kit, cognition-kit, neuron-kit). As of stream t1-vault, all four
`moot_vault_*` tools are wired in the Rust dispatch to the vault-kit crate
(`VaultBridge`, `ObsidianAdapter`, `DrawerMapping`) with a SHA-256 sidecar
manifest owned by the ARIA layer (ADR-VAULTKIT-002 decision b).
Cargo.toml path deps: `vault-kit` (new), `sha2` (new), plus existing kit deps.

This is the external access surface above the substrate; it is not
imported by any other package, so it is documented single-tier (its full
public API) rather than consumed-vs-broader tiers.

## § 2 — Public types

### Transport — JSON-RPC

```swift
public enum JSONRPCErrorCode {
    public static let parseError: Int          // -32700
    public static let invalidRequest: Int      // -32600
    public static let methodNotFound: Int      // -32601
    public static let invalidParams: Int       // -32602
    public static let internalError: Int       // -32603
    public static let toolDispatchFailure: Int // -32010 (server-defined)
}

public struct JSONRPCRequest: Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue?
    public init(jsonrpc: String, id: JSONValue?, method: String, params: JSONValue?)
    public var isNotification: Bool { get }           // id == nil
    public static func decode(_ value: JSONValue) -> JSONRPCRequest?
}

public struct JSONRPCResponse: Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONValue
    public let payload: Payload
    public enum Payload: Sendable, Equatable { case result(JSONValue), error(JSONRPCError) }
    public init(id: JSONValue, payload: Payload)
    public static func ok(_ id: JSONValue, _ result: JSONValue) -> JSONRPCResponse
    public static func failure(_ id: JSONValue, _ error: JSONRPCError) -> JSONRPCResponse
    public var asJSONValue: JSONValue { get }
}

public struct JSONRPCError: Sendable, Equatable, Error {
    public let code: Int
    public let message: String
}
```

### Wire value — `JSONValue`

A hand-rolled JSON value (no Foundation `Codable` on the wire).

```swift
public enum JSONValue: Sendable, Equatable {
    // null / bool / integer / double / string / array / object cases
    public static func from(_ any: Any) throws -> JSONValue        // throws JSONValueError
    public static func parse(_ data: Data) throws -> JSONValue
    public func encoded() throws -> Data
    public var foundationObject: Any { get }
    public var objectValue: [String: JSONValue]? { get }
    public var stringValue: String? { get }
    public var integerValue: Int64? { get }
    public var boolValue: Bool? { get }
    public var arrayValue: [JSONValue]? { get }
}
public enum JSONValueError: Error, Equatable { /* unsupported value, etc. */ }
```

### Tool projection — `ToolProjection` / `ProjectedTool` / `ToolProvenance`

MCP-INT-01 replaced the lexicon-projected surface with a five-tier
AI-client-oriented interface. `ToolProjection.tools()` assembles all
44 tools across four provenance tiers.

```swift
public enum ToolProvenance: Sendable, Equatable {
    case interface     // 19 five-tier AI-client tools
    case federation    // 1 federated-search tool (moot_federated_search)
    case recipe        // 4 recipe + 16 lens tools via CognitionKit/LensTools
    case vault         // 4 vault control tools
}
public struct ProjectedTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let provenance: ToolProvenance
}
public enum ToolProjection {
    public static let toolNamePrefix: String         // "moot_" — product namespace on every tool name
    public static func tools() -> [ProjectedTool]   // all 44 tools (interface+federation+recipe+vault)
    public static func federationTool() -> ProjectedTool
}
```

#### Five-tier AI-client interface (`.interface` provenance, 19 tools)

| Tier | Tools |
|------|-------|
| 1 — Core Memory | `moot_file_memory`, `moot_memory_search`, `moot_update_memory`, `moot_withdraw_memory`, `moot_erase_memory`, `moot_confirm_memory`, `moot_move_memory` |
| 2 — Connections | `moot_link_memories`, `moot_connection_search`, `moot_connection_map` |
| 3 — Knowledge Graph | `moot_file_fact`, `moot_fact_search`, `moot_retire_fact`, `moot_fact_timeline` |
| 4 — Journal | `moot_write_journal`, `moot_read_journal` |
| 5 — Estate | `moot_estate_status`, `moot_estate_map`, `moot_estate_ping` |

All interface tools accept an optional `estateID` (UUID string) to address a
registered non-default estate and an optional `teachme` (boolean) to request a
usage guide instead of executing. Infrastructure fields (`latticeAnchor`,
`embeddingModelID`, `addedBy`, `channel`) are server-owned and never exposed
to AI clients. Required caller fields: `content` + `location` for
`moot_file_memory`; `query` for `moot_memory_search`; `subject`, `predicate`,
`object` for `moot_file_fact`; `entry` for `moot_write_journal` (note: `entry`,
not `content` — mirrors the `DiaryEntry.entry` substrate field); optional `query`
for `moot_fact_search` (substring match across subject, predicate, and object;
omit to return all active facts).

`moot_file_fact` also accepts optional `source_id` — the row identifier of the
drawer this fact was extracted from; omit for agent-asserted freestanding triples.
`filedAt` is server-assigned and immutable; callers cannot supply it. There are no
temporal validity window fields (`valid_from`/`valid_to`) — facts are active until
retired via `moot_retire_fact`, which transitions the adjective state bitmap to
`withdrawn` and removes the fact from active recall.

#### Federation tool (`.federation` provenance, 1 tool)

```swift
ToolDispatcher.federatedSearchToolName   // "moot_federated_search"
```

Fans across locally-open estates the requester is authorized to read.
Required caller field: `requesterEstateID` (UUID string of the requesting estate).

#### Recipe and lens tools (`.recipe` provenance, 20 tools)

- `moot_list_lenses`, `moot_synthesize`, `moot_run_migration`, `moot_confirm_migration`
  (CognitionKit recipe tools)
- 16 `moot_lens_*` tools: `moot_lens_keystones`, `moot_lens_constellation`,
  `moot_lens_free_association`, `moot_lens_theme_weather`, `moot_lens_latent_themes`,
  `moot_lens_bias`, `moot_lens_drift`, `moot_lens_contradiction`,
  `moot_lens_trust_synthesis`, `moot_lens_partial_cue`, `moot_lens_anticipate`,
  `moot_lens_successors`, `moot_lens_overlap`, `moot_lens_divergence`,
  `moot_lens_associations`, `moot_lens_concepts`

#### Vault tools (`.vault` provenance, 4 tools)

`moot_vault_export`, `moot_vault_import`, `moot_vault_status`, `moot_vault_reconcile`

### Session protocol block — `ToolDispatcher.ARIASessionProtocol`

Static string constant appended unconditionally to every
`moot_estate_status` response. Defined in `SessionProtocol.swift` as an
extension on `ToolDispatcher`. Identical across every call and estate state.

```swift
extension ToolDispatcher {
    static let ARIASessionProtocol: String
    // Appended after the stats block in runEstateStatus.
    // Contains the protocol: section with the eight surface-entry hints.
}
```

### Teachme guides — `TeachmeGuides`

Static per-tool usage guides. Called by `ToolDispatcher.dispatch` when
`teachme: true` is present. No instances; no estate access.

```swift
enum TeachmeGuides {
    static func guide(for toolName: String) -> String
    // Per-tool guide for all 19 Tier 1–5 tools and moot_federated_search.
    // moot_estate_status returns the nine-tier orientation guide (MCP-INT-03).
    // Generic guide for lens, recipe, migration, and vault tools.
    // Fallback for unknown names: "Unknown tool '…'. Call moot_estate_status…"
}
```

### Coaching engine — `CoachingEngine`

Inspects completed tool calls and returns a hint string when a suboptimal
call pattern is detected. Called by `ToolDispatcher.dispatch` after the
runner returns, before the result is sent. Nil means no hint warranted.
Hints are never appended to error results (`isError: true`).

```swift
enum CoachingEngine {
    static func hint(
        name: String,
        args: [String: JSONValue],
        resultText: String
    ) -> String?
}
```

Coaching triggers (see SPEC §12 for the full table):
`moot_memory_search` — long query, no query, zero results;
`moot_file_memory` — content over 4000 chars, duplicate content;
`moot_erase_memory` — confirmed absent or false;
`moot_confirm_migration` — disqualified branch;
`moot_link_memories` — IDs not found;
any lens tool — zero results.

### Dispatch — `ToolDispatcher`

Routes a `tools/call` against one or more locally-open GeniusLocusKit
estates (by optional `estateID`; absent ⇒ default). Dispatch order:
teachme pre-check → federation → recipe → lens → vault → interface →
methodNotFound → hint injection.

```swift
public struct ToolDispatcher: Sendable {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle
    public init(kit: GeniusLocusKit, handle: EstateHandle)
    public func registering(_ additional: EstateHandle) -> ToolDispatcher   // value-semantic add
    public func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue
    public static let federatedSearchToolName: String   // "moot_federated_search"
    public static func textResult(_ text: String) -> JSONValue   // MCP success, isError:false
    public static func errorResult(_ text: String) -> JSONValue  // MCP result, isError:true
}
```

### Server — `ARIA_MCPDispatcher` / `StdioServer`

The method router and the newline-delimited stdio loop.

```swift
public struct ARIA_MCPDispatcher: Sendable {
    public struct ServerInfo: Sendable { public let name: String; public let version: String
                                         public init(name: String, version: String) }
    public let info: ServerInfo
    public let tools: [ProjectedTool]
    public let tooling: ToolDispatcher
    public init(info: ServerInfo, tooling: ToolDispatcher)
    // Handles initialize / ping / tools/list / tools/call; nil for notifications.
    public func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse?
}

public struct StdioServer {
    public let dispatcher: ARIA_MCPDispatcher
    public init(dispatcher: ARIA_MCPDispatcher)
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async
    public func handleFrame(_ frame: Data, output: FileHandle) async
    public func write(_ response: JSONRPCResponse, to output: FileHandle)
}
```

### Logging

```swift
public enum Logging {
    public static let osLog: Logger          // subsystem "com.mootx01.kit", category "AriaMCP"
    public static let stderr: StderrLogger
}
public struct StderrLogger: Sendable { public init(); public func log(_ message: String) }
```

## § 3 — Public functions

MCP methods are routed by `ARIA_MCPDispatcher.handle(_:)`:
`initialize` (echoes `protocolVersion`, advertises the `tools`
capability), `ping`, `tools/list` (from `ToolProjection.tools()`),
`tools/call` (→ `ToolDispatcher.dispatch(name:arguments:)`). The
`aria-mcp` executable wires a `GeniusLocusKit` estate into a
`ToolDispatcher`, builds an `ARIA_MCPDispatcher`, and runs
`StdioServer.run()`. Behavioral contracts: SPEC.

## § 4 — Errors

```swift
public struct JSONRPCError: Sendable, Equatable, Error { public let code: Int; public let message: String }
public enum JSONValueError: Error, Equatable
```
Out-of-band conditions (unknown tool, malformed arguments, unknown
`estateID`) surface as JSON-RPC errors; substrate refusals
(`VerbError`, `GeniusLocusKitError`) come back as `tools/call` results
with `isError: true` so the client keeps the call id. See SPEC § 6.

## § 5 — Conformance test entry points

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path apps/ARIA_MCP
```

(Targets: `AriaMCPTests` — JSON-RPC, stdio framing, server, five-tier
tool projection, connection dispatch, file-memory validation, KG and
journal dispatch, multi-estate routing, recipe/lens tools, vault tools,
teachme guides and coaching hints.)

```
cargo test --manifest-path apps/ARIA_MCP/rust/Cargo.toml
```

(Rust test targets: `dispatch_tests` — 52 tests including 6 vault dispatch
integration tests: missing-vaultPath INVALID_PARAMS, status-no-manifest,
export-stamps-manifest, export-then-import, reconcile-no-manifest,
reconcile-zero-drift. `jsonrpc_tests`, `persistence_tests`,
`stdio_framing_tests`.)

## § 6 — Examples

```swift
import AriaMCP
import GeniusLocusKit

let dispatcher = ARIA_MCPDispatcher(
    info: .init(name: "aria-mcp", version: "0.8"),
    tooling: ToolDispatcher(kit: kit, handle: estate)
)
await StdioServer(dispatcher: dispatcher).run()   // newline-delimited JSON-RPC over stdio
```

---

*End of ARIA_MCP Interface v0.8. Updated 2026-06-05 by MCP-INT-01 to document the five-tier AI-client surface; updated 2026-06-05 by MCP-INT-02 to add TeachmeGuides, CoachingEngine, and the teachme/hint dispatch protocol; updated 2026-06-05 by MCP-INT-03 to add ARIASessionProtocol, the static protocol block on estate_status, and the full cognition menu on moot_list_lenses.*
