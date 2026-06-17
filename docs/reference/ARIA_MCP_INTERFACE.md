---
title: aria-mcp Interface
version: 1.3.0
status: active
date: 2026-06-17
description: Public API surface for aria-mcp in both the Swift and Rust ports.
spec_type: protocol
authors: MOOTx01 maintainers
relates_to:
  - ARIA_MCP_SPEC.md  (the behavioral contract; §11 covers the AI-client surface)
  - GENIUSLOCUSKIT_SPEC.md  (the estate verb surface tools dispatch to)
purpose: |
  Public API surface of aria-mcp — the MCP server that exposes
  GeniusLocusKit estates over Model Context Protocol. Documents the JSON-RPC
  transport, the JSONValue wire type, the five-tier AI-client tool surface, the
  multi-estate tool dispatcher, the teachme guide engine, the coaching hint
  engine, and the server loop. The interface provides an AI-client-oriented
  tool surface, per-tool usage guides and coaching hints, a static protocol
  block on estate_status, and the full cognition menu on moot_list_lenses.
  The companion SPEC carries the behavioral contracts.

  TRANSPORT NOTE: two transports are implemented behind the same
  `AriaMcpDispatcher`.
  **Fallback:** `StdioServer` + the newline-delimited JSON-RPC loop (PoC,
  testing, migrations). **Primary:** `HTTPServer`
  (`Sources/AriaMCP/HTTPServer.swift`; Rust `rust/src/http_server.rs`) — a
  loopback Streamable-HTTP transport (POST JSON-RPC → `application/json`)
  bound to `127.0.0.1`, selected when `MOOTX01_HTTP_PORT` is set (default
  4242; `AriaMCPMain`/`main.rs` branch), with a per-request body cap from
  `MOOTX01_HTTP_MAX_BODY_BYTES` (default 4 MiB). It consumes the shared
  `LoopbackHTTP` lib (Swift) / hand-rolled `std::net` (Rust), wire-identical
  across both. SSE server-push (`LoopbackHTTP.SSEStream`) is ready but unused
  until there are notifications to push (autonomic governor phase). Still
  pending: the resident autonomic governor (dream trigger) and telemetry
  self-report, and launchd resident-mode wiring — documented in the SPEC,
  wired in the resident executable, not in the `AriaMcpKit` JSON-RPC library.
---

# aria-mcp Interface

## § 1 — Package layout

**Swift:** `packages/kits/AriaMcpKit/`

- `Sources/AriaMCP/` — the `AriaMCP` library: JSON-RPC envelope + error
  codes (`JSONRPC.swift`), the `JSONValue` wire type (`JSONValue.swift`),
  OSLog/stderr logging (`Logging.swift`), the server dispatcher + stdio
  loop (`Server.swift`), the loopback HTTP transport (`HTTPServer.swift`,
  consuming `LoopbackHTTP`), the resident autonomic governor (`BrainPump.swift`),
  the five-tier tool projection (`ToolProjection.swift`),
  the estate dispatcher + interface runners (`ToolDispatch.swift`),
  per-tool usage guide strings (`TeachmeGuides.swift`),
  coaching-hint trigger logic (`CoachingEngine.swift`),
  CognitionKit recipe tools (`RecipeTools.swift`), reasoning-lens tools
  (`LensTools.swift`), vault control tools (`VaultTools.swift`).
- `Sources/aria-mcp/` — the `aria-mcp` executable (`AriaMCPMain.swift`):
  opens an estate and runs the selected transport — stdio by default, the
  resident loopback HTTP transport when `MOOTX01_HTTP_PORT` is set.
- `Tests/AriaMCPTests/`
- `Package.swift` — depends on GeniusLocusKit, LocusKit, PersistenceKit,
  NeuronKit, CognitionKit (path deps under `../../packages/`).

**Rust:** `packages/kits/AriaMcpKit/rust/` — a wire-contract peer of the Swift server.
The Rust binary is a parity sibling; the shipped runtime is the Swift binary —
the `mootx01` executable target in `apps/mootx01/Package.swift`, which links the
`AriaMCP` library and runs `mootx01 serve` (the default subcommand on macOS).
The Rust binary
links the same 55-tool surface backed by the Rust kit stack (genius-locus-kit,
locus-kit, vault-kit, cognition-kit, neuron-kit). All five
`moot_vault_*` tools are wired in the Rust dispatch to the vault-kit crate
(`VaultBridge`, `ObsidianAdapter`, `DrawerMapping`) with a SHA-256 sidecar
manifest owned by the ARIA layer. The fifth vault
tool, `moot_vault_job`, exists for tool-surface parity: the Rust backend is
synchronous, so the tool returns completed-job
records from an in-process `VaultJobLedger` (bounded to 100 entries).
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

