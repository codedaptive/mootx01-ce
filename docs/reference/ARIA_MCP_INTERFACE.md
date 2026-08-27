---
title: aria-mcp Interface
version: 2.4.0
status: accepted-1.1-target
date: 2026-08-26
description: "Public API surface for aria-mcp in both the Swift and Rust ports. 2.0.0: consolidated reorganization (adopted from the ARIA_PROPOSED pair) — full result-format grammar catalog with Samples, structured base-row-plus-extensions schemas, zero/one/many active-adornment composition and structured minter provenance. Full history: ARIA_MCP_INTERFACE_CHANGELOG.md. 2.3.0: per-operation entry template across the six-family catalog."
spec_type: protocol
authors: MOOTx01 maintainers
relates_to:
  - ARIA_MCP_SPEC.md (the behavioral contract)
  - GENIUSLOCUSKIT_SPEC.md (the estate verb surface tools dispatch to)
  - LOCUSKIT_SPEC.md (drawer, adornment-store, and lifecycle semantics)
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
| `mode` | string | absent | Advisory `Mode` or `Mode=Variant` declaration |

The dispatcher injects `mode` into every generated input schema. Interface
tools expose `estateID` and `teachme` where their surface permits them.

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
| `.interface` | Core memory, connection, fact, journal, estate, maintenance, monitoring, dataset, and packet tools |
| `.federation` | `moot_federated_search` |
| `.recipe` | Cognition recipes and the 23 `moot_lens_*` tools |
| `.vault` | Vault export, import, status, reconcile, and job tools |

`MOOTX01_MEMORY_TOOL=1` adds the opt-in Anthropic `memory_20250818`
compatibility tool. Vault-off mode hides the vault tools and local-file import
surfaces identified by the generated projection.

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
  control, tie, answer, and coaching lines (§11).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Canonical candidate grammar in §11.2; behavioral Sample in
  Spec § 8.3.
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

#### `moot_federated_search`

- **Purpose:** Grant-authorized search across locally open estates.
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
- **Output:** Candidate row plus unlabeled distilled continuation (§11.2).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Distilled-form Sample in §11.2.
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
- **Output:** Answer/digest fields plus canonical candidate citations
  (§11.4).
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** Synthesis document grammar in §11.4.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

### 5.3 Tier 3 — Pinpoint

#### `moot_memory_get`

- **Purpose:** Exact drawer hydration.
- **Input:** Exactly one of `id` or `ids`; `depth` is `subject`,
  `distilled`, or `full` (default).
- **Behavior:** Batch shallow depths winnow a shortlist. The tool's
  `tools/list` description carries the sensitivity advisory (§11.12).
- **Output:** S2 batch rows in request order (§11.5) or the S3 full record
  (§11.6).
- **Errors:** A gated or absent single id returns the standard not-found
  tool error (§11.6).
- **Sample:** Full-record Sample in §11.6.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

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

Capture admits memories, facts, links, datasets, packets, and imports.

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

#### `moot_file_packet`

- **Purpose:** Store a structured packet with lineage.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Packet ID/acknowledgment.
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
  omitted/false uses the background encode path.
- **Output:** Reply begins `filed memory <uuid>` and carries
  location/lineage details.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

### 6.3 Tier 3 — Assertion

#### `moot_file_fact`

- **Purpose:** File one structured fact.
- **Input:** Required: `subject`, `predicate`, `object`; optional
  `source_id`.
- **Behavior:** Filing time is server-assigned.
- **Output:** Filing acknowledgment.
- **Errors:** Standard JSON-RPC errors only (§16.1).
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
- **Errors:** Standard JSON-RPC errors only (§16.1).
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
- **Input:** `tunnel_id`, `verdict` (`accept`, `reject`, `endorse`),
  optional `reviewed_by` (default `user`), optional `reason`.
- **Behavior:** Only proposed tunnels are accepted.
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

#### `moot_distill`

- **Purpose:** Bounded distillation pass.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Result reports work and debt.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

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

