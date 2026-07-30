---
title: aria-mcp Interface
version: 1.23.0
status: accepted-1.1-target
date: 2026-07-20
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
  `ARIA_MCPDispatcher`.
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
  (`LensTools.swift`), vault control tools (`VaultTools.swift`),
  tabular dataset tools (`DatasetTools.swift`),
  recall discrimination helper (`RecallDiscrimination.swift`),
  Anthropic memory_20250818 adapter (`MemoryToolAdapter.swift`; Rust: `memory_adapter.rs`),
  monitoring-control injection seam (`MonitoringControl.swift`).
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
The Rust binary links the same 71-tool surface (65 vault-off) backed by the Rust kit stack
(genius-locus-kit, locus-kit, vault-kit, cognition-kit, neuron-kit). The opt-in
Anthropic memory_20250818 adapter (`memory_adapter.rs`) adds one `memory` tool when
`MOOTX01_MEMORY_TOOL=1`, raising the count to 72/66 — same gate as the Swift port
(`MemoryToolAdapter.swift`). Default (absent/≠ "1") preserves the 71/65 baseline. All five
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
68 tools across four provenance tiers (including the maintenance tools
`moot_reindex`, `moot_drain_status`, `moot_reclassify_fdc`, and
`moot_palace_import`).

```swift
public enum ToolProvenance: Sendable, Equatable {
    case interface     // 30 tools: 22 five-tier AI-client tools + moot_monitoring_status + 4 maintenance + 3 dataset
    case federation    // 1 federated-search tool (moot_federated_search)
    case recipe        // 12 recipe + 23 lens tools via CognitionKit/LensTools
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
    public static func tools() -> [ProjectedTool]   // vault-on: 71 tools; vault-off: 65 tools (interface+federation+recipe+lens+vault+maintenance+dataset)
    public static func memoryToolEnabled(environment: [String: String]) -> Bool  // opt-in memory_20250818 adapter (MOOTX01_MEMORY_TOOL=1); default OFF
    public static var memoryToolEnabled: Bool
    public static func federationTool() -> ProjectedTool
}
```

#### Five-tier AI-client interface (`.interface` provenance, 22 five-tier tools)

| Tier | Tools |
|------|-------|
| 1 — Core Memory | `moot_file_memory`, `moot_memory_search`, `moot_memory_get`, `moot_memory_list`, `moot_update_memory`, `moot_withdraw_memory`, `moot_erase_memory`, `moot_confirm_memory`, `moot_move_memory` |
| 2 — Connections | `moot_link_memories`, `moot_review_tunnel`, `moot_connection_search`, `moot_connection_map` |
| 3 — Knowledge Graph | `moot_file_fact`, `moot_fact_search`, `moot_retire_fact`, `moot_fact_timeline` |
| 4 — Journal | `moot_write_journal`, `moot_read_journal` |
| 5 — Estate | `moot_estate_status`, `moot_estate_map`, `moot_estate_ping` |

All interface tools accept an optional `estateID` (UUID string) to address a
registered non-default estate and an optional `teachme` (boolean) to request a
usage guide instead of executing. Infrastructure fields (`latticeAnchor`,
`embeddingModelID`, `addedBy`, `channel`) are server-owned and never exposed
to AI clients. Required caller fields: `content` + `location` for
`moot_file_memory`; `query` for `moot_memory_search`; `id` for
`moot_memory_get` (drawer UUID — no `query`, this tool fetches an exact row,
not a ranked set); `subject`, `predicate`,
`object` for `moot_file_fact`; `entry` for `moot_write_journal` (note: `entry`,
not `content` — mirrors the `DiaryEntry.entry` substrate field); optional `query`
for `moot_fact_search` (substring match across subject, predicate, and object;
omit to return all active facts); `tunnel_id` + `verdict` (`"accept"` |
`"reject"`, optional `reason`) for `moot_review_tunnel` (settles a PROPOSED
tunnel: accept → active, reject → withdrawn — durable, the pair is never
re-proposed by the contradiction hunter; only proposed-lifecycle tunnels are
reviewable). `moot_link_memories` accepts an optional `proposed` (boolean,
default `false`) that files the link in the PROPOSED lifecycle instead of
active — the agent-adjudication path for borderline candidates returned by
`moot_hunt_contradictions`.

Optional MCP arguments use an omit-to-default contract. If a caller wants the
default, it omits the key entirely. A present key with JSON `null` is invalid
for semantic knobs such as `estateID`, `teachme`, `filter`, `limit`, `scoring`,
`ordering`, `sensitivity`, `exportability`, `kind`, `impatient`, `agent`, and
similar optional primitive fields. This keeps AI clients from forcing the server
to guess whether `null` meant "default", "unset", or a bug in the caller.

`moot_file_memory` also accepts an optional `classificationScheme` (string,
default `"udc"`) that identifies the classification scheme of the supplied
`latticeAnchor` code. Valid values: `"udc"` (Universal Decimal Classification)
and `"mdcc"` (MOOTx01 Decimal Content Classification). An unknown string returns
`invalidParams`. Absent defaults to `"udc"`, preserving prior bare-UDC behavior.
See `ClassificationScheme` in §2 for the type declaration.

`moot_file_memory` also accepts an optional `impatient: bool` (default `false`)
— the Dual-Path Intake write-mode execution option. It is an option on the
write verb (threaded MCP arg → GLK verb param `mode`), NOT a `CaptureFrame`
field; it mirrors how `scoring` is an option on `moot_memory_search`. When
`true`, the canonical Drawer is indexed for semantic search (BM25 + provider
embeddings under that same Drawer ID) INLINE
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
  surface/lexical signal). An optional host-supplied learned semantic lane
  (MiniLM/MPNet/Gemma, per CORPUSKIT_SPEC §9.2) is additive; when wired it
  contributes a richer signal but does not replace the deterministic lane.
  Callers use `dense_lane` to distinguish a result that included vector scoring
  from a structural/BM25-only result.

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