The lexicon-projected surface was replaced with a five-tier
AI-client-oriented interface. `ToolProjection.tools()` assembles all
55 tools across four provenance tiers (plus the maintenance tool `moot_reindex`).

```swift
public enum ToolProvenance: Sendable, Equatable {
    case interface     // 19 five-tier AI-client tools
    case federation    // 1 federated-search tool (moot_federated_search)
    case recipe        // 8 recipe + 21 lens tools via CognitionKit/LensTools
    case vault         // 5 vault control tools (export, import, status, reconcile, job)
}
public struct ProjectedTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let provenance: ToolProvenance
}
public enum ToolProjection {
    public static let toolNamePrefix: String         // "moot_" — product namespace on every tool name
    public static func tools() -> [ProjectedTool]   // all 55 tools (interface+federation+recipe+lens+vault+maintenance)
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

Optional MCP arguments use an omit-to-default contract. If a caller wants the
default, it omits the key entirely. A present key with JSON `null` is invalid
for semantic knobs such as `estateID`, `teachme`, `filter`, `limit`, `scoring`,
`ordering`, `sensitivity`, `exportability`, `kind`, `impatient`, `agent`, and
similar optional primitive fields. This keeps AI clients from forcing the server
to guess whether `null` meant "default", "unset", or a bug in the caller.

`moot_file_memory` also accepts an optional `impatient: bool` (default `false`)
— the Dual-Path Intake write-mode execution option. It is an option on the
write verb (threaded MCP arg → GLK verb param `mode`), NOT a `CaptureFrame`
field; it mirrors how `scoring` is an option on `moot_memory_search`. When
`true`, the memory is encoded for semantic search (chunk + BM25 + embed) INLINE
before the write returns, so it is immediately recallable by the BM25/vector
lanes — at the cost of a slower write. When `false` (default), the write returns
as soon as the drawer row lands and encoding happens asynchronously: in the
Swift resident, the estate's dedicated background drain Task (EncodeIntake P4,
15 ms poll cadence) ingests it; in the Rust resident, the Autonomic Governor
tick (default 5 000 ms, override via `MOOTX01_BRAIN_TICK_MS`) drives
`drain_encode_queue_once`. The content becomes semantically searchable once
that drain fires. Before this wiring, normally-captured content was found only
via the Locus structured lane — the BM25/vector lanes were dark for it.

`moot_memory_search` response always includes a `recall_provenance:` status line
as the final line of the text payload. The line carries two space-separated tokens:

- `dense_lane:<status>` — whether the dense float lane (Lane D) contributed to
  ranking. `dense_lane:active` means Lane D ran and returned hits;
  `dense_lane:dark:<reason>` means it did not (the reason matches the
  `GLKRecallResult.denseLaneStatus` vocabulary: `providerOptOut`, `noFloatRows`,
  `storeError`, `emptyQuery`). The default provider is `deterministic` (FNV-1a
  tokenization + FloatSimHash projection — permanent federation-grade vector,
  surface/lexical signal). The v1.1 learned semantic lane (MiniLM/MPNet/Gemma)
  is additive; when wired it contributes a richer signal but does not replace
  the deterministic lane. Callers use `dense_lane` to distinguish a result that
  included vector scoring from a structural/BM25-only result.

- `degraded_stages:<list>` — pipeline stages that encountered a recoverable error
  and were skipped. `degraded_stages:none` means every stage succeeded (happy
  path). A non-none value lists stage names separated by commas inside brackets,
  e.g. `degraded_stages:[vectorHamming.findNearest,corpus.embed]`. Stage names
  mirror the `GLKRecallResult.degradedStages` vocabulary.

The `recall_provenance:` line is always present — it is not conditional on hit
count, lane state, or error condition. The format is identical in both the Swift
and Rust dispatch ports.

`moot_memory_search` accepts an optional `scoring` argument with valid values
`raw`, `rrf`, and `matrixAware`. **Decode is fail-closed:** an absent
`scoring` keeps the documented default `matrixAware`; `scoring: null`, a
non-string value, or an unknown string returns `invalidParams` rather than
silently coercing to `matrixAware` (which would run a different scoring mode
than the caller asked and hide a typo). This mirrors the strict `ordering`
decode. Identical in both ports (`runMemorySearch` / `decode in
run_memory_search`).

`moot_memory_search` accepts an optional `filter` argument with valid values
`unconfirmed`, `userConfirmed`, `exportable`, and `contained` (lenses/recipes
also accept `currentlyBelieve`). Omitting `filter` means ordinary recall:
LocusKit applies the state/trust/sensitivity defaults (`currentlyBelieve`,
`trustworthy`, `sensitivityAtMost(.elevated)`) but does **not** add a
confirmation filter. Fresh unconfirmed captures are therefore recallable by
default. Callers that want only retention/user-vouched rows must explicitly send
`filter: "userConfirmed"`; callers that want only public/exportable rows must
explicitly send `filter: "exportable"`. `filter: null`, non-string filters, and
unknown strings return `invalidParams`.

`moot_file_fact` also accepts optional `source_id` — the row identifier of the
drawer this fact was extracted from; omit for agent-asserted freestanding triples.
`filedAt` is server-assigned and immutable; callers cannot supply it. There are no
temporal validity window fields (`valid_from`/`valid_to`) — facts are active until
retired via `moot_retire_fact`, which transitions the adjective state bitmap to
`withdrawn` and removes the fact from active recall.

`moot_fact_timeline` returns ALL facts ever filed — active and retired — in
`filedAt` ascending order. Each row's lifecycle tag is derived from the canonical
`RowStateAutomaton` cluster, not a raw-value boundary: the state raw in bits 0–5
of `adjective_bitmap` (`adjective_bitmap & 0x3F`) is classified by
`RowState.cluster` / `RowState.cluster(ofRawState:)` using the substrate's
`cluster(s) = (s>>4)&0x3` partition. Cluster A (active, pending, contested,
accepted) tags as `active`; Cluster B (superseded, decayed, withdrawn, expired)
and Cluster C (rejected, tombstoned) tag as `retired(B)` / `retired(C)`. A state
raw that is not one of the ten defined states tags as
`unknown(<raw>)`. Optional `entity` parameter (string) filters results to facts
whose `subject` or `object` contains the given value (case-insensitive substring
match). Rows are capped at 200. Output format:
`<ISO8601>  <lifecycle>  <id>  [<subject>] <predicate> [<object>]`. This tool is
distinct from `moot_fact_search`, which returns active-only facts and is not
affected by this change.

Both the Swift and Rust dispatch ports implement identical semantics: the same
`entity` filter parameter, the same lifecycle tags, the same ISO8601 timestamps,
the same 200-row cap, and the same `retired(<cluster>)` format for retired facts.

#### Federation tool (`.federation` provenance, 1 tool)

```swift
ToolDispatcher.federatedSearchToolName   // "moot_federated_search"
```

Fans across locally-open estates the requester is authorized to read.
Required caller field: `requesterEstateID` (UUID string of the requesting estate).

#### Recipe and lens tools (`.recipe` provenance, 29 tools)

The `.recipe` provenance bucket holds 29 tools: 8 CognitionKit recipe tools plus
the 21 reasoning-lens tools below.

- `moot_list_lenses`, `moot_list_recipes`, `moot_synthesize`, `moot_recall_precise`,
  `moot_recall_shaped`, `moot_run_migration`, `moot_confirm_migration`, `moot_dream`
  (8 CognitionKit recipe tools)
  - `moot_list_recipes` — browse the full recipe catalog: name, version, description,
    required capabilities per entry. No estate args required.
  - `moot_recall_precise` — coarse-grab a generous candidate pool then re-rank by
    query-specific precision (distinctive number/proper-noun match) to surface the
    exact answer above near-duplicates. Returns the same shape as `moot_memory_search`.
  - `moot_recall_shaped` — run recall with a named `RecallShape` preset applied
    (one preset from the GLK roster, picked by name) that forwards, excludes,
    suppresses, or inverts individual fusion lanes and bounds the candidate
    frontier. The discoverable `preset` enum lists the roster; `balanced` (or an
    omitted preset) is the unsteered default; an unknown preset is rejected. The
    four ARIA filtering adjectives compose orthogonally (the preset ranks, the
    `filter` arg filters). Returns the same shape as `moot_memory_search`.
  - `moot_dream` — rebuild the co-occurrence/temporal matrix tier (the Brain's
    association layer the matrix recall lane scores against) and run one dreaming
    cycle (latent-alignment proposals + cycle diary). The matrix is built by
    dreaming, not by capture, so a freshly-loaded estate has an empty matrix until
    this runs. Returns a cycle summary.
- 21 `moot_lens_*` tools: `moot_lens_keystones`, `moot_lens_constellation`,
  `moot_lens_free_association`, `moot_lens_theme_weather`, `moot_lens_latent_themes`,
  `moot_lens_bias`, `moot_lens_drift`, `moot_lens_contradiction`,
  `moot_lens_trust_synthesis`, `moot_lens_partial_cue`, `moot_lens_anticipate`,
  `moot_lens_successors`, `moot_lens_overlap`, `moot_lens_divergence`,
  `moot_lens_associations`, `moot_lens_concepts`,
  `moot_lens_apriori`, `moot_lens_moment`, `moot_lens_rhythm`,
  `moot_lens_precedence`, `moot_lens_complexity`

**Advanced lens tools:**

- `moot_lens_apriori` — mine multi-antecedent Apriori association rules from bitmap
  fingerprints. Optional: `minSupport`, `minConfidence`, `minLift` (floats), `maxK` (int).
  Returns `apriori_rules: N rule(s)` with antecedent/consequent as `field:value` pairs,
  support, confidence, and lift per rule.

- `moot_lens_moment` — OR-reduce the primary window's fingerprints into a temporal
  signature and rank comparison windows by Hamming proximity.
  Required: `windowStart`, `windowEnd` (ISO8601 strings).
  Optional: `comparisonWindows` (array of `{windowStart, windowEnd}` objects).
  Returns `moment: N fingerprint(s), N comparison(s) ranked` with Hamming distances.

- `moot_lens_rhythm` — FFT over a time-bucketed fingerprint bit series to surface
  dominant periodic activity patterns.
  Required: `bit` (int 0–255), `bucketSeconds` (int), `bucketCount` (int),
  `endingAt` (ISO8601). Optional: `topK` (int, default 3).
  Returns `rhythm (bucketCount=N): period=Xs magnitude=Y` per dominant period.

- `moot_lens_precedence` — fold the estate's audit trail into T-matrix deltas and rank
  antecedents most predictive of a target field-value coordinate.
  Required: `windowStart`, `windowEnd` (ISO8601), `targetField` (e.g. `"room"`),
  `targetValue` (e.g. `"string:study"`). Optional: `k` (int, default 5).
  Returns `precedence (entryCount=N): field=value lag=Xmin count=N` per antecedent.

- `moot_lens_complexity` — Shannon entropy (and optional mutual information) over the
  distribution of a label field across the recalled set.
  Required: `fieldA` (label field: `room`, `wing`, `addedBy`, `embeddingModelID`).
  Optional: `fieldB` (second field for mutual information), `filter`.
  Returns `complexity: totalCount=N, entropyA=X` and optionally entropyB, mutualInformation.

#### Vault tools (`.vault` provenance, 5 tools)

`moot_vault_export`, `moot_vault_import`, `moot_vault_status`, `moot_vault_reconcile`,
`moot_vault_job`

`moot_vault_job` — poll the status and result of a vault job by ID. Required:
`job_id` (string, returned by `moot_vault_import` or `moot_vault_export`). Returns
status (`running` / `complete` / `failed`), `elapsed_s`, and on completion the
result counts (import: `drawersWritten`, `drawersUpdated`, `itemsSkipped`,
`tunnelsCreated`, `fdcClassified`, `fdcUnclassified`; export: `noteCount`,
`exportedAt`) or an error description. Unknown `job_id` returns an error result
(`isError:true`) with text `"unknown job_id: <id>"`. The Rust backend records
completed jobs in a bounded in-process `VaultJobLedger` (last 100 jobs) — jobs
are always `complete` when polled because the Rust vault ops are synchronous.

### `moot_estate_status` — sync field vocabulary

The `moot_estate_status` response includes a `sync:` field on its own line
reporting the real ConvergenceKit backend state. The field is always present.
The vocabulary is identical in both the Swift port (`runEstateStatus` in
`ToolDispatch.swift`) and the Rust port (`run_estate_status` in
`interface_tools.rs`).

**Vocabulary table** — tokens are literal strings, not format strings:

| Backend | State | Token |
|---------|-------|-------|
| — (no engine registered) | — | `local-only` |
| None (NoSyncEngine) | disabled | `none (idle)` |
| None (NoSyncEngine) | enabled | `none (enabled, zone: <zone>)` |
| None (NoSyncEngine) | syncing | `none (syncing, direction: <d>)` |
| None (NoSyncEngine) | error | `none (error: <e>)` |
| CloudKit | disabled | `cloudkit (idle)` |
| CloudKit | enabled | `cloudkit (enabled, zone: <zone>)` |
| CloudKit | syncing | `cloudkit (syncing, direction: <d>)` |
| CloudKit | error | `cloudkit (error: <e>)` |
| Federation | disabled | `federation (idle)` |
| Federation | enabled | `federation (in-process, zone: <zone>)` |
| Federation | syncing | `federation (syncing, direction: <d>)` |
| Federation | error | `federation (error: <e>)` |

**Rules:**
- The token `"connected"` is **never** valid. If you see it, the code is stale.
- The field key is `sync:`, not `status:`. The fabricated `status: connected`
  literal must not appear in any response.
- Federation v1.0 is in-process (no network transport). The `enabled` token
  therefore says `in-process`, not `connected`, to accurately describe the
  transport topology.
- When no engine is registered (the default for all v1.0 deployments), the
  token is `local-only` — the estate operates locally with no sync backend.
- Both ports read from `GeniusLocusKit.syncStateToken(for:)` (Swift) /
  `EstateCoordinator.sync_state_token(handle)` (Rust). The accessor path is
  ARIA → GLK → ConvergenceKit; no layering inversion.

**`trace_rows:` field — fail-closed read:** the `moot_estate_status`
response includes a `trace_rows:` line reporting the reward-pipeline read-log
depth. On a successful read it is the integer count. On a `countRecallTraces`
read **failure** the field reads the literal token `unavailable` — NOT a
fabricated `0`, which would be indistinguishable from a genuinely empty trace
table and would lie about reward-pipeline depth. The read failure does not
break the rest of the status response (the other fields are still returned).
Both ports identical (`runEstateStatus`, `run_estate_status`).

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
    // moot_estate_status returns the nine-tier orientation guide.
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

### Server — `AriaMcpDispatcher` / `StdioServer` / `HTTPServer`

The transport-neutral method router and the two transports that drive it: the
newline-delimited stdio loop and the loopback HTTP (Streamable-HTTP) transport.

```swift
public struct AriaMcpDispatcher: Sendable {
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
    public let dispatcher: AriaMcpDispatcher
    public init(dispatcher: AriaMcpDispatcher)
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async
    public func handleFrame(_ frame: Data, output: FileHandle) async
    public func write(_ response: JSONRPCResponse, to output: FileHandle)
}

