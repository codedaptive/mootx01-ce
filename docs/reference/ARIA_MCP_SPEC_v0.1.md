---
status: draft specification, v0.1
authors: Bob Pankratz (via/ claude)
date: 2026-05-10
version: 0.1
relates_to:
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md (substrate contract)
  - NEURONKIT_SPEC_v0.1.md (algorithm layer ARIA_MCP calls into)
  - COGNITIONKIT_SPEC_v0.1.md (recipe layer ARIA_MCP triggers)
  - GENIUSLOCUS_IMPLEMENTATION_PLAN_v0.35.md (build order: ARIA_MCP is Phase 4)
---

# ARIA_MCP Specification — v0.1

ARIA_MCP is the external interface to the GeniusLocus system. It is the only
point of entry for tools that do not compile the library directly. Every
external entity — Claude Code, OB1 runtimes, any MCP client, any web caller —
communicates with the kit stack exclusively through ARIA_MCP.

**ARIA_MCP is a boundary, not a layer in the stack.** It does not sit between
NeuronKit and GeniusLocusKit. It sits alongside NeuronKit as a peer and calls
into the system through three distinct modes depending on what the caller needs.

**Compiled applications bypass ARIA_MCP entirely.** Fulcrum, ARIA_MacOS,
ARIA_iOS, and any other application that compiles the kit library directly
calls GeniusLocusKit, NeuronKit, and CognitionKit in-process with no MCP
overhead and no schema versioning indirection.

**The three call modes are not equal in weight:**

1. **Transactional** — direct call to GeniusLocusKit estate verbs. Fast,
   synchronous, bounded. A capture, a recall, a mutate. One call, one result.
   For tools that need a quick answer or a quick write.

2. **Algorithm** — call to NeuronKit reasoning functions. Heavier than
   transactional, still caller-driven. ARIA_MCP asks NeuronKit to run an
   algorithm (hybrid recall, context synthesis, branch tournament scoring).
   NeuronKit reaches into GeniusLocusKit as needed. The caller blocks until
   the algorithm completes.

3. **Trigger + webhook** — call to CognitionKit recipes. Asynchronous.
   ARIA_MCP fires a named recipe and returns immediately with a trigger ID.
   The recipe runs in the background. At each human-gated decision point,
   CognitionKit emits a webhook confirmation request back through ARIA_MCP to
   the caller's registered endpoint. The caller handles the UX, the human
   responds, the webhook fires back, CognitionKit proceeds. This is the path
   for mega work: daily framing tournaments, migration benchmarks, scenario
   elicitation end-to-end.

---

## § 1 — Scope

This specification defines:
- ARIA_MCP's position in the kit topology
- The three call modes and when to use each
- The MCP tool surface exposed to external callers
- Schema versioning, authentication, and write policy enforcement
- Webhook registration and confirmation protocol
- Cross-estate mediation (invariant I-13)
- Conformance requirements

ARIA_MCP does not define:
- Any algorithm (NeuronKit spec territory)
- Any storage schema (substrate spec territory)
- Any recipe logic (CognitionKit spec territory)
- The nine estate verbs (GeniusLocusKit spec territory)

---

## § 2 — Position in the kit topology

```
External tools (MCP)          Compiled apps
       ↓                     (bypass ARIA_MCP)
   ARIA_MCP  ←──── peer ────→  NeuronKit
      ↓ ①                         ↓
      ↓ ② ──────────────────→ NeuronKit
      ↓ ③ ──────────────────→ CognitionKit
      ↓                             ↓
   GeniusLocusKit ←────────────────┘
         ↓
   LocusKit · VectorKit · CorpusKit
```

ARIA_MCP is a peer of NeuronKit — neither above nor below. ARIA_MCP can call
horizontally into NeuronKit for algorithm calls. ARIA_MCP calls downward into
GeniusLocusKit for transactional calls. ARIA_MCP calls into CognitionKit for
trigger calls, and CognitionKit returns webhook confirmations back through
ARIA_MCP to the registered external endpoint.