#### Recipe and lens tools (`.recipe` provenance, 35 tools)

The `.recipe` provenance bucket holds 35 tools: 12 CognitionKit recipe tools plus
the 23 reasoning-lens tools below.

- `moot_list_lenses`, `moot_list_recipes`, `moot_synthesize`, `moot_recall_precise`,
  `moot_recall_shaped`, `moot_run_migration`, `moot_confirm_migration`, `moot_dream`,
  `moot_distill` (alias: `moot_consolidate`), `moot_recall_distilled`, `moot_recollect`,
  `moot_hunt_contradictions`
  (12 CognitionKit recipe tools)
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
    association layer the matrix recall lane scores against), run one dreaming
    cycle (latent-alignment proposals + cycle diary), and run one
    contradiction-hunt sweep (content screen over lexically-near memory
    pairs; strong conflicts persist as PROPOSED contradicts links for review).
    The matrix is built by dreaming, not by capture, so a freshly-loaded estate
    has an empty matrix until this runs. Returns a cycle summary including
    contradiction counts.
  - `moot_hunt_contradictions` — one bounded on-demand contradiction-hunt
    sweep: BM25 lexical candidate pairs from the corpus's inverted index
    (drawer-keyed Hamming kNN on the bespoke lane), screened by the
    SubstrateML conflict cue (negation asymmetry, same-template value
    divergence, revision markers). Strong findings persist as PROPOSED
    `contradicts` tunnels (settle via `moot_review_tunnel`); borderline pairs
    return with content snippets for the calling agent to adjudicate via
    `moot_link_memories kind=contradicts proposed=true`. Optional
    `probe_limit` (default 500, max 10000) and `now` (ISO8601). Requires the
    vector index (`moot_reindex` after bulk import). Dedup against ALL
    existing contradicts tunnels (any lifecycle) is durable — rejected pairs
    never re-propose. The same core pass runs inside `moot_dream` and hourly
    in the resident daemon's contradiction-scout signal.
- 23 `moot_lens_*` tools: `moot_lens_keystones`, `moot_lens_constellation`,
  `moot_lens_free_association`, `moot_lens_theme_weather`, `moot_lens_latent_themes`,
  `moot_lens_bias`, `moot_lens_drift`, `moot_lens_node_motion`,
  `moot_lens_cohesion`, `moot_lens_contradiction`,
  `moot_lens_trust_synthesis`, `moot_lens_partial_cue`, `moot_lens_anticipate`,
  `moot_lens_successors`, `moot_lens_overlap`, `moot_lens_divergence`,
  `moot_lens_associations`, `moot_lens_concepts`,
  `moot_lens_apriori`, `moot_lens_moment`, `moot_lens_rhythm`,
  `moot_lens_precedence`, `moot_lens_complexity`

`moot_lens_contradiction` reports two lifecycle tiers on its contradicts-tunnel
output: confirmed (active) edges, and PROPOSED edges flagged
`proposed (agent-derived, unreviewed)` — shown by default so hunter findings
surface without an extra flag. Withdrawn (rejected) and superseded edges never
appear.

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

**Vault job concurrency cap and slot-release invariant (availability hardening).**
The Swift port caps concurrent vault import + export jobs at 4 (`maxConcurrentVaultJobs`).
`moot_vault_import` acquires a slot via `checkAndRegister` BEFORE running `hashAllNotes`
so the cap bounds the expensive preflight (filesystem traversal + full-file reads +
SHA-256 hashing). Running `hashAllNotes` outside the cap allowed up to the HTTP transport
concurrency limit worth of parallel hashing before the cap was consulted.
If `hashAllNotes` throws after the slot is acquired (e.g. permission-denied on a regular
`.md` file), `fail(jobID:)` releases the slot immediately so the error never permanently
consumes cap capacity. Non-regular `.md` entries (directories, symlinks) are silently
skipped in `hashAllNotes` rather than causing a fatal error — a caller-controlled vault
may contain a directory or symlink named `something.md`. `moot_vault_export` has no
throwable preflight between `checkAndRegister` and the background Task. Slot-release
invariant: every successful `checkAndRegister` is matched by exactly one terminal `fail()`
or `complete()` on every code path — the pre-Task catch handles preflight throws; the
Task's catch handles bridge throws. The Rust backend has no "running" ledger state —
`run_import` records the job only after the bridge completes, and `collect_and_hash`
checks `file_type.is_file()` before reading so a directory named `directory.md` is
recursed (not hashed) and a broken symlink is skipped. The `Dispatcher` `Arc<Mutex<>>`
serializes all dispatch calls so at most one import runs at a time — no concurrent
preflight fan-out is possible and no slot can leak in the Rust port.

### Dataset tools (`.interface` provenance, 3 tools, MX-TAB-7)

Three tools expose user-owned tabular datasets (`moot_file_dataset`,
`moot_dataset_query`, `moot_dataset_stats`). They carry `.interface` provenance
and accept the standard optional `estateID`. They are always present — not
vault-gated — and are inserted after vault tools in `ToolProjection.tools()`.

Both legs (Swift `DatasetTools.swift`, Rust `dataset_tools.rs`) are at parity;
the dispatch contracts are identical. The `DatasetTools` enum is internal; its
tools reach callers solely through `ToolProjection.tools()` and
`ToolDispatcher.dispatch`.

#### `moot_file_dataset`

