---
title: aria-mcp Specification
version: 2.1.0
status: accepted-1.1-target
date: 2026-08-26
description: "Behavioral specification for aria-mcp: invariants, conformance requirements, and the contract it guarantees. 2.0.0: consolidated reorganization (adopted from the ARIA_PROPOSED pair) — return-shape taxonomy, composer invariant, canonical candidate row with fixed columns, runtime-active zero/one/many adornment composition over normalized storage, structured-result contract. Full history: ARIA_MCP_SPEC_CHANGELOG.md."
spec_type: protocol
authors: MOOTx01 maintainers
relates_to:
  - ../concepts/MOOTX01_AND_ARIA_CANON.md (the definitions this spec projects from)
  - ARIA_MCP_INTERFACE.md (the wire/interface companion)
  - AriaLexiconLib (the grammar this spec projects onto MCP)
  - DESIGN_CONSTRAINTS.md (C-1, why the substrate stays model-independent)
---

# aria-mcp Specification: ARIA Behavioral Contract

This specification defines what ARIA means and which behaviors an ARIA MCP
server guarantees. The companion
[ARIA_MCP_INTERFACE.md](ARIA_MCP_INTERFACE.md) owns the concrete
tool names, arguments, wire schemas, public types, request and response
examples, package map, and conformance commands.

This 2.0.0 revision is the adopted consolidation of the pre-2.0.0
ARIA_MCP_SPEC.md/ARIA_MCP_INTERFACE.md (history preserved in
[ARIA_MCP_SPEC_CHANGELOG.md](ARIA_MCP_SPEC_CHANGELOG.md)) and
[ARIA_VERB_FAMILIES.md](ARIA_VERB_FAMILIES.md); the drafting record lives in
the archived ARIA_PROPOSED pair (docs/archive/).

## Contents

