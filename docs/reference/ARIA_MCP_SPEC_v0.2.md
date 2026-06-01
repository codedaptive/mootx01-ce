---
status: draft specification, v0.2
supersedes_in_part: ARIA_MCP_SPEC_v0.1.md (the three-call-mode framing and the all-modes-required conformance rule)
authors: Bob Pankratz (via/ claude)
date: 2026-05-22
version: 0.2
relates_to:
  - ../canon/MOOTX01_AND_ARIA_CANON.md (the definitions this spec projects from)
  - ARIA_MCP_SPEC_v0.1.md (the transactional tool schemas and error model carry forward)
  - AriaLexiconLib (the grammar this spec projects onto MCP)
  - DESIGN_CONSTRAINTS.md (C-1, why the substrate stays model-independent)
---

# ARIA_MCP Specification v0.2: ARIA as a Language and the Lexicon-to-MCP Projection

ARIA_MCP is the external interface to a MOOTx01 substrate. v0.1 defined it as a boundary exposing three call modes and required all three for conformance. v0.2 keeps the boundary role and reframes the interface: ARIA is a language, the language already exists in AriaLexiconLib, and the MCP surface is a projection of that language onto MCP primitives. The API and the language are the same thing with the same semantics, fixed at design time. v0.2 also phases delivery into releases. The definitions of MOOTx01, the ARIA grammar, instance mode, and API mode are canonical and live in ../canon/MOOTX01_AND_ARIA_CANON.md; this spec projects from them.

## § 0. What v0.2 changes

- ARIA is specified as a language first. The MCP tool, resource, prompt, and completion surface is generated from the AriaLexiconLib grammar and the acceptance matrix, not authored ad hoc. AriaLexiconLib is the single source of truth, and the projection is conformance-gated across the Swift and Rust ports the same way the lexicon already is.
- ARIA is always the server. ARIA never acts as an MCP client.
- ARIA is the interface specification (Augmented Recall and Inference Architecture), reached three ways: the ARIA_MCP server, the Native API (the SDK), and the Embedded library (ARIA.md). This spec covers the ARIA_MCP consumption surface. ARIA_MCP is the first surface built; it carries ARIA over MCP without adding or changing semantics, thin over the SDK and bounded by it.
- ARIA serves a MOOTx01 instance. A MOOTx01 instance is GLK plus the two BrainKits, NeuronKit and CognitionKit (canon). The write surface is always GLK; reads may be lensed narrower.
- Delivery is phased (§ 9). v0.1 stated that an implementation supporting only transactional calls is not conformant; v0.2 replaces that with a release plan. The rich primitive surface is the north star.
- v1.0 wraps a full MOOTx01 instance. v1.1 lets the MCP provision a narrow instance (just LocusKit or just CorpusKit) and route across a fleet in API mode. The Custom Connector (remote HTTP) and the config-writing installer are also v1.1, the installer a candidate for v1.0.

The detailed transactional tool schemas and the error model in v0.1 sections 5 and 10 carry forward unchanged and are referenced, not repeated, here.

## § 1. ARIA is a language

The grammar, stated in one sentence in AriaLexiconLib: every call is one verb applied to a noun, optionally constrained by adjectives.

The vocabulary is small and fixed. Nine verbs, fixed by invariant I-7: capture, recall, mutate, withdraw, expunge, reanchor, learn, propose, associate. Seven are caller-driven (capture, recall, mutate, withdraw, expunge, reanchor, learn). Two are substrate-driven, emitted by the BrainKits rather than called (propose, associate). One canonical noun, the drawer, with seven further storage shapes that are facets or residue of it (tunnel, kgFact, vector, diaryEntry, proposal, association, learnedReference). Four adjective categories, fixed by invariant I-8: state, trust, sensitivity, exportability. The acceptance matrix fixes which verbs each noun accepts, and it is the design-time semantics: it is data, so a conformance harness checks the Swift and Rust ports agree.

The acceptance matrix as it stands: the drawer accepts capture, reanchor, mutate, withdraw, expunge, recall; the tunnel accepts capture, mutate, withdraw, expunge, recall; the kgFact accepts mutate, withdraw, expunge, recall; the vector is substrate-managed and accepts no direct verb; the diaryEntry accepts recall only; the proposal accepts mutate, withdraw, expunge, recall; the association accepts mutate, expunge, recall; the learnedReference accepts learn, mutate, withdraw, expunge, recall.

## § 2. The projection principle