---

## § 3 — First invariant: schema versioning

Every ARIA_MCP MCP tool call carries a `schema_version` string identifying the
contract the caller is operating against.

**Version format:** `geniuslocus.<verb>.<major>`

| Tool | Schema version |
|---|---|
| recall | `geniuslocus.recall.v1` |
| capture | `geniuslocus.capture.v1` |
| mutate | `geniuslocus.mutate.v1` |
| withdraw | `geniuslocus.withdraw.v1` |
| propose | `geniuslocus.propose.v1` |
| associate | `geniuslocus.associate.v1` |
| learn | `geniuslocus.learn.v1` |
| algorithm | `geniuslocus.algorithm.v1` |
| trigger | `geniuslocus.trigger.v1` |
| webhook_confirm | `geniuslocus.webhook_confirm.v1` |

**Rejection rules:**
- Missing `schema_version` → `SchemaVersionRequired` error
- Unrecognized version → `SchemaVersionUnknown` error
- Deprecated version (within deprecation window) → response includes
  `deprecation_warning` field with the sunset date
- Expired version → `SchemaVersionExpired` error

**Forward compatibility:** ARIA_MCP never makes breaking changes within a
major version. Adding fields to responses is non-breaking. Removing fields
or changing types requires a version bump. The deprecation window for any
major version is six months minimum.

**OB1 compatibility path:** A future ARIA_MCP release may implement the
`openbrain.agent_memory.recall.v1` schema alongside `geniuslocus.recall.v1`,
making any GeniusLocusKit estate usable as an OB1 memory backend. This is
post-v1; the versioning discipline in v1 makes it possible without breaking
changes to existing callers.

---

## § 4 — Authentication and access control

Every ARIA_MCP call must present credentials. Two credential types:

**Owner credentials** — full access to a single estate. Used by the estate
owner's tools. Carries: `estate_id`, `owner_token` (cryptographically random,
stored in the estate manifest).

**Scoped credentials** — read-only or write-limited access to specific wings
or rooms within an estate. Used for shared access (family members, colleagues).
Carries: `estate_id`, `scope_token`, `allowed_wings: [String]`,
`allowed_rooms: [String]`, `permission: .read | .readWrite`.

**Token storage:** Tokens are never logged, never included in error responses,
never echoed back. ARIA_MCP validates tokens against the estate manifest on
every call. Token rotation is supported via the estate handle's manifest
update API.

**Write policy enforcement at the ARIA_MCP boundary:**

ARIA_MCP enforces the write policy (spec Addendum A.2) before forwarding any
capture call to GeniusLocusKit. The actor class for all ARIA_MCP callers is
`mcp_agent` — blocking enforcement applies. Raw transcripts, reasoning dumps,
secrets, and oversized code blocks are rejected at the ARIA_MCP boundary
before they reach the substrate.

---

## § 5 — Call mode 1: Transactional

Direct mapping of GeniusLocusKit estate verbs to MCP tools. Synchronous.
One call, one result. No background work.

### § 5.1 — MCP tool surface (transactional)

```
geniuslocus_capture        → Estate.capture(_:)
geniuslocus_recall         → Estate.recall(_:) → first page synchronous
geniuslocus_mutate         → Estate.mutate(_:kind:payload:)
geniuslocus_withdraw       → Estate.withdraw(_:reason:)
geniuslocus_reanchor       → Estate.reanchor(_:to:)
geniuslocus_learn          → Estate.learn(_:)
geniuslocus_status         → Estate manifest + signal status
geniuslocus_report_usage   → Estate.reportRecallUsage(traceID:used:ignored:)
```

### § 5.2 — Capture tool

```json
{
  "tool": "geniuslocus_capture",
  "schema_version": "geniuslocus.capture.v1",
  "estate_id": "uuid",
  "credentials": { "owner_token": "..." },
  "frame": {
    "content": "string — the verbatim content to capture",
    "wing": "string",
    "room": "string",
    "channel": "typed | voiced | ocr | imported_file | sensor",
    "sensitivity": "normal | elevated | restricted | secret",
    "lattice_anchor": {
      "udc_code": "string",
      "wikidata_qid": "string?"
    },
    "adjective_bitmap": "Int64 — optional, defaults to 0 (state=active)",
    "idempotency_key": "string — optional, prevents duplicate captures"
  }
}
```