Create a dataset handle (a Drawer in the estate) plus its backend storage
table, then bulk-load rows. Returns the dataset UUID and handle metadata.
Inline rows or a CSV file path (not both). CSV imports are confined to the
home directory by component-wise prefix match after symlink resolution (path
security gate MX-TAB-SEC-1 A1). The CSV size cap is 100 MiB.

Required args: `name` (dataset label), `location` (room for the estate
handle). Either `rows` (JSON array of objects) or `csv_path` (string) must be
supplied, never both. When using `rows`, `columns` (array of `{name, type}`
objects) is also required; types are `"text"`, `"int"`, `"float"`, `"bool"`.
When using `csv_path`, column types are inferred from the CSV header. Optional:
`wing` (estate wing, default `"Agentic Memory"`).

Column names must be valid identifiers (ASCII letter or `_` start, ASCII
alphanumeric or `_` body only) — SQL-injection names are rejected before any
DDL.

Tier-1 (table) and tier-2 (column) signatures are computed on bulk load
(MX-TAB-5) and stored in the drawer's `ContentSignature`; they travel with
the handle in vault round-trips.

#### `moot_dataset_query`

Predicate query over a dataset's rows. Refuses withdrawn handles.

Required: `id` (UUID string from `moot_file_dataset`). Optional: `where`
(predicate tree: `{col, op, val}` leaves composed with `{and: [...]}` /
`{or: [...]}` nodes; supported ops: `eq`, `ne`, `lt`, `le`, `gt`, `ge`,
`contains`, `starts_with`, `ends_with`, `is_null`, `not_null`), `order_by`
(array of `{col, dir}` objects, `dir` is `"asc"` or `"desc"`), `limit`
(integer ≥ 1, default 1000). The `limit` is capped at 10 000.

#### `moot_dataset_stats`

Per-column aggregate statistics for a dataset. Refuses withdrawn handles.

Required: `id` (UUID string). Optional: `column` (single column name; omit
to get stats for all columns). Returns count, null count, distinct count, and
for numeric columns: min, max, mean, stddev.

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

### Version-skew advisory (the connection-ownership contract §5)

Both `moot_estate_ping` and `moot_estate_status` append an OPT-IN
`version_skew: <text>` line — present only when the host detected a mismatch
between an installed plugin and this running binary's version; absent
entirely otherwise (not a fixed empty slot).

**Detection:** the host reads `~/.claude/plugins/installed_plugins.json` for
the `mootx01@mootx01` entry's `version` field and compares it against the
running binary's own version. Checking at runtime (rather than only at
install time) catches skew regardless of install order.

**Field text:** ``plugin <pluginVersion> expects binary ≥ <pluginVersion>; binary is <binaryVersion> — run `mootx01 upgrade` ``.

**Threading (mirrors the build-serial pattern exactly):**
- Swift: `ToolDispatcher.versionSkewAdvisory: String?`, computed once by
  `ServeCommand` via `MootInstallerCore.VersionSkewAdvisory.compute(pluginID:binaryVersion:homeDirectory:)`
  and injected at construction. `nil` ⇒ no line appended.
- Rust: `Dispatcher.version_skew: String`, computed once by
  `commands::serve::run` via `core::mcp_ownership::version_skew_advisory(plugin_id, binary_version, home)`
  and threaded through `dispatch_tool_with_vault_ledger` → `dispatch_tool_with_vault_ledger_and_flag`
  → `interface_tools::dispatch` → `run_estate_ping` / `run_estate_status`.
  Empty string ⇒ no line appended.
- `aria-mcp-server` (both ports) has no plugin concept — always constructs
  with the nil/empty default, so its responses never carry the field.

This kit never reads `~/.claude/plugins/` or knows a product version
itself — the host binary computes the advisory string and injects it,
same separation of concerns as `buildSerial`/`serverIdentity`.

### Upstream-release advisory (`update_available`)

Both `moot_estate_ping` and `moot_estate_status` append an OPT-IN
`update_available: <text>` line — present only when a newer product release
exists on the release feed than the running binary; absent entirely
otherwise. Sibling of `version_skew` (which reports LOCAL plugin/binary
skew) and confined to the same two session-orientation tools on purpose:
MCP clients orient with ping/status at session start, so one line there
informs every client once without nagging on the other tools.

**Field text:** ``v<latest> is available (installed <current>) — upgrade with `mootx01 upgrade` ``.

**Threading — a provider, NOT a startup-computed string:** the resident
daemon is long-lived and releases ship while it is running, so unlike
`version_skew` the value cannot be computed once at startup. The host
injects a closure the two tools evaluate lazily:
- Swift: `ToolDispatcher.updateAdvisoryProvider: (@Sendable () async -> String?)?`,
  wired by `ServeCommand` from `MootInstallerCore.UpdateAdvisor` (an actor
  wrapping `ReleaseDownloader.latestTag()`).
- Rust: `Dispatcher.update_advisory: Option<UpdateAdvisoryProvider>` via the
  `with_update_advisory` builder, wired by `commands::serve::run` from
  `core::update_advisor::UpdateAdvisor` (wrapping
  `release::latest_version_within(Some(4))`).

**Non-annoying / non-blocking contract (host-owned):** the advisor caches
the probe result behind a 24h TTL (one release-feed hit per day per daemon,
and only when ping/status is actually called), bounds a single probe to ~4s
(a hung feed host cannot hold a ping), and collapses failures to silence
AND caches them (an offline machine probes once per TTL window, not once
per ping). `MOOTX01_NO_UPDATE_CHECK` disables the surface entirely — the
same kill switch honored by the Claude Code plugin's SessionStart update
hook (`moot_update_check.py`), so one documented variable turns off every
update phone-home surface.