Every element of the MCP surface traces to a grammar element. A tool exists because a caller-driven verb exists; its legal arguments are the nouns that verb accepts under the acceptance matrix, constrained by the adjective categories. A resource exists because a noun exists. A completion source exists because the grammar and the reference data fix a finite legal value set at design time. Tool names follow the lexicon's naming discipline: an action tool is verb-then-noun, such as capture_drawer, and a query tool is noun-then-verb, such as drawer_recall, optionally under a server namespace. This replaces the ad-hoc geniuslocus_<verb> naming used in v0.1.

This is what "the API uses the same semantics, known at design time" means. The acceptance matrix is the contract. A caller does not discover at runtime whether learn applies to a drawer; the matrix says it does not, and the generated surface reflects that before the first call. The projection is generated from AriaLexiconLib and conformance-gated, so the surface never drifts from the grammar because it is not maintained separately from it.

The `capture_drawer` tool, whose frame carries a lattice-anchor classification code, surfaces an optional `classificationScheme` discriminator alongside that code, with values `udc` (default) and `mdcc`. It lets a caller declare whether the anchor code is a UDC code or an MDCC code, expressing the dual-scheme model (architecture spec §5.8). The discriminator is optional and defaults to `udc`, so a caller that omits it gets the original UDC behavior and nothing breaks; the boundary validates the declared scheme and rejects an unrecognized value as `invalidParams`. The anchor argument keeps its `udcCode` name for wire compatibility; renaming the storage field is a separate migration outside this projection.

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
| Elicitation (elicitation/create) | The human gates | Native confirmation for proposals, branch promotions, and agent write-back review, replacing the v0.1 webhook machinery |
| Tasks (experimental) | The long-running NeuronKit calls and CognitionKit recipes | Native durable execution with deferred result and status, replacing custom trigger-id polling |
| Completions (completion/complete) | The grammar and the reference data | Argument autocomplete for legal wings, rooms, UDC prefixes, and verb-legal adjective values; the direct dividend of design-time semantics |
| Notifications and Logging | Substrate-driven verbs and audit events | propose and associate are BrainKit-emitted, not caller tools; they surface here, with taxonomy-change and audit notifications |

The two substrate-driven verbs, propose and associate, stay out of the tool surface by design. They are emitted by the BrainKits, not invoked by callers, so they appear as notifications rather than tools.

## § 5. Always the server, and transport

ARIA is always the MCP server; it never acts as a client of another MCP server. Transport by release. v1.0 uses local stdio: the server is launched by the client as a subprocess and speaks JSON-RPC over stdin and stdout. The transport is hand-rolled, no MCP SDK dependency, following the dependency-free pattern of the MemPalace MCP server: a tool registry, a request dispatcher over initialize, ping, notifications, tools/list, and tools/call, and a read-write loop. One hard rule carries over: stdout carries only JSON-RPC, and all logging goes to stderr. v1.1 adds Streamable HTTP for the Custom Connector path, behind the same dispatcher and tool router, so the handlers do not change with the transport.

## § 6. Client compatibility (verified 2026-05-22)

The MVP serves local stdio clients. The relevant denominator, confirmed against each client's documentation:

| Client | Local stdio | Tools | Resources, Prompts | Sampling, Elicitation | Notes |
|---|---|---|---|---|---|
| Claude Desktop, Claude Code | Yes | Yes | Yes | Limited | The first clients; how MemPalace already connects |
| Gemini CLI | Yes | Yes | Yes (as slash commands) | No | settings.json mcpServers; gemini mcp add |
| OpenClaw | Yes | Yes (standard tools only for generic servers) | No | No | Richer notifications reserved as client-specific experimental |
| Cursor | Yes | Yes | Partial | No | mcp.json mcpServers, command and args |

Two clients are not local-stdio clients and belong to the HTTP phase. The Claude API MCP connector is remote only: only tool calls are supported, local stdio cannot be connected directly, and the URL must be https. OpenAI's MCP is a remote server exposing a read-only search and fetch tool pair for deep research. Both are v1.1 (HTTP) considerations.

The conclusion: tools are universal across the local clients, resources and prompts are supported by the Claude hosts and Gemini, OpenClaw is tools-only for generic servers, and sampling and elicitation are not in the local baseline. The MVP is tools-first, advertising resources and prompts in capabilities so capable clients light them up and the rest degrade cleanly to tools.

## § 7. Install and connection protocols

