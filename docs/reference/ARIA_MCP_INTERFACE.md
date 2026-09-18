---
title: aria-mcp Interface
version: 5.0.0
status: accepted-1.1-target
date: 2026-09-15
description: "Public API surface for aria-mcp in both the Swift and Rust ports. 2.0.0: consolidated reorganization (adopted from the ARIA_PROPOSED pair) — full result-format grammar catalog with Samples, structured base-row-plus-extensions schemas, zero/one/many active-adornment composition and structured minter provenance. Full history: ARIA_MCP_INTERFACE_CHANGELOG.md. 2.3.0: per-operation entry template across the six-family catalog. 2.11.0: subject-length contract violations on moot_file_memory and moot_update_memory (setSubject) now return isError:true results rather than JSON-RPC errors. 2.12.0: moot_memory_search reply parity across the ports — Rust honours explain, its structured rows carry the Swift field set. 2.13.0: moot_file_fact oversize subject now returns isError:true with the contract message, both ports. 2.14.0: ENC-W6B — S1/S2 row schema updated: firstSentence→bestSpan, ssc object→sscFacts string, adornment column retired; moot_distill and moot_redistill retired. 2.15.0: dark mint tools and MOOTX01_MINT_TOOLS removed; adornment_miner status lines gone; Rust tools/list drops moot_distill/moot_redistill. 2.16.0: moot_estate_status drops the index_composition_policy line, both ports. 3.0.0: removed stored adornment projections and the contentFallback representation; recorded the removed force-redistill service. 3.1.0: moot_memory_search answer block parity — the Rust reply renders confidence:, citations: (five ids) and signals: in the Swift shape. 3.2.0: the signals: line reads the span rerank stage (lane_agreement = lexical-versus-span order agreement, dense_spread = span cosine spread) and the discrimination cap fires only when no span rerank stage is registered on the estate. 3.3.0: moot_packet_get and moot_packet_lineage read through the same containment gate as moot_memory_get (state, wing, room, sensitivity ceiling lifted only by a live grant, provenance Restricted/Secret drop) and take an optional wing argument. 3.4.0: moot_file_memory files at the live sensitivity grant ceiling, both ports: an omitted sensitivity takes the grant's tier, a lower explicit tier returns isError:true naming the ceiling, and the reply adds a sensitivity: line while a grant is live. 3.5.0: the same ceiling on moot_file_packet (new optional sensitivity argument, Swift) and on the memory adapter's create, str_replace and insert (no argument, both ports). 3.6.0: the discrimination cap reads the span rerank stage alone; the whole-record dense lane and its presets compile only under the WholeRecordDense trait. 3.7.0: the moot_recall_shaped roster under the dark switches (DenseFamilies 37 names, LSA 39, product build 26) and the byte-identical whole-record vacuum line printed by mootx01 upgrade in both ports. 3.8.0: §2.8 records the aria-mcp command line in both ports — the accepted forms, the four refusals, exit 1 on a usage error, --help, and the rule that --in-memory resolves its catalog record first and then serves it transient; the 120 of the subject contract is stated as Unicode scalars. 3.9.0: §2.8 corrects --in-memory: the estate starts empty (record resolved for validation only, content NOT loaded); table row and explanatory text updated. 3.9.1: ARIAServerConstants (in AriaMCPWire) added to §14.3 — the single stored declaration of noSubjectMarker, so consumer targets that link only AriaMCPWire have an interface reference; ResultComposer.noSubjectMarker forwards to it. 3.9.2: V2-A surface adoption — the v2 catalog is now the only published surface (git tag ARIAv1-Terminus marks the last commit before the v1 surface was removed); moot_federated_search renamed moot_federated_recall, moot_run_migration renamed moot_migration_run, moot_confirm_migration renamed moot_migration_confirm; moot_recollect removed (§16.3 retired-names list); dispatchableUnadvertisedTools removed from the frozen-posture read-set description (§12.2). 3.10.0: the catalog gains four previously-undocumented entries — moot_memory_recall_transcript, moot_propose_contradictions, moot_help, and moot_monitoring_set — each added under its family/tier with the standard per-operation template. 3.10.1: front-matter description updated to include the 3.9.1 and 3.9.2 entries that had been omitted; no contract change. 3.10.2: §12.5 coaching triggers wired to the v2 surface — AriaV2Coach/v2::coach implements all six triggers; the v2 envelope gains a new hint slot (structuredContent['hint'] + appended 'hint: …' line in content[0].text) and a periodic coaching block appended to content[0].text at the controlled cadence; estate-provisioned coaching_calls and sticky_enabled apply via applyPreferences on the first dispatch call. 3.11.0: moot_reclassify_fdc promoted to a real v2 write path — adds apply, mode, limit arguments; output moves to 18-field structuredContent.data contract (content[0].text carries a compact human report truncated at 512 scalars); moot_estate_status data gains fdc_recalculation field (current/missing/stale). 3.11.1: moot_recall_distilled Output gains capabilities.distillation and compact-text display line; §11.2 distilled sample extended with display line; §11.6 capabilities table and schema rule updated. 3.11.2: §11.6 capabilities paragraph extended with one sentence stating that distillation is measured over the rows actually emitted carrying a distilled field, after the row cap and privacy projection, using the CognitionKit measurement; the v2 surface sums per-row originalTokenCount and tokenCount from the recipe. 3.12.0: §3.2 rewritten to document the global-modifier contract — mode is stripped at the ARIA door before decode (not injected into per-tool schemas); documented once in the moot_help directory response under the global_modifiers key; owner operations that declare mode in their own input schema are excluded from door stripping; ARIASessionProtocol names the modifier. 4.0.0 (BREAKING): the four work-packet operations retired — moot_file_packet, moot_packet_get, moot_packet_list, moot_packet_lineage removed from the catalog, both ports (Swift only ever had a live implementation; the Rust twin never existed). Tool count is now 80 (vault-on) / 73 (vault-off). 4.1.0: adds report_withheld and meta.withheldBySensitivity to the recall and lens operations. 4.2.0: adds moot_memory_get(depth: "skim") and its preview-only skim object. 4.3.0: moot_list_lenses output is ordered alphabetically by tool name; both ports sort explicitly. 4.5.0: moot_recall_shaped roster is 35 entries (RI + LSA + whole-record presets); DenseFamilies and WholeRecordDense switch references removed from all tool descriptions. 4.6.0: adds moot_recall_similar, the paraphrase door over the whole-record LSA lane (query, limit 1-50 default 10, estate_id; transcript-shaped rows, no evidence block), both ports; tool count 81 (vault-on) / 74 (vault-off); the capability digest moves. 4.7.0: moot_drain_status always lists the fact_extraction lane (pending = drawers still owed extraction for the active recipe); report shape unchanged; both ports."
spec_type: protocol
authors: MOOTx01 maintainers
relates_to:
  - ARIA_MCP_SPEC.md (the behavioral contract)
  - GENIUSLOCUSKIT_SPEC.md (the estate verb surface tools dispatch to)
  - LOCUSKIT_SPEC.md (drawer storage and lifecycle semantics)
---

# aria-mcp Interface

This document defines how clients and implementations address ARIA: transports,
methods, tools, arguments, public types, wire shapes, endpoints, package
locations, and conformance entry points. Behavioral meaning and invariants live
in [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md). This 2.0.0 revision is the adopted
consolidation of the pre-2.0.0 document (history preserved in
[ARIA_MCP_INTERFACE_CHANGELOG.md](ARIA_MCP_INTERFACE_CHANGELOG.md)); the
drafting record lives in the archived ARIA_PROPOSED pair (docs/archive/).

## Contents