**Scope:** resident daemons only. stdio one-shot serves and
`aria-mcp-server` (both ports) never wire a provider — ping is documented
as returning immediately, and plugin-capable hosts reach the resident over
HTTP anyway (the connection-ownership contract §2).

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
    // Per-tool guide for all 20 Tier 1–5 tools and moot_federated_search.
    // moot_estate_status returns the ten-tier orientation guide.
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

### Server — `ARIA_MCPDispatcher` / `StdioServer` / `HTTPServer`

The transport-neutral method router and the two transports that drive it: the
newline-delimited stdio loop and the loopback HTTP (Streamable-HTTP) transport.

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

// Loopback Streamable-HTTP transport (v1.0). POST JSON-RPC -> application/json
// via the same dispatcher; loopback-only bind; no auth (CE) but a CSRF/DNS-rebinding
// Origin guard (non-loopback Origin -> 403). Rust mirror: rust/src/http_server.rs.
public struct HTTPServer: Sendable {
    public let dispatcher: ARIA_MCPDispatcher
    public let port: UInt16            // default 4242; 0 = OS-assigned (tests)
    public let maxBodyBytes: Int       // default 4 MiB
    public init(dispatcher: ARIA_MCPDispatcher, port: UInt16 = 4242, maxBodyBytes: Int = 4 * 1024 * 1024)
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

### Recall discrimination — `DiscriminationLevel` / `RecallDiscrimination`

A relative-gap confidence estimate appended to ranked recall results. Classifies
how well the top hit separates from the rest of the list using a relative gap
ratio (scale-independent), composed with a saturation discount when the semantic
vector lane is dark (dense-lane-dark cap). Applied by `moot_memory_search`,
`moot_recall_precise`, and `moot_recall_shaped`. This is a confidence estimate
of relative separation — it says nothing about whether the leading result is
the correct answer. Swift and Rust thresholds are named constants mirrored
verbatim; any change must update both ports simultaneously.

A second signal, `DistilledDiscriminationLevel`, is used by `moot_recall_distilled`
and maps to the same wire prefix (`discrimination: `) — both signals share the
`high/medium/low/n/a` ladder but classify different rank geometry (exact-search
originals vs distilled representations). See `moot_recall_distilled` output
format for the distilled variant.

```swift
public enum DiscriminationLevel: Sendable, Equatable {
    case single    // fewer than two results — nothing to compare
    case high      // top result clearly separated (topGap >= HIGH_MARGIN = 0.25)
    case medium    // partial separation
    case low       // top results within epsilon — effectively unranked
    case notFound  // distinctive query tokens with zero candidate matches
}
public enum RecallDiscrimination {
    public static func classify(_ scores: [Double]) -> DiscriminationLevel
    // Returns a result-line string for the given level. When denseLaneDark is
    // true the classification is capped at .medium (saturation discount applied)
    // and a caveat is appended.
    public static func resultLine(for level: DiscriminationLevel, denseLaneDark: Bool = false) -> String
}
```

### Monitoring control — `MonitoringControl`

Injection seam for daemon telemetry monitoring state. Defined in AriaMcpKit;
the concrete implementation (`StatsStoreMonitoringControl`) lives in the serve
host layer (AriaResident in Swift, `http_server.rs` in Rust), keeping AriaMcpKit
free of ObserverSink / IntellectusLib. The `moot_monitoring_status` tool reads
and optionally writes through this seam. `nil` from `read()` means a transient
store error or no store wired — reports `"monitoring: unavailable"`, never
fabricates a state.

```swift
public protocol MonitoringControl: Sendable {
    func read() async -> Bool?      // nil on transient error or no store
    func set(_ enabled: Bool) async // best-effort; errors logged by implementation
}
```

### Sensitivity tiers — `SensitivityTier`

The two lockable sensitivity tiers governed by the sensitivity-unlock policy. Used as the
`tier` discriminator in the `/api/control/unlock` POST body and in
`SensitivityGrantLedger` method signatures (§4.6). Raw string values
match the JSON wire values accepted by the unlock endpoint.

```swift
public enum SensitivityTier: String, Sendable, Equatable, CaseIterable {
    case restricted   // raw: "restricted" — expires at next local midnight
    case secret       // raw: "secret"    — expires 30 min after grant (fixed, non-sliding)
}
```

Rust mirror: `pub enum SensitivityTier` in `sensitivity_grant_ledger.rs`, same
two cases and raw-string wire values.

### Classification scheme — `ClassificationScheme`

The lattice-anchor classification scheme discriminator. Accepted by
`moot_file_memory` (and other capture paths) as the optional
`classificationScheme` argument. Absent defaults to `.udc`, preserving
prior bare-UDC behavior. The substrate's `LatticeAnchor` does not yet carry
a scheme tag — this type validates and echoes the scheme at the ARIA boundary.

```swift
public enum ClassificationScheme: String, Sendable, CaseIterable {
    case udc    // raw: "udc"  — Universal Decimal Classification (default)
    case mdcc   // raw: "mdcc" — MOOTx01 Decimal Content Classification
}
```

Rust mirror: `pub enum ClassificationScheme` in `ToolDispatch` module,
same two cases and raw-string values.

## § 3 — Public functions

MCP methods are routed by `ARIA_MCPDispatcher.handle(_:)`:
`initialize` (echoes `protocolVersion`, advertises the `tools`
capability), `ping`, `tools/list` (from `ToolProjection.tools()`),
`tools/call` (→ `ToolDispatcher.dispatch(name:arguments:)`). The
`aria-mcp` executable wires a `GeniusLocusKit` estate into a
`ToolDispatcher`, builds an `ARIA_MCPDispatcher`, and runs the selected
transport: `StdioServer.run()` by default, or `HTTPServer.run()` when
`MOOTX01_HTTP_PORT` is set. Behavioral contracts: SPEC.

## § 4 — Errors

```swift
public struct JSONRPCError: Sendable, Equatable, Error { public let code: Int; public let message: String }
public enum JSONValueError: Error, Equatable
```
Protocol faults (unknown tool, malformed arguments, unknown
`estateID`) surface as JSON-RPC errors. Every failure of a call that
reached its runner — substrate refusals (`VerbError`,
`GeniusLocusKitError`) and unexpected runner errors (filesystem,
adapter) alike — comes back as a `tools/call` result with
`isError: true` so the client keeps the call id and the model sees the
failure description (clients render a thrown JSON-RPC error as a bare
"failed to call tool" and discard the message). The server also mirrors
unexpected runner errors to stderr for daemon-side diagnosis.
`toolDispatchFailure` (-32010) remains defined but is an internal
marker on the Rust leg, never emitted on the wire. See SPEC § 6.

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

Implemented as `latticeSnapshot(dispatcher:)`, `graphSnapshot(topologyReader:)`,
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

## § 4.6 — Sensitivity control POST endpoints (HTTP transport only, the sensitivity-grant contract)

Two write-only POST endpoints accept out-of-band sensitivity grants and revocations.
Both ports (Swift + Rust) share the same CSRF/DNS-rebinding Origin guard as the
MCP JSON-RPC endpoint. The stdio transport does not expose these endpoints. See
ARIA_MCP_SPEC.md §19 for the full behavioral contract.

```
POST /api/control/unlock
POST /api/control/lock
```

### Swift implementation

```swift
// HTTPServer.swift — route(_ request:) dispatch
case .unlock: return try await handleUnlock(request)
case .lock:   return await handleLock()

// SensitivityGrantLedger.swift
struct SensitivityGrantLedger: Sendable {
    func ceiling_sensitivity(now: Date) -> AdjectiveSensitivity?
    func grant(tier: SensitivityTier, expiresAt: Date) async
    func revokeAll() async
}
```

CLI entry point (macOS only): `UnlockCommand.swift` / `LockCommand.swift`
(`apps/mootx01/Sources/mootx01/Commands/`). Uses `LocalAuthenticationAuthority`
(`LAContext.evaluatePolicy(.deviceOwnerAuthentication)`).

### Rust implementation

```rust
// http_server.rs — route() dispatch
"/api/control/unlock" => handle_unlock(&body, &state),
"/api/control/lock"   => handle_lock(&state),

// sensitivity_grant_ledger.rs
pub fn ceiling_sensitivity(&self, now_ms: i64) -> Option<AdjectiveSensitivity>
pub fn grant(&self, tier: SensitivityTier, expires_at_ms: i64)
pub fn revoke_all(&self)
```

CLI entry point: `commands::unlock::{run_unlock, run_lock}`. Uses
`core::unlock_authority::authenticate_and_grant` — reads `sensitivity_hashes.json`
sidecar, prompts for password (echo-off), verifies PBKDF2-HMAC-SHA256.

### Request/response shapes

**`POST /api/control/unlock`**

Request:
```json
{ "tier": "restricted" | "secret", "proof": { "ts": <unix_ms as integer> } }
```

Success (HTTP 200):
```json
{ "granted": true, "expires_at": "ISO-8601" }
```

**`POST /api/control/lock`**

Request: `{}`

Success (HTTP 200):
```json
{ "locked": true }
```

**Error responses (both endpoints):**

| HTTP | Body | Condition |
|------|------|-----------|
| 400 | `{"error":"unknown tier"}` | `tier` is not `"restricted"` or `"secret"` |
| 403 | `{"error":"proof stale"}` | `|now_ms - proof.ts| > 10_000` |
| 500 | `{"error":"<message>"}` | Any other server error |

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

(Rust test targets: `dispatch_tests`, `jsonrpc_tests`, `persistence_tests`,
`stdio_framing_tests`, `http_transport_tests`, `autonomic_governor_tests`,
`dataset_tools` coverage in `dispatch_tests`, and additional integration
test modules. Tool census: 71/71 vault-on, 65/65 vault-off (Rust matches
Swift exactly). Run `cargo test` for the current pass count.)

## § 6 — Examples

```swift
import AriaMCP
import GeniusLocusKit

let dispatcher = ARIA_MCPDispatcher(
    info: .init(name: "aria-mcp", version: "1.0.0"),
    tooling: ToolDispatcher(kit: kit, handle: estate)
)
await StdioServer(dispatcher: dispatcher).run()   // newline-delimited JSON-RPC over stdio
```

---

*End of aria-mcp Interface.*

## Changelog

### 1.23.0 -- 2026-07-20

- Updated intake/search language for GLK shared content: impatient writes index
  the canonical Drawer directly, and Corpus drain counts are Drawer-index
  counts rather than chunk counts.
- Confirmed that no ARIA/MOOTx01 surface enables CorpusKit passage chunking.

### 1.11.0 -- 2026-06-28
Security hardening — three ARIA tool gate changes (secfix/batch2-aria).

(1) **`moot_erase_memory` AriaMcpKit gate** — `confirmed=true` check enforced at the
AriaMcpKit boundary before the substrate is called. Schema unchanged; `confirmed` was
already present in `required`. Error message updated to name `confirmed=true` explicitly
and explain the owner-review intent. Both ports updated.

(2) **`moot_federated_search` requester anti-spoof** — `requesterEstateID` changed from
required to optional. When omitted the requester is the default estate. When supplied it
must match the default estate's UUID. Schema: `required` array changed from
`["requesterEstateID"]` to `[]`; property description updated to document the optional
binding and the anti-spoof refusal. Both ports updated.

### 1.10.1 -- 2026-06-28
Security (HTTP transport — both ports, both surfaces):

(1) **Origin-check hardening** — `isOriginAllowed` in `HTTPServer.swift` / `http_server.rs`
and `HTTPReadAPI.swift` / `http_read_api.rs` now validate the suffix after the loopback host
prefix instead of a bare prefix check, blocking DNS-rebinding prefix-spoof origins like
`localhost.evil`. Tests added on all four files.

(2) **`moot_palace_import` vault gate** — when `MOOTX01_VAULT=0`, `moot_palace_import` is
absent from `tools/list` and returns a clear refusal at dispatch (same as vault tools). The
tool reads arbitrary local SQLite files; gating it matches the vault-surface security posture.
Vault-off surface count: 57 → 56. Both ports updated (`ToolProjection`, `ToolDispatch`,
`tool_list.rs`, `dispatch.rs`).

### 1.10.0 -- 2026-06-25
Docs/guidance (T8 — teachme reconcile): the teachme `palace_import` guide no
longer tells the AI that `moot_reindex` + `moot_dream` are a REQUIRED two-step
finish — that contradicted the tool's own description (the import triggers its
own background indexing; the resident dreams on cadence). Guides now say
indexing is automatic, point at `moot_drain_status` to watch convergence, and
note `moot_dream` is only needed manually when running without a resident.
Residual `batch`/`non-batch` wording from the T1/T7 rename swept out of both
ports' teachme and the `moot-agent-skills` HOW_TO. No surface change.