1. [Document authority](#1-document-authority)
2. [Normative conventions](#2-normative-conventions)
3. [ARIA language model](#3-aria-language-model)
4. [Instance and dispatch model](#4-instance-and-dispatch-model)
5. [Release profiles](#5-release-profiles)
6. [Server and transport behavior](#6-server-and-transport-behavior)
7. [Shared tool behavior](#7-shared-tool-behavior)
8. [Recall and result behavior](#8-recall-and-result-behavior)
9. [Knowledge and lifecycle behavior](#9-knowledge-and-lifecycle-behavior)
10. [Session behavior](#10-session-behavior)
11. [Resident lifecycle](#11-resident-lifecycle)
12. [Auxiliary HTTP behavior](#12-auxiliary-http-behavior)
13. [Conformance](#13-conformance)
14. [Design rationale](#14-design-rationale)
15. [Source disposition](#15-source-disposition)
16. [Changelog](#changelog)

## 1. Document authority

### 1.1 Scope

ARIA is the Augmented Recall and Inference Architecture. It is reached through
three consumption surfaces:

1. the `aria-mcp` server;
2. the Native API exposed by the SDK; and
3. the embedded library described by `ARIA.md`.

This document specifies the behavioral contract of the first surface. ARIA is
always the MCP server and never acts as an MCP client.

### 1.2 Division between Spec and Interface

| Question | Owning document |
|---|---|
| What does the operation mean? | Spec |
| Which state transitions and invariants apply? | Spec |
| What must happen on failure or partial success? | Spec |
| Which release profile contains the behavior? | Spec |
| What is the tool, argument, field, or endpoint called? | Interface |
| What is its JSON, text, or public-type shape? | Interface |
| Where is it implemented and how is it tested? | Interface |

Where the two documents appear to disagree, the Spec owns semantics and the
Interface owns representation. A discrepancy is a conformance gap; neither
document silently overrides the other.

### 1.3 Canonical dependencies

- [MOOTX01_AND_ARIA_CANON.md](../concepts/MOOTX01_AND_ARIA_CANON.md) defines MOOTx01, the ARIA grammar,
  instance mode, and API mode.
- [ARIA_LEXICON.md](../concepts/ARIA_LEXICON.md) defines the lexicon and naming discipline.
- [GENIUSLOCUSKIT_SPEC.md](GENIUSLOCUSKIT_SPEC.md) defines the estate verb surface ARIA dispatches to.
- [LOCUSKIT_SPEC.md](LOCUSKIT_SPEC.md) defines drawer, tunnel, KGFact, adjective, lineage, and
  state-transition semantics.
- [NEURONKIT_SPEC.md](NEURONKIT_SPEC.md) defines the analysis and autonomous duties ARIA hosts.
- [MOOT_MGR_SPEC.md](MOOT_MGR_SPEC.md) defines the separate GUI control and monitoring surface.
- [DESIGN_CONSTRAINTS.md](../validation/DESIGN_CONSTRAINTS.md) defines the model-independence
  constraint.

## 2. Normative conventions

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY**
carry their ordinary standards-document meaning.

The following labels distinguish material that previously appeared in the
same prose register:

- **Normative** — required for conformance.
- **Release profile** — required only in the named release.
- **Rationale** — explanatory and non-normative.
- **Sample** — an illustrative serialization. Literal text is normative only
  when the surrounding section says it is byte-exact.

There is no "known gap" category: this specification leads and code follows.
An observed port or surface that differs from this document is a defect
against it, tracked in the conformance backlog, never documented here as an
alternate contract.

Requirements live in this document or the companion Interface. Changelog
entries explain history; they do not establish requirements by themselves.

## 3. ARIA language model

### 3.1 Grammar

Every ARIA call is one verb applied to one noun, optionally constrained by
adjectives. The vocabulary is fixed at design time.

The nine verbs are:

- caller-driven: `capture`, `recall`, `mutate`, `withdraw`, `expunge`,
  `reanchor`, and `learn`;
- substrate-driven: `propose` and `associate`.

The canonical noun is the drawer. Seven storage shapes are facets or residue
of it: tunnel, KGFact, vector, diary entry, proposal, association, and learned
reference.

The four adjective categories are state, trust, sensitivity, and
exportability. Confirmation is carried as a distinct operational axis on the
external memory surface.

### 3.2 Acceptance matrix

| Noun | Accepted verbs |
|---|---|
| Drawer | capture, reanchor, mutate, withdraw, expunge, recall |
| Tunnel | capture, mutate, withdraw, expunge, recall |
| KGFact | mutate, withdraw, expunge, recall |
| Vector | none; substrate-managed |
| Diary entry | recall |
| Proposal | mutate, withdraw, expunge, recall |
| Association | mutate, expunge, recall |
| Learned reference | learn, mutate, withdraw, expunge, recall |

The acceptance matrix is the internal language contract. A caller does not
discover at runtime whether a verb applies to a noun.

### 3.3 Projection onto MCP

The internal ARIA grammar projects onto MCP primitives:

| MCP primitive | ARIA element | Role |
|---|---|---|
| Tools | Caller-driven verbs | Mutations and queries |
| Resources | Nouns and their facets | Live read surface and subscriptions |
| Prompts | Recall and synthesis recipes | Discoverable parameterized patterns |
| Sampling | BrainKits borrowing the caller model | Model-independent enrichment |
| Elicitation | Human gates | Proposal, promotion, and write-back review |
| Tasks | Long-running calls and recipes | Durable deferred execution |
| Completions | Grammar and reference data | Legal argument completion |
| Notifications and logging | Substrate-driven verbs and audit events | Propose, associate, taxonomy, and audit emission |

`propose` and `associate` MUST NOT appear as caller tools. They are emitted by
the substrate and surface through notifications and audit channels.

### 3.4 External language organization

The AI-client surface uses task-oriented `moot_*` tool names rather than the
internal verb–noun spellings. It is organized into six families, each moving
from broad Tier 1 behavior to narrow Tier 3 behavior:

1. Recall — survey, focus, pinpoint;
2. Capture — intake, filing, assertion;
3. Lifecycle — circulation, belief, disposition;
4. Lenses — climate, frame, anchor;
5. Maintenance — renewal, sweeps, surgery; and
6. Utility — presence, orientation, operations.

The complete name, argument, response, and follow-up catalog lives in the
Interface. Family placement is navigational; it does not create a new noun,
verb, permission, or state transition.

## 4. Instance and dispatch model

### 4.1 MOOTx01 instance

A full MOOTx01 instance is GeniusLocusKit plus NeuronKit and CognitionKit.
ARIA addresses the substrate through GeniusLocusKit and MUST NOT bypass it for
writes.

### 4.2 Write path

All writes target GeniusLocusKit. GLK stores content once as a canonical
LocusKit Drawer and advances CorpusKit's derived indexes for the same Drawer
ID through QueueKit over PersistenceKit. ARIA calls only the GLK verb surface;
GLK owns content-source adaptation and coordination.

### 4.3 Recall lenses

Recall is hybrid by default: LocusKit spatial and graph retrieval plus
CorpusKit BM25 and vector retrieval. All lanes return canonical Drawer IDs.

A caller MAY narrow a read to CorpusKit-only or LocusKit-only. A lens narrows
the read over the same drawers; it does not create a second content store or
change the write path. Passage chunking and the standalone CorpusKit
`Chunk`/`ScoredChunk` compatibility surface remain outside a MOOTx01 instance.

### 4.4 API-mode fleet

API mode routes calls across separately configured instances. QueueKit over
PersistenceKit supplies per-database operation and cross-database coherence.
Fleet routing is distinct from the read lenses of one GLK instance.

Direct tool calls address the default estate. Cross-estate reads use the
grant-authorized federation surface; lens comparison tools retain their
explicit comparison-estate argument.

## 5. Release profiles

### 5.1 v1.0 — full resident instance

The v1.0 profile includes:

- one full MOOTx01 instance;
- resident loopback HTTP as primary transport;
- stdio as fallback;
- the caller-driven tool surface plus status/orientation;
- GLK-only writes and hybrid recall with optional narrow read lenses;
- the schema-version, local-owner credential, and write-policy seams;
- automated client configuration and resident service registration;
- the autonomic governor and standing-signal scheduler; and
- resources and prompts advertised where supported, with tools as the common
  client denominator.

### 5.2 v1.1 — narrow instances and fleet routing

The v1.1 profile adds narrow-instance provisioning, API-mode fleet routing,
remote HTTPS, OAuth/scoped tokens, and the richer resource, subscription,
prompt, and completion surface.

### 5.3 v2 and beyond

v2 adds native clients over the resident daemon. Later profiles MAY add
sampling, elicitation, durable MCP tasks, and remote multi-tenant operation.
Their exact release placement remains non-normative until promoted into a
release profile.

## 6. Server and transport behavior

### 6.1 Transport independence

One dispatcher and one tool router serve both transports. Tool handlers MUST
NOT depend on whether the request arrived by HTTP or stdio. Only JSON-RPC
crosses the protocol wire; diagnostic logging goes to stderr.

### 6.2 Resident loopback HTTP

The primary v1.0 server binds to loopback and accepts JSON-RPC 2.0 over HTTP
POST. SSE is the server-to-client streaming channel. The resident owns the
whole vertical and therefore also owns the Brain pump loop.

Remote/multi-tenant HTTPS and OAuth are not part of the local v1.0 profile.

### 6.3 Stdio fallback

The fallback transport uses newline-delimited JSON-RPC over stdin/stdout. It
supports the same dispatcher methods and tool behaviors. It is appropriate for
tests, proof-of-concept use, and migrations. An ephemeral stdio process does
not pump the Brain.

### 6.4 Stdio-to-HTTP bridge

The bridge reads one newline-delimited JSON-RPC frame, POSTs it to the resident
daemon, and writes one response frame. It performs transport adaptation only.

For every inbound request carrying an `id`, the bridge MUST produce exactly
one outbound response with the same `id`. It synthesizes JSON-RPC `-32603` for:

- a transport error;
- status 0 or an unreadable HTTP status line;
- a non-2xx response with an empty body; or
- a non-2xx response with a non-JSON-RPC body.

Notifications produce no reply on any failure path. The bridge is stateless
per frame. If session headers are added later, restart recovery MUST be added
at the same time.

The bridge caps each frame and its accumulation buffer at 4 MiB and permits at
most 16 forwarded frames in flight. Oversized frames are dropped and logged;
the seventeenth concurrent frame waits rather than being dropped.

### 6.5 Installation and client connection

`mootx01 install` performs guarded configuration merges, preserves existing
client entries, registers the resident service, and requests required client
restarts. Manual stdio configuration remains the fallback. Remote custom
connectors belong to the v1.1 profile.

### 6.6 Authentication profile

The v1.0 local-owner profile centralizes credential and write-policy checks at
one boundary. The v1.1 profile replaces the trivial local credential seam with
owner identity, scoped tokens, and OAuth where required.

## 7. Shared tool behavior

### 7.1 Common arguments

The Interface defines the exact schemas. Behavior shared across the surface:

- `estateID` selects an allowed estate where the tool permits it;
- `teachme: true` returns a guide before any runner or estate access;
- `mode` declares an advisory session bundle; and
- infrastructure fields such as lattice anchor plumbing, embedding model,
  capture channel, and actor identity remain server-owned unless an interface
  section explicitly exposes a subject-matter field.

### 7.2 Omit-to-default

Optional primitive arguments use omit-to-default semantics. A caller requesting
the default omits the key. A present JSON `null` is invalid unless the
individual schema explicitly assigns it meaning.

### 7.3 Failure representation

Malformed JSON-RPC, unknown methods, invalid parameters, and unresolved routing
are protocol errors. Once a valid tool call reaches a runner, expected substrate
refusals and unexpected runner failures return an MCP tool result with
`isError: true`, preserving the call ID and error text for the client. Unexpected
runner failures are also logged to stderr.

### 7.4 Tool-family progression

The six-family taxonomy is a progressive-discourse aid:

- Recall moves from candidate discovery to a hydrated address.
- Capture moves from bulk intake to a single assertion.
- Lifecycle moves from reversible circulation to terminal disposition.
- Lenses move from estate-wide climate to one-memory analysis.
- Maintenance moves from repeatable renewal to one promoted migration.
- Utility moves from presence to one operational thread.

The Interface lists every tool exactly once in this taxonomy and records
cross-family follow-ups without duplicating ownership.

## 8. Recall and result behavior

Decision basis: RETRIEVAL_SHAPE_OPTIMIZATION_2026-08-25 (the decided
register R1–R16). The Interface owns every literal grammar and Sample;
this section owns the semantics and invariants.

**Composer invariant.** Every payload this section defines is emitted by
one shared result composer per return shape. Tools and recipes supply
typed result data — rows, capability signals, surface extensions — and
never rendered text; the composer is the only code path that renders the
text payload and builds `structuredContent`, so text/structured parity
holds by construction and a new retrieval technique cannot emit an
off-contract payload.

For every set of result Drawer IDs, the composer performs one call-scoped
active-adornment read. That read joins the permanent adornment table to the
minter master table and returns only rows whose minter is active at composition
time. The composer never reads a Drawer adornment field, caches a seat list, or
hard-codes Apple, Candle, a port, or a fixed number of minters.

### 8.1 Default containment

Ordinary memory recall applies the default state, trust, and sensitivity
containment gates while leaving confirmation unconstrained. Fresh unconfirmed
captures are therefore recallable unless the caller requests a stricter
confirmation filter.

Exact-ID retrieval applies the same containment gate as search. A drawer that
exists but fails the gate is reported identically to an absent drawer so the
exact-ID path does not become an existence oracle.

### 8.2 Return-shape taxonomy

The read surface produces distinct semantic shapes, each with its own header
grammar so a consumer always knows which contract it is reading:

| Shape | Meaning | Score column | Members |
|---|---|---|---|
| S1 ranked memory candidates | rank-ordered pick surface | mandatory | memory search; precise, shaped, vague (both tiers), connected, distilled, temporal, and walk recall; the synthesis candidate section; federated sections |
| S2 unranked memory rows | enumeration or exact-address resolution | absent | memory list; batch memory get |
| S3 hydration | one full record, body-returning | n/a | single-id memory get at full depth |
| S4 fact rows | knowledge-graph triples | absent (filing/time order) | fact search; fact timeline |
| S5 graph-edge rows | tunnel edges with hydratable far endpoints | absent | connection search/map |
| S6 tabular rows | user-owned dataset data | n/a (caller-ordered) | dataset query/stats |
| S7 analytical findings | lens and workflow reports | n/a | lenses; contradiction hunter |

Order MUST NOT be readable as rank on an unranked surface: S2/S4/S5 headers
name their ordering (listing/filing/request order) and never use the S1
header. Scores are mandatory on S1 as rank transparency — the consumer must
always see how strongly the ordering separated.

### 8.3 Canonical candidate row

Every S1 surface uses one shared renderer. Each memory occupies one line of
exactly seven fields separated by ` · `, in this order:

1. drawer UUID;
2. subject;
3. first body sentence;
4. Semantic Search Candle (SSC) facts;
5. unlabeled active-adornment projection;
6. event time in ISO-8601 form; and
7. final relevance score to four decimal places.

The column count is FIXED: an absent optional value (a first sentence
byte-identical to the subject; no SSC; no active adornment) renders as `-`
occupying its whole column, so every position means one thing for every
reader. The header is:

```text
found N candidate memories, one per line
```

(singular: `found 1 candidate memory, one per line`). Scaffold labels and
internal lane/provenance diagnostics do not appear inside the row or
anywhere in the payload. Body-returning hydration tiers are outside this row
contract. Value normalization, escaping, truncation, and the S2 variant of
this row are Interface-owned.

The fifth field is determined entirely by current minter-master state. With no
active stored adornment it is `-`. With one, it is that adornment text. With
many, every active adornment is used in ascending minter-ID order and the text
values are joined inside the same field by ` || `. The fixed seven-column
contract therefore does not grow with the number of active minters. Minter
identity remains available losslessly in `structuredContent`; it is not
repeated as scaffold in the AI-facing text row.

**Sample**

```text
found 2 candidate memories, one per line
30B1B3B0-945D-4C07-AE57-53D9FFC9B543 · Entelo follow-up decided at TechFest · user: I'll definitely look into Entelo further. · kind: decision, entity: Entelo · TechFest; 2026-01-01; networking; elevator pitch; tips · 2026-01-01T00:07:52Z · 0.5687
E70A5761-152D-4ABB-B16A-964B06A09404 · AI recruitment tool exploration for company · user: I'm looking to explore AI-powered recruitment tools for my company. · kind: plan, entity: recruitment tools · Sarah; Google; TechFest; 2026-01-01; three weeks ago · 2026-01-01T00:07:48Z · 0.5562
```

### 8.4 Control lines

After the rows, an S1 payload MAY carry capability control lines — each
deviation-only, at most one per capability, fixed grammar (Interface-owned):

- **discrimination** — rendered only at low/medium separation; absence means
  high separation or a single result;
- **temporal** — the window/date-seeking narration of temporal recall;
- **walk** — stage and early-stop state of walk recall;
- **degradation** — `retrieval: degraded — one or more ranking stages
  unavailable`, emitted when the dense lane did not contribute for a reason
  other than an empty query OR any pipeline stage was skipped; at most once
  per reply.

Connected recall carries NO text control line: per-result graph provenance is
structured data (§ 8.9). Detailed stage names and lane vocabulary are
log-side, never payload-side. When multiple trailing lines coexist their
total order is absolute: discrimination, then the tool-specific narration
(temporal or walk), then degradation, then the non-determinate-tie
disclosure, then any coaching hint — the tie and hint lines are separate
ruled mechanisms and otherwise unchanged.

The sensitivity advisory is NOT part of any recall payload: it lives in the
search/get tool descriptions and the estate-status orientation surface
(§ 10.1). Its presence remains independent of estate contents.

### 8.5 Ranking, limits, and ordering

When a scored lane provides real relevance evidence, fusion MAY weight it.
When the scored lane is absent or bitmap-only, ordering is lexical-dominant
and recency is only a tie-break. A zero-term-match row admitted by another
lane MUST NOT outrank a term-matching row. Precision, preset, temporal, and
graph steering are SCORING changes, never shape changes: every S1 surface
renders identically, so door and preset arms compare cleanly.

The search `limit` is a relevance boundary rather than an unconditional exact
row count. Equal-scored rows at the boundary follow the tie-group contract in
the Interface. A non-determinate tie emits the specified disclosure message.

Unranked ordering is fixed per surface: memory list renders filing order;
batch get renders request order with exactly one line per requested id in its
request position (duplicates produce duplicate lines; gated or absent ids
render not-found lines); fact surfaces render filing-time order.

### 8.6 Progressive disclosure

The read surface is a four-rung ladder, cheapest to dearest; each rung's
output makes the next rung optional:

1. the S1 row (pick evidence);
2. the control lines (escalate, re-query, or stop — without another call);
3. the batch winnow (S2 shallow depths: judge a shortlist without bodies);
4. hydration (S3 full record: terminal).

S3 hydration includes the same call-scoped active-adornment projection as its
candidate row. It omits the adornment block when none are active and includes
every active text when one or many are present.

Distilled recall serves rung 3 in-line: each row is followed by its distilled
text as an unlabeled indented continuation — a body substitute cheaper than
hydration. A row still owing a distillate carries the one fallback marker and
the verbatim content it substitutes. No acknowledgment ceremony precedes any
result: behavior notices live in tool descriptions, never in payloads.

Vague recall renders both of its tiers in the canonical grammar under headers
naming the tier (summaries, then hydrated originals), so the AI knows a
summary row hydrates to a summary.

### 8.7 Grounded synthesis

An optional synthesis query deterministically extracts distinctive terms,
drops stopwords and short non-numeric fragments, lowercases and deduplicates
them, and caps the cue at twelve terms. The terms form an OR predicate that is
AND-composed with an optional filter. If every query token drops, the call
fails rather than silently becoming a whole-estate synthesis. Omitted query
means a whole-estate digest.

The candidate pool is the union of a lexical lane and a genuinely scored lane.
The caller's limit is applied after ranking.

The reply is: header; the cue line carrying the NORMALIZED extracted terms
(absent in the whole-estate form — grounded and whole-estate digests MUST be
distinguishable from the text alone); a composed summary paragraph in plain
prose with no label; then the canonical candidate section. Term-frequency
patterns, constant success rates, and template recommendations are not part
of the payload.

Synthesis receives the same call-scoped active-adornment projection as the
candidate composer. It uses all active available adornments and never consults
inactive stored rows.

### 8.8 Answer shaping and front-door selection

Search supports rows-only, always-answer, and confidence-gated automatic
response shaping. An explicit per-call answer setting overrides any sticky
Recall-mode default.

Scoring selection follows this precedence:

```text
explicit door > explicit scoring > provisioned DoorManifest > matrixAware
```

Unknown door or scoring values fail closed. Provisioned tuning affects the
default without changing the behavior of an unprovisioned estate.

### 8.9 Structured results — the second return shape

Every S1 surface declares the shared output schema and returns
`structuredContent` alongside the text block: a common base row (id, subject,
first sentence, typed SSC facts, composed adornment, active adornments, event
time, score, room) with
surface-specific extensions (graph provenance on connected recall; distillate
and representation on distilled recall; tier on vague recall; estate identity
on federated results; content at the memory-get depths) and top-level
capability metadata mirroring the control lines. The Interface owns the
schemas.

Invariants:

- one structured entry per rendered text row, same order, same cap;
- an optional field is ABSENT from the structured row when its text column
  renders the placeholder — never null, never empty-string;
- redaction parity: a structured field MUST NOT reveal content the text
  withheld; not-found rows appear in neither representation;
- score is absent on unranked surfaces;
- `adornments` contains one `{minterID, text}` entry per active stored
  adornment in minter-ID order; `adornment` is the exact composed fifth-column
  string; both fields are absent when there is no active stored adornment;
- zero/one/many conformance pins render `-`, the one text unchanged, and all
  texts joined by ` || ` respectively, while retaining exactly seven columns;
- consumption rule: machine extraction, deterministic identity matching, and
  scorer ingestion MUST use `structuredContent`; AI answer consumption and
  experiments whose independent variable is the presentation shape MAY
  consume the text payload. The text remains byte-pinned as the AI surface
  and the audit fallback.

### 8.10 Fact, edge, and tabular shapes

Facts render as their own canonical row (proposition first, then grounding
and filing time), fixed columns, with the source drawer making every
memory-derived fact hydratable; the timeline variant leads with filing time
and lifecycle. Graph edges render the edge identity followed by the far
endpoint's pick fields, unranked. Tabular data renders in its own S6 grammar
— dataset identity and result arithmetic, column names once, typed value
rows in caller order — and NEVER borrows the memory row; user-owned tabular
values round-trip losslessly in both representations, and a total-match
count that would require a separate full scan is optional, never silently
paid. All literal grammars are Interface-owned.

### 8.11 Empty results

An empty result renders the surface's zero-count header plus at most one
actionable hint. Hints are contents-independent and never imply that gated
records exist. Diagnostics never render on an empty result.

## 9. Knowledge and lifecycle behavior

### 9.1 KGFact

A KGFact stores a subject–predicate–object triple, a server-assigned ID,
optional source Drawer ID, adjective/operational/provenance bitmaps, and an
immutable server-assigned filing time. Filing time records when the fact was
stored, not when it became true in the world.

The model has no `valid_from` or `valid_to` window. A fact remains active until
retired, which moves it to withdrawn state. A freestanding agent assertion may
omit source Drawer ID; a fact derived from a memory supplies it for provenance.

Fact timeline returns active and retired facts in filing-time order and labels
lifecycle from the canonical state cluster rather than a raw-value boundary.

### 9.2 Partial erasure

Erasure walks the target lineage. If the substrate refuses accepted siblings,
those siblings remain readable and retain their derived material. The result
MUST distinguish full erasure from partial erasure and list the refused sibling
IDs. Partial completion is a successful tool result with a partial outcome, not
a fabricated full success.

### 9.3 Tunnel review ladder

Only proposed tunnels are reviewable.

- User accept activates the edge.
- A non-user accept is invalid; a model verdict never activates an edge.
- User reject withdraws the proposal durably.
- Model reject records an objection; without an endorsement the proposal may
  withdraw, while an endorsed proposal remains proposed and contested.
- Endorse records a vote without changing lifecycle.

Reviewer identity and tier are recorded in the review ledger.

### 9.4 Contradiction behavior

The contradiction hunter performs bounded candidate generation followed by a
typed conflict screen. Strong findings persist as proposed `contradicts`
tunnels; borderline pairs return for caller adjudication and do not persist.

Deduplication considers existing contradiction tunnels in every lifecycle,
including withdrawn edges. A rejected pair is not automatically re-proposed.

Single-tier contradiction searches are read-only. Dreaming and the resident
contradiction scout share the same core pass and deduplication contract.

## 10. Session behavior

### 10.1 Orientation

Every estate-status response includes a static protocol block after estate
statistics. It is independent of estate contents and requires no estate work.
The Interface owns the literal block and the live tool counts.

Status with `teachme: true` returns the full tiered orientation guide. The
guide's counts MUST be computed from the tool projection rather than maintained
as independent prose constants.

### 10.2 Teachme

Every tool accepts `teachme: true`. Dispatch intercepts it before federation,
recipe, lens, vault, interface, or runner routing. It returns a successful
static usage guide without touching an estate.

### 10.3 Coaching hints

After a successful runner result, deterministic coaching MAY append one `hint:`
line. Hints never attach to an error result and do not alter the semantic
outcome. When several triggers match, the first trigger in the Interface table
wins.

### 10.4 Modes

Modes are advisory bundles and MUST NOT disable tools. Five modes are defined:
Recall, Filing, Lenses, Vault, and Curator.

Unknown mode names or variants fail open: the call proceeds and receives a
hint. An unrecognized declaration does not replace recognized sticky state.

Recall variants set the default search answer mode:

| Declaration | Default answer mode |
|---|---|
| `Recall=Auto` | automatic confidence gate |
| `Recall=Rows` | rows only |
| `Recall=Answer` | always compose an answer |

An explicit call argument wins over sticky state. A bare `Recall` declaration
clears the variant. Sticky persistence and coaching cadence are estate
preferences applied once per session; malformed or absent preference data
falls back to defaults.

HTTP mode state is process-scoped until a client-scoped session map is defined.
That fact is a session model, not a separate mode semantic.

## 11. Resident lifecycle

### 11.1 Pump ownership

The resident HTTP process owns the only clock-reading pump loop. Each tick reads
`now` once and injects it into deterministic dreaming, maintenance, standing
signals, topology, and encode-drain duties. Individual daemons do not read the
clock. Stdio does not run this loop.

### 11.2 Standing signals

Default standing signals are registered once during resident bootstrap. The
scheduler is created on first registration. Without a scheduler, signal ticks
skip benignly while the server continues serving.

The scheduler emits propose, associate, and diagnostic events. Recall-cache
producers are governor duties rather than scheduler emissions.

### 11.3 Graph and preference producers

On their cadences, the governor:

- reads the estate structure graph, computes NeuronKit eigenvalue centrality,
  and registers the graph cache; and
- reads retained recall outcomes, fits NeuronKit preference strengths, and
  registers the preference store.

Both duties receive injected time and register empty/all-zero products for
empty inputs.

### 11.4 Pool reduction and live table swap

The governor reduces accumulated novel-token submissions into the writable
word-class artifact. An empty pool is a no-op. A non-empty reduction swaps the
running word-class table at the safe point so the tagger observes the update
without restart.

### 11.5 Encode drain

Regular captures enqueue encode work. The background drain ingests the work
into BM25 and vector indexes. The queue absorbs bursts and out-of-order arrival;
restart and stdio-exit behavior preserve pending work through the lease-aware
drain lifecycle.

### 11.6 Telemetry

Telemetry is wired through the configured stats store and remains off by
default. The resident polls the live monitoring flag and drives the reporting
gate without restart. When monitoring is off, report calls are no-ops. Store
wiring and monitoring consent are separate conditions.

## 12. Auxiliary HTTP behavior

### 12.1 Read-only endpoints

The loopback HTTP transport exposes graph, lattice, and hosted-estate reads.
They share the transport Origin guard and are routed before the POST-only MCP
guard. Unknown GET paths return the Interface-defined 404 response.

No drawer body, KGFact text, or diary text crosses these endpoints. Graph emits
identifiers and derived topology; lattice emits classification codes and
counts; hosted-estate output emits identity and backend metadata.

### 12.2 Graph snapshot

Graph reads serve a materialized topology snapshot written by the governor.
Before the first snapshot, the response explicitly reports pending structure
with empty collections; there is no inline recomputation fallback.

Topology math runs over live entities, while tombstoned entities may remain in
the playback payload with explicit tombstone timestamps. The governor skips
expensive recomputation when its topology-input fingerprint is unchanged.

The monitoring gate is checked before estate reads. Failure to read the
monitoring flag fails open for the duty so a transient stats-store error does
not silently freeze topology.

### 12.3 Lattice and estate lists

Lattice addresses are sorted by count descending and code ascending. Empty
estate and read failure remain distinguishable. Hosted-estate responses list
mounted instances and their backend labels.

### 12.4 Sensitivity grant control

Loopback-only control endpoints grant restricted or secret visibility and
revoke all grants. They share the Origin guard and are absent from stdio.

Restricted grants expire at the next local midnight; secret grants expire
thirty minutes after issue. Locking is always permitted because it only reduces
access. The Interface owns the request and response bodies and CLI aliases.

The sensitivity advisory does not render in recall payloads (§ 8.4). It lives
in the search/get tool descriptions and the estate-status orientation surface,
where every client encounters it at discovery or orientation. Advisory
presence depends only on grant state, never on whether sensitive rows exist;
conditioning it on contents would disclose the protected population.

## 13. Conformance

### 13.1 Release-scoped conformance

Conformance is measured against one named release profile. A port need not
implement later-profile primitives to conform to an earlier profile.

### 13.2 Sources of proof

Conformance consists of:

1. grammar and acceptance-matrix agreement;
2. generated/discoverable tool-schema agreement;
3. behavior and failure-path tests;
4. byte-exact fixtures where the Interface declares literal output; and
5. Swift/Rust parity tests for shared behavior.

The Interface lists the current test entry points and generated surface census.

### 13.3 Conformance backlog

This specification leads; deviations are code defects against it, not
documented variants. The known deviations at adoption time — retrieval
renderers missing score and adornment columns with content-alphabetical
ordering (precise, connected, temporal recall), fact search surfacing
internal provenance, distilled recall returning an acknowledgment gate,
the synthesize scaffold fields, and the structured-result field gap — are
enumerated with their target shapes in this document and are
resolved by the conformance pass that brings both ports to it.
Generated projection remains the census source for tool counts; port
metadata differences where backing stores carry different information are
recorded per surface in the Interface.

## 14. Design rationale

### 14.1 Ping rather than reconnect

The server opens an estate at startup and holds it for the process lifetime.
There is no network connection between ARIA and the local estate to reconnect.
`moot_estate_ping` therefore resolves the open handle in constant time and
reports server identity/build serial. Restarting the server is the remedy for
an estate that was not opened at startup.

### 14.2 Journal field name

Journal capture uses `entry`, not `content`, because it writes the
`DiaryEntry.entry` field rather than a Drawer body.

### 14.3 Fact-search query

Fact search accepts one optional query spanning subject, predicate, and object.
The shape matches an AI caller's typical entity or relationship cue; a
developer-facing field-decomposed query belongs to a different interface.

### 14.4 One canonical candidate renderer

Discovery surfaces return operational addresses rather than hauling complete
bodies. One shared row keeps results comparable, hydratable, and token-bounded.

## 15. Source disposition

Transition record of the 2.0.0 consolidation (where pre-2.0.0 material
now lives):

| Source material | Destination |
|---|---|
| ARIA language, projection, instances, profiles | Spec §§3–5 |
| Transport, bridge, install, authentication behavior | Spec §6; Interface §§2–3 |
| AI-client tool taxonomy | Interface §§4–10 |
| Verb families and follow-up affordances | Interface §§5–10 |
| Recall/result invariants | Spec §8; wire forms in Interface §11 |
| Lifecycle, facts, contradictions | Spec §9; tool schemas in Interface |
| Teachme, coaching, and modes | Spec §10; types/wire forms in Interface §12 |
| Governor and telemetry | Spec §11; public types/package map in Interface |
| Auxiliary HTTP behavior | Spec §12; request/response schemas in Interface §13 |
| Public Swift/Rust types and package layout | Interface §§14–15 |
| Test commands and fixtures | Interface §16 |
| Legacy changelogs | Retained unchanged in source documents; current requirements integrated above |

## Changelog

### 2.1.0 -- 2026-08-26
Ladder merge. The develop/1.1.x stream and the benchmark stream each
minted entries in the 1.4x-1.5x range for unrelated changes while this
document was being reorganized to 2.x. The develop entries are preserved
verbatim in the companion changelog under a repair heading; their
self-labels are historical text and do not index into this ladder.
No contract change in this entry.

The full entry ladder lives in
[ARIA_MCP_SPEC_CHANGELOG.md](ARIA_MCP_SPEC_CHANGELOG.md). Current entry:

### 2.0.1 -- 2026-08-26

Vocabulary (mission SSC-RENAME): the § 8.3 fourth column's acronym is
now defined at its definition site — Semantic Search Candle (SSC).
Terminology only; no behavioral change; rendered payloads and the
structured `ssc` key are byte-identical.

### 2.0.0 -- 2026-08-25

Adopted consolidation (Bob approval 2026-08-25) replacing the 1.55.2
document body: Spec/Interface authority split; six-family external
language organization; § 8 retrieval contract (return-shape taxonomy
S1–S7, composer invariant, canonical seven-column candidate row with
fixed `-` absence columns, deviation-only control lines with absolute
trailing order, structured base-row-plus-extensions contract with the
machine-MUST/AI-MAY consumption rule, fact/edge/tabular semantics);
runtime-active zero/one/many adornment composition over LocusKit's
normalized adornment store; sensitivity-advisory relocation; the
known-gap category deleted (spec leads, code follows).
Drafting history (0.1.0–0.3.0): the archived ARIA_PROPOSED pair.

Proposal-draft ladder (retained verbatim for the record):

### 0.3.0 -- 2026-08-25

Defined call-scoped result-composer lookup of the runtime-active minter set.
The fixed fifth candidate-row field now represents zero, one, or many active
adornments without adding columns; structured results preserve the ordered
minter-ID/text pairs. Synthesis uses the same active projection.

### 0.2.0 -- 2026-08-25

Post-review additions in this revision: the § 8 composer invariant (one
shared result composer per shape; tools supply data, never rendered
text), the absolute trailing-line order, and the degradation-line wording
broadened to match its predicate.

Integrated the decided retrieval return-shape contract
(RETRIEVAL_SHAPE_OPTIMIZATION_2026-08-25, register R1–R16, Bob-delegated
Fable+Codex agreement). § 8 rewritten: return-shape taxonomy (S1–S7);
canonical candidate row moves to a fixed seven-column model with `-`
absence placeholders; deviation-only control-line set with the exact
degradation predicate (connected recall carries structured per-result
provenance instead of a text line); ranking/ordering rules for unranked
surfaces (request-order batch get, filing-order enumerations); the
progressive-disclosure ladder; distilled recall loses its acknowledgment
ceremony; grounded synthesis loses its scaffold fields (patterns,
successRate, recommendations) and gains the composed-summary + candidate
form; structured results become a base-row-plus-extensions contract with
the machine-MUST/AI-MAY consumption rule; fact/edge/tabular shape
semantics; empty-result rule. Sensitivity advisory relocated from
search/get payloads to tool descriptions + estate-status orientation
(§ 12.4 updated). The "known gap" category is deleted (§ 2, § 13.3):
spec leads, code follows — deviations are conformance-backlog defects.

### 0.1.0 -- 2026-08-25

Created the proposed consolidated behavioral specification from the four ARIA
reference documents. Separated behavioral authority from wire/interface
authority, integrated the six-family taxonomy, isolated rationale and known
gaps, and retained the source documents unchanged.
