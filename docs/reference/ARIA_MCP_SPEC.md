---
title: aria-mcp Specification
version: 1.18.0
status: active
date: 2026-07-16
description: "Behavioral specification for aria-mcp: invariants, conformance requirements, and the contract it guarantees."
spec_type: protocol
authors: MOOTx01 maintainers
relates_to:
  - ../concepts/MOOTX01_AND_ARIA_CANON.md (the definitions this spec projects from)
  - AriaLexiconLib (the grammar this spec projects onto MCP)
  - DESIGN_CONSTRAINTS.md (C-1, why the substrate stays model-independent)
---

# aria-mcp Specification: ARIA as a Language and the Lexicon-to-MCP Projection

aria-mcp is the external interface to a MOOTx01 substrate. ARIA is a language, the language already exists in AriaLexiconLib, and the MCP surface is a projection of that language onto MCP primitives. The API and the language are the same thing with the same semantics, fixed at design time. Delivery is phased into releases. The definitions of MOOTx01, the ARIA grammar, instance mode, and API mode are canonical and live in ../concepts/MOOTX01_AND_ARIA_CANON.md; this spec projects from them.

## § 0. Interface principles

- ARIA is specified as a language first. The MCP tool, resource, prompt, and completion surface is generated from the AriaLexiconLib grammar and the acceptance matrix, not authored ad hoc. AriaLexiconLib is the single source of truth, and the projection is conformance-gated across the Swift and Rust ports the same way the lexicon already is.
- ARIA is always the server. ARIA never acts as an MCP client.
- ARIA is the interface specification (Augmented Recall and Inference Architecture), reached three ways: the aria-mcp server, the Native API (the SDK), and the Embedded library (ARIA.md). This spec covers the aria-mcp consumption surface. aria-mcp is the first surface built; it carries ARIA over MCP without adding or changing semantics, thin over the SDK and bounded by it.
- ARIA serves a MOOTx01 instance. A MOOTx01 instance is GLK plus the two BrainKits, NeuronKit and CognitionKit (canon). The write surface is always GLK; reads may be lensed narrower.
- Delivery is phased (§ 9): conformance is defined per release, not by requiring every call mode at once. The rich primitive surface is the north star.
- v1.0 wraps a full MOOTx01 instance. v1.1 lets the MCP provision a narrow instance (just LocusKit or just CorpusKit) and route across a fleet in API mode. API-mode fleet routing is v1.1; the *local* Streamable-HTTP transport is v1.0. The config-writing installer ships in v1.0.
- **Transport model.** mootx01 is the **headless resident server** that wraps the whole vertical (ARIA → GeniusLocusKit → kits → substrate) in one process. Its **primary mode is a resident HTTP MCP server**, and because it owns the stack it **triggers its own Brain cycles** — dreaming, enrichment, maintenance, and the standing-signal scheduler run on mootx01's own pump loop. **stdio is the fallback** transport of the same server (PoC, testing, migrations). Local Streamable HTTP is therefore part of **v1.0**; only remote/multi-tenant HTTP, OAuth, and API-mode fleet routing are v1.1. **moot-mgr** is the separate GUI control + monitor surface for the headless daemon (for users who do not use the CLI). Native apps are **v2**. See §5 and §9.

The detailed transactional tool schemas and the error model carry forward unchanged and are referenced, not repeated, here.

## § 1. ARIA is a language

The grammar, stated in one sentence in AriaLexiconLib: every call is one verb applied to a noun, optionally constrained by adjectives.

The vocabulary is small and fixed. Nine verbs, fixed by invariant I-7: capture, recall, mutate, withdraw, expunge, reanchor, learn, propose, associate. Seven are caller-driven (capture, recall, mutate, withdraw, expunge, reanchor, learn). Two are substrate-driven, emitted by the BrainKits rather than called (propose, associate). One canonical noun, the drawer, with seven further storage shapes that are facets or residue of it (tunnel, kgFact, vector, diaryEntry, proposal, association, learnedReference). Four adjective categories, fixed by invariant I-8: state, trust, sensitivity, exportability. The acceptance matrix fixes which verbs each noun accepts, and it is the design-time semantics: it is data, so a conformance harness checks the Swift and Rust ports agree.

The acceptance matrix as it stands: the drawer accepts capture, reanchor, mutate, withdraw, expunge, recall; the tunnel accepts capture, mutate, withdraw, expunge, recall; the kgFact accepts mutate, withdraw, expunge, recall; the vector is substrate-managed and accepts no direct verb; the diaryEntry accepts recall only; the proposal accepts mutate, withdraw, expunge, recall; the association accepts mutate, expunge, recall; the learnedReference accepts learn, mutate, withdraw, expunge, recall.

## § 2. The projection principle

Every element of the MCP surface traces to a grammar element. A tool exists because a caller-driven verb exists; its legal arguments are the nouns that verb accepts under the acceptance matrix, constrained by the adjective categories. A resource exists because a noun exists. A completion source exists because the grammar and the reference data fix a finite legal value set at design time. Tool names follow the lexicon's naming discipline: an action tool is verb-then-noun, such as capture_drawer, and a query tool is noun-then-verb, such as drawer_recall, optionally under a server namespace.

This is what "the API uses the same semantics, known at design time" means. The acceptance matrix is the contract. A caller does not discover at runtime whether learn applies to a drawer; the matrix says it does not, and the generated surface reflects that before the first call. The projection is generated from AriaLexiconLib and conformance-gated, so the surface never drifts from the grammar because it is not maintained separately from it.

The `capture_drawer` tool's frame carries a single lattice-anchor classification code: an FDC (Free Decimal Correspondence) code, the classifier the substrate adopted as its v1.0 scheme. There is no scheme discriminator — FDC is the only scheme. The anchor argument keeps its `udcCode` name for wire compatibility; renaming the storage field is a separate migration outside this projection.

## § 3. Instance mode, API mode, and the dispatch path

A MOOTx01 instance runs in GLK mode (canon). The write surface is always GLK. The write verbs (capture, mutate, withdraw, expunge, reanchor, learn) always target GLK, which keeps the databases in sync through QueueKit, which uses PersistenceKit directly. ARIA calls only the GLK verb surface for writes and never reaches the kits beneath; GLK is what fans out and coordinates.

recall is the verb that may be lensed. In GLK mode the default recall is hybrid, spanning LocusKit spatial and KG retrieval and CorpusKit BM25-plus-vector retrieval (CorpusKit exposes Chunk, ScoredChunk, BundleStore, BM25Index, HybridRecall). On the same instance a caller may request a narrower read lens, CorpusKit-only or LocusKit-only, as a recall argument. The lens narrows the read; it does not create a separate store, and it does not change the write path.

API mode is the fleet. An operator configures many separate instances of different kinds, for example three CorpusKit, two LocusKit, three GeniusLocus, and ARIA routes each call to the database it belongs to. QueueKit over PersistenceKit is the mechanism for both the per-database operations and the cross-database coherence. Fleet routing is an API-layer concern (v1.1), distinct from the read-lensing available inside a single instance.

## § 4. The full primitive surface (the north star)

The MCP primitive set, mapped onto the ARIA language. This is the complete target; § 9 phases it.

| MCP primitive | ARIA language element | What it provides |
|---|---|---|
| Tools (tools/call) | The caller-driven verbs | Each tool's input schema is generated from the verb's frame, the nouns it accepts in the acceptance matrix, and the adjective categories |
| Resources (resources/read, subscribe) | The nouns: the drawer and its facets across LocusKit and CorpusKit | Read surface as live memory; a subscription to a wing or room yields notifications/resources/updated when drawers change |
| Prompts (prompts/get) | Recall and synthesis recipes as parameterized templates | Discoverable recall patterns, surfaced as slash commands by clients that support prompts |
| Sampling (sampling/createMessage) | The BrainKits borrowing the caller's model | The substrate stays model-independent per C-1 and still reaches a model for enrichment and synthesis by borrowing the client's, never embedding one |
| Elicitation (elicitation/create) | The human gates | Native confirmation for proposals, branch promotions, and agent write-back review |
| Tasks (experimental) | The long-running NeuronKit calls and CognitionKit recipes | Native durable execution with deferred result and status, in place of custom trigger-id polling |
| Completions (completion/complete) | The grammar and the reference data | Argument autocomplete for legal wings, rooms, FDC codes, and verb-legal adjective values; the direct dividend of design-time semantics |
| Notifications and Logging | Substrate-driven verbs and audit events | propose and associate are BrainKit-emitted, not caller tools; they surface here, with taxonomy-change and audit notifications |

The two substrate-driven verbs, propose and associate, stay out of the tool surface by design. They are emitted by the BrainKits, not invoked by callers, so they appear as notifications rather than tools.

## § 5. Always the server, and transport

ARIA is always the MCP server; it never acts as a client of another MCP server. Both transports are hand-rolled, no MCP SDK dependency, behind one dispatcher and tool router so the handlers do not change with the transport. One hard rule carries over to both: only JSON-RPC crosses the wire, and all logging goes to stderr.

