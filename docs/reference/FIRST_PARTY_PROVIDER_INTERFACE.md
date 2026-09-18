---
title: FirstPartyProvider Interface
version: 1.2.0
status: accepted-1.1-target
date: 2026-09-14
description: Wire and catalog interface for the authenticated native ARIA provider.
spec_type: protocol
authors: MOOTx01 maintainers
relates_to:
  - FIRST_PARTY_PROVIDER_SPEC.md
  - ARIA_MCP_INTERFACE.md
  - ../../packages/kits/AriaMcpKit/Tests/Conformance/first_party_provider_v1_vectors.json
---

# FirstPartyProvider Interface

## 1. Discovery

`FirstPartyProviderCatalog` in
`packages/kits/AriaMcpKit/Sources/AriaMCP/FirstPartyProviderCatalog.swift`
is the executable catalog authority. Its discovery record has this exact
shape:

```json
{
  "provider": "FirstPartyProvider",
  "contract_version": "1.1.0",
  "aria_supported_version": "v2",
  "capabilities": ["memory.capture", "memory.read", "memory.mutate", "memory.connect", "fact.capture", "fact.read", "fact.retire", "journal.read", "recall.precise", "cognition.review", "estate.inspect"],
  "capability_digest": "3cb6f168d86fc2c1dc0f5384f1ac5972c8c16d49ff08b32a862abaaab2d3a77e"
}
```

`aria_supported_version` is mandatory discovery data. The record is additive
first-party metadata at the exact authenticated initialization path
`result.serverInfo.first_party_provider`; it does not widen the frozen
Community identity response.

## 2. JSON-RPC compatibility

The authenticated endpoint is exactly `POST /mcp/first-party` and continues to
receive JSON-RPC 2.0. It preserves the existing MCP methods and parameter
grammar:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
```

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"moot_file_memory","first_party_provider":{"contract_version":"1.1.0","aria_supported_version":"v2","capability_digest":"<value from initialize>"},"arguments":{"content":"The lake path is on the north side.","subject":"Lake path","location":"field notes"}}}
```

The stable-provider portion of `tools/list` projects exactly the fixed catalog
descriptors. The authenticated endpoint adds its separately governed Community
portion as described below. A stable `tools/call` accepts the name and argument
object shown above, then invokes the typed ARIA operation with caller, estate,
and policy supplied by the authenticated composition root.

### Authenticated namespace composition

The authenticated endpoint exposes two independent namespaces in one
`tools/list` response: the 26 `FirstPartyProvider` operations listed here and
the frozen 35-operation `moot_community_*` Community contract. A stable name
is dispatched only to this provider; a Community name is dispatched only to
the Community coordinator. Neither namespace falls through to the public MCP
dispatcher, and the ordinary public endpoint exposes neither namespace.

The `initialize` result retains its existing `serverInfo` identity fields. The
provider discovery record is returned as
`serverInfo.first_party_provider`, with exactly the five fields in §1. Every
stable-provider `tools/call` must include a `first_party_provider` object with
exactly `contract_version`, `aria_supported_version`, and `capability_digest`,
matching that discovery record. A mismatch or omission is rejected before
provider dispatch and performs no estate mutation. This requirement applies
only to the 26 stable names: existing Community and public MCP clients retain
their prior `tools/call` grammar.

The provider additionally admits the exact 1.0 compatibility tuple
(`contract_version: 1.0.0`, ARIA `v2`, digest
`88d682d7dd74754040b9a6ae5c81c9ddabcb830ee1fc0d0891e573edbebbfde7`)
for calls using the original 1.0 schemas. Supplying a 1.1-only argument under
that tuple is an invalid-parameters error. This compatibility path does not
change the current discovery record.

### Refusals carry the structured error data

Every argument refusal on the first-party lane is a JSON-RPC error whose `data`
object is the same shape the v2 lane emits, so a caller can correct and retry
without reading prose:

```json
{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Unsupported value for mutation.","data":{"code":"invalid_argument","path":"mutation","message":"Unsupported value for mutation.","allowed":["correct_sensitivity","correct_text","retitle"],"correction":"Use one of the allowed values."}}}
```

`data.code`, `data.path` and `data.message` are always present. `data.allowed`
is present when the refused argument has a finite value set (an enum member, an
unknown argument key, an argument the caller's `contract_version` does not
support) and lists the values or keys accepted, sorted. `data.correction` is a
one-sentence fix. The list is derived from the operation's declared schema, so
it is byte-identical to what `tools/list` advertises.

## 3. Operation schemas

Every schema is an object with `additionalProperties: false`; no operation
accepts `estate_id`. UUID fields are UUID strings, `limit`/`topK` are positive
integers, and omitted arguments are optional. The executable vector pins one
accepted argument object for every operation.