1. [Interface boundary](#1-interface-boundary)
2. [Transport and protocol](#2-transport-and-protocol)
3. [Common tool contract](#3-common-tool-contract)
4. [Tool surface and provenance](#4-tool-surface-and-provenance)
5. [Recall family](#5-recall-family)
6. [Capture family](#6-capture-family)
7. [Lifecycle family](#7-lifecycle-family)
8. [Lenses family](#8-lenses-family)
9. [Maintenance family](#9-maintenance-family)
10. [Utility family](#10-utility-family)
11. [Shared result formats](#11-shared-result-formats)
12. [Session interface](#12-session-interface)
13. [Auxiliary HTTP endpoints](#13-auxiliary-http-endpoints)
14. [Public implementation types](#14-public-implementation-types)
15. [Package and dispatch map](#15-package-and-dispatch-map)
16. [Errors and conformance](#16-errors-and-conformance)
17. [Source reconciliation](#17-source-reconciliation)
18. [Changelog](#changelog)

## 1. Interface boundary

### 1.1 Audience

This reference serves:

- MCP clients discovering and calling the `moot_*` surface;
- SDK implementers maintaining the Swift and Rust ports;
- test authors pinning schemas and byte-exact response forms; and
- operators connecting local clients to the resident daemon.

### 1.2 Ownership

This Interface owns:

- method, tool, argument, field, endpoint, and public-type names;
- required/optional status, types, default representation, and legal values;
- JSON-RPC, JSON, and text response forms;
- package and symbol locations; and
- conformance commands and fixtures.

The Spec owns semantics, invariants, state transitions, release profiles, and
behavioral failure rules.

### 1.3 Surface discovery

The generated `tools/list` response is the authoritative census for a running
build. Counts recorded in the source documents are snapshots from different
versions and port configurations. This reference therefore organizes tools by
stable family and provenance rather than maintaining one prose total.

## 2. Transport and protocol

### 2.1 Server methods

The transport-neutral dispatcher handles:

| Method | Interface |
|---|---|
| `initialize` | Echo negotiated protocol version and advertise capabilities |
| `ping` | Return protocol-level liveness |
| `tools/list` | Return generated tool descriptors |
| `tools/call` | Dispatch one named tool with one argument object |
| notifications | No response frame |

Resources, prompts, completions, sampling, elicitation, and tasks follow the
release profiles in the Spec.

### 2.2 JSON-RPC envelope

```swift
public enum JSONRPCErrorCode {
    public static let parseError: Int          // -32700
    public static let invalidRequest: Int      // -32600
    public static let methodNotFound: Int      // -32601
    public static let invalidParams: Int       // -32602
    public static let internalError: Int       // -32603
    public static let toolDispatchFailure: Int // -32010, internal marker
}

public struct JSONRPCRequest: Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue?
    public var isNotification: Bool { get }
    public static func decode(_ value: JSONValue) -> JSONRPCRequest?
}

public struct JSONRPCResponse: Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONValue
    public let payload: Payload
    public enum Payload: Sendable, Equatable {
        case result(JSONValue)
        case error(JSONRPCError)
    }
    public static func ok(_ id: JSONValue, _ result: JSONValue) -> JSONRPCResponse
    public static func failure(_ id: JSONValue, _ error: JSONRPCError) -> JSONRPCResponse
    public var asJSONValue: JSONValue { get }
}

public struct JSONRPCError: Sendable, Equatable, Error {
    public let code: Int
    public let message: String
}
```

### 2.3 JSON wire value

```swift
public enum JSONValue: Sendable, Equatable {
    // null, bool, integer, double, string, array, object
    public static func from(_ any: Any) throws -> JSONValue
    public static func parse(_ data: Data) throws -> JSONValue
    public func encoded() throws -> Data
    public var foundationObject: Any { get }
    public var objectValue: [String: JSONValue]? { get }
    public var stringValue: String? { get }
    public var integerValue: Int64? { get }
    public var boolValue: Bool? { get }
    public var arrayValue: [JSONValue]? { get }
}

public enum JSONValueError: Error, Equatable {}
```

### 2.4 Stdio

Stdio uses one newline-delimited JSON-RPC frame per input and output line.
Protocol output uses stdout; diagnostics use stderr.

### 2.5 Loopback HTTP

The resident transport accepts JSON-RPC POSTs on loopback. The default port is
4242 and the default request-body cap is 4 MiB. A non-loopback Origin is
rejected by the CSRF/DNS-rebinding guard.

### 2.6 Stdio-to-HTTP proxy

`mootx01 proxy` adapts stdio frames to independent loopback POSTs. The shared
admission surface exposes:

```swift
MootInstallerCore.proxyMaxFrameBytes       // 4 * 1024 * 1024
MootInstallerCore.proxyDisposition(statusCode:bodyEmpty:)
MootInstallerCore.proxyRequestID(of:)
MootInstallerCore.ProxyConcurrencyGate     // maximum 16 in flight
```

### 2.7 Cloud-agent adapter

`mootx01-botLink` and `mootx01 botlink` provide the explicit one-shot path for
agents that cannot reach the user's loopback daemon. Subcommands are `ping`,
`list`, `call`, and `rpc`. Stdout is machine JSON. Exit codes are:

| Code | Meaning |
|---:|---|
| 0 | success |
| 1 | transport failure |
| 2 | tool returned `isError` |
| 64 | usage error or non-loopback `--http` |

When native `moot_*` tools are present, an agent uses them instead of botLink.

### 2.8 Reference-server command line

`aria-mcp` (Swift `apps/aria-mcp-server`, Rust `apps/aria-mcp-server/rust`)
takes three arguments and no others. Both ports parse the same table.

```
usage: aria-mcp [--db <name>|<dir>/<name>] [--in-memory]
```

| Invocation | Estate |
|---|---|
| `aria-mcp` | the catalog's active estate |
| `aria-mcp --db <name>` | the registered estate of that name |
| `aria-mcp --db <dir>/<name>` | a transient estate at that directory, this process only |
| `aria-mcp --in-memory` | a fresh empty estate on the in-memory backend (record resolved for validation only) |
| `aria-mcp --help` / `-h` | prints the usage line to stdout, exit 0 |

`--in-memory` opens the catalog and resolves the record BEFORE the backend is
chosen, so a `--db` that names no registered estate and carries no path is
refused rather than ignored. What it then serves is a **fresh empty estate**
on the in-memory backend — the record's content is NOT loaded; the estate
starts with zero drawers. Nothing survives the process: no Ed25519
federation identity is minted and no charter drawers are seeded. The identical
rule governs `mootx01 serve --in-memory` in both ports.

A refused command line prints the reason and the usage line to stderr and
exits **1** in both ports. Four shapes are refused:

| Refusal | Reason |
|---|---|
| an unrecognised argument | `aria-mcp` has no other configuration on its command line |
| `--db` with no value | the estate would be unnamed |
| `--db` followed by a value beginning with `--` | the operator meant a flag and lost it to the value slot |
| a repeated `--db` | two estates named, neither unambiguously the one wanted |

`--frozen` and `--http`, which `mootx01 serve` accepts, are usage errors here.
The frozen posture reaches `aria-mcp` through `MOOTX01_FROZEN` and the HTTP
transport through `MOOTX01_HTTP_PORT`.

## 3. Common tool contract

### 3.1 Call shape

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "moot_memory_search",
    "arguments": {
      "query": "example"
    }
  }
}
```

### 3.2 Common arguments

| Argument | Type | Default | Contract |
|---|---|---|---|
| `estateID` | UUID string | default estate | Direct estate routing where permitted |
| `teachme` | boolean | `false` | Return the tool guide instead of executing |

Interface tools expose `estateID` and `teachme` where their surface permits them.

#### Global modifiers

Global modifiers are arguments stripped at the ARIA door before any operation
decodes its own arguments. They are absent from every per-tool input schema and
from per-operation help text. The full grammar and current modifier list is in
the `moot_help` directory response under the `global_modifiers` key, and the
session orientation payload (`moot_estate_status`) names each modifier.

**`mode`** — advisory session modifier. Accepted on any call. Grammar:
`mode:"Name"` sets the mode; `mode:"Name=Variant"` sets mode and variant; a
bare name (`mode:"Name"`) clears any prior variant for that mode; the last
declaration on a call wins. Fail-open: an unknown mode name or variant is
silently ignored and does not clobber existing sticky state.

*Owner operations* — operations that declare their own `mode` argument in their
input schema — are excluded from door stripping; for those operations, `mode`
belongs to the operation and is passed through untouched. Membership is read
at runtime from the catalog input schema (not a hand-coded list), so a future
operation that declares `mode` is automatically excluded.

### 3.3 Optional arguments

Optional primitive keys use omit-to-default. Unless a tool row says otherwise,
present JSON `null` is invalid for values such as `estateID`, `teachme`,
`filter`, `limit`, `scoring`, `ordering`, `sensitivity`, `exportability`,
`kind`, `impatient`, and `agent`.

### 3.4 Server-owned fields

The server owns infrastructure values including storage lattice plumbing,
embedding model identity, actor identity, and capture channel. Client schemas
expose subject-matter fields and only those infrastructure selectors explicitly
listed by a tool.

### 3.5 Tool result shape

```json
{
  "content": [
    { "type": "text", "text": "..." }
  ],
  "isError": false
}
```

Recall tools that declare `outputSchema` also include `structuredContent` as
defined in §11.3.

## 4. Tool surface and provenance

### 4.1 Projected tool

```swift
public enum ToolProvenance: Sendable, Equatable {
    case interface
    case federation
    case recipe
    case vault
}

public struct ProjectedTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let provenance: ToolProvenance
    public let outputSchema: JSONValue?
}

public enum ToolProjection {
    public static let toolNamePrefix: String  // "moot_"
    public static func tools() -> [ProjectedTool]
    public static func memoryToolEnabled(environment: [String: String]) -> Bool
    public static var memoryToolEnabled: Bool
    public static func federationTool() -> ProjectedTool
    static func recallResultsOutputSchema() -> JSONValue
}
```

### 4.2 Provenance buckets

| Provenance | Contents |
|---|---|
| `.interface` | Core memory, connection, fact, journal, estate, maintenance, monitoring, and dataset tools |
| `.federation` | `moot_federated_recall` |
| `.recipe` | Cognition recipes and the 23 `moot_lens_*` tools |
| `.vault` | Vault export, import, status, reconcile, and job tools |

`MOOTX01_MEMORY_TOOL=1` adds the opt-in Anthropic `memory_20250818`
compatibility tool. Vault-off mode hides the vault tools and local-file import
surfaces identified by the generated projection. Under a frozen serve
(§ 12.2) `memory` answers `view` only. The tool's schema is Anthropic's and
carries no sensitivity argument, so its content-bearing writes (`create`,
`str_replace`, `insert`) follow the live grant ceiling without one (SPEC
§ 12.4): while a restricted or secret grant is live the drawer files at the
higher of the tier it would otherwise carry (`normal` for `create`, the
source file's tier for an edit) and the grant's tier, and the reply appends
`sensitivity: <tier>` to the contract text; `rename` and `delete` are
unchanged; with no grant live the replies keep Anthropic's text exactly.
A file filed restricted or secret is outside the tool's no-grant read
posture (§ 4.2 visibility, `view` reports it absent) until read through a
grant-aware tool such as `moot_memory_get`. Both ports.

### 4.3 Family catalog format

The next six sections list each public verb by progressive-discourse tier.
Every tool entry uses one fixed per-operation template:

- **Purpose:** what the tool does.
- **Input:** arguments and their contract.
- **Behavior:** execution rules recorded at the interface level.
- **Output:** the reply form.
- **Errors:** failure surface beyond the common boundary (§16.1).
- **Sample:** a literal reply sample or the section that carries one.
- **Conformance:** the suite that pins the entry.

Exact JSON Schema remains generated by `ToolProjection.tools()`; these
entries are the human-readable index. A section with nothing
tool-specific to record carries the minimal factual line.

## 5. Recall family

Recall turns a question, anchor, date, or structure into remembered content.

### 5.1 Tier 1 — Survey

#### `moot_memory_search`

- **Purpose:** Hybrid recall.
- **Input:** Exactly one of `query` or `near`; optional `limit`, `filter`,
  `wing`, `media_type`, `door`, `scoring`, `ordering`, `frontier_k`,
  `anomalous_filter`, `answer`, `explain`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
  The tool's `tools/list` description carries the sensitivity advisory
  (§11.12). Recorded follow-ups: `moot_memory_get`, another `near`, or
  precise recall.
- **Output:** Canonical candidate rows plus applicable deviation-only
  control, tie, answer, and coaching lines (§11). `explain: true` follows
  each row with the explanation block (§11.2), identically in both ports.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Canonical candidate grammar and the explain block in §11.2;
  behavioral Sample in Spec § 8.3.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_recall_vague`

- **Purpose:** Two-hop vague-tier recall.
- **Input:** `query`, `hit_limit`, `constituents_per_hit`,
  `total_constituents`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Vague-hit rows followed by original rows (§11.2 two-section
  form).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Two-section grammar in §11.2.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_federated_recall`

- **Purpose:** Grant-authorized recall across locally open estates.
- **Input:** `filter`, `hydrationLevel`, `ordering`, `limit`,
  optional/validated `requesterEstateID`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
  Provenance bucket `.federation` (§4.2).
- **Output:** One section per contributing estate.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Per-estate section grammar in §11.2.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_memory_list`

- **Purpose:** Structural wing/room enumeration.
- **Input:** `wing`, optional `room`, optional `filter`.
- **Behavior:** Capped at 200. `filter: missing_subject` returns ID-only
  debt rows.
- **Output:** Unranked S2 memory rows in filing order (§11.5); debt mode
  renders IDs only.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** S2 grammars in §11.5.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_fact_timeline`

- **Purpose:** Fact history in filing-time order.
- **Input:** Optional `entity`, `limit`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Dated active/retired fact lines, capped at 200 (§11.7
  time-major variant).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Timeline grammar and cap line in §11.7.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_recall_temporal`

- **Purpose:** Date-aware recall.
- **Input:** Includes query or explicit window, temporal window mode, grab
  mode, and limit.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Candidate rows plus temporal narration (§11.2, §11.3).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Temporal control-line grammar in §11.3.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

### 5.2 Tier 2 — Focus

#### `moot_recall_precise`

- **Purpose:** Coarse candidate grab followed by precision reranking.
- **Input:** `query`, `limit`, `pool`, `composition`, `filter`, `wing`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Canonical candidate rows (§11.2).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Canonical candidate grammar in §11.2.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_recall_shaped`

- **Purpose:** Recall under a named `RecallShape`.
- **Input:** `query` or `near`, `preset`, `limit`, `filter`, `wing`,
  `frontier_k`.
- **Behavior:** Unknown preset is invalid.
- **Output:** Canonical candidate rows (§11.2).
- **Errors:** Unknown preset is invalid; otherwise standard JSON-RPC errors
  only (§16.1).
- **Sample:** Canonical candidate grammar in §11.2.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_recall_connected`

- **Purpose:** Connection-aware recall using the shared candidate renderer.
- **Input:** Args and exact schema are generated by the recipe catalog.
- **Behavior:** Renders no text control line; per-result provenance is
  structured (§11.10 `retrievalSource`).
- **Output:** Canonical candidate rows (§11.2).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Canonical candidate grammar in §11.2.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_recall_distilled`

- **Purpose:** Candidate rows with distilled continuations.
- **Input:** `query`, `limit`, `filter`, `echo_query`.
- **Behavior:** Verbatim fallback carries its marker when distillate is
  absent (§11.2).
- **Output:** Candidate row plus unlabeled distilled continuation and
  savings display line (§11.2); structured result includes
  `capabilities.distillation` (§11.6).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Distilled-form Sample and display line in §11.2; structured
  `distillation` keys in §11.6.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_recall_walk`

- **Purpose:** Two-stage escalation: shaped recall, then precise recall
  when confidence is insufficient.
- **Input:** `query`, `limit` 1–50, `filter`, `wing`, `now`, `estateID`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Candidate rows, optional discrimination, and `walk:` metadata
  (§11.2, §11.3).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** `walk:` control-line grammar in §11.3.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_memory_recall_transcript`

- **Purpose:** Strict transcript recall.
- **Input:** Required `query` (non-empty string); optional `estate_id` (UUID).
- **Behavior:** Applies a strict two-stage pipeline: a classifier selects
  transcript-type candidates, then a scored rerank over fresh head candidates
  orders them. The pipeline is operationally unavailable when the encoder
  model or classifier is not loaded; a refusal with `rerank_unavailable` is
  returned in that case rather than a generic recall fallback.
- **Output:** Ranked matches array, each carrying `memory_id`, `room`,
  `excerpt`, `score`, and a `fetch` pointer to `moot_memory_get`; the
  `strict_rerank` evidence block carries pipeline metadata (`status`,
  `policy_version`, pool/head/span limits, encoder model ID and version,
  classifier profile and revision).
- **Errors:** Standard JSON-RPC errors only (§16.1). An empty `query` is
  `invalidParams`. A `rerank_unavailable` refusal is retryable.
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_recall_similar`

- **Purpose:** Find memories that mean the same as the question even when
  they share no words with it: the paraphrase door over the whole-record
  LSA lane.
- **Input:** Required `query` (non-empty string); optional `limit`
  (integer 1–50, default 10); optional `estate_id` (UUID). Unknown keys
  are `invalidParams`.
- **Behavior:** Runs the CognitionKit `similar_recall` recipe: the estate's
  registered corpus lane is probed for the `limit` nearest drawers by
  whole-record vector, hydrated under the caller's sensitivity ceiling
  (`sensitivityAtMost`), and returned in the lane's own nearest-first order.
  No fusion and no rerank are applied. An estate with no registered lane
  returns zero matches. The withheld-by-sensitivity count follows the same
  accounting as `moot_memory_recall_transcript`.
- **Output:** `data.matches`: an array of rows, each carrying `memory_id`,
  `room`, `excerpt`, `score` (raw cosine similarity in [−1, 1]), and a
  `fetch` pointer to `moot_memory_get`. `meta.completeness` is
  `incomplete` (a top-k result). There is no evidence block.
- **Errors:** Standard JSON-RPC errors only (§16.1). An empty `query` or an
  out-of-range `limit` is `invalidParams`. A `lane_unavailable` refusal
  (recipe failure) is retryable and carries `recovery.required_operation`.
- **Sample:** None recorded in this document.
- **Conformance:** `AriaV2SimilarRecallTests` (Swift) and
  `aria_v2_similar_recall_tests.rs` (Rust): strict decode and one
  dispatcher round-trip on a scratch estate.

#### `moot_fact_search`

- **Purpose:** Active fact search.
- **Input:** Optional `query` or exact subject/predicate/object/source
  filters, `limit`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Fact rows (§11.7).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Fact-row grammar in §11.7.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_dataset_query`

- **Purpose:** Typed dataset predicate query.
- **Input:** Dataset `id`, optional `where`, `order_by`, `limit`.
  Predicates use `{col, op, val}` leaves composed with `{and:[...]}` or
  `{or:[...]}`. Operators are `eq`, `ne`, `lt`, `le`, `gt`, `ge`,
  `contains`, `starts_with`, `ends_with`, `is_null`, and `not_null`.
  `order_by` contains `{col, dir}` items. Default limit is 1,000; maximum
  is 10,000.
- **Behavior:** The total-matching count `of M` is optional: when computing
  it would require a separate full scan it is omitted, never silently paid.
- **Output:** Tabular rows with lossless value encoding (§11.9); structured
  tabular results per §11.10.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Tabular grammar in §11.9.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_synthesize`

- **Purpose:** Grounded context synthesis.
- **Input:** Optional `query`, `filter`, `limit`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
  Available under a frozen serve (§ 12.2 `frozen:`): reads candidates
  via recall and generates text; writes no drawer, packet, journal,
  meta, trace, or reward.
- **Output:** Answer/digest fields plus canonical candidate citations
  (§11.4).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Synthesis document grammar in §11.4.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

### 5.3 Tier 3 — Pinpoint

#### `moot_memory_get`

- **Purpose:** Exact drawer hydration.
- **Input:** Exactly one of `memory_id` or `memory_ids`; `depth` is `subject`,
  `distilled`, `skim`, or `full` (default). Legacy dispatch uses `id`/`ids`.
- **Behavior:** Batch shallow depths winnow a shortlist. The tool's
  `tools/list` description carries the sensitivity advisory (§11.12).
- **Output:** S2 batch rows in request order (§11.5) or the S3 full record
  (§11.6).
- **Errors:** A gated or absent single id returns the standard not-found
  tool error (§11.6).
- **Sample:** Full-record Sample in §11.6.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

`depth: "distilled"` returns v23-attributed ContextDistill output, not a
512-character prefix. The same drawer yields the same distillate in Swift and
Rust; the full-depth `distilled` field uses this converter too. Both binaries'
`--version` output reports `converter recall <id> <version>` from this live
converter and `converter hydration <id> <version>` from GLK's CompleteFormV6
selection; the existing product-version first line remains unchanged.

`depth: "skim"` explicitly requests a source-order preview of the complete
distillate, targeting 512 UTF-8 bytes. There is no budget argument. Each v2
`data.memories` row retains `memory_id`, optional `subject`, and `fetch`, and
returns `skim: {text, complete, budgetHonored, savings}` instead of `content`,
`distilled`, or tunnels. `savings` is a 🌱 text line separating estimated
distillation savings from omitted preview tokens. No continuation or fullText
is returned. Compact text carries the same preview, flags, and savings.

`complete` means no distilled text was omitted, not that the preview is
semantically sufficient. An indivisible first group can exceed the byte target;
then `budgetHonored` is false. Fetch the same id at `distilled` or `full` depth
to inspect further. Existing authorization gates apply before either reduction.

Example: `moot_memory_get({"memory_id":"<uuid>","depth":"skim"})`.

#### `moot_connection_search`

- **Purpose:** Outgoing edges from a memory.
- **Input:** `from_id`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Edge rows carrying tunnel ID, label, and endpoint citation
  (§11.8).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Edge-row grammar in §11.8.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_connection_map`

- **Purpose:** Incoming edges to a memory; mirror of connection search.
- **Input:** `to_id`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Edge rows with the header word `incoming` (§11.8).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Edge-row grammar in §11.8.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

## 6. Capture family

Capture admits memories, facts, links, datasets, and imports.

### 6.1 Tier 1 — Intake

#### `moot_palace_import`

- **Purpose:** Import a palace SQLite export.
- **Input:** `path`, `mode` and import options.
- **Behavior:** Vault-gated.
- **Output:** Import report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_json_import`

- **Purpose:** Import the versioned JSON seed schema.
- **Input:** The versioned JSON seed schema, including optional UTC
  `event_time` and `capture_date` fields.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Import report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_vault_import`

- **Purpose:** Start or execute a vault restore/import.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Swift caps concurrent import/export jobs at four and
  acquires a slot before hashing preflight. Every acquired slot terminates
  in exactly one failure or completion path. Rust records completed jobs in
  a bounded in-process ledger because its vault operations are synchronous.
- **Output:** Reply includes a job ID for `moot_vault_job`.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_file_dataset`

- **Purpose:** Create a dataset handle and bulk-load rows.
- **Input:** Required: `name`, `location`, and exactly one data source —
  either inline `rows` or `csv_path`, never both. Inline rows require a
  `columns` array whose types are `text`, `int`, `float`, or `bool`.
  Column names are ASCII identifiers.
- **Behavior:** CSV paths are resolved and confined to the allowed home
  subtree; size is capped at 100 MiB.
- **Output:** Dataset handle acknowledgment.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

### 6.2 Tier 2 — Filing

#### `moot_file_memory`

- **Purpose:** File one memory.
- **Input:** Required: `content`; `subject`, one sentence no longer than
  120 characters; and `location`. Optional fields include wing,
  sensitivity, exportability, kind, event time, `impatient`, and
  `classificationScheme` (`udc` default or `mdcc`).
- **Behavior:** `impatient: true` requests inline semantic indexing;
  omitted/false uses the background encode path. The `sensitivity`
  argument follows the live grant ceiling (SPEC § 12.4): with no
  restricted or secret grant live on the dispatcher's grant ledger an
  omitted `sensitivity` files `normal` and any explicit tier is kept.
  While a grant is live, an omitted `sensitivity` files at the grant's
  tier (`restricted` under a restricted grant, `secret` under a secret
  grant), an explicit tier at or above the ceiling is kept, and an
  explicit tier below it is refused without writing. Both ports read the
  same `SensitivityGrantLedger` the recall tools consult.
- **Output:** Reply begins `filed memory <uuid>` and carries
  location/lineage details. While a grant is live the reply adds a
  fourth line, `sensitivity: <tier>`, naming the tier applied; with no
  grant live the reply keeps its three-line shape.
- **Errors:** Missing `subject` is a JSON-RPC `invalidParams` error.
  A `subject` that is empty or exceeds 120 grapheme clusters is refused at the
  decoder as a JSON-RPC `invalidParams` error, code `-32602`, at path
  `$.subject`. The Rust decoder message is `"exceeds the subject length
  contract"` with correction `"provide at most 120 grapheme clusters"`; the
  Swift twin throws `"Argument 'subject' exceeds the subject length contract."`.
  The refusal carries no count, so a caller compresses the subject and retries
  rather than reading a target length off the error. An explicit
  `sensitivity` below the live grant ceiling returns `isError: true`
  with the text
  `"sensitivity <requested> is below the live grant ceiling <ceiling>: while a <ceiling> grant is live a memory files at <ceiling> or higher. Omit sensitivity to file at the ceiling."`,
  both ports byte-identical. A `sensitivity` of `null` or any value other
  than the four tier names is an `invalidParams` fault in both ports;
  omit the key to inherit the ceiling. Other parameter faults follow the
  standard JSON-RPC error boundary (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

### 6.3 Tier 3 — Assertion

#### `moot_file_fact`

- **Purpose:** File one structured fact.
- **Input:** Required: `subject`, `predicate`, `object`; optional
  `source_id`.
- **Behavior:** Filing time is server-assigned. `subject` is trimmed of
  leading and trailing whitespace before validation.
- **Output:** Filing acknowledgment.
- **Errors:** A `subject` that is empty or exceeds 120 Unicode scalars after
  trimming (the unit both ports count) returns `isError: true` with the text
  `"subject must be 1–120 characters (got N). One telegraphic sentence in
  the AI-facing register — compress, don't truncate."` so the caller can
  compress the subject and retry. Other parameter faults follow the
  standard JSON-RPC error boundary (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_link_memories`

- **Purpose:** Link two memories with a labeled tunnel.
- **Input:** Required endpoint IDs and link label/kind; optional `proposed`
  defaults false.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Reply identifies the tunnel.
- **Errors:** Unresolved IDs trigger the coaching hint (§12.5); otherwise
  standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

## 7. Lifecycle family

### 7.1 Tier 1 — Circulation

#### `moot_withdraw_memory`

- **Purpose:** Soft-remove a memory from active circulation.
- **Input:** `id`, `reason`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Withdrawal acknowledgment.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_move_memory`

- **Purpose:** Reanchor the drawer.
- **Input:** `id`, `location`, optional `wing`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Move acknowledgment.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

### 7.2 Tier 2 — Belief

#### `moot_update_memory`

- **Purpose:** Apply one belief mutation to a memory.
- **Input:** `id`, `mutation`, optional `note`, optional dedicated
  `subject`. Mutations include confirm, reject, contest, resolve,
  supersede, revive, accept, exportability correction, and `setSubject`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Mutation acknowledgment.
- **Errors:** For `mutation=setSubject`: a missing `subject` argument
  is a JSON-RPC `invalidParams` error. A `subject` that is empty or exceeds
  120 grapheme clusters is refused at the decoder as a JSON-RPC `invalidParams`
  error, code `-32602`, at path `$.subject`. The Rust decoder message is
  `"is required and must contain 1 to 120 grapheme clusters before trimming
  for set_subject"`; the Swift twin throws
  `"Argument 'subject' exceeds the subject length contract."`. The refusal
  carries no count, so a caller compresses the subject and retries rather than
  reading a target length off the error. Other parameter faults
  follow the standard JSON-RPC error boundary (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_confirm_memory`

- **Purpose:** Shortcut for the confirm mutation.
- **Input:** `id`, optional `note`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Confirmation acknowledgment.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

### 7.3 Tier 3 — Disposition

#### `moot_erase_memory`

- **Purpose:** Erase a memory and its lineage where permitted.
- **Input:** Required: `id`, `reason`, `confirmed: true`.
- **Behavior:** Confirmation absent or false triggers the coaching hint
  (§12.5).
- **Output:** Reply distinguishes full and partial lineage erasure
  (§11.11).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Erasure result grammars in §11.11.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_retire_fact`

- **Purpose:** End an assertion's active standing.
- **Input:** Fact ID and reason.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Retirement acknowledgment.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_review_tunnel`

- **Purpose:** Review a proposed tunnel.
- **Input:** `tunnel_id`, `decision` (`accept`, `reject`, `endorse`),
  optional `note`, optional `estate_id`.
- **Behavior:** Only proposed tunnels are accepted, and only by the trusted
  user identity. Reviewer identity comes from trusted context; caller-supplied
  `reviewed_by` is rejected.
- **Output:** Review acknowledgment.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

## 8. Lenses family

Every lens is read-only. Findings that name memories use canonical candidate
citations or directly hydratable drawer IDs. Zero results trigger the lens
coaching hint (§12.5). Unless an entry says otherwise, each lens carries
the same four template values. Behavior: read-only, with the behavioral
contract in [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md). Errors: standard
JSON-RPC errors only (§16.1). Sample: none recorded in this document.
Conformance: covered by the §16.2 and §16.3 suites. Per-lens entries
below record the Purpose, Input, and Output facts.

### 8.1 Tier 1 — Climate

#### `moot_lens_theme_weather`

- **Purpose:** Rising and fading themes.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_drift`

- **Purpose:** Structural change over time.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_rhythm`

- **Purpose:** Temporal cadence and FFT-derived periods.
- **Input:** Required `bit` (0–255), `bucketSeconds`, `bucketCount`,
  `endingAt`; optional `topK`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_constellation`

- **Purpose:** Cluster structure.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_keystones`

- **Purpose:** Load-bearing memories.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_bias`

- **Purpose:** Source and confirmation skew.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_divergence`

- **Purpose:** Difference between two estates.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_overlap`

- **Purpose:** Shared structure between two estates.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

### 8.2 Tier 2 — Frame

#### `moot_lens_latent_themes`

- **Purpose:** Themes latent in a recalled set.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_cohesion`

- **Purpose:** Cohesion of a set.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_complexity`

- **Purpose:** Entropy and optional mutual information.
- **Input:** Required `fieldA`; optional `fieldB` and `filter`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_concepts`

- **Purpose:** Formal concepts.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Extents capped at 20 IDs plus overflow in the text preview;
  the structured `extent` arrays are complete (§11.10).

#### `moot_lens_associations`

- **Purpose:** Association rules.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Exemplars capped at 5 IDs in the text preview; the
  structured `exemplars` arrays are complete (§11.10).

#### `moot_lens_apriori`

- **Purpose:** Multi-antecedent Apriori rules.
- **Input:** Optional `minSupport`, `minConfidence`, `minLift`, and `maxK`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_contradiction`

- **Purpose:** Active and proposed contradiction edges.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_trust_synthesis`

- **Purpose:** Trust-weighted reading of a set.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

### 8.3 Tier 3 — Anchor

#### `moot_lens_partial_cue`

- **Purpose:** Completion from a fragment.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_free_association`

- **Purpose:** Associative neighborhood of one memory.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_successors`

- **Purpose:** Likely successors.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_node_motion`

- **Purpose:** Structural movement of one node.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_moment`

- **Purpose:** Similar temporal windows.
- **Input:** Required `windowStart`, `windowEnd`; optional array of
  comparison windows.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_precedence`

- **Purpose:** Audit-derived antecedents.
- **Input:** Required window, `targetField`, and `targetValue`; optional
  `k`.
- **Output:** Lens reading per the family rule above.

#### `moot_lens_anticipate`

- **Purpose:** Suggested next developments.
- **Input:** Common arguments only (§3.2); exact schema is generated by
  `ToolProjection.tools()`.
- **Output:** Lens reading per the family rule above.

## 9. Maintenance family

### 9.1 Tier 1 — Renewal

#### `moot_dream`

- **Purpose:** One dreaming/contradiction cycle.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Rebuilds matrix state, runs one dreaming/contradiction
  cycle, and files proposed conflict candidates.
- **Output:** The cycle report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_reindex`

- **Purpose:** Rebuild recall indexes.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Rebuild report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

### 9.2 Tier 2 — Sweeps

#### ~~`moot_distill`~~ (retired ENC-W6B)

Retired. Distillation is now inline via `ContextDistiller` at read time.
Callers should migrate to `moot_recall_distilled`. Calls to this tool return
`methodNotFound`. The tool is absent from `tools/list`.

#### ~~`moot_redistill`~~ (retired ENC-W6B)

Retired. The force-redistill service is removed. Use `moot_recall_distilled` for
on-demand distilled hydration. Calls to this tool return `methodNotFound`.
The tool is absent from `tools/list`.

#### `moot_hunt_contradictions`

- **Purpose:** Contradiction hunt pass.
- **Input:** Includes `probe_limit`, deterministic `now`, `tier` (`1`,
  `2`, `3`, `all`), and `top_k` 1–50.
- **Behavior:** Default mode may file proposed edges; single-tier mode is
  read-only.
- **Output:** Hunt report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_propose_contradictions`

- **Purpose:** Resolve selected contradiction candidates without rerunning
  analysis.
- **Input:** Required `analysis_ref` (opaque reference returned by
  `moot_hunt_contradictions`); required `candidate_ids` (array of 1..1000
  unique non-empty opaque IDs from the same hunt result); optional
  `estate_id` (UUID).
- **Behavior:** Validates the analysis reference against the caller binding
  and authorization revision before filing. A stale reference, a candidate
  ID not belonging to the named analysis, or a changed authorization revision
  returns a typed operational refusal. Each selected candidate produces a
  `created`, `existing`, or `settled` outcome; a `stale` digest match halts
  with a top-level refusal rather than filing any partial results.
- **Output:** Array of per-candidate objects, each carrying `candidate_id`,
  `status` (`created` / `existing` / `settled`), and for non-settled outcomes
  `tunnel_id` and `lifecycle`.
- **Errors:** Standard JSON-RPC errors only (§16.1). Stale or mismatched
  references return typed operational refusals (`proposal_expired`,
  `proposal_stale`, `proposal_mismatch`, `invalid_candidate`).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_reclassify_fdc`

- **Purpose:** Audit/repair stored field-density classification anchors using
  the current FDC classifier data version.
- **Input:** Four optional arguments: `estate_id` (UUID), `apply` (boolean,
  default `false`), `mode` (`"suspectOnly"` or `"all"`, default
  `"suspectOnly"`), `limit` (integer 1–50000). An unrecognised `mode` value
  or a `limit` outside 1–50000 returns an invalid-argument refusal. With
  `apply: false` (the default) the run is a dry-run: it classifies every
  active drawer and reports what would change, but writes nothing.
- **Behavior:** Phase A classifies every active drawer in parallel
  (deterministic and pure). Phase B applies repairs serially in scan order.
  `suspectOnly` mode limits repair to drawers whose re-classification
  resolves to the `000` sentinel. `all` mode repairs any changed anchor.
  The estate-wide floor (`aria.fdc.recalced_data_version`) is stamped only
  when `applied && mode == all && no limit && skipped_non_candidate_changes
  == 0` (floor_stamp: `"stamped"`). All other outcomes leave the floor
  unchanged. Apply repairs only the primary `udc_code` and `wikidata_qid`;
  `udc_facets` and `wikidata_qids_secondary` are carried forward unchanged.
- **Output:** 18-field structured data object in `structuredContent.data`.
  Required fields: `applied`, `mode`, `estate_id`, `fdc_data_version`,
  `fdc_recalculation_version`, `scanned`, `unchanged`, `empty_content`,
  `candidates`, `updated`, `would_update`, `unclassified_after`,
  `skipped_non_candidate_changes`, `floor_stamp`, `changes` (array, capped
  at 25 entries in scan order), `changes_omitted`. Optional fields:
  `estate_recalced_data_version_before`, `estate_recalced_data_version_after`
  (absent when no floor is stored). `content[0].text` carries a compact
  human report truncated at 512 Unicode scalars; use `structuredContent.data`
  for programmatic assertions.
- **Errors:** Standard JSON-RPC errors only (§16.1). Invalid `mode` or
  out-of-range `limit` returns code `-32602` (invalidParams).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### ~~`moot_run_adornment_pass`~~ (retired, Encoder Rerank Program)

Retired with the adornment store. The name is unknown to both ports;
`tools/call` returns the standard unknown-tool error (§ 16.1). The
`MOOTX01_MINT_TOOLS` launch gate no longer exists.

#### ~~`moot_register_adornment_minter`~~ (retired, Encoder Rerank Program)

Retired with the adornment store. The name is unknown to both ports;
`tools/call` returns the standard unknown-tool error (§ 16.1).

#### `moot_migration_run`

- **Purpose:** Derive and benchmark migration branches.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Migration/benchmark report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_migration_confirm`

- **Purpose:** Promote exactly one eligible benchmarked branch.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** A disqualified branch result triggers the coaching hint
  (§12.5).
- **Output:** Promotion report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

## 10. Utility family

### 10.1 Tier 1 — Presence

#### `moot_estate_ping`

- **Purpose:** Resolve the open estate.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Never carries the sensitivity advisory (§11.12).
- **Output:** Estate identity and build serial, with optional version-skew
  and update-available lines.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_help`

- **Purpose:** Discover the callable operations in this incomplete ARIA v2
  build, or inspect one exact operation.
- **Input:** Optional `intent` or `tool`, mutually exclusive; omitting both
  returns the full directory.
- **Behavior:** A supplied `tool` resolves the exact named operation
  descriptor, or an `unknown_operation` refusal when no callable operation
  matches. A supplied `intent` is trimmed and lowercased, then matched
  against each operation's registered intents under the same normalization;
  the result carries the matched operations, which may be empty. With
  neither key, the reply is the full directory: every callable operation
  plus non-callable directory records (recipes and similar entries that
  stay outside `tools/list`, each carrying `callable: false` and its
  callable tools). Supplying both `intent` and `tool` is a conflicting
  argument.
- **Output:** For `tool`: a single operation object (`id`, `name`,
  `description`, `effect`, `input_schema`, `output_schema`, `intents`).
  For `intent`: the intent string plus a matching `operations` array. For
  the directory case: an `operations` array plus a `directory_records`
  array (`recipe_id`, `description`, `callable: false`, `callable_tools`).
  The envelope's `meta` carries `build_id`, `capability_digest`, and
  `completeness: "incomplete"`.
- **Errors:** Standard JSON-RPC errors only (§16.1). Supplying both
  `intent` and `tool` is `invalidParams` (`conflicting_arguments`). A
  `tool` naming no callable operation returns an `unknown_operation`
  refusal, non-retryable, with recovery pointing back to `moot_help`.
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

### 10.2 Tier 2 — Orientation

#### `moot_estate_status`

- **Purpose:** The composite estate condition surface.
- **Input:** Exact schema is generated by `ToolProjection.tools()`;
  `teachme: true` returns the full orientation guide.
- **Behavior:** The body carries the sensitivity advisory when a grant is
  in effect (§11.12); presence depends only on grant state, never on
  estate contents. The body appends the drain report and the rebuild line
  (Bob rulings 2026-08-26); the narrow tools `moot_drain_status` and
  `moot_rebuild_status` remain the cheap machine-polling surfaces.
- **Output:** Estate counts, subject debt, sync, trace,
  migration/recalculation, modes, protocol, and optional advisory fields,
  plus the appended drain report and rebuild line. The `data` object includes
  a required `fdc_recalculation` field with values `"current"` (stored floor
  matches the current recalculation version), `"missing"` (no floor stored),
  or `"stale"` (floor stored but differs from the current version). Protocol
  block per §12.1; sync vocabulary per §12.2; optional advisories per §12.3.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Protocol-block grammar in §12.1.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_estate_map`

- **Purpose:** Wings and rooms with sensitivity-filtered counts.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Wing/room map with counts.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_list_lenses`

- **Purpose:** Cognition catalog.
- **Input:** Terse by default; `verbose: true` for full descriptions and
  required arguments.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Lens catalog listing. Tools are ordered alphabetically by tool name.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_list_recipes`

- **Purpose:** Recipe catalog.
- **Input:** Same terse/verbose convention as `moot_list_lenses`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Recipe catalog listing.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_monitoring_set`

- **Purpose:** Set daemon telemetry monitoring and return only its
  confirmed effective state.
- **Input:** Required `enabled` (boolean).
- **Behavior:** Sets the requested value through the injected
  `MonitoringControl` seam (§14.3), then re-reads the control before
  reporting success. The write is best-effort and cannot self-report
  whether persistence survived, so a nil or mismatched readback renders
  as a refusal rather than an optimistic success.
- **Output:** `monitoring: "enabled"` or `"disabled"`, reflecting the
  confirmed post-write readback, never the requested value directly.
- **Errors:** Standard JSON-RPC errors only (§16.1). Typed operational
  refusals: `monitoring_unavailable` (no monitoring control in this
  daemon context) and `monitoring_unverified` (the write may have
  landed, but its effective state could not be confirmed), the latter
  with recovery pointing to `moot_monitoring_status`.
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_monitoring_status`

- **Purpose:** Read or set monitoring.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Operates through the injected control seam
  (`MonitoringControl`, §14.3).
- **Output:** Monitoring state.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_dataset_stats`

- **Purpose:** Per-column dataset statistics.
- **Input:** Required dataset `id` and optionally one `column`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Count, null count, distinct count, and numeric
  min/max/mean/stddev per the §11.9 stats grammar.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Stats grammar in §11.9.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_vault_status`

- **Purpose:** Vault configuration and posture.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Vault configuration and posture report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

### 10.3 Tier 3 — Operations

#### `moot_drain_status`

- **Purpose:** Poll registered drains without claiming work.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Distinguishes no drain from an idle drain. Lanes include
  `dreaming` (the recall-event dreaming queue — a genuine queue drain,
  paid down out-of-band; the benchmarker's encode barrier denylists it)
  and `fact_extraction` (always listed: `pending` is the count of drawers
  still owed fact extraction for the active recipe — bit 28 clear —
  paid down only by a dreaming cycle's bounded batch; `state` is
  `draining` while any drawer is owed and `idle` once none are; the
  benchmarker's encode barrier denylists it, and a caller settles an
  estate on this lane reaching `idle` rather than by running blind
  dreaming cycles). A rebuild is not a drain, so it never appears here
  (see `moot_rebuild_status`).
- **Output:** Drain report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_rebuild_status`

- **Purpose:** The derived-state rebuild operation status.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Covers reindex backfill and basis retrain plus re-embed,
  whoever triggered it. A rebuild is not a drain, so it never appears in
  `moot_drain_status`.
- **Output:** `rebuild: running | idle`.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_vault_export`

- **Purpose:** Start/execute a vault export.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Concurrency and completion rules per the
  `moot_vault_import` entry (§6.1).
- **Output:** Job identity.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_vault_job`

- **Purpose:** Poll a vault job.
- **Input:** `job_id`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Running/complete/failed, elapsed time, counts, or error.
- **Errors:** Unknown `job_id` returns `isError: true`.
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_vault_reconcile`

- **Purpose:** Reconcile vault state against the estate.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Reconciliation report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_read_journal`

- **Purpose:** Read recent diary entries.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Recent diary entries.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_write_journal`

- **Purpose:** Append one session-continuity entry.
- **Input:** Required `entry`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Append acknowledgment.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_timing_report`

- **Purpose:** Report timing/benchmark instrumentation.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Present where the generated surface includes it.
- **Output:** Timing/benchmark report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

## 11. Shared result formats

Decision basis: RETRIEVAL_SHAPE_OPTIMIZATION_2026-08-25 (register R1–R16).
Behavioral semantics: Spec § 8. This section owns every literal grammar.

### 11.1 Row-grammar rules

These rules apply to S1 (ranked candidate), S2 (unranked memory), S4
(fact), and S5 (edge) rows and make them stable presentation. Machine
parsing uses `structuredContent` (§ 11.10); the text is the AI surface and
audit fallback.

1. **Separator.** The three-character sequence ` · ` (space, U+00B7,
   space). The renderer guarantees it never occurs inside a value: each
   value is normalized — embedded newlines become one space, whitespace
   runs collapse, leading/trailing whitespace is trimmed, and any literal
   `·` inside a value is replaced with `-`. (S6 tabular values are exempt —
   § 11.9.)
2. **Fixed columns.** Every row shape has a fixed column count. An absent
   optional value renders `-` occupying its whole column: on the S1 row, a
   best span byte-identical to the subject and an absent SSC (Semantic
   Search Candle) each render `-`. A literal `-` inside a real value is
   unambiguous because the placeholder only ever occupies a whole column.
3. **Truncation.** The best-span column uses the shared first-sentence
   truncator with a 120-character limit. Subject: ≤120 by capture contract.
4. **Timestamps** are ISO-8601 with trailing `Z`. **Scores** are `%.4f`,
   never absent on a ranked row, never zero for a genuinely ranked hit.
5. **Ordering.** S1: score-descending under the tie-group contract. S2
   memory list: filing order. S2 batch get: request order — exactly one
   line per requested id in its request position; duplicate ids produce
   duplicate lines. S4: filing-time order. S5: edge filing order.
6. **Caps** append one line ONLY when hit, naming the cap and the
   narrowing argument (e.g. `listing capped at 200 — narrow with room`).
7. **Empty results** render the surface's zero-count header plus at most
   one actionable `hint:` line; never diagnostics.

### 11.2 Canonical candidate text (S1)

```text
found N candidate memories, one per line
<uuid> · <subject> · <best span | -> · <SSC facts | -> · <event time> · <score %.4f>
```

Singular header: `found 1 candidate memory, one per line`. Behavioral
contract and Sample: Spec § 8.3. Emitted identically by memory search and
precise, shaped, connected, temporal, and walk recall — steering is
scoring, never shape. Federated search renders one section per estate:

```text
estate: <name> [<uuid>]
found N candidate memories, one per line
<rows>
```

Vague recall renders two S1 sections:

```text
found N vague summaries, one per line
<rows>
found M hydrated originals, one per line
<rows>
```

Distilled recall follows each row with text computed inline from its source
content. The continuation is indented by four spaces. Every returned row
has an inline rendering.

```text
found 1 candidate memory, one per line
30B1B3B0-945D-4C07-AE57-53D9FFC9B543 · Evaluation follow-up · Review the proposal on Friday. · - · 2026-01-01T00:07:52Z · 0.5687
    Review the proposal on Friday.
```

The v2 compact text for the same result is `Returned 1 distilled recall
result(s).` followed on the next line by the savings display line. For
this row the distilled rendering equals the content, so the line reads
`🌱 Distilled: ~7 tokens returned vs ~7 original · ~0 saved (0%)` (the
estimator gives 7 for the 30-byte, five-word body).

No acknowledgment or contract-change notice ever precedes results.

`explain: true` on `moot_memory_search` follows each row with the recall
engine's explanation block, two-space indented, before the control lines.
The block is the `RecallHit.explanation` array rendered one line each, in
both ports: the sorted candidate-supply sources (`none` when empty), the
non-zero score columns to two decimals (`final=` when every column is
zero), the effective mode and scoring, a `why:` sentence built from the
query type and the active signals, and, when the dense lane voted, the
signal ids that voted. The structured twin is unchanged by `explain`.

```text
found N candidate memories, one per line
<S1 row>
  sources: <candidate-supply sources>
  score: <contributing score columns>
  mode: <mode> | scoring: <scoring>
  why: <query and active-signal explanation>
```

Encoder evidence is included when the span stage contributes. Retired
record-vector families do not appear in the default build.

Both ports assert the block's lines against the shared vector
`GeniusLocusKit/Tests/Conformance/recall_explainer_fixture.json`.

### 11.3 Control lines (deviation-only, fixed grammar, after the rows)

```text
discrimination: low — top results within epsilon.
discrimination: medium — partial separation.
temporal: <window-mode> (<source>, <grab>) window <from>..<to>[ ±Nd]
temporal: loose date-seeking — real-dated memories first; read the answer from each row's event_time
walk: stage=<stage> stoppedEarly=<yes|no>
retrieval: degraded — one or more ranking stages unavailable
```

The discrimination line renders only at low/medium. A `high` level renders
no line; it is capped to `medium` when the dense lane was dark for the
query AND the estate has no span rerank stage registered (the ranking is
then lexical-only; `RecallDiscrimination.denseLaneDark(status:spanRerankRegistered:)`,
§ 14.3). With a span rerank stage registered the encoder reorders the
lexical head, so `high` stands. The degradation line
renders when the dense lane did not contribute for a reason other than an
empty query OR any pipeline stage was skipped — at most once; stage names
and lane vocabulary never render (they are log-side). Connected recall
renders NO text control line — per-result provenance is structured
(§ 11.10).

**Total trailing-line order** (each line optional, this order absolute):

```text
<rows>
discrimination: …
temporal: … | walk: …        (tool-specific; at most one exists per tool)
retrieval: degraded — …
note: additional results share this score …
hint: …
```

The non-determinate-tie line is unchanged:

```text
note: additional results share this score on a non-deterministic tie; refine the query
```

### 11.4 Synthesis document

```text
grounded_synthesis: N drawer(s)
query: <normalized cue terms, comma-separated>
<composed summary paragraph — plain prose, no label>
found N candidate memories, one per line
<rows>
```

The `query:` line carries the normalized extracted cues and is absent in
the whole-estate form. No `summary:`, `patterns:`, `successRate:`, or
`recommendations:` fields exist.

### 11.5 Unranked memory rows (S2)

memory list:

```text
listing N memories in <wing> / <room> — filing order, unranked
<uuid> · <subject | -> · <best span | -> · <SSC facts | -> · <event time>
```

Debt mode (`filter: missing_subject`):

```text
listing N memories missing subjects — ids only
<uuid>
```

Batch memory get (`ids` + `depth: subject | distilled`):

```text
resolved N of M requested memories, in request order
<S2 row>
not found: <uuid>
```

The header counts resolved-of-requested; exactly one line per requested id
in request position. `depth: distilled` adds the indented continuation per
§ 11.2. The header verb `listing`/`resolved` versus `found … candidate` is
how a consumer tells enumeration from ranking.

### 11.6 Full record (S3) — single-id memory get, `depth: full`

Base field spellings are pinned by renderer readback (`fullRecordLines`,
2026-08-25). The `subject:` line appears only when the drawer carries one;
Tunnel lines are
confirmed-active edges only, arrow gives direction, cap 50; verbatim content
follows the `content:` label untruncated.

```text
memory 30B1B3B0-945D-4C07-AE57-53D9FFC9B543
room: recruiting  wing: Agentic Memory
subject: Entelo follow-up decided at TechFest
filed_at: 2026-01-02T10:15:00Z
event_time: 2026-01-01T00:07:52Z
state: active
trust: verbatim
sensitivity: normal
exportability: exportable
confirmation: unconfirmed
lineage: 9D1E6B30-4C77-4A28-B5F0-2E83A1D97C60
tunnels: 2
  → E70A5761-152D-4ABB-B16A-964B06A09404  [relates]
  ← 931F2411-95B7-4DE9-9B96-CF96DF66175E  [precedes]
content:
user: I'll definitely look into Entelo further. Sarah from Google walked me through it at TechFest and it fits the sourcing workflow we discussed.
```

Full hydration contains no adornment block.

A gated or absent single id returns the standard not-found tool error.

### 11.7 Fact rows (S4)

fact search — fixed six columns, `-` for a freestanding assertion's
absent source:

```text
found N facts, one per line
<fact ID> · <subject> · <predicate> · <object> · <source drawer UUID | -> · <filedAt>
```

fact timeline — the time-major variant, fixed seven columns:

```text
fact timeline: N facts in filing order (active and retired)
<filedAt> · <lifecycle> · <fact ID> · <subject> · <predicate> · <object> · <source drawer UUID | ->
```

Lifecycle values: `active`, `retired(B)`, `retired(C)`, `unknown(<raw>)`.
Cap line when hit: `timeline capped at 200 rows — narrow with entity`.

### 11.8 Edge rows (S5)

```text
found N outgoing connections, one per line
<tunnel ID> · <kind/label[ (lifecycle)]> · <far endpoint: uuid · subject · best span | - · SSC facts | - · event time>
```

connection map is identical with the header word `incoming`. The far
endpoint renders the S2 pick fields (no score); lifecycle renders only
when not active.

### 11.9 Tabular rows (S6)

dataset query:

```text
dataset <uuid> "<name>": returned N of M matching rows (limit N, ordered by <col> <dir>)
<col> · <col> · <col>
<value rows in caller order>
```

dataset stats:

```text
dataset <uuid> "<name>": N rows, M columns
<col> · count=N · nulls=N · distinct=N[ · min=… · max=… · mean=… · stddev=…]
```

Lossless encoding — S6 values are user-owned data and round-trip exactly;
the § 11.1 `·`→`-` replacement never applies:

- a value containing the separator sequence, a quote, a newline, or
  leading/trailing whitespace renders double-quoted with `""` as the
  embedded-quote escape;
- embedded newlines render as the two-character escape `\n` inside quotes
  (one result row is always one presentation line);
- NULL = empty unquoted field; empty string = `""`; booleans =
  `true`/`false`; numerics = shortest exact decimal; timestamps =
  ISO-8601 `Z`.

The total-matching count `of M` is optional: when computing it would
require a separate full scan it is omitted, never silently paid.

### 11.10 Structured recall — base schema plus surface extensions

Every S1 surface declares the shared output schema. Base row schema:

```json
{
  "type": "object",
  "required": ["results"],
  "properties": {
    "results": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id"],
        "properties": {
          "id": { "type": "string" },
          "subject": { "type": "string" },
          "bestSpan": { "type": "string" },
          "sscFacts": { "type": "string" },
          "eventTime": { "type": "string" },
          "score": { "type": "number" },
          "room": { "type": "string" },
          "content": { "type": "string" }
        }
      }
    },
    "capabilities": { "type": "object" }
  }
}
```

The shared composer uses the result data supplied by each surface.
`adornment` and `adornments` are absent from the schema and all results.

Surface extensions (additional per-row properties):

| Surface | Extension properties |
|---|---|
| connected recall | `retrievalSource`: `"anchor"` \| `"walk"` \| `"both"` |
| distilled recall | `distilled` (string), `representation`: `"distilled"` |
| vague recall | `tier`: `"summary"` \| `"original"` |
| federated search | `estateID` (string) |
| memory get | `content` at the depths where the text carries it |
| lens concepts / associations | `extent` / `exemplars`: full drawer-UUID arrays (the text preview caps at count + first 3; the structured arrays are complete) |

Top-level `capabilities` object mirrors the control lines — keys:
`discrimination` (`"low"` \| `"medium"`), `walk` (`{ "stage": string,
"stoppedEarly": boolean }`), `temporal` (`{ "mode": string, "source":
string, "grab": string, "from": string, "to": string, "widenedDays":
integer }`), `degraded` (`true`), and, on `moot_recall_distilled` only,
`distillation` (the savings object: `returnedTokens`, `originalTokens`,
`savedTokens`, `savedPercent`, `estimated`, `estimator`, optional `skim`
(`{ "omittedTokens": integer }`), and `display`; `additionalProperties:
false`). The measurement covers only the rows actually emitted carrying a `distilled` field, after the row cap and the privacy projection; the v2 surface sums per-row `originalTokenCount` and `tokenCount` from the recipe and calls the CognitionKit measurement. Each key except `distillation` is ABSENT when its control line
does not render; `distillation` is always present on `moot_recall_distilled`
and always absent on every other operation. Synthesis adds top-level `cues`
(string array, the normalized terms) and `summary` (string).

`moot_recall_distilled` declares its own `data` schema: `results` (the
shared memory-row array) plus a required `capabilities` object in which
`distillation` is required and `discrimination` is optional. The shared
capabilities schema of all other recall and lens operations is unchanged.

Structured tabular results (S6): `columns` (array of `{ "name": string,
"type": "text" | "int" | "float" | "bool" }`) and `rows` (array of arrays
of typed values, null for NULL) — values travel typed and exact.

Contract rules: one entry per rendered text row, same order, same cap; an
optional field is ABSENT when the text column renders `-` — never null,
never empty-string; `score` is absent on S2; redaction parity per Spec
§ 8.9; consumption rule per Spec § 8.9 (machine MUST structured; AI and
presentation-shape experiments MAY text).

### 11.11 Erasure results

```text
erased memory <id>
```

or:

```text
partially erased memory <id>: <N> accepted lineage sibling(s) refused erasure and remain readable: <ids>
```

### 11.12 Sensitivity advisory placement

The advisory does NOT render in search/get payloads. Its text lives in:

- the `moot_memory_search` and `moot_memory_get` tool descriptions in
  `tools/list`;
- the `moot_estate_status` body and its teachme orientation guide; and
- onboarding documentation.

The sentence (search form):

```text
sensitivity_advisory: a sensitivity tier gate is in effect — run `mootx01 unlock private` to include restricted memories, `mootx01 unlock secret` for secret memories.
```

The estate-status form inserts `on this estate` after `in effect`.
`moot_estate_ping` never carries it. Presence in estate_status depends only
on grant state, never on estate contents.

## 12. Session interface

### 12.1 Status protocol block

Every `moot_estate_status` response includes:

```text
protocol:
  — Call moot_estate_status with teachme:true for a full orientation guide.
  — Call moot_list_lenses to see available cognition tools.
  — Add teachme:true to any tool to learn it before using it.
  — Watch for hint: lines in responses — they contain coaching for better results.
  — File memories: moot_file_memory (content + subject + location required).
  — Search memories: moot_memory_search (query required).
  — Write journal entries: moot_write_journal after meaningful sessions.
  — Store structured facts: moot_file_fact (subject + predicate + object).
```

### 12.2 Sync vocabulary

| Backend | State | Token |
|---|---|---|
| no engine | — | `local-only` |
| none | disabled | `none (idle)` |
| none | enabled | `none (enabled, zone: <zone>)` |
| none | syncing | `none (syncing, direction: <d>)` |
| none | error | `none (error: <e>)` |
| CloudKit | disabled | `cloudkit (idle)` |
| CloudKit | enabled | `cloudkit (enabled, zone: <zone>)` |
| CloudKit | syncing | `cloudkit (syncing, direction: <d>)` |
| CloudKit | error | `cloudkit (error: <e>)` |
| Federation | disabled | `federation (idle)` |
| Federation | enabled | `federation (in-process, zone: <zone>)` |
| Federation | syncing | `federation (syncing, direction: <d>)` |
| Federation | error | `federation (error: <e>)` |

The field key is `sync:`. `status: connected` is not part of this vocabulary.
Trace-read failure renders `trace_rows: unavailable`, not zero. Drawer-derived
aggregates use the bulk-exportable sensitivity ceiling.

`frozen:` follows `sync:` and renders `true` when the
serving process was started with `mootx01 serve --frozen` or `MOOTX01_FROZEN=1`,
else `false`. It is a property of the serve process, not of the estate. A
frozen serve classifies every tool it can dispatch into exactly one of three
sets, held in `AriaMCP.ToolMutationInventory` /
`aria_mcp::tool_mutation_inventory` and pinned by a completeness test in each
port under every combination of `MOOTX01_VAULT` and `MOOTX01_MEMORY_TOOL`:

- the read set (`frozenReadTools` / `FROZEN_READ_TOOLS`), let through unconditionally;
- the refused set (additive writes, mutations, and erasure), refused
  by name with the `isError` text `estate is frozen (serve --frozen): <tool> is
  a mutating tool and was refused`;
- the command-classified set (`frozenReadCommands` / `FROZEN_READ_COMMANDS`):
  `memory`, whose `command` argument decides per call. `view` proceeds; every
  other command, and a missing or unknown one, is refused with the `isError`
  text `estate is frozen (serve --frozen): memory command <command> is not a
  read command and was refused` (`(missing)` when the argument is absent).

Both refusals fire before any runner and before session state records the
call, so a refused call leaves no side effect; the `memory` adapter itself is
posture-blind. A frozen serve also runs `moot_memory_search` with internal
recall origin and writes no reward mark on dereference.

### 12.3 Optional advisories

`version_skew:` appears only when injected plugin/binary mismatch text exists.
`update_available:` appears only when the host's cached provider reports a newer
release. A resident provider uses a 24-hour cache, bounds a probe to roughly
four seconds, caches failures as silence, and respects
`MOOTX01_NO_UPDATE_CHECK`.

### 12.4 Modes public types

```swift
public enum MootMode: String, CaseIterable, Sendable {
    case recall = "Recall"
    case filing = "Filing"
    case lenses = "Lenses"
    case vault = "Vault"
    case curator = "Curator"
}

public enum RecallVariant {
    case auto, rows, answer
}

public struct ModeDeclaration {
    public let modeName: String
    public let variant: String?
    public static func parse(_ raw: String) -> ModeDeclaration
}

public actor ModeSessionState: Sendable {
    public var stickyEnabled: Bool
    public var coachingCallsX: Int
    public func recordCall(toolName: String, mode: ModeDeclaration?) -> Int
    public func shouldCoach() -> Bool
    public var snapshot: CoachingSnapshot { get }
}
```

Coaching snapshots carry total calls, per-tool counts, bigram counts, and mode
attribution. `PeriodicCoach` renders the deterministic block pinned by
`Tests/Conformance/modes_coaching_fixture.json`.

### 12.5 Coaching triggers

| Tool | Trigger |
|---|---|
| `moot_memory_search` | no query, query over 200 characters, or zero memories |
| `moot_file_memory` | content over 4,000 characters or duplicate result |
| `moot_erase_memory` | confirmation absent or false |
| `moot_migration_confirm` | disqualified branch result |
| `moot_link_memories` | unresolved IDs |
| any lens | zero results |

Hints never attach to error results (`isError: true` results pass through
unmodified). The first matching trigger wins and exactly one hint fires per
call.

#### Hint slot

When a trigger fires the v2 envelope gains two additions:

- `structuredContent["hint"]` — a string value, sibling of `data` and `meta`,
  present only when a trigger fires and absent otherwise. Consumers that read
  `structuredContent` programmatically use this field.
- A `"\nhint: <text>"` line appended to `content[0].text`. The append happens
  **after** the 512 Unicode-scalar clamp of the operation body; the hint line
  itself is never clamped.

The periodic coaching block (§12.4) is appended to `content[0].text` **after**
any hint line already present, so hint-then-block ordering is guaranteed.

#### Lens scope

The "any lens" row in the trigger table applies to `SurfaceRequest::Recall`
variants — `moot_recall_precise`, `moot_recall_temporal`,
`moot_recall_connected`, `moot_recall_shaped`, `moot_recall_distilled`,
`moot_recall_vague`, and `moot_recall_walk`. The `moot_federated_recall` and
`moot_memory_recall_transcript` tools map to separate enum variants
(`FederatedRecall`, `TranscriptRecall`) and never receive the zero-results
hint. This is an intentional boundary: federated and transcript recalls are
read-only inspection tools whose zero results carry no actionable filing
guidance.

## 13. Auxiliary HTTP endpoints

### 13.1 Read endpoints

```text
GET /api/graph
GET /api/lattice
GET /api/admin/estates
```

All accept no body and ignore query strings for routing.

**Graph response**

```json
{
  "nodes": [
    {
      "id": "<drawer UUID>",
      "nounType": 0,
      "communityId": 3,
      "centrality": 0.42,
      "anomaly": false,
      "lastActiveTs": "<ISO-8601>",
      "createdTs": "<ISO-8601>",
      "tombstonedTs": null
    }
  ],
  "edges": [
    {
      "source": "<drawer UUID>",
      "target": "<drawer UUID>",
      "edgeType": "tunnel",
      "weight": 1.0,
      "decayedWeight": 1.0,
      "createdTs": "<ISO-8601>",
      "tombstonedTs": null
    }
  ],
  "structurePending": false,
  "communities": [
    { "id": 3, "size": 17, "dominantUdcCode": "652" }
  ],
  "generatedTs": "<ISO-8601>"
}
```

`edgeType` is `tunnel`, `kgFact`, or `lattice`. A pending response has empty
arrays and omits `generatedTs`.

**Lattice response**

```json
{
  "addresses": [
    { "code": "006.6", "count": 12 }
  ]
}
```

A lattice read failure is HTTP 503 with
`{"error":"lattice read failed","degraded":true}`.

**Hosted-estates response**

```json
{
  "hosted": [
    {
      "estateUUID": "<UUID>",
      "estateName": "<name>",
      "kind": "GLK",
      "backend": "SQLite",
      "mountState": "mounted"
    }
  ]
}
```

Backend is `SQLite`, `PostgreSQL`, or `InMemory`. Unknown GET paths return
HTTP 404 `{"error":"not_found"}`.

### 13.2 Sensitivity control

```text
POST /api/control/unlock
POST /api/control/lock
```

Unlock request:

```json
{ "tier": "restricted", "proof": { "ts": 1787670000000 } }
```

Legal tiers are `restricted` and `secret`. The user-facing CLI alias `private`
maps to `restricted`.

The legacy source documents record this success shape:

```json
{ "granted": true, "expires_at": "<ISO-8601>" }
```

Lock accepts `{}` and records:

```json
{ "locked": true }
```

Error statuses are 400 for unknown tier, 403 for stale proof, and 500 for other
server errors. These shapes remain unreconciled inputs pending reconciliation with
the generated/implemented endpoint fixtures; see §17.

## 14. Public implementation types

### 14.1 Dispatcher and servers

```swift
public struct ToolDispatcher: Sendable {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle
    public init(kit: GeniusLocusKit, handle: EstateHandle)
    public func registering(_ additional: EstateHandle) -> ToolDispatcher
    public func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue
    public static func textResult(_ text: String) -> JSONValue
    public static func errorResult(_ text: String) -> JSONValue
}

public struct ARIA_MCPDispatcher: Sendable {
    public struct ServerInfo: Sendable {
        public let name: String
        public let version: String
    }
    public let info: ServerInfo
    public let tools: [ProjectedTool]
    public let tooling: ToolDispatcher
    public func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse?
}

public struct StdioServer {
    public let dispatcher: ARIA_MCPDispatcher
    public func run(input: FileHandle, output: FileHandle) async
}

public struct HTTPServer: Sendable {
    public let dispatcher: ARIA_MCPDispatcher
    public let port: UInt16
    public let maxBodyBytes: Int
    public func run() async throws
    public func bind() throws -> (fd: Int32, port: UInt16)
}
```

### 14.2 Governor

```swift
public actor BrainPump {
    public init(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        baseTickMs: Int = 5000,
        clock: @escaping @Sendable () -> Date = { Date() }
    )
    public func run() async
    @discardableResult public func tick(now: Date) async -> TickReport
}
```

The Rust `AutonomicGovernor` owns its serial-lane standing-signal scheduler and
exposes registration, status, open-count, and request-fire operations. Resident
bootstrap registers the default signals once; stdio does not.

### 14.3 Supporting types

```swift
public enum DiscriminationLevel: Sendable, Equatable {
    case single, high, medium, low, notFound
}

public enum RecallDiscrimination {
    public static func classify(_ scores: [Double]) -> DiscriminationLevel
    /// True when no span rerank stage is registered on the estate
    /// (`GeniusLocusKit.isSpanRerankRegistered(for:)`): the cap's condition
    /// (3.3.0; the span stage is the one dense provider).
    /// Rust: `recall_discrimination::dense_lane_dark(span_rerank_registered)`.
    public static func denseLaneDark(spanRerankRegistered: Bool) -> Bool
    public static func resultLine(
        for level: DiscriminationLevel,
        denseLaneDark: Bool = false
    ) -> String
}

public protocol MonitoringControl: Sendable {
    func read() async -> Bool?
    func set(_ enabled: Bool) async
}

public enum SensitivityTier: String, Sendable, Equatable, CaseIterable {
    case restricted
    case secret
}

public enum ClassificationScheme: String, Sendable, CaseIterable {
    case udc
    case mdcc
}

public enum Logging {
    public static let osLog: Logger
    public static let stderr: StderrLogger
}

/// Server-side string constants shared between the `AriaMCP` producer and
/// `AriaMCPWire`-only consumer targets (e.g. `MootCommunityGateway`).
/// Declaring them in `AriaMCPWire` lets a consumer that links only
/// `AriaMCPWire` reference the same value the composer emits without risk
/// of silent divergence through a duplicated literal.
///
/// `ResultComposer.noSubjectMarker` (in `AriaMCP`) forwards to this constant;
/// the compiler enforces parity between the producer and all consumers.
public enum ARIAServerConstants {
    /// The subject value the server places on an opaque (gated or unhydrated)
    /// search row. Consumers must filter rows whose subject equals this marker
    /// before showing them in any UI surface.
    ///
    /// Value: `"(no subject)"`
    public static let noSubjectMarker: String
}
```

## 15. Package and dispatch map

### 15.1 Swift

`packages/kits/AriaMcpKit/` contains:

| Location | Responsibility |
|---|---|
| `Sources/AriaMCP/JSONRPC.swift` | envelopes and error codes |
| `Sources/AriaMCP/JSONValue.swift` | wire JSON value |
| `Sources/AriaMCP/Server.swift` | dispatcher and stdio server |
| `Sources/AriaMCP/HTTPServer.swift` | loopback HTTP and auxiliary endpoints |
| `Sources/AriaMCP/BrainPump.swift` | resident governor |
| `Sources/AriaMCP/ToolProjection.swift` | generated tool descriptors |
| `Sources/AriaMCP/ToolDispatch.swift` | estate routing and interface runners |
| `Sources/AriaMCP/RecipeTools.swift` | recipe tools |
| `Sources/AriaMCP/LensTools.swift` | reasoning lenses |
| `Sources/AriaMCP/VaultTools.swift` | vault tools |
| `Sources/AriaMCP/DatasetTools.swift` | dataset tools |
| `Sources/AriaMCP/TeachmeGuides.swift` | static guides |
| `Sources/AriaMCP/CoachingEngine.swift` | deterministic hints |
| `Sources/AriaMCP/MemoryToolAdapter.swift` | optional Anthropic adapter |
| `Sources/aria-mcp/AriaMCPMain.swift` | executable entry point |
| `Tests/AriaMCPTests/` | Swift conformance and integration tests |

The shipped macOS runtime is the `mootx01` executable under `apps/mootx01`.
`ProxyCommand.swift` implements the stdio-to-HTTP bridge.

### 15.2 Rust

`packages/kits/AriaMcpKit/rust/` is the wire-contract peer. Important modules
include `dispatcher.rs`, `tool_list.rs`, `interface_tools.rs`,
`recipe_tools.rs`, `dataset_tools.rs`, `memory_adapter.rs`, `http_server.rs`,
and `autonomic_governor.rs`.

### 15.3 Dispatch order

```text
teachme pre-check
  → federation
  → recipe
  → lens
  → vault
  → interface
  → methodNotFound
  → hint and mode/coaching decoration
```

## 16. Errors and conformance

### 16.1 Error boundary

Protocol faults are JSON-RPC errors. Runner failures are `tools/call` results
with `isError: true`. `toolDispatchFailure` remains an internal marker and is
not a public wire code.

Subject-length contract violations on `moot_file_memory` and
`moot_update_memory` (`mutation=setSubject`) are runner failures: the call
reached the runner and the value was rejected for exceeding the 120-character
contract. These return `isError: true` rather than a JSON-RPC error so the
model sees the contract message and can compress the subject and retry. A
missing `subject` argument (the field is absent from the call) is a JSON-RPC
`invalidParams` error because the call is malformed before any runner logic
runs.

### 16.2 Swift

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/AriaMcpKit
```

Coverage includes JSON-RPC, framing, HTTP, projection, dispatch, memory, facts,
journal, multi-estate routing, recipes, lenses, vault, datasets, teachme,
coaching, modes, structured recall, and resident behavior.

### 16.3 Rust

```sh
cargo test --manifest-path packages/kits/AriaMcpKit/rust/Cargo.toml
```

Coverage includes JSON-RPC, framing, dispatch, persistence, HTTP transport,
governor, dataset, structured recall, modes, and integration modules.

### 16.4 Construction example

```swift
import AriaMCP
import GeniusLocusKit

let dispatcher = ARIA_MCPDispatcher(
    info: .init(name: "aria-mcp", version: "1.0.0"),
    tooling: ToolDispatcher(kit: kit, handle: estate)
)

await StdioServer(dispatcher: dispatcher).run()
```

## 17. Source reconciliation

Transition record of the 2.0.0 consolidation: source material was
preserved without silently selecting among
conflicting snapshots:

| Source difference | Treatment |
|---|---|
| Tool counts differ across interface prose, verb taxonomy, changelogs, ports, and feature gates | Generated `tools/list` is the release census; prose is organized without a fixed total |
| `ARIA_VERB_FAMILIES.md` predates temporal, connected, walk, and later maintenance tools | Later additions are placed in the nearest ratified family/tier and remain explicitly named |
| Older dense-row vocabulary has five fields; later candidate-row contract has seven components | §11 carries the decided seven-column canonical row (fixed columns, R16); superseded renderings are conformance-backlog defects per Spec §13.3, not documented variants |
| Spec and Interface both describe endpoint behavior and wire forms | Behavioral rules moved to Spec §12; serialization stays here in §13 |
| Spec and Interface both describe tool semantics | Behavioral invariants moved to Spec; names/args/replies/follow-ups remain in §§5–10 |
| Main documents contain large historical changelogs | Histories externalized: ARIA_MCP_SPEC_CHANGELOG.md and ARIA_MCP_INTERFACE_CHANGELOG.md carry the full ladders |
| Source unlock response examples and implementation fixtures require reconciliation | Legacy shapes are labeled unreconciled inputs rather than silently asserted as resolved (conformance-backlog item) |

Names found only in legacy or supporting prose are retained here rather than
misrepresented as current projected tools:

- `moot_estate_reconnect` is the retired name whose rationale is captured by
  `moot_estate_ping` in Spec §14.1;
- `moot_recollect` was a retired notice-only stub; removed at V2-A (git tag ARIAv1-Terminus);
- `moot_update_check.py` is an update-check hook, not an MCP tool; and
- `moot_vault_*` is prose shorthand for the five explicitly listed vault tools,
  not an additional tool name.

## Sensitivity-withheld reporting

`report_withheld` is a per-call global modifier, stripped by the chain registry
before strict argument decoding and absent from every operation input schema.
Only boolean `true` enables it; omitted, false, and other values leave it off.
Successful precise, shaped, vague, connected, distilled, federated and transcript
recall, and partial-cue, keystones and trust-synthesis lenses conditionally add
integer `meta.withheldBySensitivity`. When off, the key is absent and rows and
ordering are unchanged. Refusals and unrelated operations do not disclose a count.

LocusKit counts primary candidates excluded only by its default adjective-
sensitivity ceiling while all other frame predicates admit. Explicit sensitivity
filters yield zero. Vague counts hop-1 candidates; federated counts only the
grant-authorized source population. Keystones counts only ranked topK endpoint
drawers rejected at hydration by that ceiling, not all graph endpoints. Later
provenance projection and tunnel counts are separate. The default Rust partial-cue
frame remains its current frame; this modifier does not change frame admission.

Transcript recall supplies the caller's explicit sensitivity ceiling in both
ports (default elevated, or the live grant ceiling). Rust now matches Swift's
existing caller-frame construction; the state default remains CurrentlyBelieve.
Its sensitivity-default-only count is therefore zero, including when restricted
candidates exist. This correction is separate from the partial-cue frame unit.

The optional meta field uses existing additional-properties permissions; catalog
schemas, release artifacts and the pinned capability digest are unchanged. Global
modifier help is documented once and pinned byte-identically in both ports.

## Security repair contract

### Security boundaries for review, lenses, and memory reads

`moot_review_tunnel` accepts `tunnel_id`, `decision` (`accept`, `reject`,
`endorse`), optional `note`, and optional `estate_id`. `reviewed_by` is an
unknown argument. Attribution comes from trusted caller context or the daemon
identity; only the trusted user identity may accept a proposal. Authenticated first-party agent sessions retain their agent identity and cannot accept on a human user’s behalf; trusted-user dispatcher context is required.

Memory search filters provenance before packaging answer citations. The
`explain` option gates discrimination text. Contradiction totals describe only
the admissible population; compatibility withheld counters are zero and do not
reveal protected populations. FDC reclassification filters the caller's current
sensitivity ceiling before applying limits, reporting, or writing anchors.
First-party lens discovery uses the first-party projected schemas.

## Changelog

### 5.0.0 — 2026-09-15

Updated the security repair contract and cross-port API guarantees above.


### 4.7.0 -- 2026-09-15

`moot_drain_status` always lists the `fact_extraction` lane: `pending` is
the count of drawers still owed fact extraction for the active recipe
(bit 28 clear), `state` is `draining` while any drawer is owed and `idle`
once none are. The report shape (`drains: [{name, state, pending}]`) is
unchanged. Both ports.

### 4.6.0 -- 2026-09-14

Added `moot_recall_similar` (catalog identity `similar_recall`, effect
read) under the recall family in both ports: the paraphrase door over the
whole-record LSA lane through the CognitionKit `similar_recall` recipe.
Arguments `query` (required, non-empty), `limit` (1–50, default 10),
`estate_id`. Rows carry the `moot_memory_recall_transcript` shape
(`memory_id`, `room`, `excerpt`, `score`, `fetch`); no evidence block.
Tool count 80 → 81 (vault-on) and 73 → 74 (vault-off); the capability
digest moves with the descriptor set. Classified as a pure read in both
ports' mutation inventories and installer permission tiers.

### 4.4.0 -- 2026-09-14

The drawer subject contract is 120 grapheme clusters at every enforcement site
in both ports. Updated two entries:

- `moot_file_memory` §7.1 Errors: "120 Unicode scalars" → "120 grapheme clusters",
  and the parenthetical updated to the Rust error string "provide at most 120
  grapheme clusters".
- `moot_update_memory` §7.2 Errors (mutation=setSubject): "120 characters" →
  "120 grapheme clusters", and N described as the grapheme-cluster count both
  ports report, citing the Rust error string "is required and must contain 1 to
  120 grapheme clusters before trimming for set_subject".

Lines 735 (`moot_file_fact`) and 2434 (historical changelog entry) are left
unchanged: `moot_file_fact` subject is a different noun outside this ruling.

Both entries also corrected the error shape: the subject-length refusal is a
thrown JSON-RPC `invalidParams` error (code `-32602`, path `$.subject`), not
an `isError: true` result. The Rust decoder messages are quoted verbatim; the
Swift twin message is `"Argument 'subject' exceeds the subject length
contract."`. Neither port reports a count in the refusal.

### 4.3.0 -- 2026-09-14

`moot_list_lenses` output is now contractually ordered alphabetically by
tool name. Both ports sort explicitly; the ordering no longer depends on
the registry's internal container order.

### 4.2.0 -- 2026-09-13

Added `moot_memory_get(depth: "skim")` and its preview-only `skim` object:
`text`, `complete`, `budgetHonored`, and `savings`. Retains id and full-fetch
reference. Corrected the public get argument names to `memory_id`/`memory_ids`.

### 4.1.0 -- 2026-09-13

Added the default-off report_withheld modifier, conditional sensitivity-only meta
count, ranked topK keystones hydration definition, and unchanged-schema contract.

### 4.0.0 -- 2026-09-11 (BREAKING)

The four work-packet operations are retired from the ARIA surface, both
ports: `moot_file_packet` (§6.1), `moot_packet_get`, `moot_packet_list`,
and `moot_packet_lineage` (all three formerly §10.4-§10.6). The Swift
package's `WorkPacketKit` dependency is removed from `AriaMcpKit`; the
Rust port never carried a packet implementation. Stored packet drawers
already in an estate are unaffected — this is a surface retirement, not
a schema change, and no migration step is required. `.interface`
provenance (§4.2) and the capture family summary (§6) drop the packet
mention. Tool count is now 80 (vault-on, the default) / 73 (vault-off),
down from 84 / 77.

### 3.12.0 -- 2026-09-11

§3.2 rewritten to document the global-modifier contract: `mode` is stripped
at the ARIA door before any operation decodes its arguments (it is no longer
injected into per-tool input schemas); it is documented once, in the
`moot_help` directory response under the `global_modifiers` key; owner
operations that declare `mode` in their own input schema are excluded from
door stripping; `ARIASessionProtocol` names the modifier.

### 3.11.2 -- 2026-09-09

§11.6 capabilities paragraph extended: one sentence added stating that the distillation measurement covers only the rows actually emitted carrying a `distilled` field, after the row cap and privacy projection, using the CognitionKit measurement; the v2 surface sums per-row `originalTokenCount` and `tokenCount` from the recipe.

### 3.11.1 -- 2026-09-09

`moot_recall_distilled` Output entry (§5) updated: Output now states `capabilities.distillation` and the compact-text savings display line; Sample points to §11.2 and §11.6. §11.2 distilled recall sample extended with the display line appended after the indented continuation. §11.6 `capabilities` keys paragraph extended: `distillation` added (distilled recall only, always present, keys listed, `skim` optional); `moot_recall_distilled` declared as carrying its own `data` schema with `capabilities` and `distillation` required; shared capabilities schema of all other operations noted as unchanged.


### 3.11.0 -- 2026-09-09

moot_reclassify_fdc promoted to a real v2 write path — adds apply, mode, limit arguments; output moves to 18-field structuredContent.data contract (content[0].text carries a compact human report truncated at 512 scalars); moot_estate_status data gains fdc_recalculation field (current/missing/stale).

### 3.10.2 -- 2026-09-09

§12.5 coaching triggers wired to the v2 surface — AriaV2Coach/v2::coach implements all six triggers; the v2 envelope gains a new hint slot (structuredContent['hint'] + appended 'hint: …' line in content[0].text) and a periodic coaching block appended to content[0].text at the controlled cadence; estate-provisioned coaching_calls and sticky_enabled apply via applyPreferences on the first dispatch call.

### 3.10.1 -- 2026-09-10

Front-matter description was missing 3.9.1 and 3.9.2 entries (the
description ran 3.9.0 straight to 3.10.0). Added, summarized from those two
entries below. No contract change.

### 3.10.0 -- 2026-09-09

Added four previously-undocumented catalog entries: `moot_memory_recall_transcript`
and `moot_propose_contradictions` (§5.2 and §9.2 respectively), and
`moot_help` and `moot_monitoring_set` (§10.1 and §10.2 respectively, the
latter alongside its `moot_monitoring_status` read counterpart). Tool count
is now 84.

### 3.9.2 -- 2026-09-09

V2-A surface adoption: v2 catalog is now the only published surface (git tag
ARIAv1-Terminus marks the last commit before the v1 surface was removed).
Tool name updates: `moot_federated_search` renamed `moot_federated_recall`
(§8 federation family), `moot_run_migration` renamed `moot_migration_run`,
`moot_confirm_migration` renamed `moot_migration_confirm` (§9 migration
family). `moot_recollect` removed; recorded in §16.3 retired-names list.
`dispatchableUnadvertisedTools` removed from the frozen-posture read-set
description (§12.2) — no unadvertised dispatchable names remain.


### 3.9.1 -- 2026-09-09

`ARIAServerConstants` (in `AriaMCPWire`) added to §14.3: documents the single
stored declaration for `noSubjectMarker` so consumer targets that link only
`AriaMCPWire` have an interface reference. `ResultComposer.noSubjectMarker`
forwards to it; the compiler enforces parity.

### 3.9.0 -- 2026-09-08

§2.8 corrects the `--in-memory` description. The estate starts empty: the
catalog record is resolved only to validate the selector argument; its content
is NOT loaded. The command-table row now reads
`aria-mcp --in-memory  a fresh empty estate on the in-memory backend (record
resolved for validation only)` and the explanatory note is updated to match.

### 3.8.0 -- 2026-09-08

New §2.8 records the `aria-mcp` command line, which both ports now parse from
one table: the four accepted invocations, `--help`/`-h` printing the usage
line and exiting 0, and the four refused shapes (unrecognised argument, `--db`
without a value, `--db` followed by a flag, repeated `--db`), each exiting 1.
The Rust port previously exited 2, accepted `--db a --db b` last-wins, and
took `--db --in-memory` as an estate named `--in-memory`; the Swift port had
no `--help`.

`--in-memory` is one rule across `aria-mcp` and `mootx01 serve`, both ports:
the catalog opens and the record resolves before the backend is chosen, and
the estate is then served TRANSIENT — no federation identity, no charter
drawers. The Rust `aria-mcp` skipped the catalog entirely and the Swift ports
federated when the record was registered.

The 120 of the subject contract is stated as 120 Unicode scalars, the unit
both ports count and both `moot-bridge` ports cut a derived subject on. Swift
counted grapheme clusters, so a subject of combining sequences could pass the
Swift check and be refused by the Rust one.

### 3.7.0 -- 2026-09-07

The `moot_recall_shaped` roster under the dark switches, both ports: with
`DenseFamilies` / `dense-families` the roster holds 37 names (`ppmi_forward`,
`nmf_forward`, `anti_redundant_nmf` beside the 34 of a `WholeRecordDense`
build); `lsa_forward` and `anti_redundant_lsa` exist only in an `LSA` /
`lsa` build (39 names), the switch of their own LSA moved to on 2026-09-07
(GENIUSLOCUSKIT_SPEC 3.8.0). The product build is unchanged at 26 names.
`mootx01 upgrade` gains the whole-record vacuum step, whose one output line
(`whole-record vacuum: N float row(s), M graph row(s) deleted; B bytes
returned to filesystem`, or `nothing to reclaim`) is byte-identical in both
ports.

### 3.6.0 -- 2026-09-07

The discrimination cap reads the span rerank stage alone, both ports:
`RecallDiscrimination.denseLaneDark(spanRerankRegistered:)` /
`recall_discrimination::dense_lane_dark(span_rerank_registered)` is true when
no span rerank stage is registered on the estate. The whole-record dense lane
left the default build (GENIUSLOCUSKIT_SPEC 3.7.0), so its status is no longer
an input. The `moot_recall_shaped` roster follows `RecallShape.presetNames`:
26 names in the product build (`conceptual`, `associative`, `consensus`,
`ri_forward`, `anti_redundant_ri`, `float-l2`, `float-dot` exist only in a
`WholeRecordDense` build, with `whole_record_baseline`). The Rust
`moot_fact_search` no longer appends a `recall_provenance: dense_lane:` line
(the Swift port never did and 2.0.0 removed the line from the surface); the
Swift `moot_fact_search` no longer runs a probe recall whose only output was
the discarded dense lane status. The `moot_recall_precise` composition list
drops `dense-fused` (NEURONKIT_SPEC 1.23.0). The `AriaMcpKit` package gains
the `WholeRecordDense` trait, which compiles the resident adapter's float
index duties and enables the trait in NeuronKit, GeniusLocusKit and CorpusKit.

### 3.5.0 -- 2026-09-07

The live sensitivity grant ceiling now floors the two remaining filing
surfaces. `moot_file_packet` (Swift; the packet tools have no Rust twin)
takes an optional `sensitivity` argument in the `moot_file_memory` shape:
an omitted `sensitivity` files at the grant's tier, an explicit tier at or
above the ceiling is kept, an explicit lower tier returns `isError: true`
with the `moot_file_memory` refusal text and writes nothing, and the
`packet_filed:` block ends with `sensitivity: <tier>` while a grant is
live. WorkPacketKit's `store` gains the `sensitivity` parameter that
carries the tier (WORKPACKETKIT_INTERFACE 1.1.0). The opt-in `memory`
adapter, whose schema is Anthropic's and carries no sensitivity argument,
floors its content-bearing writes without one, both ports: `create`,
`str_replace` and `insert` file at the higher of the tier the write would
otherwise carry and the grant's tier, and append `sensitivity: <tier>` to
the contract reply while a grant is live; `rename` and `delete` are
unchanged; with no grant live every reply keeps Anthropic's text exactly.
A file filed restricted or secret is outside the adapter's no-grant read
posture until read through a grant-aware tool. The `tools/list`
descriptions of `moot_file_packet` and `memory` state the rule. Permission
tiers unchanged (Allow). Tests: `PacketToolsTests.filePacket*` and
`WorkPacketStoreTests` sensitivity cases (Swift),
`MemoryToolAdapterSensitivityTests` grant cases (Swift) and
`memory_create_under_restricted_grant_files_restricted_and_names_it` and
siblings in `memory_adapter_tests.rs` (Rust).

### 3.4.0 -- 2026-09-07

`moot_file_memory` files at the live sensitivity grant ceiling, both
ports. The checkpoint and handoff notes the context-meter hook asks for
summarise whatever the session recalled, including material read under a
restricted or secret grant, and a note filed with the default `normal`
tier stayed readable after the grant expired. The write side now reads
the same `SensitivityGrantLedger` as `moot_memory_search` and
`moot_memory_get`: an omitted `sensitivity` files at the grant's tier, an
explicit tier at or above it is kept, and an explicit lower tier returns
`isError: true` with
`"sensitivity <requested> is below the live grant ceiling <ceiling>: while a <ceiling> grant is live a memory files at <ceiling> or higher. Omit sensitivity to file at the ceiling."`
and writes nothing. While a grant is live the reply adds a fourth line
`sensitivity: <tier>`; with no grant live the argument, the default and
the three-line reply are unchanged. The `tools/list` description of the
`sensitivity` argument states the rule. Permission tier unchanged
(Allow): the floor lives on the server, so the installer's allow-tier
default needs no prompt to hold it. `moot_file_packet` and
`moot_write_journal` carry no sensitivity argument and are unchanged. The
context-meter hook's rungs and recovery text now say the same thing
(file at the highest sensitivity recalled under a grant, name it in the
call, the handoff is read back under the same ceiling). Tests:
`FileMemorySensitivityCeilingTests` (Swift) and
`file_memory_omitted_sensitivity_under_restricted_grant_files_restricted`
and siblings (Rust).

### 3.3.0 -- 2026-09-07
`moot_packet_get` and `moot_packet_lineage` enforce the sensitivity ceiling
(Swift; the packet tools have no Rust twin). Both readers now go through
WorkPacketKit's frame-gated fetch (WORKPACKETKIT_SPEC 1.0.0 § 4 I-6): the
`.currentlyBelieve` state gate, the wing and `work-packets` room, the
adjective sensitivity ceiling — the estate default `.elevated`, lifted only
by a live restricted or secret grant on the dispatcher's
`SensitivityGrantLedger`, the same ledger `moot_memory_get` consults — and an
unconditional drop of provenance Restricted/Secret rows. A gated row is
reported with the not-found shape an absent id gets, so `drawer_id` cannot
confirm hidden content exists. `moot_packet_lineage` gates its root before
traversal and omits gated antecedents from the reported thread. Both tools
gain an optional `wing` argument (default Agentic Memory), matching
`moot_file_packet` and `moot_packet_list`, so packets filed into another
wing stay reachable under the wing-scoped read. Permission tier unchanged
(Allow). No change to `moot_packet_list`, which already read through a
frame.

### 3.2.0 -- 2026-09-06

`moot_memory_search` answer block: the `signals:` line keeps its labels and
shape, and its values now come from the span rerank stage
(GENIUSLOCUSKIT_SPEC 3.2.0). `lane_agreement=<m2>` is the agreement between
the lexical head order and the span-encoder reranked order of the
span-scored hits (1.00 when the encoder confirms the lexical order, 0.00
when it reverses it or when no hit carries span evidence);
`dense_spread=<m3>` is the spread of the span cosines over those hits.
`margin=` and `containment=` are unchanged, as are the thresholds, so an
estate with an active encoder now reports `confident` and `intermediate`
where every multi-hit answer read WEAK; an estate with no encoder still
reads WEAK on multi-hit answers. The discrimination cap (`high` →
`medium` with the "semantic lane dark" caveat) fires only when no span
rerank stage is registered on the estate (since 3.3.0 the stage is the whole
predicate); `RecallDiscrimination.denseLaneDark(spanRerankRegistered:)` /
`recall_discrimination::dense_lane_dark` is the seam, both ports. Estates
created after this version are encoder-active from their first open
(GENIUSLOCUSKIT_SPEC 3.2.0 registry seeding); the app bundle must still
carry the Arctic model folder.

### 3.1.0 -- 2026-09-06

`moot_memory_search` answer block parity (answer:always|auto). The Rust
reply renders the lines Swift `runMemorySearch` renders: `confidence:
confident|intermediate` (the level name; it read `high|medium`),
`citations:` with up to five ids (it showed three), and `signals:
margin=<m1> lane_agreement=<m2> dense_spread=<m3> containment=<m4>` with
the two-decimal values in shortest form (it read `m1= m2= m3= m4=` with
three decimals). The Rust port composes no answer text, so its `answer:`
line stays absent; Swift's stands. The gate inputs agree too: Rust reads
m4 as false with no composed answer, the Swift rule, and its citation ids
are the first five hydrated drawer ids (GENIUSLOCUSKIT_INTERFACE 3.1.0).
On one served-style fixture (seven charter hints, one filed memory, dense
lane dark) both ports return the identical eight rows with identical lane
scores and both classify WEAK; the Rust `sticky_recall_auto_e2e_dispatcher`
test now runs on the Swift twin's bare-estate fixture, files its seed with
the required `location`, and pins the line shape.

### 3.0.0 -- 2026-09-06

Corrected candidate-row examples and structured hydration. Removed stored
adornment projections and the contentFallback representation. Recorded the
removed force-redistill service.

### 2.16.0 -- 2026-09-05

One index composition (CorpusKit spec 1.28.0, GeniusLocusKit spec 2.23.0).
`moot_estate_status` no longer prints `index_composition_policy: <id>`;
`frozen:` now follows `sync:` directly, both ports. The benchmark harness
`RunEnvironment` and the matrix rows drop the `index_composition_policy`
field, and `MOOT_INDEX_COMPOSITION` is read nowhere. `mootx01 db composition`
is gone from both ports (`db` keeps create, list, open, delete).

### 2.15.0 -- 2026-09-05

Encoder Rerank Program, integration. The two dark mint tools
(`moot_run_adornment_pass`, `moot_register_adornment_minter`) and the
`MOOTX01_MINT_TOOLS` launch gate are removed in both ports; the frozen
refused set is the three advertised tiers only. `moot_estate_status` no
longer carries the `adornment_miner` lines. `depth:distilled` on
`moot_memory_get` renders inline in both ports; the
`source: content (not yet distilled)` marker and the `moot_distill` hint are
gone. Rust `tools/list` no longer advertises `moot_distill` / `moot_redistill`
(parity with 2.14.0).

### 2.14.0 -- 2026-09-05

ENC-W6B: S1/S2 row schema updated. Text format: 7 columns → 6 columns.
`firstSentence` renamed `bestSpan` (best content span from the highest-ranked
SpanRerankHit, 60-word cap, falls back to first body sentence when no span
hit is available). SSC column becomes `sscFacts` (raw string, e.g. `kind:
hobby, entity: painting`; stubbed as `-` until schema-19 drawer.sscFacts
lands). Adornment column retired from both text and structured rows;
`adornment`, `adornments` keys removed from the structured result schema.
Structured row now carries `bestSpan` and `sscFacts` in place of the
old SSC object and firstSentence string. `moot_distill` and `moot_redistill`
marked retired in §9.2; their entries replaced with retirement notices.
Tool count: 82 → 80.

### 2.13.0 -- 2026-09-05
`moot_file_fact` oversize subject now returns `isError: true` with the
contract message, both ports. Previously the Swift port returned a JSON-RPC
`invalidParams` error while Rust returned a successful result; both now
produce a uniform `isError` result.

### 2.12.0 -- 2026-09-05
PAR-1: `moot_memory_search` reaches reply parity across the ports. The
Rust reply is composed through the shared S1 composer exactly as the Swift
reply is: the adornment text is column 5 of the row (the separate
`adornment:` line is gone), the structured row carries `score`,
`eventTime`, `firstSentence`, `adornment`, `adornments`, and `room` (it
carried `id`, `subject`, `room`, `content` before), the always-on
`recall_provenance:` line that 2.0.0 removed from this surface is gone
from the Rust reply too (the `retrieval: degraded` control line stands in),
and the advertised `explain` argument is honoured: both ports follow each
row with the recall engine's explanation block (§11.2 documents the
grammar). Swift is unchanged. Rust GLK fills `RecallHit.explanation` with
the same lines as Swift and `RecallHit.sources` with the candidate-supply
lanes only (GENIUSLOCUSKIT_SPEC 2.16.0).

### 2.11.0 -- 2026-09-04
Subject-length contract violations on `moot_file_memory` and `moot_update_memory`
(`mutation=setSubject`) now surface as `isError: true` results rather than JSON-RPC
`invalidParams` errors. MCP clients render JSON-RPC errors as a bare "Tool execution
failed" with no message; the `isError` surface puts the contract text in front of the
model so it can compress the subject and retry. Both ports fixed (Swift `ToolDispatch.swift`,
Rust `interface_tools.rs`). §16.1 updated to document the distinction. Verb error sections
for `moot_file_memory` and `moot_update_memory` updated with the exact error text.
Missing `subject` (absent field) remains a JSON-RPC `invalidParams` error — that is a
malformed call, not a runner-level refusal.

### 2.10.0 -- 2026-09-04
Cross-reference updated: VECTORKIT_SPEC.md and VECTORKIT_INTERFACE.md renamed to SYNAPSEKIT_SPEC.md and SYNAPSEKIT_INTERFACE.md; VectorKit renamed to SynapseKit throughout. No behavioral changes.

### 2.9.0 -- 2026-09-03
Frozen posture closes the gated-tool escape, both ports. `memory`
(`MOOTX01_MEMORY_TOOL=1`) is classified per call under a frozen serve: `view`
proceeds; `create`, `str_replace`, `insert`, `delete`, `rename`, and a missing
or unknown command return the `isError` text `estate is frozen (serve
--frozen): memory command <command> is not a read command and was refused`,
before the adapter runs and before session state records the call. The two
dark mint tools (`MOOTX01_MINT_TOOLS=1`) join the refused inventory as
`darkMutationTools` / `DARK_MUTATION_TOOLS` and are refused by name. The
inventory gains an explicit read set (`frozenReadTools` / `FROZEN_READ_TOOLS`)
and a command map (`frozenReadCommands` / `FROZEN_READ_COMMANDS`); a
completeness test in each port asserts every tool a serve can dispatch, under
every combination of `MOOTX01_VAULT`, `MOOTX01_MEMORY_TOOL`, and
`MOOTX01_MINT_TOOLS`, is in exactly one of the three sets, so a future tool
cannot reach a frozen serve unclassified. `moot_file_packet` (Swift) is
triaged as an additive write. § 12.2 rewritten.

### 2.8.0 -- 2026-09-03
`moot_estate_status`'s `index_composition_policy: <id>` line reports the
estate's stored index composition setting (GeniusLocusKit spec I-23), the
policy the wired Corpus runs under, and `none` when no Corpus is wired; both
ports read it through the kit (Swift `kit.indexCompositionPolicy(for:)`, Rust
`EstateCoordinator::index_composition_policy`), and the Rust handler no
longer reads `MOOT_INDEX_COMPOSITION`. The benchmark harness
`RunEnvironment.index_composition_policy` is the stored id captured from this
line through the lane's own MCP client while the measured estate is
connected (the matrix lane records it per row, one database per row). The
setting is changed with `mootx01 db composition --set`, which rebuilds every
index lane in the same command.

### 2.7.0 -- 2026-09-03
`moot_redistill` was advertised by `tools/list` in both ports (Swift tool
count 82 with vault, Rust 78 with vault) and documented in § 9.2. The Swift
recipe tool and its CognitionKit recipe were restored; the Rust list gained
the entry for the handler it already dispatched. Both tools were retired in
2.14.0 (ENC-W6B).

### 2.6.0 -- 2026-09-03
Frozen serve posture. `mootx01 serve --frozen` (or `MOOTX01_FROZEN=1`; the
flag wins) serves an estate as a read-only, side-effect-free snapshot over
stdio, both ports: no detached dreamer or drainer is spawned at startup, on
the periodic trigger, or at exit; `moot_memory_search` runs with internal
recall origin (no recall-trace rows, no dreaming enqueue); dereference verbs
write no reward mark; and every tool in the mutation inventory
(`AriaMCP.ToolMutationInventory` / `aria_mcp::tool_mutation_inventory` —
additive writes, mutations, erasure) returns an `isError` tool result with
the text `estate is frozen (serve --frozen): <tool> is a mutating tool and
was refused`, before any runner fires and before session state records the
call. `teachme:true` is still answered. `moot_estate_status` gains a
`"frozen: true|false"` line immediately after `index_composition_policy`.
The combination with `--http` / `MOOTX01_HTTP_PORT` is refused (the resident
daemon runs background workers), and a frozen stdio serve refuses to forward
to a live resident serving the same estate. The mutation inventory moved
from the two installers into the kit so the installer's permission tiers
and the frozen refusal read one table. The benchmark harness sets
`MOOTX01_FROZEN=1` on every read-only artifact serve it launches.

### 2.5.0 -- 2026-09-02
Dark mint tools gated at launch (codex finding 16). `moot_run_adornment_pass`
and `moot_register_adornment_minter` (§ 9.2) dispatch only when the serving
process was started with `MOOTX01_MINT_TOOLS=1` (§ 4.2); the variable is read
once per process, and without it `tools/call` for either name returns the
standard unknown-tool error in both ports. `moot_run_adornment_pass`
`batch_size` is clamped to `ADORNMENT_PASS_MAX_BATCH_SIZE` (5000). The
benchmark mint driver sets the variable on the serve it launches. The
advertised tool surface is unchanged.

CDL-03: `moot_estate_status` response stats array gains
`"index_composition_policy: <id>"` entry (e.g.
`"index_composition_policy: lex=original;dense=distilled"`). The value is the
`IndexCompositionPolicy.id` of the policy active for this estate open.
`"index_composition_policy: none"` when no estate is open. Benchmark harness
`RunEnvironment` gains the `index_composition_policy` field (snake_case CodingKey)
populated from the `MOOT_INDEX_COMPOSITION` env var at run start.

### 2.4.0 -- 2026-08-26
Ladder merge. The develop/1.1.x stream and the benchmark stream each
minted entries in the 1.4x-1.5x range for unrelated changes while this
document was being reorganized to 2.x. The develop entries are preserved
verbatim in the companion changelog under a repair heading; their
self-labels are historical text and do not index into this ladder.
No contract change in this entry.

### 2.3.0 -- 2026-08-26
Per-operation template pass (structural, no contract change). Every tool
entry in the six-family catalog now uses one fixed template: Purpose,
Input, Behavior, Output, Errors, Sample, Conformance. Compact family
tables replaced by per-tool blocks; the shared dataset-schema and
vault-job facts moved into the owning tool entries; the advanced lens
arguments moved into each lens entry. The 2.1.0 maintenance-status
entries are folded into the catalog: `moot_rebuild_status` now has a
catalog entry, `moot_drain_status` records the `dreaming` lane and
`moot_estate_status` records the composite condition surface. Payload
samples unchanged byte for byte.

### 2.2.0 -- 2026-08-26
MINTCLI-78: NEW dark tool `moot_register_adornment_minter` (§ 9.2) —
registers one full adornment-minter descriptor through the product
surface and atomically replaces the active set with exactly that
minter. Dark like `moot_run_adornment_pass`: dispatched by name,
never in `tools/list`, so the advertised tool count is unchanged.
The benchmark mint subcommand calls it once per restored estate
before looping `moot_run_adornment_pass` (now called with an
explicit `batch_size`) to debt exhaustion.

### 2.1.1 -- 2026-08-26
Vocabulary (mission SSC-RENAME): the S1 fourth column's acronym is
defined at its first use — SSC = Semantic Search Candle. The typed
intermediate renames to `SemanticSearchCandleData` in both ports
(`renderSscText`/`render_ssc_text` → `renderSemanticSearchCandleText`/
`render_semantic_search_candle_text`; row field `ssc` →
`semanticSearchCandle`/`semantic_search_candle`). Wire shapes are
unchanged: the structured `ssc` key, all row grammars, and every
rendered payload are byte-identical.

### 2.1.0 -- 2026-08-26
Maintenance status surfaces (Bob rulings 2026-08-26): NEW tool
`moot_rebuild_status` — the derived-state rebuild OPERATION status
(`rebuild: running | idle`; reindex backfill / basis retrain +
re-embed, whoever triggered it). A rebuild is not a drain, so it never
appears in `moot_drain_status`. `moot_drain_status` gains the
`dreaming` lane (the recall-event dreaming queue — a genuine queue
drain, paid down out-of-band; the benchmarker's encode barrier
denylists it). `moot_estate_status` becomes the composite condition
surface: its body now appends the drain report and the rebuild line;
the narrow tools remain the cheap machine-polling surfaces. Tool count
80 → 81.

The full entry ladder (1.0.0–1.59.0 and onward) lives in
[ARIA_MCP_INTERFACE_CHANGELOG.md](ARIA_MCP_INTERFACE_CHANGELOG.md).
Current entry:

### 2.0.0 -- 2026-08-25

Adopted consolidation (Bob approval 2026-08-25) replacing the 1.59.0
document body: six-family tool catalog (§§ 5–10); § 11 full result-format
grammar catalog with Samples (row-grammar rules, fixed-column canonical
row, control-line grammars, S2–S6 shapes, lossless tabular encoding,
structured base-row-plus-extensions schemas, zero/one/many
active-adornment composition with the ordered structured `adornments`
array); sensitivity-advisory relocation to tool descriptions +
estate_status; `ack` removed from recall_distilled. History externalized
to ARIA_MCP_INTERFACE_CHANGELOG.md; drafting record (0.1.0–0.3.0): the
archived ARIA_PROPOSED pair.

Proposal-draft ladder (retained verbatim for the record):

### 0.3.0 -- 2026-08-25

Specified the fifth-column grammar for zero, one, or many active adornments.
Added the ordered structured `adornments` array with `minterID` and `text`,
while retaining `adornment` as the exact composed text field for additive
compatibility.

### 0.2.0 -- 2026-08-25

Integrated the decided retrieval return-shape contract
(RETRIEVAL_SHAPE_OPTIMIZATION_2026-08-25, register R1–R16). § 11 rebuilt
as the full grammar catalog: row-grammar rules (separator guarantee,
fixed columns with `-` absence placeholders, truncation, per-surface
ordering including request-order batch get with duplicate-id semantics,
caps, empty states); the canonical S1 row and its federated/vague/
distilled forms (ack ceremony deleted); the deviation-only control-line
grammars including the degradation line (the always-on
`recall_provenance:` line is removed — stage/lane vocabulary is
log-side); the synthesis document form (scaffold fields removed;
normalized-cue `query:` line); S2 enumeration grammars; the S3 full
record pinned from renderer readback; S4 fact rows (search + time-major
timeline); S5 edge rows; the S6 tabular grammar with lossless value
encoding; the structured base-row schema with surface extensions, typed
`ssc`, capability metadata, synthesis `cues`/`summary`, complete lens
extents, and structured tabular results; sensitivity-advisory
relocation to tool descriptions + estate_status (§ 11.12). § 5 reply
cells updated; `ack` removed from recall_distilled's arguments.

### 0.1.0 -- 2026-08-25

Created the proposed consolidated interface reference from the four ARIA source
documents. Integrated the six-family taxonomy, grouped shared schemas and wire
formats, separated behavioral authority into the companion Spec, isolated
source discrepancies, and retained the original documents unchanged.