**Primary transport (v1.0): resident local HTTP.** mootx01 runs as a long-lived, headless process bound to loopback (`127.0.0.1:<port>`), speaking JSON-RPC 2.0 over HTTP POST with SSE for server→client streaming (MCP "Streamable HTTP"). Because the process is resident and owns the whole stack down to the substrate, it is also what **triggers the Brain** — the pump loop that drives dreaming, enrichment, maintenance, and the standing-signal scheduler runs inside this server (see §9 and §17). This is the mode `mootx01 install` wires by default, registered under launchd so it starts at login and restarts on exit.

**Fallback transport: local stdio.** The same server, launched by a client as a subprocess, speaking JSON-RPC over stdin/stdout (newline-delimited, a dependency-free pattern: tool registry; dispatcher over initialize, ping, notifications, tools/list, tools/call; read-write loop). stdio is the simple path — proof-of-concept, testing, and the fallback for operations like migrations — and is ephemeral: it lives only while the client holds it, so it does **not** pump the Brain. The tool/JSON-RPC surface is byte-identical to the HTTP transport.

Remote/multi-tenant HTTP (the Custom Connector path: internet-hosted https, OAuth, scoped tokens) remains v1.1; only the *local* loopback HTTP transport is v1.0.

## § 6. Client compatibility (verified 2026-05-22)

The MVP serves local stdio clients. The relevant denominator, confirmed against each client's documentation:

| Client | Local stdio | Tools | Resources, Prompts | Sampling, Elicitation | Notes |
|---|---|---|---|---|---|
| Claude Desktop, Claude Code | Yes | Yes | Yes | Limited | The first clients targeted |
| Gemini CLI | Yes | Yes | Yes (as slash commands) | No | settings.json mcpServers; gemini mcp add |
| OpenClaw | Yes | Yes (standard tools only for generic servers) | No | No | Richer notifications reserved as client-specific experimental |
| Cursor | Yes | Yes | Partial | No | mcp.json mcpServers, command and args |

Two clients are not local-stdio clients and belong to the HTTP phase. The Claude API MCP connector is remote only: only tool calls are supported, local stdio cannot be connected directly, and the URL must be https. OpenAI's MCP is a remote server exposing a read-only search and fetch tool pair for deep research. Both are v1.1 (HTTP) considerations.

The conclusion: tools are universal across the local clients, resources and prompts are supported by the Claude hosts and Gemini, OpenClaw is tools-only for generic servers, and sampling and elicitation are not in the local baseline. The MVP is tools-first, advertising resources and prompts in capabilities so capable clients light them up and the rest degrade cleanly to tools.

## § 7. Install and connection protocols

Installer-written configuration (v1.0, the default path). `mootx01 install` detects which clients are present and merges the mootx01 entry into each client's configuration file — a guarded merge that preserves existing entries — then prompts the restart. It also registers the resident daemon under launchd and points the wired clients at it. This is a guarded file merge plus service registration, not new protocol. (See the transport correction: the daemon's primary endpoint is local HTTP; the stdio entry below is the fallback.)

Local stdio, manual configuration (the fallback / PoC path). Without the installer, each client can register a stdio server with a command and arguments, then restart: Claude Desktop in claude_desktop_config.json then quit and restart; Claude Code via claude mcp add or project .mcp.json; Gemini CLI via gemini mcp add or settings.json; Cursor in ~/.cursor/mcp.json; OpenClaw in its mcpServers registry. This works but requires hand-editing JSON and restarting, per client and per device — and an stdio entry is ephemeral, so it does not pump the Brain. Suitable for testing, PoC, and migrations.

Custom Connector, remote HTTP (v1.1). The easiest install for the user: in the client's Connectors settings, add a custom connector, paste the URL, authenticate. No file editing, no restart, and resources and prompts surface natively. The cost is that this path requires an internet-hosted https endpoint and authentication, commonly OAuth, so it is not a local-host mechanism. That is why it is v1.1.

## § 8. Authentication, phased

v1.0, local owner by default. The connection is a process the machine owner launched against a configured instance. The schema-version gate (§ 9 below references it) is kept. The credential check is a present-but-trivial seam that resolves the configured instance, structured as the single chokepoint so the real check drops in without rework. The write-policy gate is present as a single boundary on the write path, an allow-all stub for now. v1.1 and beyond, with HTTP: an owner and scoped token model, and OAuth for the Custom Connector path.

Every tool call carries a schema_version of the form geniuslocus.<verb>.<major>, validated before credentials and before any substrate access. This is the design-time contract between caller and surface.

## § 9. Release plan

v1.0, full MOOTx01, resident. ARIA wraps a full MOOTx01 instance, GLK plus NeuronKit and CognitionKit — the whole vertical from ARIA down to the substrate in one headless process. Its primary transport is the resident loopback HTTP MCP server (§5); stdio is the fallback. Because it is resident and owns the stack, it runs the autonomic governor (§17) that triggers dreaming, enrichment, maintenance, and the standing-signal scheduler — the continuous-operation behavior the architecture spec requires. The caller-driven verbs project as MCP tools whose schemas are generated from the lexicon and the acceptance matrix: capture, recall, mutate, withdraw, expunge, reanchor, learn, plus a status tool. Writes always target GLK; recall is hybrid by default and accepts a CorpusKit-only or LocusKit-only read lens. Resources and prompts are advertised in capabilities and implemented opportunistically. The schema-version gate, the local-owner credential seam, and the write-policy seam are present. Install is automated (`mootx01 install`): it wires clients to the HTTP endpoint and registers the daemon under launchd. The GUI control + monitor surface for the headless daemon is moot-mgr (a separate process; see MOOT_MGR_SPEC). Swift first; the Rust version is a fast-follow.

Dependency. v1.0 as defined depends on the two BrainKits, NeuronKit and CognitionKit. ARIA v1.0 therefore sequences after they land. A GLK-only transactional server is buildable against the shipped GeniusLocusKit, but that is a pre-v1.0 spike, not v1.0, because it lacks the BrainKits that make the instance MOOTx01.

v1.1. The MCP can provision a narrow instance, just LocusKit or just CorpusKit, rather than only wrapping a pre-built MOOTx01. API-mode fleet routing across many instances. The **remote** Custom Connector path — internet-hosted https, OAuth, and the owner and scoped token model (the *local* loopback HTTP transport already ships in v1.0). The richer read surface: resources with subscriptions, prompts, and completions.

v2. Native apps (macOS/iOS) over the headless daemon — expected sooner than later. The HTTP daemon remains the engine they drive; the GUI moves from the moot-mgr web console toward first-class native clients.

Beyond. The client-initiated primitives, gated on capable clients: sampling, so the BrainKits borrow the caller's model and the substrate stays model-independent; elicitation, so human gates are native; tasks, so long-running NeuronKit calls and CognitionKit recipes are durable. Then full remote, multi-tenant operation at scale.

The placement of resources, prompts, completions, sampling, elicitation, and tasks across v1.1 and beyond is a proposal, not a fixed boundary, and can move with client support and need.

## § 10. Build impact

Conformance is defined per release in § 9, not by requiring all three call modes at once. ARIA addresses the substrate through a backend-adapter seam: in GLK mode it calls the GeniusLocusKit verb surface, and the adapter is where the v1.1 narrow-instance modes and the API-mode fleet routing attach without reworking the projection. The v1.0 build, once the BrainKits land, is: tools generated from the lexicon and the acceptance matrix; the local-stdio clients as the named compatibility set with a smoke test against Claude and one other; local-owner trust with the credential seam; writes always GLK with recall lensing; resources and prompts advertised while only tools are implemented.

The lexicon-to-MCP projection in § 2 and § 4, and the instance-versus-API model in § 3, are the durable core of the contract. Everything else is sequencing around them.

## § 11. AI-client-oriented external surface

> **Note.** The lexicon-to-MCP projection principle in §2 and the
> tool naming discipline ("verb-then-noun") apply to the substrate's internal ARIA grammar
> contract. The *external* MCP tool surface exposed to AI clients uses an
> AI-client-oriented five-tier interface. The §2 projection principle is preserved as
> the architectural rationale; it does not describe the external tool names or schemas.

The external MCP tool surface is an AI-client-oriented interface
organized in five tiers. This design exposes familiar, task-oriented verbs
to AI clients rather than the substrate's internal grammar vocabulary.

### Five-tier external tool surface (22 interface tools)

| Tier | Tools | Substrate operation |
|------|-------|---------------------|
| 1 — Core Memory | `moot_file_memory`, `moot_memory_search`, `moot_memory_get`, `moot_memory_list`, `moot_update_memory`, `moot_withdraw_memory`, `moot_erase_memory`, `moot_confirm_memory`, `moot_move_memory` | GLK capture/recall (by query or by id)/mutate/withdraw/expunge/reanchor on drawers |
| 2 — Connections | `moot_link_memories`, `moot_review_tunnel`, `moot_connection_search`, `moot_connection_map` | GLK tunnel capture/recall; `Estate.respondToTunnel` (proposed → active/withdrawn) |
| 3 — Knowledge Graph | `moot_file_fact`, `moot_fact_search`, `moot_retire_fact`, `moot_fact_timeline` | GLK captureKGFact/recallKGFacts/retireKGFact |
| 4 — Journal | `moot_write_journal`, `moot_read_journal` | GLK addDiaryEntry/readDiaryEntries |
| 5 — Estate | `moot_estate_status`, `moot_estate_map`, `moot_estate_ping` | Kit estate introspection |