#### `moot_reclassify_fdc`

- **Purpose:** Audit/repair stored classification anchors.
- **Input:** Explicit mode/apply gate.
- **Behavior:** The mode/apply gate controls writes.
- **Output:** Audit/repair report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_run_adornment_pass`

- **Purpose:** Dark benchmark/maintenance adornment pass.
- **Input:** Harness-only maximum-length override; `batch_size` bounds
  (drawer, minter) pairs per call.
- **Behavior:** Dispatched by name but omitted from `tools/list`.
- **Output:** Pass report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_register_adornment_minter`

- **Purpose:** Dark benchmark/maintenance minter registration.
- **Input:** One full minter descriptor: `minter_id`, `minter_name`,
  `minter_family`, `minter_model_id`, `minter_model_version`,
  `minter_prompt_digest`, optional string-map `minter_parameters`.
- **Behavior:** Dispatched by name but omitted from `tools/list`.
  Registers the descriptor through the product surface and atomically
  replaces the active set with exactly that minter.
- **Output:** Registration report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

### 9.3 Tier 3 — Surgery

#### `moot_run_migration`

- **Purpose:** Derive and benchmark migration branches.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Migration/benchmark report.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_confirm_migration`

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
  plus the appended drain report and rebuild line. Protocol block per
  §12.1; sync vocabulary per §12.2; optional advisories per §12.3.
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
- **Output:** Lens catalog listing.
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
  paid down out-of-band; the benchmarker's encode barrier denylists it).
  A rebuild is not a drain, so it never appears here (see
  `moot_rebuild_status`).
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

#### `moot_packet_get`

- **Purpose:** Fetch one packet by ID.
- **Input:** Packet ID.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** The packet.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_packet_list`

- **Purpose:** List/filter packets.
- **Input:** Exact schema is generated by `ToolProjection.tools()`.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Packet listing.
- **Errors:** Standard JSON-RPC errors only (§16.1).
- **Sample:** None recorded in this document.
- **Conformance:** Covered by the §16.2 and §16.3 suites.

#### `moot_packet_lineage`

- **Purpose:** Return one packet's derivation thread.
- **Input:** Packet ID.
- **Behavior:** Behavioral contract: [ARIA_MCP_SPEC.md](ARIA_MCP_SPEC.md).
- **Output:** Derivation thread.
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
   first sentence byte-identical to the subject, an absent SSC (Semantic
   Search Candle), and an
   absent active-adornment projection each render `-`. A literal `-` inside a real value is
   unambiguous because the placeholder only ever occupies a whole column.
3. **Truncation.** First sentence: hard cut at 120 characters, no
   ellipsis. Subject: ≤120 by capture contract. Each adornment: ≤280 by mint
   contract. One active adornment renders unchanged. Multiple active
   adornments render in ascending minter-ID order, joined by ` || ` inside the
   same column; a literal ` || ` inside an adornment is normalized to ` / `.
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
<uuid> · <subject> · <first sentence | -> · <SSC facts | -> · <active adornment text(s) | -> · <event time> · <score %.4f>
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

Distilled recall follows each row with its distilled text as a four-space
indented unlabeled continuation; a row still owing a distillate carries the
fallback marker then the verbatim content:

```text
found 2 candidate memories, one per line
30B1B3B0-945D-4C07-AE57-53D9FFC9B543 · Entelo follow-up decided at TechFest · user: I'll definitely look into Entelo further. · kind: decision, entity: Entelo · TechFest; 2026-01-01; networking; elevator pitch; tips · 2026-01-01T00:07:52Z · 0.5687
    Decided at TechFest to evaluate Entelo as the recruitment tool; user owns the follow-up.
E70A5761-152D-4ABB-B16A-964B06A09404 · AI recruitment tool exploration for company · user: I'm looking to explore AI-powered recruitment tools for my company. · kind: plan, entity: recruitment tools · Sarah; Google; TechFest; 2026-01-01; three weeks ago · 2026-01-01T00:07:48Z · 0.5562
    source: content (not yet distilled)
    I'm looking to explore AI-powered recruitment tools for my company. Sarah from Google suggested several options at TechFest three weeks ago.
```