// Loopback Streamable-HTTP transport (v1.0). POST JSON-RPC -> application/json
// via the same dispatcher; loopback-only bind; no auth (CE) but a CSRF/DNS-rebinding
// Origin guard (non-loopback Origin -> 403). Rust mirror: rust/src/http_server.rs.
public struct HTTPServer: Sendable {
    public let dispatcher: AriaMcpDispatcher
    public let port: UInt16            // default 4242; 0 = OS-assigned (tests)
    public let maxBodyBytes: Int       // default 4 MiB
    public init(dispatcher: AriaMcpDispatcher, port: UInt16 = 4242, maxBodyBytes: Int = 4 * 1024 * 1024)
    public func run() async throws     // resident; returns only on bind failure
    public func bind() throws -> (fd: Int32, port: UInt16)   // bind without accepting (tests)
}

// Resident autonomic governor. Drives dreaming + maintenance (NeuronKit) and
// the standing-signal scheduler (GLK) on each daemon's own cadence; `now` is
// injected once per tick (the loop is the only scheduler; daemons never read the
// clock). Spawned alongside HTTPServer in resident mode; stdio does not pump.
// In-memory cadence policy in P2 (manifest store is P3). Base tick env
// MOOTX01_BRAIN_TICK_MS (default 5000ms).
public actor BrainPump {
    public init(kit: GeniusLocusKit, handle: EstateHandle,
                baseTickMs: Int = 5000, clock: @escaping @Sendable () -> Date = { Date() })
    public func run() async                 // loops until the task is cancelled (shutdown)
    public struct TickReport: Sendable {
        public let dreamingFired: Bool; public let maintenanceFired: Bool; public let signalsTicked: Bool
    }
    @discardableResult public func tick(now: Date) async -> TickReport   // one iteration (tests)
}
```

#### Rust governor — standing-signal harness

The Rust `AutonomicGovernor` (`rust/src/autonomic_governor.rs`) OWNS this
estate's standing-signal scheduler (a GLK `SerialLaneScheduler<CoordinatorDispatcher>`)
and ticks it each iteration, mirroring the Swift governor's
`kit.signalTick(in:handle:now:)`. The scheduler lives in the governor (not the
GLK coordinator) because the production dispatcher holds an
`Arc<Mutex<EstateCoordinator>>`; a coordinator-owned scheduler would close a
reference cycle. The scheduler drives propose/associate/diagnostic emissions
only; the recall-cache PRODUCERS are governor DUTIES (the scheduler emission model
cannot register a cache). The graph-centrality producer duty
(`graph_centrality_duty`, fired on a cadence inside `tick`) reads the estate
structure graph, computes per-drawer eigenvalue centrality via
`neuron_kit::keystones`, and registers a `GraphCache` on the coordinator —
`GovernorReport` gains `pub graph_centrality_fired: bool`. The Swift mirror is
`AutonomicGovernor.graphCentralityScan` with `GovernorReport.graphCentralityFired`.
The standing-signal registration methods remain the scheduler seam:

```rust
impl AutonomicGovernor {
    // Register the architecture-spec §11.2 default standing signals. Reads the
    // live VectorStore via EstateCoordinator::vector_store_for; returns Err when
    // none is registered so the caller log-and-skips (no fabricated store).
    // model_id matches the Swift resident default ("minilm-v6").
    pub fn register_default_standing_signals(
        &mut self, model_id: impl Into<String>, now: SystemTime,
    ) -> Result<Vec<(String, SchedulerSignalID)>, String>;
    // Register one custom signal; lazily mints the scheduler on first call.
    pub fn register_standing_signal(
        &mut self, spec: SchedulerSignalSpec, now: SystemTime,
    ) -> SchedulerSignalID;
    pub fn signal_status(&self) -> Vec<SchedulerSignalReport>;   // empty when no scheduler
    pub fn open_signal_count(&self) -> usize;                    // 0 when no scheduler
    pub fn signal_request_fire(                                  // event/condition triggers
        &mut self, id: &SchedulerSignalID, now: SystemTime,
    ) -> Result<(), SchedulerError>;
}
// GovernorReport gains `pub signals_ticked: bool` — true once a scheduler is
// registered and ticks; false on the benign no-scheduler skip (parity with the
// Swift TickReport.signalsTicked). The resident HTTP bootstrap (rust/src/runtime.rs)
// calls register_default_standing_signals once at startup; stdio mode does not.
```
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

MCP methods are routed by `AriaMcpDispatcher.handle(_:)`:
`initialize` (echoes `protocolVersion`, advertises the `tools`
capability), `ping`, `tools/list` (from `ToolProjection.tools()`),
`tools/call` (→ `ToolDispatcher.dispatch(name:arguments:)`). The
`aria-mcp` executable wires a `GeniusLocusKit` estate into a
`ToolDispatcher`, builds an `AriaMcpDispatcher`, and runs the selected
transport: `StdioServer.run()` by default, or `HTTPServer.run()` when
`MOOTX01_HTTP_PORT` is set. Behavioral contracts: SPEC.

## § 4 — Errors

```swift
public struct JSONRPCError: Sendable, Equatable, Error { public let code: Int; public let message: String }
public enum JSONValueError: Error, Equatable
```
Out-of-band conditions (unknown tool, malformed arguments, unknown
`estateID`) surface as JSON-RPC errors; substrate refusals
(`VerbError`, `GeniusLocusKitError`) come back as `tools/call` results
with `isError: true` so the client keeps the call id. See SPEC § 6.

## § 4.5 — Side-channel GET endpoints (HTTP transport only)

Three read-only GET endpoints are available on both the Swift and Rust HTTP
transports. They share the CSRF/DNS-rebinding Origin guard. The stdio transport
does not expose these endpoints. See SPEC §18 for behavioral contracts.

```
GET /api/graph
GET /api/lattice
GET /api/admin/estates
```

### Swift

Implemented as `latticeSnapshot(dispatcher:)`, `graphSnapshot(dispatcher:estate:)`,
and `adminEstatesSnapshot(dispatcher:)` in `HTTPServer.swift`, called from the
`route(_:)` function before the POST guard.

### Rust

Implemented as `get_lattice_snapshot`, `get_graph_snapshot`, and
`get_admin_estates_snapshot` in `rust/src/http_server.rs`, called from `route()`
before the POST guard. Both ports access `EstateRegistry.default.store` directly
via `all_drawers()` and `all_tunnels()` (synchronous in Rust; async via LocusEstate
in Swift).

### Request shape

All three endpoints accept `GET <path> HTTP/1.1` with no body. Query strings are
stripped from the path before routing; no query parameters are consumed.

### Response shapes

**`GET /api/graph` → 200 `application/json`**
```json
{
  "nodes": [
    { "id": "string (drawer UUID)",
      "nounType": 0,
      "communityId": 3,
      "centrality": 0.42,
      "anomaly": false,
      "lastActiveTs": "ISO8601",
      "createdTs": "ISO8601",
      "tombstonedTs": "ISO8601 | null" }
  ],
  "edges": [
    { "source": "string (drawer UUID)",
      "target": "string (drawer UUID)",
      "edgeType": "tunnel | kgFact | lattice",
      "weight": 1.0,
      "decayedWeight": 1.0,
      "createdTs": "ISO8601 | null",
      "tombstonedTs": "ISO8601 | null" }
  ],
  "structurePending": false,
  "communities": [
    { "id": 3, "size": 17, "dominantUdcCode": "652" }
  ],
  "generatedTs": "ISO8601"
}
```
Serving model: the handler reads the materialized topology snapshot from
`topology_snapshots` in the ObserverSink stats store (one row per estate,
written by the autonomic governor on its cadence). Target latency <50 ms
(SQLite read). `structurePending: true` (with empty `nodes`/`edges`/
`communities`) is returned before the governor's first duty cycle completes —
the honest pending state, not a fallback compute. No inline compute path exists.
`generatedTs` carries the ISO-8601 instant the governor produced the snapshot.
Tombstoned drawers and tunnels ARE included in the stored payload, carrying
`tombstonedTs` (alive entities carry an explicit `null`); all Louvain/centrality
math in the governor runs over live entities only. kgFact edges (shared-subject
bonds, weight 0.3) ship with null timestamps. Full field semantics:
ARIA_MCP_SPEC.md § response shapes;
analysis contract: NEURONKIT_SPEC.md § TOPOLOGY_ANALYSIS.

**`GET /api/lattice` → 200 `application/json`**
```json
{
  "addresses": [
    { "code": "string (UDC/MDCC code)", "count": 3 }
  ]
}
```
Sorted by `count` descending; ties broken by `code` ascending for determinism.
Tombstoned drawers excluded. Unanchored drawers (empty `udc_code`) excluded.
A genuinely empty estate (read succeeds, zero anchored drawers) returns
`200 {"addresses":[]}`. A store **read failure** returns
`503 {"error":"lattice read failed","degraded":true}` — NOT a fabricated
empty-200, which would be indistinguishable from a genuinely empty estate.
Both ports identical (`latticeSnapshot`, `get_lattice_snapshot`).

**`GET /api/admin/estates` → 200 `application/json`**
```json
{
  "hosted": [
    { "estateUUID": "string (UUID)",
      "estateName": "string",
      "kind": "GLK",
      "backend": "SQLite | PostgreSQL | InMemory",
      "mountState": "mounted" }
  ]
}
```
`estateName` is the human-readable name in Swift (from GeniusLocusKit); the UUID
string in Rust (Rust EstateRegistry stores no separate name). `backend` inferred
from env vars (`ARIA_MCP_POSTGRES_URL` / `ARIA_MCP_SQLITE_PATH` / neither →
`InMemory`). `mountState` is always `"mounted"`. Empty `{"hosted":[]}` on
serialization failure.

### Unknown path

`GET <anything-else>` returns HTTP 404 `{"error":"not_found"}`.

## § 5 — Conformance test entry points

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/AriaMcpKit
```