One federation tool (`moot_federated_search`) sits above the interface tier. It performs
a grant-authorized federated read across all locally-open estates the requester is
authorized for.

### Contradiction hunter surface

Three tools plus one lens expose the content-driven contradiction hunter
(GLK `huntContradictions` / `EstateCoordinator::hunt_contradictions`):

- `moot_hunt_contradictions` (recipe) — one bounded on-demand sweep: BM25
  lexical candidate pairs from the corpus's inverted index (drawer-keyed
  Hamming kNN on the bespoke lane), screened by the SubstrateML
  conflict cue. Strong findings persist as `contradicts` tunnels with
  lifecycle `proposed` / origin class `derived` (sensitivity = max of the
  endpoint tiers, stamped by `addTunnel`); borderline pairs are returned
  with ≤160-char snippets and never persisted — the calling agent
  adjudicates and records genuine conflicts via
  `moot_link_memories kind=contradicts proposed=true`. Dedup is durable
  against ALL existing contradicts tunnels including withdrawn ones: a
  rejected pair is never re-proposed. Optional `probe_limit`
  (default 500, max 10000) and `now` (ISO8601, deterministic runs). With
  no vector index the report says so honestly and scans nothing.
- `moot_review_tunnel` (Tier 2, ask tier) — settles a proposed tunnel:
  `verdict: "accept"` → lifecycle `active`; `"reject"` → `withdrawn`.
  Only proposed-lifecycle tunnels are reviewable; not-found and
  not-proposed return clean tool-level errors.
- `moot_dream` — runs the same hunt sweep as its content-driven third
  phase (probe budget 500/call) and reports `contradictionsProposed` /
  `contradictionCandidatesBorderline` in the cycle summary.
- `moot_lens_contradiction` — reports lifecycle tiers on contradicts
  edges: active (confirmed) and proposed (flagged
  `proposed (agent-derived, unreviewed)`, shown by default);
  withdrawn/superseded never surface.

The same core pass also runs hourly in the resident daemon
(`contradiction-scout`, standing signal 10 — see GENIUSLOCUSKIT_SPEC.md
signal inventory), so the background and on-demand surfaces share one
implementation and one dedup contract.

### `moot_memory_get` — fetch a drawer by id

`moot_memory_get` reifies the `recall` verb (§2) applied to the Drawer noun,
constrained by an exact identifier rather than a query. Per the naming
discipline in `docs/concepts/ARIA_LEXICON.md` ("a query tool is
`<noun>_<verb>`"), it is named as a `moot_memory_search` sibling, not as a
`verb_noun` mutation tool — fetching an existing drawer by id is a read, not
a capture/mutate/withdraw action.

Input: `id` (drawer UUID, required) plus the standard optional `estateID`
every direct tool accepts. Output: the drawer's verbatim content (hydration
`.full`, never truncated or previewed), its room/wing location, `filedAt`
and `eventTime`, the five adjective-axis fields (state, trust, sensitivity,
exportability, confirmation), lineage, and a summary of linked tunnels
(reusing the same tunnel-scan pattern as `moot_connection_search` /
`moot_connection_map`).

`moot_memory_get` applies the identical default containment gate that
`moot_memory_search` applies when its filter chain does not constrain
state/trust/sensitivity — `currentlyBelieve` (active/pending/contested/
accepted), `trustworthy` (verbatim/observed/imported/canonical), and
`sensitivityAtMost(.elevated)` (normal/elevated only), with tombstones
always excluded. A drawer that exists but fails that gate (e.g. withdrawn,
untrustworthy, or restricted/secret) is reported with the identical
"Memory not found: `<id>`" error as a genuinely absent id — the by-id
door cannot be used to probe for the existence of content the estate
would otherwise refuse to surface. This is the same not-found convention
`moot_link_memories` already uses for an unresolvable id.

### Infrastructure field ownership

The server owns all infrastructure fields: `latticeAnchor`, `embeddingModelID`, `addedBy`,
and capture `channel`. AI clients supply only subject-matter fields (`content`, `location`,
`query`, etc.). This isolates AI clients from substrate plumbing and allows server-side
evolution of infrastructure configuration without client changes.

### KGFact model

The `KGFact` substrate type (`LocusKit.KGFact`) stores a subject–predicate–object triple
with the following fields: `id` (server-assigned UUID), `subject`, `predicate`, `object`,
`sourceDrawerID`, three adjective/operational/provenance bitmaps, and `filedAt`.

`filedAt` is immutable and server-assigned at capture time — the same pattern as
`captureTime` on drawers. It records when the fact was filed, not when the underlying
fact became true in the world. Callers cannot supply it.

There are no temporal validity windows (`valid_from`/`valid_to`) in the current KGFact
model. Facts are active from the moment they are filed until explicitly retired via
`moot_retire_fact`. Retirement transitions the adjective bitmap state axis to `withdrawn`
(the same state machine as drawers), which excludes the fact from active recall.

`source_id` is the optional `sourceDrawerID` field — the drawer this fact was extracted
from. Omit for agent-asserted freestanding triples (the server supplies `""` as the
unanchored sentinel). Supply when the fact was derived from a specific memory to preserve
provenance.

### Recipe, lens, vault, and dataset tools

Twelve CognitionKit recipe tools (`moot_list_lenses`, `moot_list_recipes`,
`moot_synthesize`, `moot_recall_precise`, `moot_recall_shaped`,
`moot_run_migration`, `moot_confirm_migration`, `moot_dream`, `moot_consolidate`,
`moot_recall_distilled`, `moot_recollect`, `moot_hunt_contradictions`),
twenty-three reasoning-lens tools (`moot_lens_*`), and five vault control tools
(`moot_vault_export`, `moot_vault_import`, `moot_vault_status`,
`moot_vault_reconcile`, `moot_vault_job`) carry `.recipe` and `.vault`
provenance respectively. Three tabular-dataset tools (`moot_file_dataset`,
`moot_dataset_query`, `moot_dataset_stats`, MX-TAB-7) carry `.interface`
provenance — always visible, never vault-gated. Total: 71 tools vault-on,
65 vault-off (30 interface: 22 five-tier + 4 maintenance + 1 monitoring + 3
dataset; 1 federation; 35 recipe/lens; 5 vault). For the full enumeration see
ARIA_MCP_INTERFACE.md §2.

### Conformance contract

The acceptance matrix (§2) remains the internal substrate contract; it is not surfaced as
the external API shape. External conformance is defined by the tool list in the
AriaMcpKit interface specification §2 and its accompanying conformance suite. The §9
release plan is not affected — the AI-client-oriented surface is a refinement within v1.0,
not a release boundary change.

## § 12. Session orientation protocol

Two additions to the session entry-point (`moot_estate_status`) and the
cognition-discovery tool (`moot_list_lenses`).

### Protocol block in `moot_estate_status`

Every `moot_estate_status` response now appends a static `protocol:` section
unconditionally, after the estate stats block. The block teaches a cold AI
client the full ARIA surface in a single call, without prior knowledge:

```
estate: <name> [<uuid>]
memories: N active (M total)
wings: <list>
kg facts: N active
status: connected

protocol:
  — Call moot_estate_status with teachme:true for a full orientation guide.
  — Call moot_list_lenses to see available cognition tools.
  — Add teachme:true to any tool to learn it before using it.
  — Watch for hint: lines in responses — they contain coaching for better results.
  — File memories: moot_file_memory (content + location required).
  — Search memories: moot_memory_search (query required).
  — Write journal entries: moot_write_journal after meaningful sessions.
  — Store structured facts: moot_file_fact (subject + predicate + object).
```

Invariants:
- The block is **static** — identical across every call, every estate, every
  estate state. Content is a fixed constant.
- The block is **unconditional** — appears even on zero-memory estates.
- No estate is touched to produce the block; it requires no async work.

### Ten-tier `moot_estate_status teachme:true` guide

The `TeachmeGuides` entry for `moot_estate_status` is a ten-tier surface
summary covering tiers 1–10 plus the teachme and coaching mechanisms. The
total count line and all per-tier counts are computed at call time from
`ToolProjection.tools()` — the guide can never drift from the shipped surface.
The live vault-on count is 71 tools; vault-off is 65 (moot_palace_import and
the 5 moot_vault_* tools omitted). The cold-start sequence is named explicitly.
Tier structure: Tier 1 Core Memory (9), Tier 2 Connections (4), Tier 3 KG (4),
Tier 4 Journal (2), Tier 5 Estate (7 always + 1 vault-gated), Tier 6 Cognition
(27 = 4 recipe + 23 lens), Tier 7 Extended Cognition (8 = remaining recipe
tools), Tier 8 Dataset (3), Tier 9 Vault (5 vault-on only), Tier 10 Federation
(1). The authoritative live count is always in ARIA_MCP_INTERFACE.md §2.

### `moot_list_lenses` cognition menu