### 1.9.0 -- 2026-06-25
Changed (T7 — one ingest engine, many gates): `moot_vault_import` takes a `mode`
(foreground/background encode SPEED) arg, replacing the Swift-only `batch` flag,
and the Rust vault-import tool now exposes `mode` too (it previously had no such
arg — a fixed Swift/Rust parity gap). All import gates (palace + vault/Obsidian/
OKF) now share one policy: caller declares SPEED, write strategy is size-gated
automatically. No new tool. Both ports.

### 1.8.0 -- 2026-06-25
Added (T5 — drain lifecycle): new internal CLI subcommand `mootx01 drain [--db]`
— opens an estate, drains its encode queue to empty, then exits. It is the
detached finisher a direct-open stdio `serve` spawns on exit (setsid/detached);
rarely run by hand. Also: estate open now eager-mounts the corpus drain worker so
a restarted daemon resumes a non-empty queue (daemon resume-on-restart). No
`moot_*` tool-surface change. Both ports.

### 1.7.0 -- 2026-06-25
Changed (T4 — serve transport): an stdio `serve` forwards to a live resident
serving the same estate (estate-marker match + `daemon.port` probe → the `proxy`
stdin→HTTP bridge) instead of opening a second direct writer; falls back to a
direct open when no resident answers. Resident writes a `mootx01.estate` marker
(removed on exit). No tool-surface change; transport behavior only. Both ports.