No acknowledgment or contract-change notice ever precedes results.

### 11.3 Control lines (deviation-only, fixed grammar, after the rows)

```text
discrimination: low — top results within epsilon.
discrimination: medium — partial separation.
temporal: <window-mode> (<source>, <grab>) window <from>..<to>[ ±Nd]
temporal: loose date-seeking — real-dated memories first; read the answer from each row's event_time
walk: stage=<stage> stoppedEarly=<yes|no>
retrieval: degraded — one or more ranking stages unavailable
```

The discrimination line renders only at low/medium. The degradation line
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
<uuid> · <subject | -> · <first sentence | -> · <SSC | -> · <active adornment text(s) | -> · <event time>
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
the active `adornments:` block follows it when present. Tunnel lines are
confirmed-active edges only, arrow gives direction, cap 50; verbatim content
follows the `content:` label untruncated.

```text
memory 30B1B3B0-945D-4C07-AE57-53D9FFC9B543
room: recruiting  wing: Agentic Memory
subject: Entelo follow-up decided at TechFest
adornments: 2
  TechFest; Entelo evaluation; recruitment workflow; user follow-up
  Entelo; sourcing tool review; TechFest recommendation; next action
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

The `adornments:` block is omitted when no active stored adornment exists. Its
unlabeled indented values appear in ascending minter-ID order; structured
content carries the IDs. One active minter renders `adornments: 1` and one
value.

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
<tunnel ID> · <kind/label[ (lifecycle)]> · <far endpoint: uuid · subject · first sentence | - · SSC | - · active adornment text(s) | - · event time>
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
          "firstSentence": { "type": "string" },
          "ssc": {
            "type": "object",
            "properties": {
              "kind": { "type": "string" },
              "entities": { "type": "array", "items": { "type": "string" } }
            }
          },
          "adornment": { "type": "string" },
          "adornments": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["minterID", "text"],
              "properties": {
                "minterID": { "type": "string" },
                "text": { "type": "string" }
              }
            }
          },
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

Before rendering, the shared composer calls GLK `activeAdornments` once with
all result Drawer IDs. `adornment` is the exact text projected into the fifth
column. `adornments` preserves the same contributing values as ordered
`{minterID, text}` entries. Both properties are absent when no active stored
adornment exists for that Drawer.

Surface extensions (additional per-row properties):

| Surface | Extension properties |
|---|---|
| connected recall | `retrievalSource`: `"anchor"` \| `"walk"` \| `"both"` |
| distilled recall | `distilled` (string), `representation`: `"distilled"` \| `"contentFallback"` |
| vague recall | `tier`: `"summary"` \| `"original"` |
| federated search | `estateID` (string) |
| memory get | `content` at the depths where the text carries it |
| lens concepts / associations | `extent` / `exemplars`: full drawer-UUID arrays (the text preview caps at count + first 3; the structured arrays are complete) |

Top-level `capabilities` object mirrors the control lines — keys:
`discrimination` (`"low"` \| `"medium"`), `walk` (`{ "stage": string,
"stoppedEarly": boolean }`), `temporal` (`{ "mode": string, "source":
string, "grab": string, "from": string, "to": string, "widenedDays":
integer }`), `degraded` (`true`). Each key is ABSENT when its control line
does not render. Synthesis adds top-level `cues` (string array, the
normalized terms) and `summary` (string).

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
| `moot_confirm_migration` | disqualified branch result |
| `moot_link_memories` | unresolved IDs |
| any lens | zero results |

Hints never attach to error results. The first matching trigger wins.

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
- `moot_recollect` is a retired notice-only stub queued for removal at the next
  major version;
- `moot_update_check.py` is an update-check hook, not an MCP tool; and
- `moot_vault_*` is prose shorthand for the five explicitly listed vault tools,
  not an additional tool name.

## Changelog

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