| Tool | Effect | Required arguments | Optional arguments |
|---|---|---|---|
| `moot_file_memory` | write | `content`, `subject`, `location` | `wing`, `sensitivity`, `exportability`, `kind`, `event_time`, `impatient` |
| `moot_memory_get` | read | `memory_id` | — |
| `moot_memory_list` | read | `wing` | `room`, `filter`, `limit`, `cursor` |
| `moot_memory_search` | read | exactly one of `query`, `near` | `limit`, `filter: "exportable"` |
| `moot_update_memory` | write | exactly one of `id`, `memory_id`; `mutation` | `subject`, `sensitivity`, `exportability`, `note` |
| `moot_withdraw_memory` | write | exactly one of `id`, `memory_id` | `reason` |
| `moot_erase_memory` | write | exactly one of `id`, `memory_id`; exactly one of `confirmed: true`, `confirmation: true` | `reason` |
| `moot_confirm_memory` | write | exactly one of `id`, `memory_id` | — |
| `moot_move_memory` | write | exactly one of `id`, `memory_id`; exactly one of `location`, `room` | `wing` |
| `moot_link_memories` | write | `from_id`, `to_id`, `relationship` | `confidence`, `evidence` |
| `moot_review_tunnel` | write | `tunnel_id`; exactly one of `verdict`, `decision` | `note` |
| `moot_file_fact` | write | `subject`, `predicate`, `object` | `source_memory_id`, `event_time` |
| `moot_fact_search` | read | — | `query`, `subject`, `predicate`, `object`, `source_id_exact`, `subject_exact`, `limit` |
| `moot_retire_fact` | write | exactly one of `id`, `fact_id` | `reason` |
| `moot_read_journal` | read | — | `limit`, `before`, `after` |
| `moot_recall_precise` | read | `query` | `limit`, `filter: "exportable"` |
| `moot_list_lenses` | read | — | `verbose` |
| `moot_lens_keystones` | read | `wing` | `topK`, `keystoneOnly` |
| `moot_lens_theme_weather`, `moot_lens_contradiction` | read | — | — |
| `moot_lens_cohesion` | read | — | `dataset_id` |
| `moot_lens_drift` | read | `splitAt` | — |
| `moot_estate_status`, `moot_drain_status`, `moot_rebuild_status`, `moot_timing_report` | read | — | — |

## 4. Result grammar

Every listed operation returns the current ARIA v2 result envelope nested in
the existing `tools/call` JSON-RPC result:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [{"type": "text", "text": "..."}],
    "structuredContent": {
      "surface_version": "v2",
      "tool": "<called tool name>",
      "data": {"...": "typed ARIA result data"},
      "meta": {"effect": "read|write", "...": "typed ARIA metadata"}
    },
    "isError": false
  }
}
```

The `tool` and `meta.effect` constants inside `structuredContent` match the
selected descriptor. The typed operation owns `data` and all other metadata,
including any completeness state; this catalog does not fabricate a fixed
completeness value. Runner failures remain JSON-RPC successes with
`result.isError: true`; protocol faults are JSON-RPC `error` responses.

For `moot_fact_search`, `source_id_exact` and `subject_exact` are case-sensitive
equality filters. They combine with the existing fields. An empty
`source_id_exact` is valid and selects sourceless facts; an omitted field does
not constrain the source. Filtering occurs before `limit` is applied.

For memory search and precise recall, `filter` has the sole accepted value
`exportable`. The executor removes this wire selector after mapping it into the
server-owned authorization context. Effective exportability is exportable-only
when either the caller requests it or `FirstPartyRecallPolicy` requires it;
the policy's sensitivity ceiling is always retained.

The native mutation grammar uses `id` for memory update, withdrawal, erasure,
confirmation, move, and fact retirement; `confirmed` for erasure; `location`
for the move destination room; and `verdict` for tunnel review. The original
stable names remain accepted as explicit alternatives so existing clients can
upgrade their compatibility tuple without rewriting calls. Supplying both
names for one field is invalid. The provider translates the accepted form once
at its authenticated executor boundary. For `moot_move_memory`, omitted `wing`
is resolved from the authorized target memory and retained exactly; the
provider does not guess a default wing.

## 5. Native operation inventory

The native app routes durable capture, memory reads and mutation follow-ons,
facts, journal reads, recall, lenses, and estate status through the matching
stable operation above. `moot_memory_search` exposes only the exportable
narrowing from the broader public-v2 filter controls. Mutation follow-ons use
the native grammar documented in §3. Community lifecycle/capture/review/transfer/LAN
operations remain in the `moot_community_*` lane. ProductDock and licensed
product workflows remain separate connections and are not aliases for this
provider.

## 6. Conformance vectors

[`first_party_provider_v1_vectors.json`](../../packages/kits/AriaMcpKit/Tests/Conformance/first_party_provider_v1_vectors.json)
is executable from `FirstPartyProviderCatalogTests`. It pins discovery,
operation identities/effects, and the unchanged `tools/list`/`tools/call`
JSON-RPC examples. The later Rust runtime implementation consumes this same
vector; a verifier fixture alone is not a runtime parity claim.

## Changelog

### 1.2.0 -- 2026-09-14

- First-party argument refusals carry `data.code`, `data.path`, `data.message`, and where a finite value set exists `data.allowed` and `data.correction`, identical in shape to the v2 lane. Previously the lane returned a bare message.

### 1.1.0 -- 2026-09-11

Kept the roster at 26 operations; added stable `source_id_exact` and
`subject_exact` fact inventory fields plus the exportable-only filter for
memory search and precise recall. Added the native mutation spellings as
deterministic provider-boundary aliases, including room-only move semantics
that retain the stored wing. Pinned the new digest and the constrained 1.0
compatibility path.

### 1.0.3 -- 2026-09-10

Removed unimplemented `moot_recall_precise` answer/explain modifiers from the
stable schema. `moot_lens_keystones.keystoneOnly` is implemented as a real
post-filter; stable callers use boolean/integer values while the public v2
adapter retains its documented string forms.

### 1.0.2 -- 2026-09-10

Pinned authenticated discovery at `result.serverInfo.first_party_provider` and
required the matching three-field compatibility record on every stable call.
Community and ordinary public MCP calls retain their existing grammar.

### 1.0.1 -- 2026-09-10

Corrected the result nesting, named the endpoint, and described the full
26-operation stable peer rather than a two-operation example.

### 1.0.0 -- 2026-09-10

Established the executable first-party catalog, discovery grammar, fixed
operation schemas, ARIA v2 envelope rule, and shared Swift/Rust vector.