(Targets: `AriaMCPTests` — JSON-RPC, stdio framing, HTTP transport
(`HTTPServerTests`, loopback round-trips), server, five-tier
tool projection, connection dispatch, file-memory validation, KG and
journal dispatch, multi-estate routing, recipe/lens tools, vault tools,
teachme guides and coaching hints.)

```
cargo test --manifest-path packages/kits/AriaMcpKit/rust/Cargo.toml
```

(Rust test targets: `dispatch_tests` — 93 tests including 5 new moot_vault_job
tests (schema parity, export→job_id→complete record, import→job_id→complete
record, unknown id→Swift-identical not-found, missing job_id→INVALID_PARAMS,
ledger eviction at 100 entries). `jsonrpc_tests`, `persistence_tests`,
`stdio_framing_tests`, `http_transport_tests` — 4 loopback HTTP round-trips
(initialize, tools/list, non-POST 405, malformed-body parse error). Total Rust
suite: 188 tests, 0 failures. Tool census: 55/55 (Rust matches Swift exactly).)

## § 6 — Examples

```swift
import AriaMCP
import GeniusLocusKit

let dispatcher = AriaMcpDispatcher(
    info: .init(name: "aria-mcp", version: "1.0.0"),
    tooling: ToolDispatcher(kit: kit, handle: estate)
)
await StdioServer(dispatcher: dispatcher).run()   // newline-delimited JSON-RPC over stdio
```