**Response:**

```json
{
  "schema_version": "geniuslocus.capture.v1",
  "drawer_id": "uuid",
  "lineage_id": "uuid",
  "created_at": "ISO8601",
  "write_policy_warnings": []
}
```

### § 5.3 — Recall tool

```json
{
  "tool": "geniuslocus_recall",
  "schema_version": "geniuslocus.recall.v1",
  "estate_id": "uuid",
  "credentials": { "owner_token": "..." },
  "frame": {
    "query": "string",
    "scope": { "wing": "string?", "room": "string?", "udc_prefix": "string?" },
    "filters": ["currentlyBelieve", "trustworthy", "userConfirmed"],
    "hydration_level": "minimal | standard | full",
    "page_size": 10,
    "mmr_lambda": 0.7,
    "bm25_weight": 0.3,
    "vector_weight": 0.7
  }
}
```

**Response:**

```json
{
  "schema_version": "geniuslocus.recall.v1",
  "trace_id": "uuid",
  "page": {
    "rows": [...],
    "page_index": 0,
    "is_last": true
  }
}
```

The `trace_id` must be passed to `geniuslocus_report_usage` after the caller
processes the results. Callers that never report usage provide no reward signal
to the dreaming daemon and degrade the estate's learning over time.

### § 5.4 — Report usage tool

```json
{
  "tool": "geniuslocus_report_usage",
  "schema_version": "geniuslocus.recall.v1",
  "estate_id": "uuid",
  "credentials": { "owner_token": "..." },
  "trace_id": "uuid",
  "used": ["drawer_uuid", "drawer_uuid"],
  "ignored": [
    { "drawer_id": "uuid", "reason": "not relevant to current context" }
  ]
}
```

---

## § 6 — Call mode 2: Algorithm

ARIA_MCP calls horizontally into NeuronKit to run a named reasoning function.
The caller blocks until the algorithm completes. Heavier than transactional
but still request-response.

### § 6.1 — MCP tool surface (algorithm)

```
geniuslocus_hybrid_recall     → NeuronKit.hybridRecall(_:estate:)
geniuslocus_synthesize        → NeuronKit.synthesize(from:estate:)
geniuslocus_verify_audit      → NeuronKit.verifyAuditChain()
geniuslocus_derive_branch     → NeuronKit.deriveBranch(name:from:)
geniuslocus_score_branches    → NeuronKit.runTournament(over:scoring:interval:)
geniuslocus_benchmark         → NeuronKit.benchmark(branch:against:queries:)
```

### § 6.2 — Hybrid recall tool

```json
{
  "tool": "geniuslocus_hybrid_recall",
  "schema_version": "geniuslocus.algorithm.v1",
  "estate_id": "uuid",
  "credentials": { "owner_token": "..." },
  "query": "string",
  "scope": { "wing": "string?", "room": "string?" },
  "bm25_weight": 0.3,
  "vector_weight": 0.7,
  "rrf_k": 60,
  "mmr_lambda": 0.7,
  "page_size": 10,
  "hydration_level": "standard"
}
```

**Response:**

```json
{
  "schema_version": "geniuslocus.algorithm.v1",
  "trace_id": "uuid",
  "results": [...],
  "bm25_hits": 4,
  "vector_hits": 8,
  "rrf_merged": 10,
  "mmr_reranked": 10
}
```

### § 6.3 — Synthesize tool

```json
{
  "tool": "geniuslocus_synthesize",
  "schema_version": "geniuslocus.algorithm.v1",
  "estate_id": "uuid",
  "credentials": { "owner_token": "..." },
  "trace_id": "uuid"
}
```

**Response:**