Local stdio, manual configuration (the v1.0 path). Each client registers a stdio server with a command and arguments, then restarts: Claude Desktop in claude_desktop_config.json then quit and restart; Claude Code via claude mcp add or project .mcp.json; Gemini CLI via gemini mcp add or settings.json; Cursor in ~/.cursor/mcp.json; OpenClaw in its mcpServers registry. This works but requires hand-editing JSON and restarting, per client and per device.

Installer-written configuration (v1.1, candidate for v1.0). An ARIA installer detects which clients are present and merges the ARIA stdio entry into each client's configuration file, a guarded merge that preserves existing entries, then prompts the restart. This removes the JSON editing without remote hosting, and it generalizes across all clients, where the Claude Desktop extension bundle would cover only one. It is a guarded file merge plus a restart prompt, not new protocol, so it is a reasonable v1.0 stretch.

Custom Connector, remote HTTP (v1.1). The easiest install for the user: in the client's Connectors settings, add a custom connector, paste the URL, authenticate. No file editing, no restart, and resources and prompts surface natively. The cost is that this path requires an internet-hosted https endpoint and authentication, commonly OAuth, so it is not a local-host mechanism. That is why it is v1.1.

## § 8. Authentication, phased

v1.0, local owner by default. The connection is a process the machine owner launched against a configured instance. The schema-version gate (§ 9 below references it) is kept. The credential check is a present-but-trivial seam that resolves the configured instance, structured as the single chokepoint so the real check drops in without rework. The write-policy gate is present as a single boundary on the write path, an allow-all stub for now. v1.1 and beyond, with HTTP: the owner and scoped token model from v0.1 section 4, and OAuth for the Custom Connector path.

Schema versioning is retained from v0.1 section 3. Every tool call carries a schema_version of the form geniuslocus.<verb>.<major>, validated before credentials and before any substrate access. This is the design-time contract between caller and surface.

## § 9. Release plan

v1.0, full MOOTx01. ARIA wraps a full MOOTx01 instance, GLK plus NeuronKit and CognitionKit, over local stdio, always the server. The caller-driven verbs project as MCP tools whose schemas are generated from the lexicon and the acceptance matrix: capture, recall, mutate, withdraw, expunge, reanchor, learn, plus a status tool. Writes always target GLK; recall is hybrid by default and accepts a CorpusKit-only or LocusKit-only read lens. Resources and prompts are advertised in capabilities and implemented opportunistically. The schema-version gate, the local-owner credential seam, and the write-policy seam are present. Install is by manual client configuration. Swift first; the Rust version is a fast-follow.

Dependency. v1.0 as defined depends on the two BrainKits, which are unbuilt: NeuronKit is Mission 9 and CognitionKit is Mission 10. ARIA v1.0 therefore sequences after those missions. A GLK-only transactional server is buildable now against the shipped GeniusLocusKit, but that is a pre-v1.0 spike, not v1.0, because it lacks the BrainKits that make the instance MOOTx01.

v1.1. The MCP can provision a narrow instance, just LocusKit or just CorpusKit, rather than only wrapping a pre-built MOOTx01. API-mode fleet routing across many instances. The Custom Connector path: Streamable HTTP, OAuth, and the owner and scoped token model. The config-writing installer (candidate for pull-forward into v1.0). The richer read surface: resources with subscriptions, prompts, and completions.

Beyond v1.1. The client-initiated primitives, gated on capable clients: sampling, so the BrainKits borrow the caller's model and the substrate stays model-independent; elicitation, so human gates are native; tasks, so long-running NeuronKit calls and CognitionKit recipes are durable. Then full remote, multi-tenant operation at scale.

The placement of resources, prompts, completions, sampling, elicitation, and tasks across v1.1 and beyond is a proposal, not a fixed boundary, and can move with client support and need.

## § 10. Build impact

This supersedes the v0.1 conformance rule that required all three call modes. Conformance is now defined per release in § 9. ARIA addresses the substrate through a backend-adapter seam: in GLK mode it calls the GeniusLocusKit verb surface, and the adapter is where the v1.1 narrow-instance modes and the API-mode fleet routing attach without reworking the projection. The transactional scaffold becomes the v1.0 build once the BrainKits land, refined to: tools generated from the lexicon and the acceptance matrix; the local-stdio clients as the named compatibility set with a smoke test against Claude and one other; local-owner trust with the credential seam; writes always GLK with recall lensing; resources and prompts advertised while only tools are implemented.

The lexicon-to-MCP projection in § 2 and § 4, and the instance-versus-API model in § 3, are the durable contribution of v0.2. Everything else is sequencing around them.