`RecipeTools.runListRecipes()` returns a one-block-per-tool cognition menu
assembled from `LensTools.tools()` and four Tier 6 recipe tools, listing 27
cognition tools total (23 `moot_lens_*` tools + `moot_synthesize`,
`moot_list_lenses`, `moot_recall_precise`, `moot_recall_shaped`).
Migration and distillation tools (Tier 7: `moot_run_migration`,
`moot_confirm_migration`, `moot_consolidate`, `moot_recall_distilled`,
`moot_recollect`) are intentionally excluded — they have their own tier and
teachme guides.

Response shape:
```
moot_list_lenses: 27 cognition tools

moot_list_lenses
  List the available reasoning lenses and CognitionKit behaviour recipes...
  Required: none.

moot_synthesize
  Synthesize memories into a grounded context document...
  Required: none.

moot_lens_keystones
  Reasoning lens: rank a wing's load-bearing memories by centrality...
  Required: wing.

... (one block per tool)

Call any tool with teachme:true for a full usage guide.
```

Required args are extracted from each tool's JSON Schema `required` array.

## § 13. teachme protocol and coaching hints

Two companion mechanisms wired into the dispatch layer.

### teachme

Every tool accepts an optional `teachme: boolean` argument. When `true`, the
dispatch layer intercepts the call before any runner fires, looks up the static
per-tool guide in `TeachmeGuides`, and returns it as a successful text result.
No estate is touched. The guide contains: what the tool does, when to use it vs
siblings, an annotated example call, response shape, and common mistakes.

Dispatch contract:
- Intercept happens at the top of `ToolDispatcher.dispatch`, before all routing
  (federation, recipe, lens, vault, interface checks).
- Result: `textResult(TeachmeGuides.guide(for: name))` with `isError: false`.
- Unknown tool names receive a fallback guide directing callers to
  `moot_estate_status` with `teachme: true` for orientation.
- Generic guides apply to lens tools, migration tools (`moot_run_migration`,
  `moot_confirm_migration`), other recipe tools, and vault tools.

### Coaching hints

Runners return a plain text result; after the runner returns, the dispatch layer
calls `CoachingEngine.hint(name:args:resultText:)` and, if a hint is returned,
appends `\nhint: <message>` to the result text before wrapping it.

Invariants:
- Hints are **never** appended to error results (`isError: true`).
- Hint injection does not change the tool's semantic result — it only appends
  advisory text. The `isError` flag is unaffected.

Coaching triggers:

| Tool | Condition | Hint summary |
|------|-----------|-------------|
| `moot_memory_search` | No `query` arg | Use `query` for semantic retrieval; browse with `moot_estate_map` |
| `moot_memory_search` | `query` length > 200 chars | Short queries recall more precisely |
| `moot_memory_search` | Result contains "0 memory" | Try broader terms or verify location with `moot_estate_map` |
| `moot_file_memory` | `content` length > 4000 chars | Split into smaller memories |
| `moot_file_memory` | Result contains "already exists" | Use `moot_update_memory` instead |
| `moot_erase_memory` | `confirmed` absent or false | Erase is irreversible; use `moot_withdraw_memory` for recoverable removal |
| `moot_confirm_migration` | Result contains "disqualified" | Promote only branches from the rankings list |
| `moot_link_memories` | Result contains "isError" | One or both IDs not found; search first |
| Any lens tool | Result contains "0 result" | Try `scope: active` for a fuller picture |

Multiple triggers per tool are evaluated in the order listed; the first matching
trigger wins and subsequent checks are skipped.

## § 14. Design note: moot_estate_ping replaces moot_estate_reconnect

aria-mcp is a long-running process (resident HTTP in the primary mode; the
stdio fallback is also long-lived for the duration of the client session). It
opens one estate at startup and
holds the handle for the lifetime of the process. There is no transient
disconnection state in this design: a `GeniusLocusKit` estate handle is either
registered in the actor's registry (open) or absent (`.estateNotOpen`). There
is no network layer between the MCP server and the estate — the storage is
direct (SQLite via `PersistenceKit`). Accordingly, there is nothing to
reconnect.

The tool is named `moot_estate_ping`, and its implementation is a
handle-resolution check only. A full `allDrawers()` table scan would be O(N) on
estate size — an expensive proxy for a question that `resolveHandle` already
answers in O(1), so the ping deliberately avoids it.

`moot_estate_ping` resolves the handle and returns
`pong: estate <name> [<uuid>] is live — build <serial>`. The build serial is
derived once at server startup from the running executable's modification time
and file size (`<mtime-yyyyMMddHHmmss>/<8-hex-fingerprint>`) and changes on
every relink. It can be overridden via the `MOOTX01_BUILD_SERIAL` environment
variable (set and non-empty value is used verbatim). This lets a driver — an
AI client or a test harness — confirm it is talking to the most recently
compiled build without restarting the session. The serial is stored on the
dispatcher at construction; no filesystem access occurs on each ping call.

If the estate is not open, `resolveHandle` throws `.estateNotOpen` and dispatch
surfaces it as `isError: true` before the runner is called. If that occurs, the
correct remediation is restarting the server process — no MCP tool can reopen
an estate that the process did not open at startup.

## § 15. Design note: moot_write_journal field name is `entry`, not `content`

`moot_write_journal` requires the field `entry`, not `content`. This mirrors
the `DiaryEntry.entry` substrate field in `LocusKit`. The distinction is
intentional: `moot_file_memory` files a memory into the estate’s drawer store
and uses `content`; `moot_write_journal` files a diary entry into the agent
journal and uses `entry`. The two tools write to different substrate stores
and the field name reflects that boundary. Using `content` with
`moot_write_journal` returns a missing-required-argument error.

## § 16. Design note: moot_fact_search accepts an optional query filter

`moot_fact_search` accepts an optional `query` string that performs a
case-insensitive substring match across all three KGFact fields: `subject`,
`predicate`, and `object`. Omitting `query` returns all active facts
(the unfiltered case).

This design was chosen over per-field filters (`subject`, `predicate`,
`object` as separate arguments) because LLM callers naturally produce a
single search term — an entity name, a relationship keyword, a concept —
rather than decomposing a query into a triple structure before calling.
A single `query` field matches how LLMs are trained to express retrieval
intent. Per-field decomposition would be appropriate for a developer-facing
SPARQL-style interface; it is not appropriate for the AI-client surface.

## § 17. Resident lifecycle, the autonomic governor, and telemetry self-report

mootx01 is headless and resident. In the primary (HTTP) mode it is a long-lived
process — registered under launchd by `mootx01 install` — that opens its estate
once and serves until stopped. Because the same process owns the whole vertical
(ARIA → GeniusLocusKit → kits → substrate), two responsibilities that have no
home in an ephemeral stdio server live here.

### 17.1 The autonomic governor (dream trigger)

The Brain daemons — NeuronKit's dreaming, enrichment, and maintenance daemons,
and GLK's `StandingSignalDaemon` scheduler — are deterministic and
caller-pumped: `now` is always supplied by the caller; a daemon never reads the
clock itself (GENIUSLOCUS_ARCHITECTURE_SPEC; NEURONKIT_SPEC B-4/C-1). The
resident server owns the **pump loop**: the single scheduler that calls each
daemon's `pump(now:)`/`runCycle(now:)` on its policy cadence. Determinism is
preserved — the loop is the only place `now` enters, and it is the only
scheduler. Cadences come from policy/env. This is the mechanism that realizes
the architecture spec's "continuous-operation behavior … overnight enrichment":
without a resident host pumping it, the Brain never fires, which is why the
stdio fallback (ephemeral, per-client) does not dream.

The `AutonomicGovernor` is spawned in the resident HTTP branch alongside the
transport; stdio does not pump. The loop reads `now` once per tick and drives
`dreaming.pump(now:)`, `maintenance.pump(now:)`, `signalTick(in:now:)`, and the
Dual-Path Intake encode queue drain; each daemon self-gates on its policy
interval. Base tick is `MOOTX01_BRAIN_TICK_MS` (default 5 s). The Rust port
drives the same loop over the same shared estate coordinator. Per tick it drives
dreaming, maintenance, topology snapshot, and drains the default estate's encode
queue, ingesting any pending regular-write EncodeJobs into the Corpus (BM25 +
vector indexed). This keeps regular-capture content semantically recallable on
both ports. `GovernorReport` exposes `encode_drain_fired: bool` (true when drain
was called; idempotent on an empty queue).

**Standing-signal activation (Swift + Rust).** The governor ticks the
estate's standing-signal scheduler each iteration, but `signalTick` only drives
emissions once a scheduler exists for the estate; the scheduler is minted by the
first `registerStandingSignal`. Both resident daemons register the
architecture-spec §11.2 default standing signals ONCE at bootstrap, reading the
estate's already-registered `VectorStore` back (so the `VectorSimilaritySignal`
queries real embeddings). Without registration the tick benign-skips
(`signalsTicked == false` / `signals_ticked == false`) — the propose/associate
emission loop never runs, but the daemon still serves. The scheduler's weekly
`DreamingSignal` is registered with the default no-op cycle: the governor's own
dreaming pump is the single dreaming driver, so the signal does not double-drive
it.