```json
{
  "schema_version": "geniuslocus.algorithm.v1",
  "context_document": {
    "summary": "string",
    "patterns": ["string"],
    "success_rate": 0.0,
    "average_reward": 0.0,
    "recommendations": ["string"],
    "key_insights": ["string"]
  }
}
```

### § 6.4 — Verify audit chain tool

```json
{
  "tool": "geniuslocus_verify_audit",
  "schema_version": "geniuslocus.algorithm.v1",
  "estate_id": "uuid",
  "credentials": { "owner_token": "..." }
}
```

**Response:**

```json
{
  "schema_version": "geniuslocus.algorithm.v1",
  "valid": true,
  "entry_count": 10432,
  "first_entry_at": "ISO8601",
  "last_entry_at": "ISO8601",
  "first_broken_at": null
}
```

---

## § 7 — Call mode 3: Trigger + webhook

ARIA_MCP fires a named CognitionKit recipe and returns immediately with a
trigger ID. The recipe runs asynchronously. At each human-gated decision
point, CognitionKit emits a webhook confirmation request to the caller's
registered endpoint. The caller handles UX, the human responds, the webhook
fires the confirmation back, CognitionKit proceeds.

This is the path for long-running work: daily framing tournaments, migration
benchmarks, scenario elicitation, any recipe that requires human confirmation
at one or more steps.

### § 7.1 — Webhook registration

Before triggering any recipe, the caller must register a webhook endpoint:

```json
{
  "tool": "geniuslocus_register_webhook",
  "schema_version": "geniuslocus.trigger.v1",
  "estate_id": "uuid",
  "credentials": { "owner_token": "..." },
  "webhook_url": "https://caller.example.com/nexus/confirm",
  "webhook_secret": "string — used to sign confirmation payloads",
  "ttl_seconds": 86400
}
```

**Response:**

```json
{
  "webhook_id": "uuid",
  "expires_at": "ISO8601"
}
```

### § 7.2 — Trigger tool

```json
{
  "tool": "geniuslocus_trigger",
  "schema_version": "geniuslocus.trigger.v1",
  "estate_id": "uuid",
  "credentials": { "owner_token": "..." },
  "webhook_id": "uuid",
  "recipe": "FulcrumDailyFraming | MigrationBenchmark | ScenarioSkill",
  "input": { }
}
```

**Response (immediate):**

```json
{
  "schema_version": "geniuslocus.trigger.v1",
  "trigger_id": "uuid",
  "recipe": "FulcrumDailyFraming",
  "status": "running",
  "started_at": "ISO8601"
}
```

### § 7.3 — Webhook confirmation payload

When CognitionKit reaches a human-gated step, ARIA_MCP POSTs to the
registered webhook URL:

```json
{
  "trigger_id": "uuid",
  "recipe": "FulcrumDailyFraming",
  "step": "promote_branch",
  "payload": {
    "tournament_report": { ... },
    "recommended_winner": { "branch_id": "uuid", "name": "Morning framing" },
    "scores": [ ... ]
  },
  "confirm_url": "https://nexuskit.estate/confirm/uuid",
  "expires_at": "ISO8601",
  "signature": "HMAC-SHA256 of payload using webhook_secret"
}
```

### § 7.4 — Confirmation response

The caller POSTs to `confirm_url`:

```json
{
  "trigger_id": "uuid",
  "step": "promote_branch",
  "decision": "confirm | reject | defer",
  "selected": "branch_id — when decision=confirm",
  "note": "string — optional human note recorded in DiaryEntry"
}
```

**Decision semantics:**
- `confirm` — proceed with the recommended action or the selected item
- `reject` — abort this step; recipe receives `RecipeError.userConfirmationRequired`
- `defer` — pause the recipe; it resumes when a fresh confirmation arrives
  within the webhook TTL

### § 7.5 — Trigger status poll

Callers can poll recipe status between webhooks:

```json
{
  "tool": "geniuslocus_trigger_status",
  "schema_version": "geniuslocus.trigger.v1",
  "estate_id": "uuid",
  "credentials": { "owner_token": "..." },
  "trigger_id": "uuid"
}
```