### 1.6.0 -- 2026-06-25
Changed (T1 — encode mode): `moot_palace_import` replaces its `batch` (bool) arg
with `mode` (string `"foreground"` | `"background"`, default `"foreground"`).
`mode` selects the post-import encode SPEED (drain QoS) only — foreground drains
the encode queue across all cores, background caps to ~a quarter for very large
imports. The WRITE strategy (bulk transaction vs per-item stream) is now chosen
AUTOMATICALLY by source size (≤250k rows → bulk; larger → stream), not by the
caller. Unknown `mode` is rejected (fail-closed). Both ports.

### 1.5.0 -- 2026-06-25
Additive (T6 — drain status): new maintenance tool `moot_drain_status` (both
ports) — a read-only, pollable report of every long-running background drain the
estate runs. Today the only drain is `corpus_encode` (the encode/ingest queue);
each drain reports pending + in-flight job counts, a draining/idle state, and
optional drain-specific detail (the corpus drain reports its live encoded-chunk
count). Unlike `moot_estate_status` it does NOT append the session-protocol
block, so it is cheap to poll while a drain settles (e.g. after
`moot_palace_import`). The report is list-shaped so additional drains surface
automatically. The whole surface grows 55 → 56. Reachable from the CLI as
`mootx01 query drain_status`. Also fixed a stale `moot_reindex` doc-comment that
pointed callers at `moot_estate_status` for encode-queue depth (it never reported
it) — now points at `moot_drain_status`. Conformance: dispatch tool-count/name-set
gates (Swift `ToolProjection` / Rust `tool_list.rs`).

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

### 1.13.0 -- 2026-06-29
Vault cap ordering fix (secfix/c-vault-cap): corrected `moot_vault_import` preflight
ordering in the Swift port. Previously `hashAllNotes` ran BEFORE `checkAndRegister`,
allowing up to the HTTP transport concurrency limit worth of concurrent expensive
filesystem/SHA-256 preflight work outside the cap. The cap now binds the preflight:
`checkAndRegister` runs FIRST, then `hashAllNotes` runs while holding the slot. A new
pre-Task do/catch releases the slot via `fail(jobID:)` when `hashAllNotes` throws, so a
throwing preflight never permanently consumes a cap slot. §Vault job concurrency cap
updated to reflect the new ordering. Rust port unchanged — `Dispatcher` `Arc<Mutex<>>`
already serializes all calls (effective cap of 1, no concurrent preflight fan-out
possible). New tests: `import_cap_enforced_before_expensive_preflight`,
`import_throwing_preflight_releases_slot` (Swift). Supersedes/refines secfix/c-vault-jobslot
(1.12.0) which established the slot-release invariant but placed the preflight before
the cap acquisition.