- **Swift.** `AriaResident.runResidentDaemon` calls
  `kit.registerDefaultStandingSignals(in:vectorStore:now:)` before
  `governor.run()`, reading the store via `kit.registeredVectorStore(for:)`. The
  scheduler registry lives on the `GeniusLocusKit` actor
  (`schedulers: [EstateHandle: StandingSignalScheduler]`); the governor calls
  `kit.signalTick`.
- **Rust.** The `AutonomicGovernor` OWNS the scheduler (a GLK
  `SerialLaneScheduler<CoordinatorDispatcher>`) and ticks it directly — it
  cannot live on the coordinator because the dispatcher holds an
  `Arc<Mutex<EstateCoordinator>>` (a coordinator-owned scheduler would close a
  reference cycle). The resident HTTP bootstrap (`rust/src/runtime.rs`) calls
  `governor.register_default_standing_signals(model_id, now)` once before
  `run_loop`, reading the store via the now-`pub`
  `EstateCoordinator::vector_store_for`. The serial-lane single-drainer
  guarantee is identical. The standing-signal scheduler drives
  propose/associate/diagnostic emissions only; the recall-cache PRODUCERS are
  governor DUTIES, not scheduler signals (see the graph-centrality producer
  duty below).

**Graph-centrality producer duty (Swift + Rust).** The PRODUCER for the recall
`graph` score column. On its cadence (default 10 min; `graphCentralityScan` /
`graph_centrality_duty`) the governor reads the estate structure graph (drawers +
tunnels + kg_facts) through the shared coordinator, builds the unit-weight
adjacency the NeuronKit `keystones` oracle consumes, computes per-drawer
eigenvalue centrality over ALL drawers via that conformance-gated oracle (no math
reinvented — I-17), wraps the scores in a `GraphCache`, and registers it on the
kit/coordinator (`registerGraphCache` / `register_graph_cache`). After it runs the
`unionBest` / `matrixAware` recall `graph` column is LIVE on both ports —
structurally-central drawers score non-zero, identical Swift↔Rust for the same
graph. `GovernorReport` exposes `graphCentralityFired` / `graph_centrality_fired`
(true when the cadence gate fired). The producer is a governor duty rather than a
standing signal because the governor is the only cadence-driver that can register
a cache at parity: the Rust scheduler emission model cannot register a cache, and
the synchronous emit closure has no `&mut EstateCoordinator`. Determinism: `now`
is injected by the tick; no clock read inside the duty. An empty/edgeless estate
registers an all-zero cache (correct — identical to no cache registered).

**Preference producer duty (Swift + Rust).** The PRODUCER for the recall
`preference` score column — the SIBLING of the graph-centrality producer. On its
cadence (default 10 min; `preferenceScan` / `preference_duty`) the governor reads
the estate's recall-trace reward history (`RecallTraceItem`: per-drawer `target` +
`used` flag) through the shared coordinator, shapes it into per-drawer
`(label, endorsements, dismissals)` curation records (surfaced-and-used →
endorsement, surfaced-and-passed → dismissal — the implicit relevance signal,
C-15), fits per-drawer Bradley-Terry preference strengths via the NeuronKit
`learnedPreference` / `learned_preference` anchor-reduction fitter (the `Bias`
lens — no fitting math reinvented, I-17), wraps the strengths in a
`PreferenceStore`, and registers it on the kit/coordinator (`registerPreferenceStore`
/ `register_preference_store`). After it runs the `unionBest` / `matrixAware`
recall `preference` column is LIVE on both ports — endorsed drawers score non-zero,
identical Swift↔Rust for the same record set. `GovernorReport` exposes
`preferenceFired` / `preference_fired` (true when the cadence gate fired). The
producer is a governor duty for the same parity reason as the graph producer (only
the governor can register a store at parity). Determinism: `now` is injected by the
tick; no clock read inside the duty. The window is the full retained trace history
(`since = distantPast`), bounded upstream by the maintenance prune cycle. An estate
with no recall traces registers an empty store (correct — identical to no store
registered). The OUTCOME SOURCE is the existing recall reward cycle; no new
substrate data was required.

**Pool-reducer activation + LIVE tagger swap (Swift + Rust).** NEAR-REALTIME
(`MOOTX01_POOL_REDUCE_CADENCE_SECONDS`, default 0 = considered every tick) the
governor drives the LatticeLib `PoolReducer` (`PoolReducer.reduce` /
`lattice::pool_reduce`), folding accumulated novel-token submissions from the
pool directory (`LATTICE_POOL_DIR` or the platform default) into the writable
WordClassTable artifact (its sibling). The reduce is no-op-safe on an
empty/absent pool (so an idle tick costs nothing) and idempotent on a drained
pool. After a NON-NOOP reduce the governor **live-swaps** the running word-class
table at the post-reduce safe point (`WordClassTableCache.reload(fromArtifact:)`
/ `swap_global_table_from_precedence`) — the running tagger learns the merged
tokens IN-SESSION, no process restart (cookbook §1.3/§2.2). A positive
`MOOTX01_POOL_REDUCE_CADENCE_SECONDS` reinstates a minimum spacing (test
determinism / load throttling). `GovernorReport` exposes `poolReduceFired` /
`pool_reduce_fired` (true when the gate fired, including the empty-pool no-op),
`tableSwapped` / `table_swapped` (true when a non-noop reduce live-swapped), and
`tableVersion` / `table_version` (the holder's swap counter after the tick).

**Encode drain (Swift + Rust).** Regular-mode captures enqueue an EncodeJob onto
a per-estate QueueKit; a background drain worker ingests it into the Corpus
(BM25 + vector) near-realtime — the Rust port runs an observer-`watch`-driven
background thread (the governor-tick drain remains an idempotent backstop), the
Swift port an on-actor whole-batch poll worker (~15 ms floor, never starves under
burst). The queue absorbs bursts and out-of-order arrival without dropping or
wedging.

### 17.2 Telemetry self-report

The resident server installs ObserverSink's `PersistenceStatsSink` against the
manager's stats store and drives the IntellectusLib gate from that store's
monitoring flag — the same opt-in, off-by-default contract documented in
MOOT_MGR_SPEC §8 and INTELLECTUSLIB_SPEC I-6. Because the process is resident,
the report is continuous (not just during a client request). The wiring is
gated by `ARIA_MCP_STATS_STORE`; `mootx01 install` sets it to the manager store
path so the headless daemon is observable by moot-mgr out of the box, while the
off-by-default flag still governs whether any sample actually flows. moot-mgr
reads this store and, through its control channel, signals the daemon
(monitoring on/off, admin lifecycle, Brain signals).

- **On/off switch:** the store's `monitoring` flag (ObserverSink
  `StatsStore.isMonitoringEnabled`/`setMonitoringEnabled`, toggled via
  `moot-mgr monitoring on|off`) plus env-gated wiring that runs for both
  transports.
- **Continuous gate:** in resident mode the server polls the store flag every
  `MOOTX01_MONITORING_POLL_MS` (default 5 s) and drives `Intellectus.setEnabled`
  from it, so flipping monitoring via moot-mgr takes effect on the running daemon
  (the OFF→ON case) without a restart. "Off is free" is preserved: when off,
  `isEnabled` stays false and `report()` no-ops.
- **Installer default:** `mootx01 install` sets `ARIA_MCP_STATS_STORE` to the
  manager store via the launchd plist `EnvironmentVariables` so the resident
  daemon self-reports out of the box; absent that variable it self-reports only
  when `ARIA_MCP_STATS_STORE` is set manually.

## § 18. Side-channel GET endpoints

Three loopback-only GET endpoints expose read-only estate state for polling clients
(moot-mgr polls every 5 s). They share the HTTP transport's CSRF/DNS-rebinding
Origin guard and are accessible on both the Swift and Rust HTTP transports.

| Path | Response top-level key | Description |
|------|------------------------|-------------|
| `GET /api/graph` | `nodes`, `edges`, `structurePending`, `communities`, `generatedTs` | Estate topology snapshot: Louvain-enriched drawer nodes, tunnel + kgFact + lattice edges, community summaries — materialized by the autonomic governor, served from `topology_snapshots` table |
| `GET /api/lattice` | `addresses` | Active lattice codes with drawer counts |
| `GET /api/admin/estates` | `hosted` | List of hosted estates with backend and mount state |

### Content-safety guarantee

No drawer content, KGFact text, or diary entry text crosses these endpoints. The graph
endpoint emits only drawer IDs and edge identifiers; the lattice endpoint emits code
strings and counts; the admin endpoint emits estate UUIDs and backend labels.

### GET-before-POST routing order

GET requests are dispatched before the POST guard so they are never rejected as
`method_not_allowed`. An unknown GET path returns HTTP 404 `{"error":"not_found"}`.

### Response shapes

**`GET /api/graph`**
```json
{
  "nodes": [
    {"id": "<drawer-uuid>", "nounType": 0, "communityId": 3,
     "centrality": 0.42, "anomaly": false,
     "lastActiveTs": "2026-06-08T08:26:00Z",
     "createdTs": "2026-06-01T11:02:33Z",
     "tombstonedTs": null}
  ],
  "edges": [
    {"source": "<drawer-uuid>", "target": "<drawer-uuid>",
     "edgeType": "tunnel", "weight": 1.0, "decayedWeight": 1.0,
     "createdTs": "2026-06-01T11:05:00Z", "tombstonedTs": null}
  ],
  "structurePending": false,
  "communities": [
    {"id": 3, "size": 17, "dominantUdcCode": "652"}
  ],
  "generatedTs": "2026-06-10T00:00:00Z"
}
```