**Response:**

```json
{
  "trigger_id": "uuid",
  "recipe": "FulcrumDailyFraming",
  "status": "running | awaiting_confirmation | completed | failed | deferred",
  "current_step": "score_branches",
  "started_at": "ISO8601",
  "last_activity_at": "ISO8601",
  "output": { } // non-null when status=completed
}
```

---

## § 8 — Cross-estate mediation (invariant I-13)

ARIA_MCP is the only component that mediates cross-estate access. The substrate
does not federate. Two estates are never directly connected at the substrate
level.

Cross-estate operations are mediated by ARIA_MCP presenting credentials for
multiple estates and routing calls appropriately. The caller sees a unified
interface; the substrate sees isolated estate calls.

**Cross-estate recall:**

```json
{
  "tool": "geniuslocus_cross_estate_recall",
  "schema_version": "geniuslocus.recall.v1",
  "estates": [
    { "estate_id": "uuid-A", "credentials": { "owner_token": "..." } },
    { "estate_id": "uuid-B", "credentials": { "scoped_token": "...", "allowed_wings": ["shared"] } }
  ],
  "query": "string",
  "quality_threshold": 0.7
}
```

Results from multiple estates are merged. The `quality_threshold` filters
cross-estate results — only results with `reward >= quality_threshold` from
non-primary estates are included. The primary estate (first in the list)
returns all results regardless of threshold.

**Invariant I-13 enforcement:** ARIA_MCP never presents one estate's raw
database content to another estate's tools. It never joins across estate
SQLite databases. All cross-estate work is mediated through the estate handle
verb API.

---

## § 9 — Agent memory protocol

ARIA_MCP exposes a dedicated agent memory surface for agent runtimes that
need to recall context before work and write back compact summaries after.
This surface is modeled on the OB1 agent memory contract to enable future
compatibility.

```
geniuslocus_agent_recall    → structured context recall for agents
geniuslocus_agent_writeback → compact memory write-back with policy enforcement
geniuslocus_agent_usage     → report which recalled items were used
geniuslocus_agent_review    → list pending agent-written memories for human review
```

### § 9.1 — Agent recall

```json
{
  "tool": "geniuslocus_agent_recall",
  "schema_version": "geniuslocus.recall.v1",
  "estate_id": "uuid",
  "credentials": { "owner_token": "..." },
  "workspace_id": "string",
  "project_id": "string?",
  "task_id": "string?",
  "query": "string",
  "include_unconfirmed": false,
  "max_results": 10
}
```

**Response includes:** matched drawers + their adjective/provenance state +
a `use_policy` block declaring what the agent is permitted to do with each
result (`can_use_as_instruction`, `can_use_as_evidence`,
`requires_user_confirmation`).

### § 9.2 — Agent write-back

```json
{
  "tool": "geniuslocus_agent_writeback",
  "schema_version": "geniuslocus.capture.v1",
  "estate_id": "uuid",
  "credentials": { "owner_token": "..." },
  "workspace_id": "string",
  "project_id": "string?",
  "task_id": "string?",
  "memory_type": "decision | output | lesson | constraint | open_question | failure | artifact_reference | work_log",
  "summary": "string — compact summary, not raw transcript",
  "content": "string",
  "idempotency_key": "string?"
}
```

Write policy is enforced at this boundary (spec Addendum A.2). Raw transcripts,
reasoning dumps, secrets, and oversized code blocks are rejected.
`review_status` of all agent write-backs defaults to `pending` — they appear
in `geniuslocus_agent_review` for human confirmation before becoming
instruction-eligible.

---

## § 10 — Error model