---

*End of aria-mcp Interface.*

## Changelog

### 1.3.0 -- 2026-06-17
Additive (mission BRAIN-GRAPH-PRODUCER — graph-centrality producer, both ports).
New `AutonomicGovernor` PRODUCER DUTY on both ports: Swift
`AutonomicGovernor.graphCentralityScan(kit:handle:now:)` (a nonisolated static
duty dispatched on the `graphCentralityIntervalMs` cadence, default 10 min) and
Rust `graph_centrality_duty` (fired inside `tick` on the same cadence). The duty
reads the estate structure graph, computes per-drawer eigenvalue centrality via
the NeuronKit `keystones` oracle, and registers a `GraphCache`
(`registerGraphCache` / `register_graph_cache`). `GovernorReport` /
`GovernorReport` gains `graphCentralityFired` / `graph_centrality_fired`. Swift
`AutonomicGovernor.init` gains a `graphCentralityIntervalMs` parameter; Rust adds
the `set_graph_centrality_cadence_ms` test knob. This takes the
`unionBest`/`matrixAware` recall `graph` column from dark to live in production on
both ports. Corrects the prior text framing the recall-cache producers as
standing-signal seam plug-ins: they are governor DUTIES.

### 1.2.0 -- 2026-06-17
Additive (#8 Track 1 — Brain orchestration harness, Rust side). The Rust
`AutonomicGovernor` now OWNS this estate's standing-signal scheduler (a GLK
`SerialLaneScheduler<CoordinatorDispatcher>`) and ticks it each iteration,
mirroring the Swift governor's `kit.signalTick(in:handle:now:)` — previously the
Rust governor ticked dreaming + maintenance only and documented "no
standing-signal scheduler". New public Rust surface on `AutonomicGovernor`:
`register_default_standing_signals(model_id, now)` (the architecture-spec §11.2
bootstrap, reading the live VectorStore via `EstateCoordinator::vector_store_for`,
now `pub`), `register_standing_signal(spec, now)`, `signal_status()`,
`open_signal_count()`, `signal_request_fire(id, now)`; `GovernorReport` gains
`pub signals_ticked: bool` (parity with the Swift `TickReport.signalsTicked`).
The scheduler lives in the governor (not the GLK coordinator) to avoid a
dispatcher reference cycle. The registration methods are the producer SEAM where
Track 2 (graph-centrality) and Track 3 (Bradley-Terry) plug in — their outputs
land in GLK `recall::{GraphCache, PreferenceStore}`; the producers themselves are
NOT part of this harness. The resident HTTP bootstrap (`rust/src/runtime.rs`)
registers the defaults once at startup, best-effort (a missing VectorStore logs
and the governor benign-skips, parity with the Swift resident). Conformance:
`tests/governor_standing_signals.rs` (benign skip / registered-defaults fire /
queryable emission / interval cadence) over the existing GLK
`tests/scheduler_parity.rs` engine gate. Swift behavior unchanged.