Field semantics (the graph wire contract):

- `communityId` — Louvain community label over the live weighted graph
  (tunnel 1.0, kgFact 0.3, lattice 0.2). `-1` is the dead-node sentinel.
- `centrality` — eigenvalue centrality normalised to [0, 1] over live
  entities using tunnel + kgFact adjacency only (lattice excluded from
  centrality — prevents hub inflation); `0.0` on dead nodes.
- `edgeType` — one of `"tunnel"`, `"kgFact"`, `"lattice"`. Lattice edges
  bond drawers sharing a non-empty `udcCode` in a star from the earliest-filed
  member; weight 0.2; no `createdTs`.
- `createdTs` — ISO-8601 ingest instant (`filedAt`); the alive(t) playback
  boundary. Tunnel edges carry the tunnel's `filedAt`; kgFact and lattice
  edges carry `null` (derived bonds have no single ingest instant).
- `tombstonedTs` — ISO-8601 tombstone instant; `null` = alive. Tombstoned
  drawers and tunnels ARE included on the wire (dissolution playback); all
  graph math runs over live entities only, so dead entities never shift
  community structure. The key is always present (explicit JSON null).
- `communities` — per-community summaries over LIVE members:
  `dominantUdcCode` is the most frequent non-empty member `udcCode`
  (frequency ties lexicographic ascending; `""` when all empty), sorted by
  size descending then id ascending.
- `generatedTs` — ISO-8601 instant the autonomic governor LAST RECOMPUTED
  this snapshot, which — because of the duty's input fingerprint (below) —
  means *when the estate's topology content last changed*, not when the duty
  last ran. An idle estate's `generatedTs` honestly stops advancing. Always
  present in a materialized payload; the key is omitted only on the
  cold-start `structurePending: true` pending path.

**Serving model.** `GET /api/graph` serves the materialized snapshot from
the `topology_snapshots` table in the ObserverSink stats store. The
autonomic governor recomputes topology on its cadence (default 300 s,
configurable via `MOOTX01_TOPOLOGY_CADENCE_SECONDS`) and upserts one row
per estate. The handler is a pure SQLite read — target latency <50 ms
regardless of estate size.

**Cold-start pending path.** Before the governor's startup pass lands, no
snapshot row exists. The handler returns `structurePending: true` with empty
`nodes`, `edges`, and `communities` arrays. No inline compute fallback
exists — the pending path is the honest state, not a degradation.

**Topology computation (governor duty).** The governor performs the estate
reads (drawers, tunnels, KGFacts — tombstoned rows included) and the
tombstone-instant resolution (Swift: state axis + audit-trail fallback when
the stamp does not round-trip; Rust: the round-tripping stamp), then
delegates analysis to `NeuronKit.graphTopology(drawers:tunnels:facts:)` /
`neuron_kit::topology_analysis::graph_topology` — both legs run the same
SubstrateML Louvain + eigenvalue centrality over the same weighted graph.
See NEURONKIT_SPEC.md § TOPOLOGY_ANALYSIS.

Two cheap escapes precede the expensive work, in both legs:

1. **Monitoring gate.** At each due cadence the duty reads the stats
   store's LIVE monitoring flag BEFORE any estate read or compute: flag off
   skips the interval entirely ("off is free"), and a moot-mgr on/off flip
   takes effect at the next cadence without a daemon restart. Store-read
   failures fail OPEN (the duty runs) — a transient store error must not
   silently freeze topology. A fresh store defaults to monitoring OFF, so a
   new install serves the pending path until monitoring is enabled.
2. **Input fingerprint (dirty check).** The duty fingerprints the fetched
   rows — drawer/tunnel/fact counts, dead counts, max ingest and event
   instants, and an order-independent per-drawer id+udc digest — before the
   math. An unchanged fingerprint skips Louvain, centrality, encode, and
   the store write: the stored snapshot is still current. Sensitivity:
   adds, removes, tombstones, new ingests, re-activity (event time), and
   udc re-anchoring all force a recompute; a content edit changing none of
   those does not alter the topology payload and correctly skips. The
   fingerprint is process-local governor state, never persisted; a daemon
   restart recomputes once unconditionally.

**`GET /api/lattice`**
```json
{
  "addresses": [
    {"code": "006.6", "count": 12}
  ]
}
```
Codes sorted by count descending; ties broken by code ascending. Unanchored drawers
(empty `udc_code`) and tombstoned drawers are omitted.

**`GET /api/admin/estates`**
```json
{
  "hosted": [
    {"estateUUID": "<uuid>", "estateName": "<name>",
     "kind": "GLK", "backend": "SQLite", "mountState": "mounted"}
  ]
}
```
`backend` values: `"SQLite"`, `"PostgreSQL"`, `"InMemory"`. `mountState` is
always `"mounted"` (estates are open for the process lifetime). In the Swift
port, `estateName` is the human-readable name from GeniusLocusKit; in the Rust
port it is the estate UUID string (Rust EstateRegistry stores no separate name).

### Known Rust deviations