```swift
enum NexusError: Error {
  // Schema versioning
  case schemaVersionRequired
  case schemaVersionUnknown(String)
  case schemaVersionExpired(String, sunset: Date)

  // Authentication
  case credentialsRequired
  case credentialsInvalid
  case credentialsExpired
  case insufficientScope(required: String)

  // Write policy
  case writeViolation(WriteViolation)

  // Transactional
  case estateNotFound(UUID)
  case drawersNotFound([UUID])
  case verbRejected(verb: String, reason: String)

  // Algorithm
  case algorithmFailed(String)
  case algorithmTimeout(String)

  // Trigger + webhook
  case webhookNotRegistered
  case webhookExpired
  case triggerNotFound(UUID)
  case confirmationExpired(triggerID: UUID, step: String)
  case recipeError(RecipeError)

  // Cross-estate
  case crossEstateCredentialsMissing(UUID)
  case crossEstateAccessDenied(UUID, wing: String)
}
```

All errors carry `schema_version`, `error_code`, `message`, and
`request_id` for tracing.

---

## § 11 — Behavioral contracts

**B-1: ARIA_MCP is the only external entry point.** No substrate kit exposes
a network interface. No GeniusLocusKit method is reachable from the network
except through ARIA_MCP.

**B-2: Schema version required on every call.** No call proceeds without a
recognized schema_version. The version is validated before credentials,
before write policy, before any substrate access.

**B-3: Write policy enforced at the boundary.** ARIA_MCP applies write policy
before forwarding any capture to GeniusLocusKit. A rejected write never
reaches the substrate.

**B-4: Webhook confirmations are signed.** Every webhook payload is signed
with HMAC-SHA256 using the caller's registered webhook_secret. Unsigned or
invalid-signature confirmations are rejected.

**B-5: Cross-estate mediation is ARIA_MCP only.** No substrate kit joins
across estate databases. ARIA_MCP presents isolated estate calls to the
substrate and merges results at the response layer.

**B-6: Agent write-backs default to pending.** All memory written via
`geniuslocus_agent_writeback` has `review_status=pending` until a human
confirms via `geniuslocus_agent_review`. Pending memories are not
instruction-eligible regardless of their content.

**B-7: Trigger calls return immediately.** `geniuslocus_trigger` never
blocks on recipe execution. The response carries only the trigger_id and
initial status. All progress is communicated via webhook.

---

## § 12 — Conformance requirements

**C-1:** Every MCP tool call that reaches ARIA_MCP without `schema_version`
is rejected with `SchemaVersionRequired` before any processing.

**C-2:** Every call from an `mcp_agent` actor carrying raw transcript content
> 2000 characters is rejected at the ARIA_MCP boundary with
`WriteViolation.rawTranscript`. The capture does not reach GeniusLocusKit.

**C-3:** Cross-estate recall applies `quality_threshold` filtering to
non-primary estates. Results below threshold are not returned to the caller.

**C-4:** Webhook payloads are signed with HMAC-SHA256. A conforming
implementation rejects confirmations with invalid signatures.

**C-5:** `geniuslocus_trigger` returns within 500ms regardless of recipe
complexity. The recipe executes on a background task; the response carries
only the trigger_id.

**C-6:** Agent write-backs via `geniuslocus_agent_writeback` always have
`review_status=pending` in the substrate. A conforming implementation cannot
write an agent memory with `review_status=confirmed` without a prior human
review action.

**C-7:** `geniuslocus_report_usage` is accepted for any `trace_id` produced
by `geniuslocus_recall` or `geniuslocus_hybrid_recall` within the estate.
Usage reports received after the RecallTrace TTL (default 7 days) are silently
discarded rather than errored.

---

## § 13 — v0.1 scope

All capabilities in this spec ship in v1.0. Nothing is deferred.

**The three call modes are required:** a conforming ARIA_MCP implementation
that supports only transactional calls is not conformant.

**Post-v1 items (not deferred — not yet designed):**
- OB1 agent memory protocol compatibility (`openbrain.agent_memory.recall.v1`)
- Rate limiting and quota management per estate
- Audit log export endpoint
- Estate provisioning API (create a new estate via ARIA_MCP without direct
  filesystem access)
- Federation between ARIA_MCP instances (two ARIA_MCP servers sharing an
  estate group)

---

*End of ARIA_MCP Specification v0.1.*