### 1.12.0 -- 2026-06-28
Vault availability hardening (secfix/c-vault-jobslot): documented the vault job
concurrency cap (4 slots, Swift port) and the slot-release invariant. In the Swift
port, `moot_vault_import` ran `hashAllNotes` preflight BEFORE `checkAndRegister`
so a preflight failure never consumed a slot. Non-regular `.md` entries (directories,
symlinks) are skipped in `hashAllNotes` rather than causing a fatal throw. The Rust
port is safe by construction (`run_import` records jobs only after bridge completion;
`collect_and_hash` skips non-files). Both behaviors and the concurrency contract are
described in §Vault tools above. New tests: `hashAllNotes_skips_directory_named_md`,
`import_cap_not_exhausted_after_directory_md_vault` (Swift); `hash_all_notes_skips_directory_named_md`,
`import_with_directory_md_vault_does_not_exhaust_ledger` (Rust). Note: the preflight-
before-cap ordering in this version left `hashAllNotes` outside the cap — corrected in
1.13.0 (secfix/c-vault-cap).

### 1.4.0 -- 2026-06-19
`moot_estate_ping` response now includes a build serial segment:
`pong: estate <name> [<uuid>] is live — build <serial>`. The serial is derived
once at `ToolDispatcher` (Swift) / `Dispatcher` (Rust) construction from the
running executable's mtime and size; stored as `buildSerial` on the dispatcher;
threaded to `runEstatePing` / `run_estate_ping` without per-call filesystem
access. Override via `MOOTX01_BUILD_SERIAL` env var (non-empty value used
verbatim). New tests: `testEstatePingIncludesBuildSerial`,
`testEstatePingHonorsBuildSerialOverride` (Swift);
`estate_ping_includes_injected_build_serial` (Rust). Spec companion: § 14 in
ARIA_MCP_SPEC.md updated to document the derivation contract.

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

### 1.14.0 -- 2026-06-29
Security fix (secfix/c-aria-minor, CAND-043): `GET /api/graph` now ignores the
`?estate=` query parameter and always reads the **default estate's** topology
snapshot. The Swift private function signature changed from
`graphSnapshot(estate:topologyReader:)` to `graphSnapshot(topologyReader:)`;
callers (the `route` function) no longer extract the `estate` query string or
pass it to the reader. The `queryValue(_:in:)` helper was removed as it had no
remaining callers. This matches the existing Rust posture where `get_graph_snapshot`
always uses `registry.default` and explicitly documents that `?estate=` is ignored.
The observable GET /api/graph response format is unchanged.

### 1.15.0 -- 2026-07-04
the connection-ownership contract §5: `moot_estate_ping` / `moot_estate_status` gain an opt-in
`version_skew:` line (see the new "Version-skew advisory" subsection under
§`moot_estate_status` — sync field vocabulary, below) when the host detects a
mismatch between an installed plugin (currently Claude Code's
`mootx01@mootx01`) and the running binary's version. `ToolDispatcher`
(Swift) gains a `versionSkewAdvisory: String?` field, injected at
construction the same way `buildSerial` already is; `Dispatcher` (Rust)
gains a `version_skew: String` field (empty string ⇒ no advisory), threaded
through `dispatch_tool_with_vault_ledger` / `interface_tools::dispatch`
alongside `build_serial`. Computed once at server startup by the host binary
— `MootInstallerCore.VersionSkewAdvisory.compute` (Swift) /
`mootx01_cli::core::mcp_ownership::version_skew_advisory` (Rust) — never by
the kit itself, which does not read `~/.claude/plugins/` or know a product
version. `aria-mcp-server` (both ports) has no plugin concept and always
passes the empty/nil default. Both ports at parity.

### 1.22.0 -- 2026-07-16
Upstream-release advisory: `moot_estate_ping` / `moot_estate_status` gain an
opt-in `update_available:` line (see the "Upstream-release advisory"
subsection beside the version-skew one) when a newer product release exists
than the running binary. `ToolDispatcher` (Swift) gains
`updateAdvisoryProvider: (@Sendable () async -> String?)?` (defaulted `nil`);
`Dispatcher` (Rust) gains `update_advisory: Option<UpdateAdvisoryProvider>`
via the `with_update_advisory` builder (the Rust equivalent of the defaulted
Swift parameter — existing `Dispatcher::new` call sites unchanged), threaded
through `dispatch_tool_with_ledgers` / `interface_tools::dispatch` alongside
`version_skew`. Unlike `version_skew` the value is a lazily-evaluated
provider, not a startup-computed string — the resident daemon outlives
releases. Rate limiting (24h TTL), the 4s probe bound, failure caching, and
the `MOOTX01_NO_UPDATE_CHECK` kill switch live in the host advisor
(`MootInstallerCore.UpdateAdvisor` / `mootx01-cli::core::update_advisor`);
the kit only renders the line. Resident daemons only; stdio one-shots and
`aria-mcp-server` (both ports) never wire a provider. Both ports at parity.

### 1.21.0 -- 2026-07-16
Rust leg Anthropic memory_20250818 adapter parity (M-MEMTOOL-1): `memory_adapter.rs`
implements all six commands (view, create, str_replace, insert, delete, rename),
the `MOOTX01_MEMORY_TOOL=1` opt-in gate, the Normal-tier sensitivity filter (mirrors
`isMemoryAdapterVisible` in Swift), and sensitivity-tier carry-forward on edits so
elevated-tier drawers are not silently downgraded. `tool_list.rs` gains
`memory_enabled()`, `build_tool_list_with_flags(vault_on, memory_on)`, and the
`memory_adapter_tool()` schema; `build_tool_list()` and `build_tool_list_with_vault_flag()`
delegate to it. When `memory_on=true` the `memory` tool is prepended (first in list,
mirrors Swift `memoryAdapterTools()` prepend order), raising the count to 72/66.
Existing dispatch and count tests updated to use `build_tool_list_with_flags(vault_enabled(), false)`
for determinism (prevents racing with env-var mutations in memory-tool tests). New test
file `tests/memory_adapter_tests.rs`: 19 tests covering env gate, tool-list projection,
and per-command happy + error paths. Updated §1 Rust package layout and Rust binary
description to document `memory_adapter.rs` and the opt-in gate.