### 1.1.0 -- 2026-06-17
Additive (GLK-RECALL-SHAPE-PRESETS): new `moot_recall_shaped` recipe tool (both
ports) — a single recall tool with a discoverable `preset` enum selecting a named
`RecallShape` from the GLK roster (preferable to ~20 tools). The tool description
embeds the full roster (each preset name + one-line emphasis); the preset enum is
the GLK `presetNames` list. Validation is fail-CLOSED: an absent preset uses the
unsteered `balanced` default, a present-but-unknown name is rejected with a tool
error. Returns the same plain-text shape as `moot_memory_search`. The four ARIA
filtering adjectives compose orthogonally (the preset ranks, the `filter` arg
filters). The `.recipe` bucket grows to 29 tools and the whole surface to 55
(census references updated to the current live count, which prior additions
— `moot_reindex`, `moot_vault_job` — had left at the stale 53). Conformance:
`RecipeToolsTests.swift` shaped-recall cases / `dispatch_tests.rs`
`recall_shaped_*` + the tool-count/name-set gates.

### 1.0.1 -- 2026-06-14
Reconciled the `.recipe` provenance tool count: the §`Recipe and lens tools` body enumerated only 5 CognitionKit recipe tools (yielding 26 with the 21 lenses) while the heading, the `ToolProvenance` projection, and the 53-tool census all carry 28. Added the two missing recipe tools (`moot_recall_precise`, `moot_dream`) to the body so it lists all 7 recipe tools + 21 lenses = 28, consistent with the verified Swift/Rust surface (`ToolProjection.tools()` / `tool_list.rs`, both gated at 53).

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