| Field | Swift behavior | Rust behavior | Reason |
|-------|---------------|---------------|--------|
| `estateName` in `/api/admin/estates` | Human-readable name via GeniusLocusKit | UUID string | Rust `EstateRegistry` stores no separate human-readable name |
| tombstone-instant resolution in `/api/graph` | state axis + audit-trail fallback (the Swift store's stamp does not round-trip) | `tombstoned_at` stamp directly (round-trips) | per-store stamp behavior; same wire shape |
| dead-tunnel edges in `/api/graph` | emitted when the store surfaces tombstoned tunnels | in-memory store filters tombstoned tunnels at the store layer | store-backend behavior, not handler behavior |

Both ports emit the same wire shape: `lastActiveTs` is ISO-8601 derived from
`event_time`, `communityId`/`centrality` carry real Louvain/eigenvalue values,
and kgFact edges are emitted by both legs.

On any store failure the endpoints return HTTP 200 with an empty-collection body
(`structurePending: true` for `/api/graph`); they never return HTTP 500.

## § 19. Sensitivity unlock/lock control endpoints (the sensitivity-grant contract)

Two loopback-only POST endpoints accept out-of-band sensitivity-tier grants and
revocations. They share the HTTP transport's CSRF/DNS-rebinding Origin guard. The
stdio transport does not expose these endpoints.

```
POST /api/control/unlock
POST /api/control/lock
```

### POST /api/control/unlock — grant a sensitivity tier

Admits the caller's estate session to view restricted or secret drawers by lifting
the default `sensitivityAtMost(.elevated)` recall gate for the duration of the
grant. The daemon validates a freshness proof in the request body; the caller's
host-side binary performs identity verification before issuing the POST.

**Identity verification (platform-specific):**

- **Swift/macOS** — `LocalAuthenticationAuthority` calls
  `LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...)`. The daemon issues
  the grant only after receiving the POST with a valid proof; LocalAuthentication
  runs client-side in the `mootx01 unlock` command before the POST.
- **Rust/Linux/Windows** — `unlock_authority::authenticate_and_grant` reads the
  `sensitivity_hashes.json` sidecar (PBKDF2-HMAC-SHA256 at 260,000 iterations,
  OWASP 2024 minimum), prompts the user for the tier-specific password (echo-off
  via `tcgetattr`/`tcsetattr` on Unix, plain stdin on Windows), verifies the hash,
  then issues the POST.

**Request body (both ports):**
```json
{
  "tier": "restricted" | "secret",
  "proof": { "ts": <unix_ms> }
}
```

The daemon rejects proofs where `|now_ms - proof.ts| > 10_000` (10-second window)
to prevent replay attacks on the loopback socket. `"tier"` must be one of the two
legal strings; any other value returns HTTP 400.

**TTL semantics (the sensitivity-grant contract §1):**

| Tier | Grant TTL |
|---|---|
| `restricted` | Expires at next local midnight |
| `secret` | Expires 30 minutes after grant |

**Success response (HTTP 200):**
```json
{ "granted": true, "expires_at": "2026-07-05T23:59:59Z" }
```

**Failure responses:**

| Condition | HTTP | Body |
|---|---|---|
| Tier unknown | 400 | `{"error": "unknown tier"}` |
| Proof stale (±10s) | 403 | `{"error": "proof stale"}` |
| Any other server error | 500 | `{"error": "<message>"}` |

### POST /api/control/lock — revoke all grants

Immediately clears all active sensitivity grants. No identity verification is
required (the sensitivity-grant contract §1: "locking reduces the user's own access and is always
permitted").

**Request body:** empty (`{}`)

**Success response (HTTP 200):**
```json
{ "locked": true }
```

### CLI surface

```
mootx01 unlock private | secret
mootx01 lock
```

`private` is the user-facing alias for the `restricted` tier; `restricted` is also
accepted. Both commands require the resident daemon (`mootx01 serve --http auto`)
to be running.

### Redaction advisory in moot_memory_search / moot_memory_get output

When no sensitivity grant is active and the estate has at least one row tagged
`restricted` or `secret`, both `moot_memory_search` and `moot_memory_get` append a
trailing `sensitivity_advisory:` line to their output text:

```
sensitivity_advisory: results may be hidden by sensitivity tier — run `mootx01 unlock private` to include restricted memories, `mootx01 unlock secret` for secret memories.
```

The advisory is absent when a grant IS active (rows are already visible and no
guidance is needed). It is also absent when the estate has no sensitive rows at all.
The detection is a cheap pair of limit-1 bitmap-filter probes (no BM25/vector cost,
no recall-trace rows written — `origin: internal` per B-10a).

## Changelog

### 1.18.0 -- 2026-07-16
Upstream-release advisory: `moot_estate_ping` / `moot_estate_status` gain an
opt-in `update_available:` line when a newer product release exists on the
release feed than the running binary. Sibling of the 1.10.0 `version_skew:`
line (that one reports local plugin/binary skew; this one reports "the world
has moved past this install"), and deliberately confined to the same two
session-orientation tools so MCP clients are informed once at orientation
time, never nagged per call. Unlike `version_skew` the value is NOT computed
at startup: the resident daemon outlives releases, so the host injects a
PROVIDER (Swift `ToolDispatcher.updateAdvisoryProvider` closure; Rust
`Dispatcher.update_advisory` via `with_update_advisory`) that the two tools
evaluate lazily behind a host-owned 24h-TTL cache (Swift
`MootInstallerCore.UpdateAdvisor`; Rust `mootx01-cli::core::update_advisor`).
Probe bounded (4s) and failure-cached; resident daemons only (stdio
one-shots and aria-mcp dev never probe); disabled by
`MOOTX01_NO_UPDATE_CHECK` — the same kill switch as the Claude Code plugin's
SessionStart update hook. Line text: ``v<latest> is available (installed
<current>) — upgrade with `mootx01 upgrade` ``. Both ports at parity. New
tests: `testUpdateAdvisorySurfacesInPingAndStatus`,
`testNilUpdateAdvisoryOmitsField` (Swift `ServerTests.swift`);
`update_advisory_surfaces_when_wired_and_omitted_when_none` (Rust
`dispatch_tests.rs`); `UpdateAdvisorTests` (Swift, 8) and
`core::update_advisor::tests` (Rust, 6) unit-test the TTL/kill-switch cache.

### 1.17.0 -- 2026-07-16
Rust leg Anthropic memory_20250818 adapter parity (M-MEMTOOL-1): the `memory` tool
is now at full parity in both ports. `memory_adapter.rs` implements all six commands
(view, create, str_replace, insert, delete, rename), the `MOOTX01_MEMORY_TOOL=1`
opt-in gate (off by default — 71/65 baseline unchanged), the Normal-tier sensitivity
gate (Restricted/Secret drawers not visible), and sensitivity-tier carry-forward on
edit/rename so elevated drawers are not silently downgraded. Wire contract is
byte-identical to the Swift `MemoryToolAdapter.swift` adapter per the no-FFI law.

### 1.16.0 -- 2026-07-16
§12 teachme guide: corrects stale tier tallies (Tier 1: 7→9, Tier 2: 3→4,
Tier 6: 18→27, Tier 8: 4→5, Total: 56→71/65) and expands from nine to ten
tiers (adds Tier 8 Dataset, Tier 7 Extended Cognition, renumbers Vault→Tier 9
and Federation→Tier 10). The guide is now a computed var deriving all counts
from ToolProjection.tools() at call time — it can never silently drift from
the shipped surface. Adds moot_memory_list to Tier 1 listing and its teachme
guide. Adds moot_review_tunnel to Tier 2 listing. Adds moot_vault_job to the
vault generic guide. New test (sp-3b) pins that the guide's count matches the
live registry.

### 1.15.0 -- 2026-07-16
Dataset tools (MX-TAB-7, §11): corrects the stale "44 tools / 19 interface /
16 lens / 4 vault / 4 recipe" figures throughout §11 to reflect the current
shipped surface (71 vault-on / 65 vault-off; 22 five-tier interface tools;
23 lens tools; 5 vault tools; 12 recipe tools; 3 new dataset tools
`moot_file_dataset`, `moot_dataset_query`, `moot_dataset_stats`). Updates
§12 moot_list_lenses cognition-menu count from 18 to 27 (23 lens + 4 recipe
tier-6 tools). Corrects the guide's stated total from the wrong "44 tools"
(written when the guide code said 44; the code now says "56 tools") to "56
tools", pointing to ARIA_MCP_INTERFACE.md §2 as the authoritative live count.

### 1.14.0 -- 2026-07-12
Contradiction hunter surface (§11): `moot_hunt_contradictions` (recipe,
on-demand bounded content sweep), `moot_review_tunnel` (Tier 2 review verb
over `Estate.respondToTunnel`), `moot_link_memories` optional
`proposed: bool`, `moot_dream` third phase (hunt sweep + contradiction
counts), `moot_lens_contradiction` lifecycle tiers (proposed shown by
default, flagged). Total tool count: 68 (was 66). Permission tier `ask`
for both new tools. Both Swift and Rust ports at parity.

### 1.13.0 -- 2026-07-05
the sensitivity-grant contract wave 8.2: adds `moot_monitoring_status` to the interface-tool surface.
Reifies the ARIA `read` verb on the monitoring object (estate-scoped, daemon
daemon-global flag). Args: absent `enabled` → read current state; present
`enabled: bool` → write flag + echo new state with `monitoring_source: user`.
When no telemetry store is wired (stdio, test harnesses, provision-less
contexts), reports `monitoring: unavailable` — never fabricates enabled/disabled.
Permission tier: `ask` in both `mcp__mootx01__` and `mcp__plugin_mootx01_mootx01__`
namespaces. Total tool count: 64 (was 63). Both Swift and Rust ports at parity.

### 1.12.0 -- 2026-07-05
the sensitivity-grant contract: sensitivity unlock/lock control endpoints (§19). Adds
`POST /api/control/unlock` and `POST /api/control/lock` — loopback-only
endpoints for out-of-band sensitivity-tier grants and revocations. Grant
TTLs: restricted → next local midnight; secret → 30 minutes. Proof
freshness gate ±10s. Platform identity: macOS/Swift via LocalAuthentication;
Linux/Windows/Rust via PBKDF2-HMAC-SHA256 (260,000 iterations) against
the `sensitivity_hashes.json` sidecar. CLI surface: `mootx01 unlock
private|secret` and `mootx01 lock`. Both ports at parity. Also adds
redaction advisory (`sensitivity_advisory:` trailing line) to
`moot_memory_search` and `moot_memory_get` when no grant is active and
the estate has restricted/secret rows.

### 1.11.0 -- 2026-07-04
Added `moot_memory_get` (§11) — fetch-drawer-by-ID, build-now per Bob's
ruling on the parking-lot gap ("no verb to fetch a full drawer by UUID on
the MCP surface — recollect covers distilled factoids only"). Reifies the
`recall` verb, named as a `moot_memory_search` sibling per the lexicon's
`<noun>_<verb>` query-tool naming discipline. Routes through the existing
frame-faithful by-id load (`Estate.getDrawers(ids:matchingFrame:
hydrationLevel:)` / Rust `Estate::get_drawers_matching_frame`) with an
empty filter chain, so it inherits `moot_memory_search`'s default
containment gate unchanged — a drawer that exists but fails the gate is
reported not-found identically to a genuinely absent id, closing off the
by-id door as a gate-bypass vector. Returns verbatim content plus the full
adjective-axis metadata and a linked-tunnel summary. Tool surface: 19 -> 20
interface tools (Tier 1: 7 -> 8). Both ports at parity; teachme guide
added on both. New tests: `MemoryGetTests.swift` (10 tests, AriaMcpKit);
`memory_get_*` (7 tests) + 1 teachme test in Rust `dispatch_tests.rs`.

### 1.10.0 -- 2026-07-04
the connection-ownership contract §5 (MCP connection ownership, plugin transport, and install-moment
dedupe): `moot_estate_ping` / `moot_estate_status` gain an opt-in
`version_skew:` line when the host has detected a mismatch between an
installed plugin (currently Claude Code's `mootx01@mootx01`) and this
running binary's version. Runtime detection (rather than only at install
time) catches skew regardless of install order — plugin-then-binary or
binary-then-plugin both leave a point-in-time version pinned in
`~/.claude/plugins/installed_plugins.json` that can drift as either side
upgrades independently. Computed once at server startup (Swift
`ServeCommand`; Rust `commands::serve::run`), never per-call, and threaded
through the dispatcher (`ToolDispatcher.versionSkewAdvisory` / Rust
`Dispatcher.version_skew`) exactly like the existing build-serial pattern
(§ 14). Empty/`nil` when no plugin is detected or versions match — the
common case, which leaves the response shape byte-identical to before this
change. Both ports at parity. New tests:
`testVersionSkewAdvisorySurfacesInPingAndStatus`,
`testNoVersionSkewAdvisoryOmitsField` (Swift, AriaMcpKit `ServerTests.swift`);
`version_skew_advisory_surfaces_when_present_and_omitted_when_absent` (Rust,
`dispatch_tests.rs`); `VersionSkewAdvisory` / `version_skew_advisory` unit
tests in `MootInstallerCore` (Swift) and `mootx01-cli::core::mcp_ownership`
(Rust).

### 1.9.0 -- 2026-06-28
Security hardening — three ARIA tool gate changes (secfix/batch2-aria). Framed as
planned hardening to lock down prompt-injection attack surfaces.

(1) **`moot_erase_memory` gate** — the `confirmed=true` + `reason` requirement is
now enforced at the AriaMcpKit boundary BEFORE calling the substrate. A prompt-injected
agent that receives `confirmed=false` (or omits `confirmed`) cannot trigger irreversible
erasure regardless of any other argument. Tool stays on the surface; gate is the defense.
Both ports updated. Schema unchanged; field was already present.

(2) **Federated-search requester anti-spoof** — `requesterEstateID` in
`moot_federated_search` is now OPTIONAL. When omitted the requester is bound to the
default (authenticated caller) estate. When supplied it must match the default estate's
UUID exactly; a different UUID is refused (anti-spoof gate). This prevents a prompt-injected
agent from spoofing another estate's identity to escalate cross-estate read scope.
`required` array changed from `["requesterEstateID"]` to `[]`. Both ports updated.

(3) **Direct estate routing restricted to default estate** — `estateID` in direct MCP
tool calls (all Tier 1–5 interface tools, recipe tools, vault tools, lens primary estate)
is restricted to the default estate. A present `estateID` that names any registered
non-default estate is refused with `invalidParams`. Callers must use `moot_federated_search`
for grant-authorized cross-estate reads. Lens comparison tools (`moot_lens_overlap`,
`moot_lens_divergence`) are explicitly exempted for their `estateIDB` argument. Both ports
updated.

### 1.8.1 -- 2026-06-28
Security (HTTP transport — both ports, both surfaces):

(1) **Origin-check hardening** — `HTTPServer.isOriginAllowed` and `HTTPReadAPI.isOriginAllowed`
now validate the suffix after the loopback scheme+host prefix (must be empty or `:PORT`) instead
of a bare prefix check. A bare prefix check accepted attacker-owned names like `localhost.evil`
or `127.0.0.1.evil` DNS-resolved to loopback (the DNS-rebinding prefix-spoof vector). Both
ports (Swift + Rust) updated in lockstep: AriaMcpKit `HTTPServer`, moot-mgr `HTTPReadAPI`.
Tests added in `HTTPServerTests`, `HTTPReadAPITests`, `http_transport_tests.rs`,
`http_control_tests.rs`.

(2) **`moot_palace_import` vault gate** — `moot_palace_import` is now hidden from `tools/list`
and refused at dispatch when `MOOTX01_VAULT=0` (installed with `--vault-off`). The tool opens
arbitrary SQLite files from the local filesystem; gating it under the vault surface matches the
security posture of vault import/export and mitigates an arbitrary-path-traversal vector
(a caller could pass any filesystem path). Vault-off tool count: 57 → 56. Both ports updated.

### 1.8.0 -- 2026-06-25
Changed (T5 — drain lifecycle): (1) **daemon resume-on-restart** — opening an
estate now EAGER-mounts the corpus's lease-gated drain worker, so a restarted
resident drains a non-empty persisted queue immediately instead of waiting for a
fresh capture. (Swift already eager-mounted via `wireSubstores`; Rust now mounts
in `wire_sqlite_semantic_recall` rather than lazily on first capture — a fixed
Swift/Rust parity gap.) (2) **detached stdio finisher** — a direct-open stdio
`serve`, on exit with encode work still queued, spawns a detached `mootx01 drain`
that takes the T3 lease and drains to empty, so a client SIGKILL on disconnect no
longer abandons the queue. The finisher detaches via `setsid` (unix) /
`DETACHED_PROCESS` (windows) and is gated on the maildir actually having pending
work. Both ports.

### 1.7.0 -- 2026-06-25
Changed (T4 — serve lease-aware transport): an stdio `serve` now **forwards** to a
live resident that serves the same estate instead of opening a second direct
writer. On start it checks a resident-written estate marker (`mootx01.estate`)
against its own estate and, on match, probes the resident port (`daemon.port`);
if the resident answers it runs the stdin→loopback-HTTP bridge (the `proxy`
path), so all traffic funnels through the one resident writer and the resident's
in-RAM derived state stays coherent. If no resident answers (stale marker) it
opens the estate directly. Detection is a port probe + estate-marker match
(uniform Swift↔Rust, dep-free) — not PID-liveness. Both ports.

### 1.6.0 -- 2026-06-25
Changed (T1 — encode mode): `moot_palace_import`'s caller-facing knob is now
`mode` (foreground/background encode SPEED), not `batch`. Contract: the caller
declares SPEED only; the server chooses the WRITE strategy automatically by
source size. Foreground/background select the drain's embed concurrency (all
cores vs ~a quarter) and never change the encoded output — byte-identical either
way. Unknown `mode` is a fail-closed invalid-params error. Both ports conform.

### 1.5.0 -- 2026-06-25
Additive (T6 — drain status): new maintenance tool `moot_drain_status` joins the
behavioral surface. It is a read-only observer of the estate's long-running
background drains (today only `corpus_encode`, the encode/ingest queue): it reads
each drain's pending + in-flight frontiers and reports a draining/idle state plus
optional detail, never claiming or draining. Contract guarantees: (1) read-only —
polling it has no effect on drain progress and is safe from any process; (2)
honest empties — `drains: none` (no drain registered, e.g. a bare estate) is
distinct from a drain listed at `pending: 0, in_flight: 0` (idle); (3) no
session-protocol block, so it is cheap to poll. Both ports conform.

### 1.3.0 -- 2026-06-17
Additive (mission BRAIN-PREF-PRODUCER — Bradley-Terry preference producer, both
ports). Documents the new preference PRODUCER DUTY on the `AutonomicGovernor`, the
sibling of the graph-centrality producer: on a cadence (default 10 min) it reads
the estate's recall-trace reward history (`RecallTraceItem` target+used), shapes it
into per-drawer `(endorsements, dismissals)` curation records (surfaced-and-used →
endorsement, surfaced-and-passed → dismissal), fits per-drawer Bradley-Terry
preference strengths via the NeuronKit `learnedPreference` / `learned_preference`
anchor-reduction fitter (I-17, no math reinvented), and registers a
`PreferenceStore` — taking the `unionBest`/`matrixAware` recall `preference` column
from dark to live on BOTH ports. `GovernorReport` gains `preferenceFired` /
`preference_fired`. The outcome source is the existing recall reward cycle; no new
substrate data was required. Both recall-cache producer boundaries (graph +
preference) are now closed. Swift + Rust at parity; conformance
`PreferenceProducerTests.swift` / `preference_producer_parity.rs`.

### 1.2.0 -- 2026-06-17
Additive (mission BRAIN-GRAPH-PRODUCER — graph-centrality producer, both ports).
Documents the new graph-centrality PRODUCER DUTY on the `AutonomicGovernor`: on a
cadence (default 10 min) it reads the estate structure graph (drawers + tunnels +
kg_facts), computes per-drawer eigenvalue centrality via the NeuronKit `keystones`
oracle, and registers a `GraphCache` — taking the `unionBest`/`matrixAware` recall
`graph` column from dark to live on BOTH ports. `GovernorReport` gains
`graphCentralityFired` / `graph_centrality_fired`. Corrects the prior text that
implied the recall-cache producers plug into the standing-signal registration
seam: the producers are governor DUTIES (the scheduler emission model cannot
register a cache, and its synchronous emit closure has no `&mut` coordinator). The
Bradley-Terry preference producer remains a separate future duty. Swift + Rust at
parity; conformance `GraphCentralityProducerTests.swift` /
`graph_centrality_parity.rs`.

### 1.4.0 -- 2026-06-19
`moot_estate_ping` now surfaces the build serial in its response:
`pong: estate <name> [<uuid>] is live — build <serial>`. § 14 updated with the
full derivation contract: mtime+size fingerprint (`<yyyyMMddHHmmss>/<8-hex>`)
computed once at server construction, `MOOTX01_BUILD_SERIAL` env override
honored verbatim. Both Swift and Rust ports at parity. Tests asserting the
exact `estate_ping` text updated to assert the stable prefix/shape rather than
a specific serial. New unit and dispatch tests added for serial threading and
the env override path.

### 1.1.0 -- 2026-06-17
Additive + correction (#8 Track 1 — Brain harness, Rust side). §17.1
standing-signal activation now specifies BOTH ports: the Rust
`AutonomicGovernor` owns and ticks the estate's standing-signal scheduler (a GLK
`SerialLaneScheduler<CoordinatorDispatcher>`) and the resident HTTP bootstrap
registers the §11.2 default signals once at startup — corrects the prior text
that claimed "Rust has no standing-signal scheduler by design", which is no
longer true. Documents WHY the Rust scheduler lives in the governor (dispatcher
reference-cycle avoidance) and that the registration methods are the producer
seam for the graph-centrality / Bradley-Terry tracks. Swift behavior unchanged.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