### 1.20.0 -- 2026-07-16
Dataset tools (MX-TAB-7): three new tools `moot_file_dataset`,
`moot_dataset_query`, `moot_dataset_stats` with `.interface` provenance —
always visible, not vault-gated. Both ports (Swift `DatasetTools.swift`,
Rust `dataset_tools.rs`) at parity. Tool count: 68 → 71 (vault-on), 62 → 65
(vault-off). Adds new "Dataset tools" subsection in §2. Also adds previously
undocumented public types: `DiscriminationLevel`, `RecallDiscrimination`
(scale-independent recall confidence heuristic, both ports mirrored), and
`MonitoringControl` protocol (the monitoring-control injection seam). Adds
`memoryToolEnabled` to ToolProjection block (opt-in memory_20250818 adapter,
MOOTX01_MEMORY_TOOL=1). Updates stale Rust tool census (55 → 71).
Updates `DatasetTools.swift`, `RecallDiscrimination.swift`, and
`MemoryToolAdapter.swift` / `MonitoringControl.swift` to §1 package layout.

### 1.19.0 -- 2026-07-12
Contradiction hunter MCP surface (both ports at parity, tool count 66 → 68):
`moot_hunt_contradictions` (recipe — on-demand bounded content sweep; strong
findings persist as PROPOSED `contradicts` tunnels, borderline pairs return
with snippets for agent adjudication) and `moot_review_tunnel` (Tier 2 —
accept/reject a proposed tunnel via `Estate.respondToTunnel`; rejection is
durable). `moot_link_memories` gains optional `proposed: bool` (files the
link in the PROPOSED lifecycle). `moot_dream` now runs the hunt sweep as its
content-driven third phase and reports `contradictionsProposed` /
`contradictionCandidatesBorderline`. `moot_lens_contradiction` output gains
lifecycle tiers: proposed edges shown by default flagged
`proposed (agent-derived, unreviewed)`; withdrawn/superseded excluded.
Permission tier: both new tools `ask` (mutation table, both installer legs).
Teachme guides for both tools plus updated dream/link guides. Contract tests
updated: 68 total, 62 vault-off (Swift `ToolProjectionTests` /
`V1ConformanceTests` / `VaultToolsTests`; Rust `dispatch_tests`;
installer `PermissionsWriter` inventories both legs).

### 1.18.0 -- 2026-07-05
the sensitivity-grant contract wave 8.2: `moot_monitoring_status` tool (§2 Tool projection, Tier 5 —
Estate tools, monitoring-control entry). Injection pattern: `MonitoringControl`
protocol (Swift) / trait (Rust) defined in AriaMcpKit; concrete implementation
(`StatsStoreMonitoringControl`) in AriaResident (Swift) and `http_server.rs`
(Rust). Read path: absent `enabled` arg returns current flag state. Write path:
present `enabled: bool` persists the flag via `StatsStore.setMonitoringEnabled` /
`set_monitoring_enabled` (wave 8.1 API), echoes new state with
`monitoring_source: user` line. No-store case: returns `monitoring: unavailable`
— never fabricates state. Permission tier: `ask` in both namespace prefixes.
Wave 8.3 smoke: `HTTPReadAPITests.freshStoreMonitoringDefaultIsEnabled` verifies
fresh StatsStore seeds monitoring=ON (wave 8.1 regression gate). Tool count: 64
(Swift and Rust at parity).

### 1.17.0 -- 2026-07-05
the sensitivity-grant contract sensitivity unlock/lock control endpoints (§4.6). Documents
`POST /api/control/unlock` and `POST /api/control/lock` — platform-
specific identity verification (macOS: LocalAuthentication; Linux/Windows:
PBKDF2-HMAC-SHA256), request/response shapes, proof freshness gate,
CLI surface (`mootx01 unlock private|secret`, `mootx01 lock`). Both
Swift and Rust ports at parity. Redaction advisory
(`sensitivity_advisory:` line) added to `moot_memory_search` and
`moot_memory_get` output when no grant is active and estate has
restricted/secret rows.

### 1.16.0 -- 2026-07-04
Added `moot_memory_get` (§2 Tool projection, Tier 1 — Core Memory table)
— fetch-drawer-by-ID, build-now per Bob's ruling. Input: `id` (drawer UUID,
required) plus the standard `estateID` every direct tool accepts.
Output: verbatim content (hydration `.full`), room/wing, `filedAt`/
`eventTime`, the five adjective-axis fields (state, trust, sensitivity,
exportability, confirmation), lineage, and a linked-tunnel summary
(same tunnel-scan pattern as `moot_connection_search`/
`moot_connection_map`). Swift `ToolDispatcher.runMemoryGet` routes
through `Estate.getDrawers(ids:matchingFrame:hydrationLevel:)`; Rust
`interface_tools::run_memory_get` routes through the Rust twin
`Estate::get_drawers_matching_frame` — both with an empty filter chain,
so `moot_memory_search`'s default containment gate (see the `filter`
argument section above) applies unchanged. A drawer that exists but
fails the gate is reported with the same "Memory not found: `<id>`"
error `moot_link_memories` already uses for an unresolvable id — the
by-id door cannot confirm existence of content the gate would
otherwise hide. Tool surface: 62 -> 63 (Tier 1: 7 -> 8; vault-on
62 -> 63, vault-off 56 -> 57). teachme guide added on both ports. Both
ports at parity. New tests: `MemoryGetTests.swift` (10 tests); Rust
`dispatch_tests.rs` `memory_get_*` (7 tests) + 1 teachme test.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
