---
title: GeniusLocusKit Specification
version: 3.45.0
status: accepted-1.1-target
date: 2026-09-15
description: "Behavioral specification for GeniusLocusKit. 2.0.0 makes dreaming and result composition consume the runtime-active minter set over LocusKit's permanent normalized adornment store; 2.2.0 adds the engine-neutral neural-embed-v1 provisioned provider; 2.10.0 adds the estate format V1_2 and the 1.1→1.2 migration capsule; 2.11.0 makes distillation convergence idempotent across mid-run process crashes; 2.12.0 activates intent-span v23.2 as the product converter, adds the source-digest half of the representation-currency rule, and adds estate format V1_3 with the 1.2→1.3 migration capsule; 2.13.0 makes the index composition policy a stored estate setting and adds estate format V1_4 with the 1.3→1.4 migration capsule; 2.14.0 adds estate format V1_5 with the 1.4→1.5 storage-ledger kit-id migration capsule, which carries the SynapseKit kit ids into every populated estate's schema-version ledger; 2.15.0 gives the Rust union-best path the MMR stage; 2.16.0 gives the Rust unionBest pipeline the sub-span dense refinement step and hit provenance and explanation parity; 2.17.0 adds the signal:* column-budget key namespace and RecallSignalBudget; 2.18.0 excludes all-zero scoring columns and the locus column on text queries and gates matrix scoring on bitmap predicates; 2.19.0 keeps the unionBest MMR similarity term on the redistributed relevance scale; 2.20.0 adds no_bm25 and no_vector ablation presets to the named preset roster, both ports; 2.21.0 adds the unionBest span rerank stage (Encoder Rerank Program): the lexical lane reads to depth 1000, an encoder reranks its head by best int8 span cosine and reciprocal-rank fusion reorders the lexical list, hits carry span evidence and a span: explain token, no_encoder joins the roster, the dense-family keys go behind the DenseFamilies switch, and the vector column leaves the default fused score. 2.23.0: the index composition policy setting and its two capsules retire; I-21 and I-23 are historical records. 2.24.0: span encoder activation runs after the estate's VectorStore is registered, so the rerank stage is installed whenever the model loads. 2.25.0: the span encoder is the default recall stage — provision and the upgrade migration write embedding_provider = encoder when an estate names no provider. 2.25.1: wording only — hedging vocabulary removed from the prose; no contract change. 3.0.0: corrected default provider wiring and standing-signal roster; replaced adornment orchestration with its retirement record. 3.1.0: estate format V1_6 and the 1.5→1.6 capsule drop corpus_index_state.composition_policy (I-25); every Rust serve path wires through wire_glk_substores. 3.2.0: the answer:auto confidence gate reads the span rerank stage (m2 is the agreement between the lexical head order and the span order, m3 the span cosine spread) and the activation path seeds the active encoder_models row at open, both ports. 3.3.0: the Rust unionBest raw, rrf and discriminative path reports the normalised buffer columns and buffer.final on every hit and runs the full pipeline without a corpus, the same values Swift reports. 3.4.0: the Rust Hybrid and CorpusOnly raw path is the ordered list merge Swift performs, and the Rust unionBest matrixAware branch seeds the union profile's final column with the per-lane max, both ports. 3.5.0: a Hybrid or CorpusOnly hit carries per-signal lane columns (the locus ramp, the BM25 score, the Hamming similarity, 0 where a lane did not supply the hit) under every scoring, and the Hybrid path fuses the locus, BM25 and vector lanes and no graph lane, both ports. 3.6.0: expunge step 2 and the integrity sweep scrub the encoder span lanes (every encoder_models registry id plus the registered encoder) between the distillation and corpus-model lanes, and the spanEncode duty rechecks drawer liveness and content version before each span write, both ports. 3.8.0 adds estate format V1_7 with the 1.6→1.7 whole-record float vacuum capsule (I-26) and moves LSA to its own switch. 3.9.0: the unionBest step 5.8 sub-span refinement and the step 9.5 shingle view run under fixed work bounds (a per-record byte cap and an aggregate window budget; a body cap and an aggregate shingle budget) with the stages subSpan.budget and unionBest.mmrBudget and the explainer token subSpan:budget, and the Rust migration chain reads the persisted estate format and refuses a stamp below the compiled floor or above the current format before any capsule runs, both ports. 3.10.0: the unionBest step 5.8 sub-span refinement runs only when the recall request turns it on (GLKRecallRequest.subSpanScoring / sub_span_scoring, off unless a caller sets it, not an ARIA argument), both ports. 3.11.0: the flat-layout capsule moves a pre-catalog Swift estate from the configuration directory into the catalog's default record directory before any migration step opens it; a layout step, not a format step, Swift only. 3.12.0: § ESTATE_CATALOG records the estate catalog: the configuration directory computed from the platform, estatecatalog.json with its ordered records and default location, registered and transient records, the per-estate estate.json manifest with its closed key set, selection by --db, and the catalog's boundary (storage only, never the database, the daemon or the environment). 3.13.0: § ESTATE_OPEN_POSTURE records the one at-rest open decision and the key custody beneath it, moved into the kit beside the catalog; Swift only. 3.14.0: an estate record names its backend (SQLite in the directory, or PostgreSQL at a connection string) in estatecatalog.json, the posture decision refuses a record with no database file, and the kit reports the backend each open estate runs on for status surfaces; Swift only. 3.15.0: the configuration directory's home is the process home (the container inside a sandbox, on macOS and iOS alike), and an estate's Keychain key follows its file: the layout capsules relocate the key to the new path's account before the database moves. 3.16.0: the app-container capsule moves a pre-catalog Apple app estate (<Application Support>/mootx01/mootx01.sqlite in the app's container) into the default record's directory under the catalog's names, key first; Swift only. 3.17.0: the configuration directory's home is the process family's, the user's home for the unsandboxed CLI family and the group container for the sandboxed app family (DECISION_INSTALL_TAKEOVER_2026-09-08). 3.19.0: the retrieval-time cross-encoder stage runs after the admission gate when a request carries an apply directive, scores the head of the pool with the packaged pair classifier and fuses by reciprocal rank, degrades with a reason otherwise, and the manifest keys cross_encoder_pool/head/spans clamp its maxima; both ports. 3.20.0: the open posture decision table is one table in both ports, pinned by a shared fixture: a transient ciphertext estate is refused whether or not a key exists for it, a manifest the catalog refuses refuses the open with a typed error, the harness key file is a compile condition in both ports (Swift MOOTX01_HARNESS_KEYFILE, Rust feature harness-keyfile) and honours the plaintext declaration; the manifest refresh never overwrites a manifest it could not read; the selector expands a bare ~ only; and the catalog answers whether a --db value names a registered estate by canonical directory. 3.21.0 adds the Windows base-directory adoption capsule, Rust only: the pre-catalog Windows base moves into the estate catalog's configuration directory on the first command that opens the catalog, and the novel-token pool directory is pinned in both ports. 3.22.0 to 3.23.0: recorded in the changelog below; this description line was not extended at the time. 3.24.0: the GLK retire verb carries changedBy and reason down to the LocusKit store verb, which emits the sealed audit row. 3.25.0: sensitivity ceiling enforced on expunge and retireKGFact/withdraw_kg_fact — rows and facts at .restricted/.secret are refused with the absent-row error; no existence oracle is provided to the caller. 3.26.0: defines the opt-in bounded fact-extraction duty in both ports. 3.28.0: adds estate format V1_8, the FactExtractionSetting type, the fact_extraction manifest key and accessor pair, and the 1.7 to 1.8 migration capsule (seeds fact_extraction = on when absent, I-27). 3.29.0: retires the explicit fact-first recall pre-stage; the fact layer moves to its own door (moot_fact_search). 3.30.0: Signal 14 activates live in the resident daemon behind the fact_extraction setting; the CoreAI NuExtract extractor is the daemon's extractor. 3.31.0: adds the recall router (§ RECALL_ROUTER): an ordered route list applied once per scored recall; route 1 is cross-encoder conversation routing behind the cross_encoder_routing preference; both ports. 3.32.0: the dense switches go; the whole-record float engine is in the default build with LSA as its provider; PPMI, NMF, FDC, MPNet, EmbeddingGemma and the MiniLM baseline are retired. 3.35.0: signal 7 (end-of-day-tournament) runs as GeniusLocusKit.endOfDayTournament, folding the day's recall traces into Bradley-Terry ratings in recall_ratings; Swift. 3.36.0: adds estate format V1_9 and the 1.8 to 1.9 preference-seed migration capsule (seeds the consolidation, contradiction_sweep, cross_encoder_routing, maintenance and adaptive_recall preferences on when absent and creates recall_ratings, I-28); both ports. 3.38.0: Route 1 of the recall router applies the degradable apply directive (reason route:cross_encoder_routing), never the transcript operation's fail-closed strict directive; a routed ordinary question keeps its lane order when the stage cannot run. 3.39.0: every migration capsule trait is in the Swift package's default trait set. 3.40.0: adds `fact_extractor` preference key (allowed: nuextract, apple; default: nuextract; no seeding capsule; `fact_extraction` remains the on/off master switch); per-key `allowedValues`/`allowed_values` and `defaultValue`/`default_value`; both ports. 3.42.0: the drain report always carries the `fact_extraction` lane — drawers still owed extraction for the active recipe (bit 28 clear), in-flight 0, non-gating for the encode finisher and the benchmarker's encode barrier — so a caller settles an estate on product state; both ports. 3.43.0: I-3 names the access surface: AriaMcpKit reads drawers, tunnels, facts and meta through the handle-scoped read surface and holds no LocusKit.Estate."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - GENIUSLOCUSKIT_INTERFACE.md  (the API surface this spec contracts)
  - GENIUSLOCUS_ARCHITECTURE_SPEC.md  (§ 7.8 verb surface, § 11 standing signals, § 12 matrix tier, § 15 kit composition; invariants I-13, I-15)
  - LOCUSKIT_SPEC.md  (the single-estate tier GLK composes)
  - SYNAPSEKIT_SPEC.md  (the vector tier composed per estate)
  - CORPUSKIT_SPEC.md  (the standalone-capable RAG/index tier composed per estate)
  - QUEUEKIT_SPEC.md  (the serial-lane dispatch substrate the scheduler owns)
  - ARIALEXICONLIB_SPEC.md  (the verb/noun/adjective vocabulary the surface conforms to)
  - ARIA_MCP_SPEC.md  (the access surface that mediates cross-device federation, I-13)
  - SUBSTRATEML_SPEC.md  (the algorithm tier GLK composes for matrix/mining work)
purpose: |
  GeniusLocusKit is the composition and orchestration layer of the
  substrate. It coordinates N estates on one device behind one handle
  type, projects the unified nine-verb ARIA surface over each estate,
  unifies the per-tier audit streams into one G-Set CRDT per estate,
  and runs the Brain layer: the per-estate standing-signal scheduler
  (one QueueKit serial lane per estate), the six v1 standing signals,
  the F/C/O/T matrix tier, and the threshold-gated training daemon. It
  also owns the device-local sharing primitives — grants, the scope-key
  vault, COW branches, and the MemPalace migration API — that the ARIA
  access surface builds federation on top of. GLK composes LocusKit,
  SynapseKit, CorpusKit, PersistenceKit, QueueKit, and AriaLexiconLib; it
  never reaches around them. The companion INTERFACE document carries
  the signatures.
---

# GeniusLocusKit Specification

## Typed write boundary

GLK exposes typed tunnel capture and settlement, dataset-handle capture, the
fixed FDC recalculation-floor stamp, and explicit audited anchor reanchoring in
both ports. Each operation resolves through the existing mounted/stale estate
gate before it reaches LocusKit. Settlement preserves the existing atomic
lifecycle and canonical review-ledger update: accept makes a proposed tunnel
Active, reject makes it Withdrawn, and `reviewedBy` records the actor. The
existing `reason` and clock inputs are forwarded but are intentionally not
persisted in tunnel `ext`; no migration or new ledger keys are introduced.

Governed dataset filing creates the backend table, appends rows, and captures
its typed handle as one sequence. An append or handle failure drops the new
table. The subsequent signature computation is the existing governed
dataset-signature patch, after the handle is durable; failure leaves a
recoverable `signatures: pending` result and does not erase the loaded dataset.
The common Swift/Rust capture and filing contract accepts a UDC code only.
Swift's lower LocusKit call can construct a richer anchor, but facets and QIDs
are deliberately outside the shared route because the Rust lower primitive
cannot retain them.

The current ARIA v2 link/review callers and GLK conflict
proposal/supersession filers use the typed tunnel verbs. Their existing
suppression, unresolved-endpoint, and nonfatal caller result behavior remains
unchanged.

The FDC seam owns exactly `aria.fdc.recalced_data_version`. It is a fixed typed
operation, not a metadata broker, and emits no synthetic audit event, signal, or
index. Dataset capture remains the existing typed LocusKit handle path.

## § 1 — What this package is

GeniusLocusKit is the layer where one estate becomes a substrate. Where
`LocusKit.Estate` is exactly one estate's structured-memory tier, the
`GeniusLocusKit` actor coordinates N estates on one device: it admits
each estate into a registry behind an opaque `EstateHandle`, projects
the unified nine-verb surface (`capture`, `recall`, `mutate`, `withdraw`,
`expunge`, `reanchor`, `learn`, `propose`, `associate`) over the
addressed estate, and runs the Brain layer that the architecture spec
§ 11–12 defines — the standing-signal scheduler, the six v1 standing
signals, the matrix tier, and the training daemon.

GLK is the composition root. Everything a reasoning layer (NeuronKit,
CognitionKit) or an access surface (aria-mcp) needs from the substrate
flows through the `GeniusLocusKit` actor: the verb surface, the
lattice-scoped read fan-out, the grant-gated federated read, the unified
audit log, COW branching, and the migration API. The composed kits —
LocusKit, SynapseKit, CorpusKit — are reached only through this layer's
surface; consumers above GLK do not import them directly (B-1).

This package is a **Kit**: it manages state and lifecycle. The
`GeniusLocusKit` actor owns the estate registry, one
`StandingSignalScheduler` actor per estate (each holding one QueueKit
serial lane), one `UnifiedAuditLog` per estate, the per-estate
`GrantStore`/`ScopeKeyVault`, and the in-memory COW branch registry. The
value types it moves (frames, reports, grants, audit entries) are
immutable `Sendable` structs and enums.

## § 2 — Scope

This specification defines:

- The multi-estate lifecycle: `open(storage:owner:)`, `close(_:)`, internal
  registry resolution, `handles`, `openEstateCount`, and the duplicate-UUID
  refusal.
- The unified nine-verb surface and how each verb dispatches to its
  estate body, governed by the lexicon's § 7.2 acceptance matrix.
- The `similarRecall` verb (`Verbs/SimilarRecall.swift`; Rust
  `EstateCoordinator::similar_recall`): the paraphrase door. It probes the
  corpus engine's default float slot — the whole-record LSA lane — for the
  `limit` nearest drawers, keeps the lane's nearest-first order, hydrates the
  drawers through the frame filter (tombstone exclusion, the default
  sensitivity ceiling, superseded rows dropped) and returns `RecallHit`s whose
  `score.final` is the raw cosine similarity in [−1, 1] and `score.dense` its
  [0, 1] normalisation. No fusion, no rerank. Empty when no corpus engine is
  registered, when the lane is dark for the query, or when nothing passes
  the filter. CognitionKit's `similar_recall` recipe and ARIA's
  `moot_recall_similar` wrap it.
- The lattice-scoped read fan-out (`fanOutRecall`, `estatesOverlapping`)
  and its zoom-window overlap rule — a device-local read router, not
  federation (I-13).
- The grant-gated federated read (`federatedRecall`), the grant model
  (`Grant`, `GrantStore`, `ScopeKeyVault`, custody modes, the
  Lagrange-decay key), and the fail-closed A-versus-C refusal.
- The Brain layer: the per-estate `StandingSignalScheduler` and its
  single-serial-lane contract, the four emission classes, the six v1
  standing signals, the F/C/O/T matrix tier, and the threshold-gated
  training daemon.
- The unified per-estate audit log (G-Set CRDT over both storage tiers),
  its projection, asOf reconstruction, recovery rebuild, and chain
  verification.
- COW branching: derive, promote, cherry-pick merge, and the
  parent-never-modified invariant (I-15).
- The MemPalace migration API: import, parallel-run, and zero-loss
  verification.
  - The Swift ⇄ Rust conformance obligation and the documented port gap.
- The shared-content composition contract: LocusKit owns each canonical Drawer,
  while CorpusKit indexes that same content through a GLK-owned adapter.

This specification does NOT define:

- API signatures — those live in `GENIUSLOCUSKIT_INTERFACE.md`.
- Single-estate nouns, bitmaps, the recall pipeline, container pruning,
  or the per-kit bitmap-audit trail — see `LOCUSKIT_SPEC.md`.
- Embeddings and ANN search — see `SYNAPSEKIT_SPEC.md`.
- CorpusKit's standalone document/passage storage policy — see
  `CORPUSKIT_SPEC.md`. GLK uses CorpusKit's attached-content mode.
- The job-queue mechanics the scheduler dispatches over — see
  `QUEUEKIT_SPEC.md`.
- Cross-device federation, the MCP wire protocol, and answer-assembly
  scope filtering — see `ARIA_MCP_SPEC.md`. GLK enforces the binary
  read gate locally; the wire boundary is the access surface's job
  (I-13).
- The hybrid-recall, dreaming, Bradley-Terry, and reward algorithms a
  standing signal's `emit` closure may call — those live in NeuronKit.
  GLK provides the scheduler and the emission contract, not the
  algorithms.
- The ARIA grammar the verbs realise — see `ARIALEXICONLIB_SPEC.md`.

## § 3 — Position in the kit family

```
  AriaLexiconLib  LocusKit  SynapseKit  CorpusKit  PersistenceKit  QueueKit
         \           \         |          /            /            /
          \           \        |         /            /            /
           +-----------+-------+--------+------------+------------+
                                  |
                            GeniusLocusKit       ← N estates, Brain layer,
                                  ▲                 grants, branches, migration
                                  │ composed by
                                  ├── NeuronKit    (recall/dreaming algorithms;
                                  │                 signal emit closures)
                                  └── aria-mcp     (estate exposed over MCP;
                                                    cross-device federation)
```

**Depends on:** `AriaLexiconLib` (the verb/noun/adjective vocabulary and
acceptance matrix), `LocusKit` (the single-estate tier and its nouns,
frames, recall stream, manifest, schema), `SynapseKit` and `CorpusKit`
(the per-estate vector and RAG tiers it composes), `PersistenceKit`
(`Storage`, schema declaration, and the in-memory backend the scheduler
mounts its queue on), and `QueueKit` (the serial-lane dispatch substrate
the scheduler owns one of per estate). Metal is not used here.

**Consumed by:** `NeuronKit` (the heaviest consumer — owns the
`GeniusLocusKit` actor, drives verbs, reads the unified audit log,
authors signal `emit` closures, derives branches) and `aria-mcp` (drives
verbs and the grant-gated federated read over the wire).
The `aria-mcp` access surface is implemented by `AriaMcpKit`.

## § 4 — Invariants

**I-1 (one handle, one estate):** an `EstateHandle` addresses exactly one
estate, keyed by its manifest `estate_uuid`. The handle is a value-type
ticket carrying a cached manifest snapshot (UUID, zoom window, name); it
holds no reference to the live `LocusKit.Estate` actor. A handle whose
registry entry has been closed is stale and every lookup of it raises
`GeniusLocusKitError.estateNotOpen`.

**I-2 (estate isolation):** estates are isolated by construction. Each
has its own injected `Storage`; the coordinator never shares a storage
across estates and the registry is keyed by handle, so no verb, read
fan-out, grant, or branch operation can cross an estate boundary except
through the explicit grant-gated `federatedRecall` path. A duplicate
`open` of the same estate UUID is refused (`duplicateEstate`) rather than
shadowing the live entry.

**I-3 (substrate access flows through the verb surface — B-1 of the
architecture):** the composed kits (LocusKit, SynapseKit, CorpusKit) are
reached only through GLK's estate verb surface. NeuronKit and CognitionKit
MAY import LocusKit to name read-only value types (e.g. `Drawer`,
`ContentKind`) in their inputs and outputs, but never call a LocusKit,
SynapseKit, or CorpusKit estate/verb/storage surface directly; all substrate
access is a verb applied to an `EstateHandle`. This is the structural form
of the architecture's layering rule and is the reason the verb surface, not
the composed kits, is GLK's consumed contract. Every consumer and test outside
GLK uses verbs and handle-scoped APIs only; `estate(for:)` is internal to the
GeniusLocusKit module and is never a public consumer surface.

**I-4 (queue authority):** GLK holds exactly one QueueKit instance per
estate, inside that estate's `StandingSignalScheduler`, mounted on a
dedicated in-memory backend. NeuronKit and CognitionKit never import
QueueKit. The scheduler is the only owner of the dispatch lane; signal
work reaches the substrate only by being enqueued and drained on that
lane.

**I-5 (single serial lane per estate):** each estate's scheduler drains
its queue through a single drainer at `.serializable` isolation
(the standing-signal scheduling contract). Exactly one job is
claimed at a time, FIFO; two signals' emissions against one estate never
interleave at job grain. There is no per-signal queue and no
cross-estate lane.

**I-6 (federation is mediated at the access surface — I-13):** the
substrate does not communicate with other substrates. GLK's
"federated read" is strictly device-local: both the source and the
requester are estates already open in the same kit instance. GLK opens
no socket, performs no handshake, and exposes no `federateWith(remote:)`
API; crossing the device boundary is aria-mcp's concern. What GLK
enforces is the binary read gate (B-7), not the wire.

**I-7 (parent never modified — I-15):** a COW branch is a logical copy of
its parent at derivation time. No branch operation — capture, promote,
merge, discard — ever writes the parent estate. Promotion and merge
re-capture branch content into the parent as new rows; they never mutate
the parent in place. Terminal branches retain their rows so the audit
trail stays accessible.

**I-8 (determinism — `now` passed in):** every engine computation is a
pure function of its inputs. Wall-clock time enters only as an explicit
parameter: `now: Date` on the scheduler `tick`, the grant `issueGrant`/
`revokeGrant`, `federatedRecall`, every migration verb, and the signal
`SignalContext`. No scheduler, matrix-tier fold, training-daemon pass,
grant store, or verifier reads the system clock internally.

**I-9 (dates stored as TEXT ISO8601):** the only date column GLK declares
is the `grants` table (`issued_at`, `revoked_at`); both are
PersistenceKit `.timestamp`, which maps to TEXT ISO8601, never REAL.
Rationale: human readability, string sortability, timezone correctness.

**I-10 (no Bool stored properties on entities):** GLK's persisted entity
is the `Grant`; its lifecycle state is carried in the unified audit log's
`before`/`after` `.bitmap` values (active-bit transition on issue/revoke),
not as a stored `Bool`. The `Bool` fields that appear on value types
(`ExpungeFrame.confirmation`, `UnifiedRowProjection.withdrawn`/`expunged`,
`TrainingThresholdDecision.isActive`) are transient frame inputs or
computed projection results, not stored entity columns.

**I-11 (unified audit log is a G-Set CRDT):** the per-estate
`UnifiedAuditLog` is a grow-only set keyed by each entry's SHA-256
content hash over its wire encoding. `add` is idempotent; `merge` is set
union and therefore commutative, associative, and idempotent. Entries
are immutable; two replicas producing the same logical mutation produce
identical IDs and dedupe on merge. Ingress (`add`, and therefore every
path that routes through it) unconditionally rejects an entry whose
stored id does not match its recomputed content hash — never re-admits
it, never overwrites a valid entry with the same id (codex a477800,
secfix ce-audit-content-id 5101e112). The rejection is counted
(`rejectedEntryCount` / Rust `rejected_count()`), monotonic and excluded
from structural equality, so a log's ingress history is observable
without weakening the defence (AUDIT-ALERT-RESTORE, 2026-07-09;
NeuronKit SPEC § 9 C-4/C-12).

**I-12 (HLC total order across tiers):** `UnifiedHLC` defines a total
order over `(physicalTime, logicalCount, nodeID)` with the same byte
shape and comparison as `SubstrateLib.HLC`. The audit projection, asOf
reconstruction, matrix rebuild, and chain verification all sort by HLC,
so they are order-independent given the HLC stamps.

**I-13 (verb-noun vocabulary is the lexicon's):** GLK's nine verb methods
map one-to-one onto `AriaLexiconLib.Verb`, in the same names. The
`(verb, noun)` legality the surface targets is the lexicon's § 7.2
acceptance matrix, checked as data through `AriaLexiconConformance`, not
re-derived.

**I-14 (transition gate excludes reads and grant events):** the training
daemon's admission gate counts only state-changing verbs (`capture`,
`mutate`, `withdraw`, `expunge`, `reanchor`). Read verbs (`recall`,
`propose`, `associate`, `learn`, `dreamCompact`, `migrate`) and the
federation grant/key verbs (`grantIssued`, `grantRevoked`, `keyDecayed`,
`physicalKeyDecayed`) do not advance the count. This is the same
partition the matrix rebuild uses to decide which entries feed F/O.

**I-15 (cross-version parity):** the Swift and Rust versions are
conformance-gated against shared test vectors across the whole surface —
the verb vocabulary, the audit log/projection/recovery, the scheduler
emission ordering, the matrix tier, the training daemon, and the grant,
federation, branch, and migration surfaces. Value-level results must
agree; neither version leads.

**I-16 (composite schema version derives from attached profiles):** the GLK
composite schema version derives from the live GLK-attached schema declarations
for LocusKit, SynapseKit, and CorpusKit. CorpusKit's standalone content,
passage/chunk, and removed-source schemas are not component declarations in a
GLK composite. Any attached-profile component bump advances the composite and
therefore the replication schema gate. Historical version 7 described the 1.0
layout; the 1.1 migration advances it rather than pretending that the old
`BundleStore` remains part of GLK.

**I-17 (one canonical content row):** LocusKit owns the canonical Drawer row and
`Drawer.id` in every GLK estate. GLK injects a LocusKit-backed
`CorpusContentSource` into CorpusKit. CorpusKit persists only derived retrieval
state keyed by that Drawer id and never stores Drawer text in a document,
passage, chunk, queue payload, or metadata copy.

**I-18 (passage chunking is dark in GLK):** GLK always selects
`CorpusIndexUnitPolicy.wholeContent`. Passage production and standalone chunk
compatibility types are unreachable from GLK and MOOTx01. Corpus BM25, vector,
provider-basis, counts, and checkpoints operate at Drawer identity; recall
returns that identity without a chunk-to-Drawer translation join.

**I-19 (migration preserves canonical state):** upgrading a legacy estate may
delete only redundant Corpus content/chunk rows and Corpus-derived indexes.
Canonical Drawers, their audit/history relationships, and unrelated
Drawer-keyed vector lanes are preserved. CorpusKit's derived BM25/vector and
provider basis/count state is rebuilt from Drawers before the Corpus lane is
made available.

**I-20 (historical migration is optional build baggage):** current-format GLK
runtime and attached CorpusKit composition contain no concrete historical
migration implementation. Each historical step is a separate capsule selected
at build time by a declared minimum estate-format floor. A consumer that starts
with fresh/current estates compiles no capsules; a consumer that supports floor
1.0 compiles the contiguous 1.0-to-1.1 and 1.4-to-1.5 capsules and refuses
estates below that floor before any destructive transition; floors 1.1, 1.2,
1.3, and 1.4 compile only the 1.4-to-1.5 capsule, because nothing separates
those stamps any more: the 1.1-to-1.2 step added a column CorpusKit's own
ladder adds, the 1.2-to-1.3 step added a LocusKit column that schema v19
removed, and the 1.3-to-1.4 step seeded a setting that retired (I-21, I-23).

**I-21 (estate format V1_2 — composition-policy column present; historical
record):** as of V1_2, `corpus_index_state` carries the `composition_policy`
column (TEXT NOT NULL DEFAULT ''). CorpusKit's checkpoint ladder (v2→v3)
adds it at open, so the 1.1→1.2 capsule that once stamped V1_2 no longer
exists; a 1.1-stamped estate proceeds straight to the 1.4→1.5 capsule. The
column was neither written nor read once the composition policy retired
(CorpusKit spec 1.28.0), and the 1.5→1.6 capsule drops it (I-25).

**I-22 (estate format V1_3 — distilled-source-digest column, schema 1–18
only):** as of V1_3, `drawers` carried the `distilled_source_digest` column
(TEXT NULL, LocusKit schema v18). Schema 19 (Encoder Rerank Program, ENC-W6B)
removed this column and the other stored-distillation columns; V1_3 estates
reaching schema 19 via upgrade no longer carry it. This invariant is retained
as a record for the V1_3/schema-18 era.

**I-23 (estate format V1_4 — the index composition policy was a stored
estate setting; historical record):** between V1_4 and GeniusLocusKit 2.22.0
the estate manifest carried `index_composition_policy`, an
`IndexCompositionPolicy.id` (`lex=<source>;dense=<source>`) naming which text
each search index lane was built from, seeded at creation and by the 1.3→1.4
capsule. Since schema 19 every id composed the same document, so the setting
retired with the policy (2.23.0): nothing reads the key, nothing writes it,
no capsule seeds it, and `mootx01 db composition` is gone. An estate that
stored the key still opens; the value is ignored and is not rewritten. Every
Corpus indexes the one composition: the content plus its `ssc_facts`
supplement.

**I-24 (estate format V1_5 — the schema-version ledger carries the SynapseKit
kit ids):** as of V1_5 the PersistenceKit schema-version ledger
(`_storagekit_migrations` on SQLite; the `schema_version:<kitID>` keys of
`_storagekit_meta` on PostgreSQL) records the vector tier under the kit ids
`SynapseKit` (the vector store, schema v6) and `SynapseKitClaims` (the
representation-claims ledger, schema v1). Estates written before V1_5 carry the
same two rows under `VectorKit` and `VectorKitClaims`, the kit's name before
it was renamed (that name collided with Apple's MapKit VectorKit framework).
The `StorageLedgerKitIDMigration` capsule (the 1.4→1.5 capsule) moves each row
to its new id through `Storage.renameSchemaKit(from:to:)` (PERSISTENCEKIT_SPEC
I-7a), keeping the row's version and applied-at instant, then stamps V1_5. The
rewrite is idempotent: an estate with no row under an old id is left as it is,
and a row already present under the new id is never overwritten (the old row
is then left in place and the capsule reports the conflict). The rewrite runs
before every other capsule in the chain, because the 1.0→1.1 capsule opens the
vector store, and before `wireSubstores`, because the store's own schema
ladder looks its version up by kit id: a store that finds no row treats the
estate as version 0 and replays its ladder from the start against the v6
layout, whose v5→v6 step rebuilds `vectors` through a copy table that folds
every row's generation to 0 (and fails outright when a serving and a shadow
row share a key) and leaves a duplicate ledger row under the old id. The
V1_5 stamp is written last,
after every older capsule has stamped its own format, so a crash mid-chain
never leaves an estate stamped V1_5 with an older capsule's work undone. The
stamp is also what protects a migrated estate from a pre-rename runtime: that
runtime reads a format newer than its own and refuses the open
(`unsupportedFuture`) instead of opening the vector store under the old id and
replaying. The rewrite runs in `GLKMigrationCatalog.prepare` (Swift) and
`run_migration_chain` (Rust), both reached by `mootx01 upgrade` (and `upgrade
--backfill-only`) and by every host that opens a populated estate. Fresh
estates are provisioned under the new ids from the start and stamp V1_5
without running the capsule.

**I-25 (estate format V1_6 — the composition-policy column is gone):** as of
V1_6, `corpus_index_state` carries no `composition_policy` column. CorpusKit's
checkpoint ladder drops it at schema v4 (CORPUSKIT_SPEC 2.1.0), but a
populated estate opens CorpusKit only through the composite estate
declarations, which carry no migrations, so the ladder never runs at serve
open. The `IndexCompositionColumnDropMigration` capsule (the 1.5→1.6 capsule)
replays the checkpoint ladder on the estate storage through
`Storage.migrate(to: CorpusIndexStateStore.schemaDeclaration)` and stamps
V1_6. The replay is correct on every estate shape: a ledger row at v3 replays
v3→v4 (the drop); no ledger row (the composite shape every provisioned estate
has) replays from version 0, where `addColumn` skips the columns already
present and the v3→v4 step drops the column; and a second run finds the
column gone and passes through, because PersistenceKit `dropColumn` is
idempotent (PERSISTENCEKIT_SPEC I-7b). Every checkpoint row survives with its
other fields intact. The capsule runs last in the chain, after the 1.4→1.5
stamp, so a crash mid-chain never leaves an estate stamped V1_6 with an older
capsule's work undone; it runs before `wireSubstores`, which opens the
engine over the migrated table. Reached by `GLKMigrationCatalog.prepare`
(Swift) and `run_migration_chain` (Rust), which `mootx01 upgrade` and every
host that opens a populated estate call. Fresh estates are created at
checkpoint schema v4 without the column and stamp V1_6 without running the
capsule.

**I-26 (estate format V1_7 — the whole-record float rows are gone):** as of
V1_7 a populated estate carries no `vectors` row of kind 1 (the float32
payload at `vector_index` 1 the retired whole-record dense lane read, 3.7.0)
and no `hnsw_graph` row (the float lane's approximate index), its binary
sidecar (`<estate>.vectors.vec`) is rebuilt from the surviving rows so its
live count and generation match the serving table, and the CorpusKit
consumer holds no representation claim on `vector_index` 1. The
`WholeRecordFloatVacuumMigration` capsule (the 1.6→1.7 capsule) does the
work through `VectorStore.reclaimWholeRecordFloatRows` /
`reclaim_whole_record_float_rows` (SYNAPSEKIT_SPEC), releases the lane-1
claims of the `corpus` consumer and stamps V1_7. Kind 0 (binary
fingerprints) and kind 2 (Arctic spans) are never touched, so the binary
lane returns the same ordered neighbours before and after. The CorpusKit
engine's default build claims lane 0 alone (CORPUSKIT_SPEC I-21), so its
reconcile never re-creates the released claim; under the `WholeRecordDense`
trait it claims lanes 0 and 1 again, and the capsule leaves an audition
estate's rows in place when the manifest's `embedding_provider` names a
whole-record provider (present, non-empty, not `encoder`), stamping V1_7
without deleting anything. Idempotent: a second run deletes nothing,
releases nothing and rewrites an identical sidecar. The capsule runs last in
the chain, after the 1.5→1.6 stamp, so a crash mid-chain never leaves an
estate stamped V1_7 with an older capsule's work undone; it runs before
`wireSubstores`. Reached by `GLKMigrationCatalog.prepare` (Swift) and
`run_migration_chain` (Rust), which `mootx01 upgrade` (whose whole-record
vacuum step is the first estate open of the sequence and reports the
reclaimed rows and bytes in one line, both ports) and every host that opens
a populated estate call. Fresh estates are born without the rows and are
stamped at the current format (V1_8) without running the capsule.

**I-27 (estate format V1_8 — the fact-extraction setting is present in
the manifest):** as of V1_8 a populated estate carries a `fact_extraction`
manifest key whose value is the plain string `"on"` or `"off"`. An estate
that already carried the key before the capsule ran keeps its stored value
unchanged; only an absent key is seeded with `"on"`. The
`FactExtractionSettingMigration` capsule (the 1.7→1.8 capsule) does the
seeding through `GeniusLocusKit.runFactExtractionSettingMigration` /
`run_fact_extraction_setting_migration` and stamps V1_8. Idempotent: a
second run finds the key already present, skips the write, and re-stamps
V1_8 as a no-op. Reached by `GLKMigrationCatalog.prepare` (Swift) and
`run_migration_chain` (Rust), which `mootx01 upgrade` and every host that
opens a populated estate call. A fresh estate is created at the current
format and carries no `fact_extraction` row until one is provisioned. The
accessor reads an absent key as `"on"`, so the setting reads the same on a
fresh estate as on a seeded one.

**I-28 (estate format V1_9 — the five remaining preferences are present in
the manifest and the rating table exists):** as of V1_9 a populated estate
carries a manifest key for each of `consolidation`, `contradiction_sweep`,
`cross_encoder_routing`, `maintenance` and `adaptive_recall` whose value is
the plain string `"on"` or `"off"`, and carries the `recall_ratings` table
(`drawer_id TEXT PRIMARY KEY NOT NULL, rating REAL NOT NULL, contests
INTEGER NOT NULL, updated_at TEXT NOT NULL`, schema ladder kit id
`GLKRecallRatings` version 1). An estate that already carried a key before
the capsule ran keeps its stored value unchanged; only an absent key is
seeded with `"on"`; the capsule never overwrites. A storage error on the
read propagates rather than reading as absent. The `PreferenceSeedMigration`
capsule (the 1.8→1.9 capsule) does the seeding through
`GeniusLocusKit.runPreferenceSeedMigration` / `run_preference_seed_migration`,
creates the table through the storage schema ladder and stamps V1_9.
Idempotent: a second run finds every key present and the ladder at version
1, skips both writes, and re-stamps V1_9 as a no-op. Reached by
`GLKMigrationCatalog.prepare` (Swift) and `run_migration_chain` (Rust) as
the last capsule of the chain. A fresh estate is created at the current
format and carries no preference rows until one is provisioned; the accessor
reads an absent key as `"on"`.

## § 5 — Behavioral contracts

**B-1 (open composes then registers):** `open(storage:owner:)` opens a
`LocusKit.Estate` over the supplied storage, reads its manifest, derives
the `EstateHandle` (validating the UUID and the zoom window), refuses a
duplicate UUID, constructs a GLK-owned LocusKit-to-`CorpusContentSource`
adapter, and opens CorpusKit in attached whole-content mode over that adapter.
It then registers the estate, retains its storage for the grant surface, and
mints an empty `UnifiedAuditLog`. Opening attached CorpusKit must not register
standalone content/passage schemas. `close(_:)` flushes
the estate, drops the registry entry, the audit log, and the grant
surface; a refusing flush still drops the entry so a dead handle never
lingers.

**B-2 (verb dispatch and error normalisation):** each verb resolves the
handle through GLK's internal registry first (so a stale handle uniformly raises
`estateNotOpen` regardless of substrate state), then dispatches to the
estate body. `capture`, `recall`, `withdraw`, `mutate`, `expunge`,
`reanchor`, and `learn` dispatch to their `LocusKit.Estate` bodies.
`propose` and `associate` dispatch through the `Proposal` and
`Association` noun stores. `expunge` with `confirmation == false` and
`reanchor` with neither target raise `VerbError.expungeNotConfirmed` /
`.emptyReanchor` at the boundary before dispatch. A `(verb, noun)` pair
the § 7.2 acceptance matrix rejects raises `VerbError.rejectedByLexicon`.
Any other estate error becomes `VerbError.underlyingEstateFailure`; a
`GeniusLocusKitError` passes through unchanged.

**B-2a (expunge cross-kit vector delete — fail-closed privacy contract with
deferred audit seal):**
`expunge` is a three-step operation at the GLK boundary, with the success
audit sealed only after ALL steps complete (§B-2a audit-seal ordering
invariant):

Step 1 (LocusKit storage; Swift `estate.expungeReturningUnsealedEvent(...)`,
Rust `estate.expunge(..., seal_audit: false)`): validates the confirmation
flag and S-3 state gate, tombstones the gate-admitted lineage members, and
zeroes their content blobs — atomically. The gate produces an `AuditEvent`
(the substrate record) but does NOT append it to the audit log yet. The call
returns the full `ExpungeOutcome` (LOCUSKIT_SPEC B-8b): the unsealed event
plus `refusedSiblingIDs` — the accepted lineage members the gate refused and
preserved byte-identical.

Step 2 (GLK orchestration, derived-state delete): when a `Corpus` is registered
for the estate, call `Corpus.remove(sourceID: rowID)` to purge Drawer-keyed BM25,
Corpus vector, provider, and checkpoint state. When an independent GLK
`VectorStore` lane is registered, delete only rows for the exact Drawer id and
lane/model ownership, in this order: the distillation fingerprint lane
(`deleteAllVectors` / `delete_all_vectors` under `distillation-features-v1`),
the encoder span lanes (`deleteSpanVectors` / `delete_span_vectors` under
every `encoder_models` registry row's model id plus the encoder registered
for the session — the `spanEncode` duty writes its int8 span rows under the
encoder's own `<model>-w<window>` id, which is neither of the other two
lanes), then the corpus model lane (`deleteAllVectors` under the corpus
model id). The first two lanes are unconditional on the corpus handle. A
broad `destroyAllVectors` call is forbidden here. Canonical content was
already zeroed by LocusKit in step 1; CorpusKit has no verbatim copy to
scrub. With no Corpus or vector lane (`.locusOnly`), step 2 is a no-op.

The `spanEncode` duty re-reads the drawer immediately before each span
write and skips the write (bit 27 stays clear) when the drawer is missing or
tombstoned, or when its current content no longer hashes to the content
version stamped on the spans, so an encode that was in flight when the erase
landed cannot recreate span rows for the erased drawer.

**Scrub scope (MXE-FA):** the step-2 fan-out covers the lineage chain MINUS
the gate-refused siblings — vectors are deleted only for members the storage
expunge actually scrubbed. A refused sibling's content survives, so its
vector must survive with it; deleting it would produce a third inconsistent
state (a row readable by id but invisible to search).

Step 3 (audit seal):
- **On success (steps 1+2 both complete):** GLK calls
  `estate.sealExpungeAudit(event)`, which appends the gate-produced event
  to the substrate audit log as `verb = "tombstone"`. The audit record states the
  actual outcome: the full expunge (storage + cross-kit delete) succeeded.
- **On step-2 failure:** GLK calls `estate.sealExpungeOrphanAudit(...)`,
  which appends an `"expungeOrphan"` event to the substrate audit log, then
  throws `VerbError.crossKitVectorDeleteFailed`. The audit record states the
  actual outcome: the storage half succeeded but the cross-kit vector delete did not. The
  caller must NOT report the row as fully deleted.

The `"tombstone"` and `"expungeOrphan"` substrate verb strings both map to
`UnifiedAuditVerb.expunge` in the unified log (via `AuditBridge`/`verb_from_str`).
Consumers needing to distinguish a clean expunge from a partial one must read
the substrate audit trail directly (the verb string is preserved there as-is).

**Partial outcome (MXE-FA):** the verb returns `ExpungeVerbOutcome`
(`refusedSiblingIDs` / `refused_sibling_ids`; Swift not `@discardableResult`,
Rust `Result<ExpungeVerbOutcome, VerbDispatchError>`). Binding invariant: **no
layer reports success for an expunge that refused a sibling.** ARIA's
`moot_erase_memory` reports a partial expunge as partial, naming the refused
count and ids (ARIA_MCP_SPEC). GLK-internal consumers that cannot represent
partiality in their return shape (`defragVagueItem` / `defrag_vague_item`)
raise `VerbError.underlyingEstateFailure` instead of summarising the partial
cascade as success.

Direct LocusKit callers (bypassing GLK) use Swift `estate.expunge(...)` /
Rust `estate.expunge(..., seal_audit: true)` and retain the historical
single-call atomic contract — the audit is sealed inside the call, as before
— receiving the same `ExpungeOutcome`.

Both Swift and Rust ports implement this contract. Orphan-seal failures are
propagated: in Swift, a `sealExpungeOrphanAudit` failure is logged at `.fault`
level (OSLog) before rethrowing the step-2 error; in Rust, the seal-failure
string is folded into the `CrossKitVectorDeleteFailed.reason` field so callers
receive both failure descriptions from a single typed error.

**B-2b (expunge integrity sweep — crash-window remediation):**
`runExpungeIntegritySweep(_:now:)` is a maintenance function (not a verb) that
closes the crash-window audit gap for a single estate. The crash-window arises
when step 1 (LocusKit storage expunge) ran but the process crashed before step
3 (audit seal) and the orphan-seal recovery path also did not complete — leaving
the row tombstoned and content-zeroed but with no "tombstone" or "expungeOrphan"
audit event.

The sweep must be called AFTER all per-estate Corpus and VectorStore instances
have been registered (they are registered after `open`, not during it). Calling
it at application startup or on a periodic maintenance timer is sufficient.

Algorithm:
1. Query for tombstoned rows with no "tombstone" or "expungeOrphan" audit event
   (`tombstonedRowsWithoutExpungeAudit` on the underlying estate). A query
   failure is fatal (the orphan set is unknown; returns `GeniusLocusKitError`
   / `GeniusLocusKitError::UnderlyingEstateFailure` in Rust).
2. If the set is empty, return immediately (no-op; the common case on a healthy
   estate).
3. For each orphaned row:
   a. Re-attempt the cross-kit vector+corpus delete (same logic and lane
      order as §B-2a step 2: corpus removal, the distillation fingerprint
      lane, the encoder span lanes, the corpus model lane).
   b. Seal a synthetic "expungeOrphan" audit via `sealExpungeOrphanAuditSynthetic`
      / `seal_expunge_orphan_audit_synthetic`. Both the re-delete success and
      failure paths seal this event: the original gate event was lost in the
      crash window and cannot be reconstructed.
   c. On re-delete success + audit seal success: increment `remediatedCount`.
   d. On re-delete failure + audit seal success: increment `orphanedCount`.
   e. On audit seal failure: append a per-row error string (do NOT abort the
      sweep — continue to the next row).
4. Return `ExpungeIntegritySweepResult` (Swift) /
   `ExpungeIntegritySweepResult` (Rust) with the aggregate counts and any
   per-row error strings.

The "expungeOrphan" verb on a sweep-sealed event is indistinguishable from a
live-expunge orphan by verb string alone. Sweep events carry `beforeBitmaps:
nil` / `before_bitmaps: None` (the pre-tombstone snapshot was lost in the crash
window), while live-expunge orphan events carry the gate-computed before-bitmaps.
Consumers that need to distinguish sweep-sealed from live-sealed events can check
for the nil/None before-bitmaps field.

**B-3 (recall drains to an array):** the GLK `recall` verb drains
LocusKit's `RecallStream` fully and returns a materialized `[Drawer]`,
matching the shape of `fanOutRecall` and `federatedRecall` so the three
recall surfaces compose predictably. Callers needing a narrower materialized
read use the available bounded handle-scoped reads; GLK exposes no public
page-stream surface.

**B-4 (fan-out routes by zoom-window overlap):** `fanOutRecall(_:region:)`
consults exactly the open estates whose closed zoom-window interval
intersects `region` (`low <= h.zoomWindowHigh && high >= h.zoomWindowLow`),
runs the same frame against each, and returns one
`EstateRecallContribution` per contributing estate tagged with its
handle. An inverted region raises `invalidLatticeRegion`. An estate
closed mid-fan-out is skipped, not faulted. This is a local read router;
it performs no grant check (contrast B-7).

**B-5 (scheduler tick is deterministic, serial, FIFO):** `tick(now:)`
evaluates due signals in `SignalID.rawValue` order, invokes each due
signal's `emit(context)`, enqueues every returned emission on the estate's
single QueueKit lane with a monotonic HLC stamp, then drains the lane to
empty — one job at a time, FIFO, at `.serializable` isolation (I-5).
Interval triggers fire from `tick`; event and condition triggers fire
through `requestFire`. Same inputs in, same emission ordering out (I-8).

**B-6 (emission routing):** the drainer routes each emission by class
(architecture § 11.1): `propose` and `associate` dispatch through GLK's
verb surface, `mutateCandidate` is rewritten to a `propose` of kind
`mutateCandidate`, and `diagnostic` is recorded on the signal's report
without a verb call. A routed emission records `routed` in
`signalStatus` once its verb dispatch returns.

**B-7 (federated read is fail-closed, grantee-scoped, content-level-gated):**
`federatedRecall` resolves both handles (stale either side →
`estateNotOpen`), consults the **source** estate's grant store, keeps
active grants naming the requester as grantee (none →
`crossEstateReadRefused(.noActiveGrant)`), requires at least one
unexpired at `now` (all expired → `.grantExpired`), and only then reads
the source estate. Before returning, drawers whose `adjectiveSensitivity`
(bits 6–11 of `adjectiveBitmap`, scale-gapped raw values 0/16/32/48 for
normal/elevated/restricted/secret) exceeds `grant.contentLevel` are
excluded — this is the GLK-layer primary content-level enforcement. A
default grant (`contentLevel: 0`) exposes only normal-sensitivity rows.
A revoked grant is already dropped from `active()`, so a read after
revocation lands on `.noActiveGrant`.

GLK is the primary enforcer of the content-level gate regardless of
which caller invokes `federatedRecall` — callers that bypass the ARIA
access surface still receive sensitivity-narrowed results. Scope-subtree
narrowing (wing/room/lattice/singleRow) is NOT applied here; `grant.scope`
rides back as advisory metadata for the ARIA surface to apply as
defense-in-depth secondary per DECISION §10.

**CustodyMode recall-path enforcement:**
Each federated read enforces custody semantics BEFORE estate access:

| Mode | Recall-path rule |
|------|-----------------|
| `.mediated` (mode 1) | Vault must hold the scope key (`ScopeKeyVault.holdsScopeKey`). If no key is present (estate restarted, key revoked) → `.custodyRefused`. Spec B.1: "every read is a live request to the substrate." |
| `.handedOver` (mode 2) | No vault check. Expiry gate (step 4) covers the offline window. |
| `.decayDerived` (mode 3) | Grant lifetime field is the proxy for decay viability (known limitation: threshold/totalShares/driftRate are NOT persisted in the grants schema, so source-side share reconstruction is not possible). Lifetime expiry gate (step 4) covers the decay window. |
| `.timeAging` (mode 4) | The grant's **effective content level** attenuates over time per its `DecayPolicy`. The recall path computes `effective = max(floor, round(contentLevel · 0.5^(elapsed / halfLifeSeconds)))` where `elapsed = max(0, now − startedAt)`, using the injected `now` (deterministic, no wall clock). A grant whose effective level reaches `0` (only when `floor == 0`) has aged out of all access and is refused with `.custodyRefused`; otherwise the read proceeds and the **attenuated** level — not the grant's raw `contentLevel` — gates the content-level sensitivity filter (step 8). The decay policy persists in the dedicated `decay_half_life`, `decay_started_at`, and `decay_floor` columns. |

**Mode 4 — time-aging decay.**
The original Appendix B mode 4 modelled physical SRAM decay (a
hardware-retention decay technique): a grant whose capability attenuates over
time the way data retention in an unpowered SRAM cell decays. SRAM hardware is
not available as a substrate surface, so the shipped policy is a deterministic
**software** time-aging model with the same semantics: capability attenuates
over time. The
mode is named `timeAging` for that semantics, but the mode-4 discriminant slot
and the legacy `"physicalDecay"` token both decode into it — the slot was never
retired. `DecayPolicy` carries `halfLifeSeconds` (every half-life of elapsed
time halves the surviving above-floor level), `startedAt` (the decay-clock
origin, persisted separately from `issuedAt`), and `floor` (the residual
capability that never ages away). The half-life form reuses the
matrix-calibration decay constant family (math treatise §8). A legacy mode-4 row
with no decay columns receives documented defaults: a 30-day half-life
(`DecayPolicy.defaultHalfLifeSeconds`), `startedAt = issuedAt`, and `floor = 0`
— it migrates cleanly, never faulting as a corrupt row. Mode 4 requires no IP
clearance (it is a shippable software policy) and derives a handed-over scope
key like mode 2; the decay is a content-level attenuation, not a key mechanic.

If a mode is not handled above, fail-closed wins: refuse with `.custodyRefused`.

**InferenceRemainingBudget debit:**
Each federated read that succeeds the custody gate DEBITS the grant's
`inferenceRemainingBudget` by a fixed quantum (0.01 per read, yielding
~100 reads on a fresh 1.0 budget). The debit is:

- **Re-read before check**: the current stored budget is fetched from
  the grant store immediately before the guard, capturing any prior
  debits from the same session.
- **Atomic with the read**: the debit is written to the store BEFORE
  estate content is returned. No read succeeds without consuming budget.
- **Persisted**: Swift debits via SQLite UPDATE on the `grants` table.
  Rust debits via `Storage::transaction(Serializable)` → `RowStore::update`
  on the grants table; durable when the `SqliteStorage` backend is used,
  in-process when `InMemoryStorage` is used. Both verticals persist the
  debit before returning content. The Rust `GrantStore` is backed by
  `Arc<dyn Storage>` so the backend is injected at construction time —
  production code passes `SqliteStorage`; tests pass `InMemoryStorage`.
- **Fail-closed on zero**: `inferenceRemainingBudget <= 0.0` → refuse
  with `.budgetExhausted`. The refusal carries no content.
- **Clamp at zero**: debit amount is clamped so budget cannot go negative
  (`max(0.0, current - quantum)`).

Spec §6 is silent on the debit quantum. Chosen rule (fail-closed wins):
**0.01 per read** (~100 reads on a full 1.0 budget). This rule is
documented here as the enforced canonical value; future spec revisions
that change it must also update `GeniusLocusKit.budgetDebitPerRead`
(Swift) and `EstateCoordinator::BUDGET_DEBIT_PER_READ` (Rust).

**Rust concurrency model — double-spend prevention:**
Swift serialises all grant mutations through the actor's isolated
executor. Rust achieves the equivalent guarantee via `Mutex<EstateCoordinator>`:
`EstateCoordinator` is `!Sync`, so all concurrent callers contend on the
`Mutex` before reaching `federatedRecall`. The `debit_budget` call inside
the coordinator therefore never executes concurrently for the same estate —
the per-call `Storage::transaction(Serializable)` is a second defence
layer for the `SqliteStorage` backend. Together these two layers guarantee
that concurrent federated reads cannot drive budget below zero or
double-grant the last quantum in either vertical.

**Rust decode fail-closed contract:**
Grant rows read back from storage via `decode_storage_row` must fully
decode every field or return an error — permissive defaults (e.g.
`WholeEstate`, `Permanent`) are prohibited on real read-back. Any
corrupt or missing required field (`id`, `grantee_id`, `issued_at`,
`scope_json`, `lifetime_json`) produces `GrantStoreError::CorruptRow` or
`GrantStoreError::CorruptIssuedAt` rather than a silently degraded grant.
The epoch-0 substitution pattern is explicitly prohibited.

**§B-7 budget issuance rule:**
`issue_grant` (both Swift and Rust) defaults `inference_remaining_budget`
to `0.0` (fail-closed production default). This is correct for the storage
read-back decode path, but means a freshly issued grant has zero budget and
will be refused immediately at the `federatedRecall` budget gate.

**Callers that issue grants for federated access MUST call
`grantStore.setInferenceBudget(id:value:)` (Swift) /
`grant_store_mut().set_budget(id, value)` (Rust) immediately after
`issue_grant` to assign an explicit budget.** The canonical full budget is
`1.0` (~100 reads at the 0.01 quantum). Callers that need a narrower
budget set a smaller value. The 0.0 production default is intentional and
must never be changed to a permissive default in `issue_grant` itself: the
fail-closed contract applies at the issuance call site, not the
`issue_grant` implementation.

Test fixtures must follow the same rule: issue the grant, then set budget
explicitly. A test that calls `issue_grant` without a subsequent
`set_budget` will fail with `BudgetExhausted` on the first federated read —
this is the correct behavior exposing that the fixture is incomplete.

**B-8 (grant issue/revoke is signed, persisted, audited, custody-gated):**
`issueGrant` gates the custody mode first (mode 3 requires confirmed IP
clearance via `experimentalIPClearanceConfirmed: true`, else raises
`experimentalModeNotActivated`), loads the estate's Ed25519 identity,
builds and signs the grant over a canonical pipe-delimited payload,
persists it to the estate's `grants` table, derives the scope key per
custody mode (mode 1 retains in the vault and returns nil; modes 2 and 3
return the key and retain nothing), and appends a `grantIssued` audit
entry. `revokeGrant` writes the revocation
record, drops any mode-1 vault key (cryptographic clawback), and appends
a `grantRevoked` entry. Both append HLC-stamped entries that sort cleanly
and cannot break the chain.

**B-8a (sensitivity-unlock audit seam):** Four public methods on
`GeniusLocusKit` (`SensitivityAuditVerbs.swift`) provide the audit write
surface that `AriaMcpKit`'s `SensitivityGrantLedger` / `ToolDispatcher`
calls into to satisfy the "every grant, every denial, every
manual revocation, and every read served under an active grant is written
to the UnifiedAuditLog with tier, grant id, and timestamps"):
- `recordSensitivityGrantIssued(_:tier:grantID:expiresAt:now:)` — a
  `sensitivityGrantIssued` audit entry with `afterValue = .integer(expiresAt_epochMs)`.
  `grantID` (a fresh caller-minted UUID) occupies `rowID` as the grant's
  synthetic identity; correlates with the matching revocation entry.
- `recordSensitivityGrantDenied(_:tier:now:)` — a `sensitivityGrantDenied`
  entry; a fresh UUID is minted for the denial event (no grant to correlate).
- `recordSensitivityGrantRevoked(_:tier:grantID:now:)` — a
  `sensitivityGrantRevoked` entry; `grantID` is the SAME id used in
  `recordSensitivityGrantIssued`, allowing the two entries to correlate by
  `rowID`. `beforeValue = .integer(1)`, `afterValue = .null`.
- `recordSensitivityReadUnderGrant(_:tier:drawerID:now:)` — a
  `sensitivityReadUnderGrant` entry; `rowID` here is the DRAWER's own UUID
  (not a grant id), because this event is about a specific row. A malformed
  `drawerID` is silently skipped without error — audit recording is
  best-effort observability on the read path, never a gate.

All four use `sensitivityGrant*` verbs (not the federation-reserved `grantIssued`/
`grantRevoked`), appended via `storage.auditLog.append(event)` (awaited,
`async throws` — a failed durable append surfaces to the caller). The `fieldPath`
slot carries the `AdjectiveSensitivity` tier token (`"restricted"` or `"secret"`),
making entries self-describing. Entries are readable through `auditLog(for:)` via
`AuditBridge`'s synthetic-verb decode path (no new storage schema needed). Rust
parity: `EstateCoordinator` exposes the four methods under snake_case names with
`now_ms: i64` (epoch-ms) in place of `now: Date`.

**B-9 (audit feed, projection, recovery):** `auditLog(for:)` (exposed to
NeuronKit as `currentAuditLog(in:)`) issues a single bounded SQL query
against `_storagekit_audit`, bridges the rows to `UnifiedAuditEntry`
values, and folds them into a freshly-built `UnifiedAuditLog` via
`add(contentsOf:)` (idempotent by content hash, I-11) — replacing the
former N+1-per-drawer `feedAuditLog(for:)` walk into a persistent
registry under the storage-residency rule; the returned
log is a value-type snapshot, not accumulated state. `AuditProjectionFold.project`
folds the HLC-ordered log into per-row state; the asOf variant folds only
entries at or before a cutoff HLC. `AuditRecovery.rebuild` replays the
log into a `UnifiedProjection` and `verify` compares a rebuilt projection
against an expected one field-by-field. All are order-independent given
HLC (I-12).

**B-10 (chain verification):** `verifyAuditChain(_:)` feeds the log, then
runs `AuditChainVerifier.verify`, returning an `AuditChainReport` per the
NeuronKit § 3.5 contract: `valid == true` and `firstBrokenAt == nil` on a
clean chain (including an empty one); on the first entry whose stored ID
does not match its recomputed content hash or whose HLC reverses,
`valid == false` with `firstBrokenAt` set to that entry's timestamp.
Because ingress (I-11) rejects a content-hash-mismatched entry before it
can ever reach this walk, `valid` alone cannot surface ingress-level
tampering — the snapshot's `rejectedEntryCount` (I-11) is the
complementary signal; NeuronKit's maintenance daemon reads both (SPEC §
9 C-4).

**B-11 (branch derive/promote/merge preserve the parent):** `glkDeriveBranch`
snapshots the parent's (or parent branch's) current rows into a fresh
in-memory branch estate at `lineageDepth` one greater than the parent's;
the snapshot IDs are recorded. `glkPromoteBranch` re-captures the
branch's post-derivation rows into the parent and marks the branch
`.won`; `glkMergeDrawers` cherry-picks named rows and marks it `.merged`,
returning a `MergeReport`. Both assert the destination is the branch's
parent estate (`invalidPromotionTarget` otherwise) and reject a branch not
tracked by this kit (`branchNotTracked`). The parent is never modified in
place (I-7).

**B-12 (training daemon is threshold-gated):** the daemon counts
state-changing transitions in the unified log (I-14) and, below the
manifest-set threshold (default 500), runs no enrichment and moves no
matrix cells — it surfaces a dormant diagnostic only, leaving its
watermark at `.zero` so the first open-gate tick folds the full backlog.
At or above threshold it runs the enrichment pipeline over entries past
its watermark, advances the watermark, and returns a `TrainingDaemonTick`.

**B-13 (matrix tier — incremental equals rebuild):** the F/C/O/T tier
accumulates counts incrementally on the capture path (`applyCapture`,
opposite sign on expunge) and can be fully rebuilt by replaying the
HLC-ordered unified log (`MatrixTier.rebuild`); the two paths produce a
cell-equal tier. C is derived as F / live-row-count. O and T decay lazily
by half-life; F and C do not decay (population statistics are stable).

**B-14 (migration orchestration; ingestion retired to VaultKit):** GLK
ships two migration verbs. `verifyMigration` issues one content-match
recall per corpus entry and returns `.identical` only when every entry
is recallable, else `.diverged` with the missing entries. `runParallel`
returns a `ParallelRunHandle` that routes captures per
`ParallelCaptureMode` until `stop()`. Mass data ingestion is NOT a GLK
verb: per the data-movement contract Decision 1 the flat import verb is
retired, superseded by VaultKit's adapter → bridge path
(`ExchangeAdapter` → `VaultBridge.importVault`), which provides
idempotent re-import, link reconstruction, and per-entry provenance
(`.importedFile` channel, `imported` source type). The reference corpus
`verifyMigration` consumes is fed by VaultKit's `CorpusProjection` from
the same adapter pipeline. The zero-loss invariant (C-13) is enforced on
the VaultKit path: skipped notes and dropped fields are recorded in
`ImportReport`, never silent.

**B-15 (Rust write-path surface):** the Rust
`EstateCoordinator` exposes four write methods that mirror the Swift
`VerbSurface.captureKGFact` / `retireKGFact` and `DreamingWrites.addDiaryEntry`
/ `readDiaryEntries` surfaces. These methods are required because
`locus_kit::Estate::store` is `pub(crate)`, so GeniusLocusKit must reach the
store through `estate_verbs` pass-throughs (B-1/I-3). Contracts:

- `add_kg_fact` allocates a UUID v4 `id`, writes the fact with
  `adjective_bitmap = 0` (State::Active), and returns the stored struct. The
  returned fact appears in `recall_kg_facts` (`g_state_cluster 0 < 7`).
- `withdraw_kg_fact(handle, id, changed_by, reason, now)` routes through
  `audit_gate::admit` with verb `Retract`, sets bits 0-5 of the fact's
  `adjective_bitmap` to `State::Withdrawn` (raw 18) preserving bits 6+
  (sensitivity, exportability, trust, flags), and appends a sealed audit row
  in the same transaction. After withdrawal `g_state_cluster = 18 ≥ 7`, so
  the fact is excluded from the `recall_kg_facts` active filter. The row is
  never deleted. `changed_by` must be non-empty. The Swift `retireKGFact`
  pass-through carries the same `changedBy` and `reason` parameters.
- `add_diary_entry` sets `wing = "wing_<agent_name>"` and `room = "diary"`;
  an empty `embedding_model_id` is substituted with `"no-embedding"` (mirrors
  the Swift `DreamingWrites.addDiaryEntry` guard for autonomous diary writes
  that carry no embedding). A UUID v4 `id` is allocated and the stored entry
  is returned.
- `diary_entries` delegates to `DrawerStore.read_diary`; results are ordered
  and capped by `last_n`.

All four methods return `VerbDispatchError::EstateNotOpen` on an unregistered
handle, `VerbDispatchError::Verb(...)` wrapping an underlying `VerbError` on
store failures. Every write allocates a fresh UUID so no two calls in the same
coordinator share an id (deterministic with respect to inputs; UUID v4 entropy
is acceptable here as the id is opaque to callers).

**B-16 (recall drop is frame-faithful — both ports):** the RecallDirector's
corpus/vector hydration join honors the recall frame's state filter. A
BM25/vector-lane candidate whose drawer the frame EXCLUDES (e.g. a `.withdrawn`
drawer under the default `.currentlyBelieve`, or any tombstoned row) is DROPPED
from the result — it must NOT surface as a `RecallHit` with `drawer == nil`
(no nil-drawer phantom). The SAME candidate SURFACES when the frame overrides
the state axis (e.g. `.usedToBelieve`): the drop is the frame's, not a constant.
Both ports agree for the default frame and any override.

- **Rust** derives the hydration `drawer_index` from a frame-filtered
  `estate.recall(frame)` scan and drops fused candidates absent from it via
  `.filter(|(id,..)| drawer_index.contains_key(id))`.
- **Swift** builds the equivalent `drawerIndex` via the LocusKit frame-aware
  by-id load `getDrawers(ids:matchingFrame:hydrationLevel:)` (LOCUSKIT_SPEC
  B-12), across all three emit sites (`unionBest` step 5.5/11, `corpusOnly`
  hydrateHits, `hybrid` extra-IDs hydration).

Note (pre-existing scope-bound asymmetry, not a correctness concern): the Rust
`corpusOnly` path derives `drawer_index` from a `frontier_k`-bounded
`estate.recall(frame).take(frontier_k)` scan (≤256 rows), so a BM25/vector
candidate that is frame-admissible but ranks beyond `frontier_k` in the locus
scan is absent from `drawer_index` and dropped in Rust, whereas Swift's by-id
load fetches exactly the fused candidates and admits it. This affects only WHICH
frame-admissible candidates surface at very large estate sizes, never whether a
frame-EXCLUDED candidate is dropped (the B-16 guarantee, identical both ports).
It predates this work and is tracked separately.

The drop is GATED on by-id load success: an id that loaded but failed the frame
filter is dropped; an id that did NOT load (a transient/partial read; the
by-id load threw or returned a partial set) is degraded gracefully — kept — so
a valid ACTIVE drawer that is merely not-yet-joined is never dropped. The
forced-`getDrawers`-failure degradation contract (query survives on lane
signals, stage recorded in `degradedStages`) is preserved.

**B-17 (legacy Corpus-to-Drawer migration):** opening a pre-1.1 GLK layout
enters a migration gate before the Corpus lane becomes queryable:

1. Validate that every active legacy Corpus source maps to an existing
   canonical Drawer and record any mismatch as a migration failure; do not
   synthesize Drawers from chunks.
2. Drop legacy GLK-only copied content/chunk tables, chunk-source maps,
   removed-source rows, and stale Corpus-derived BM25/vector/provider state.
   Preserve Drawers, Drawer audit/history, tunnels, facts, diary rows, and
   vector rows outside CorpusKit's declared ownership scope.
3. Open CorpusKit in attached `.wholeContent` mode, rebuild BM25, Corpus-scoped
   vectors, provider basis/counts, and checkpoints from the Drawer source.
4. Verify canonical-id coverage and sample recall/hydration. Only then advance
   the schema/checkpoint and make the Corpus lane non-dark. Failure leaves
   LocusKit recall available and Corpus recall explicitly degraded/dark.

The migration capsule is not called by the current GLK core. MOOTx01 and Aria
build the floor-1.0 catalog and invoke it before current-runtime CorpusKit wiring;
fresh SDK consumers omit that dependency/feature. Each subsequent migration
must declare its source/target versions and join the same contiguous catalog so
raising the compiled floor removes all lower capsules.

Entry gate (both ports, Rust since 3.9.0). The catalog reads the persisted
estate format before any capsule runs and dispatches from it:
an unstamped estate is a fresh bare open and is stamped current with no
capsule run; a current estate returns at once; a stamp above the current
format is refused (`unsupportedFuture` / `UnsupportedFuture`); a stamp below
the compiled floor is refused (`belowCompiledFloor` / `BelowCompiledFloor`);
a historical stamp in a build whose chain does not reach the current format
is refused (`noHistoricalMigrationsCompiled` /
`NoHistoricalMigrationsCompiled`). A refusal writes nothing. The capsules
then run only for the stamps below their target: the shared-content capsule
for a stamp below 1.1, the ledger-id capsule for a stamp below 1.5, the
column-drop capsule for a stamp below 1.6, the whole-record float vacuum
capsule for a stamp below 1.7. Rust reports the refusals through
`MigrationChainError`; pinned by `rust-migrations/tests/migration_chain_tests.rs`
under any floor above 1.0.

The migration streams in stable Drawer-ID order. Pure tokenization and
stateless embedding compute run in bounded parallel batches; all durable writes
remain ordered/serial and the cursor advances only after the batch commit.
Trainable bases commit atomically before per-model backfill. A crash either
restarts basis training from zero or resumes deterministic upserts from the last
durable cursor. Before the first destructive state, the five-signal rebuild
checks a conservative working-set requirement (`2 GiB + 320 KiB × active
content`) against 80% of physical RAM, or the lower operator-supplied
`MOOT_MIGRATION_MEMORY_BUDGET_BYTES`, and refuses when it cannot complete
safely. It must not retain copied passage text as a compatibility cache.
Selective deletion is mandatory; an unqualified `destroyAllVectors` is a
migration defect.

Migration verification also covers MX-TAB: dataset-handle Drawers and their
backing typed tables are excluded from CorpusKit and must retain canonical rows,
schema/index declarations, statistics, signatures, and handle identity.

## § 6 — Error model (conceptual)

| Category | Trigger | Recovery posture |
|---|---|---|
| `GeniusLocusKitError.estateNotOpen` | a handle is stale or was never issued by this kit | surface; the addressed estate is closed — the caller reopens or abandons |
| `GeniusLocusKitError.duplicateEstate` | `open` of an estate UUID already in the registry (I-2) | surface; almost always the same database opened twice |
| `GeniusLocusKitError.invalidManifest` | the opened estate's manifest is malformed (bad UUID, inverted zoom window) | surface; the estate's on-disk manifest is wrong |
| `GeniusLocusKitError.underlyingEstateFailure` | a composed `LocusKit.Estate` lifecycle call failed | surface; wraps the underlying diagnostic without leaking LocusKit's taxonomy |
| `GeniusLocusKitError.invalidLatticeRegion` | a fan-out region has `low > high` | surface; a programmer error, distinct from an empty result |
| `GeniusLocusKitError.schedulerSignalNotRegistered` / `.schedulerNotStarted` | a signal handle or the scheduler itself is referenced before registration | surface; an ordering fault, not an empty response |
| `GeniusLocusKitError.branchNotTracked` / `.invalidPromotionTarget` | a branch was not derived by this kit, or promotion targets a non-parent estate | surface; protects the parent-never-modified and per-estate-key boundaries (I-7) |
| `GeniusLocusKitError.crossEstateReadRefused` | the source holds no valid grant naming the requester (B-7) | surface, never silently empty — the executable A-versus-C refusal |
| `VerbError.rejectedByLexicon` | a `(verb, noun)` pair the § 7.2 acceptance matrix rejects | surface; the verb is not legal on the addressed noun |
| `VerbError.emptyReanchor` / `.expungeNotConfirmed` | a frame fails a boundary precondition before dispatch | surface; a deliberate two-step / non-no-op protocol guard |
| `VerbError.crossKitVectorDeleteFailed` | LocusKit storage expunge succeeded but the cross-kit vector delete (Corpus.remove / VectorStore.deleteAllVectors / VectorStore.deleteSpanVectors) threw | surface immediately, never swallow — a surviving embedding of content the user believed was irreversibly destroyed is a privacy breach; the row's verbatim content is already zeroed but the caller must NOT report the row as fully deleted |
| `GrantError` | a gated custody mode, a missing identity key, an expired/revoked/decayed grant, or an absent grant id | surface; mode 3 is gated behind IP clearance, mode-3 decay past threshold is unrecoverable (no partial recovery); mode 4 (time-aging) ships ungated and attenuates on the recall path |
| `MigrationError` | an unreadable corpus, a capture on a stopped parallel run, or a closed target estate | surface; a migration-surface fault isolated from the estate error space |
| `MatrixPersistenceError` | a matrix snapshot could not be loaded or saved | surface; the snapshot is corrupt or the backend is unavailable |

All categories are programmer/protocol or substrate-fault conditions, not
silent fallbacks. `GeniusLocusKitError` is the coordinator/lifecycle
surface; `VerbError` is the verb-dispatch surface; `GrantError`,
`MigrationError`, and `MatrixPersistenceError` are the additive
sub-surfaces (declared standalone because Swift cannot add enum cases by
extension).

## § 7 — Conformance requirements

**C-1 (lifecycle + isolation):** `open`/`close` and internal registry
resolution admit, remove, and resolve estates by handle; a duplicate UUID is refused
(`duplicateEstate`); a stale handle resolves to `estateNotOpen`; no
operation crosses an estate boundary except `federatedRecall` (I-1, I-2,
B-1).

**C-2 (verb surface + lexicon conformance):** the nine verbs dispatch per
B-2, normalising boundary errors to the documented `VerbError`
cases; every GLK verb maps to its `AriaLexiconLib.Verb` and every surface
`(verb, noun)` target is accepted by the § 7.2 matrix
(`AriaLexiconConformance.everySurfaceTargetIsAccepted`) (I-13, B-2).

**C-3 (fan-out overlap):** `fanOutRecall` consults exactly the
zoom-window-overlapping estates, returns one contribution each, raises on
an inverted region, and performs no grant check (B-4).

**C-4 (scheduler serial lane):** a tick evaluates due signals in ID order
and drains FIFO through one `.serializable` lane; two signals' emissions
never interleave at job grain; identical inputs produce identical drain
order (I-5, I-8, B-5, B-6).

**C-5 (audit CRDT + projection + recovery):** `UnifiedAuditLog` `add` is
idempotent and `merge` is commutative/associative/idempotent on every
shared vector; the projection, asOf reconstruction, and recovery rebuild
are order-independent given HLC; `verifyAuditChain` reports per the § 3.5
shape (I-11, I-12, B-9, B-10).

**C-6 (matrix incremental == rebuild):** for any capture/expunge sequence,
`MatrixTier.rebuild` from the log produces a cell-equal tier to the
incremental path; C = F / live-row-count; O/T decay by half-life while
F/C do not (B-13).

**C-7 (training gate):** the daemon is dormant below the threshold (no
enrichment, watermark unmoved) and active at or above it; the transition
count excludes read and grant/key verbs (I-14, B-12).

**C-8 (grants fail-closed):** `federatedRecall` refuses absent a valid
grantee-named grant and never returns silently empty; `issueGrant` signs,
persists, and audits; `revokeGrant` clamps mode-1 keys and audits; mode 3 is
gated behind IP clearance before any key work; mode-3 decay past threshold
raises `keyDecayed`; mode 4 (time-aging) attenuates the effective content
level over time and refuses with `.custodyRefused` once it decays to the floor
of 0 (B-7, B-8).

**C-9 (COW branch isolation):** derive/promote/merge never modify the
parent in place; promotion/merge re-capture into the parent and reject a
non-parent destination or an untracked branch; terminal branches retain
rows (I-7, B-11).

**C-10 (migration zero-loss):** every corpus entry lands as a drawer or an
unmapped concept (counts sum to corpus size); `verifyMigration` is
`.identical` iff every entry is recallable (B-14).

**C-11 (determinism):** running any tick, grant issue, federated read,
matrix fold, training pass, or migration twice with identical inputs and
the same injected `now` produces identical results; no engine reads the
system clock (I-8).

**C-12 (cross-version parity, I-15):** the Swift and Rust versions produce
identical value-level results across the whole gated surface — C-2 (verb
vocabulary), C-4 (scheduler ordering), C-5 (audit/projection/recovery),
C-6 (matrix), C-7 (training), and the grant, federation, branch, and
migration surfaces — against the shared `glref` vectors.

**C-13 (shared content and migration):** a black-box suite runs the same
capture/change/remove/rebuild/recall cases against standalone CorpusKit and the
GLK attached adapter. For GLK it additionally asserts one verbatim Drawer row,
zero Corpus document/passage/chunk rows, Drawer-id results, passage policy dark,
and survival of unrelated vectors across legacy migration (I-17…I-19, B-17).



---

## § 8 — DreamingSubstrateReader adapter (EstateDreamingReader)

`EstateDreamingReader` is the production adapter that binds
NeuronKit's `DreamingSubstrateReader` protocol seam to the live
GeniusLocusKit estate surface. It is declared in NeuronKit
because that is the only package that can import both the protocol
(NeuronKit) and the estate surface (GeniusLocusKit) without creating
a circular package dependency.

GeniusLocusKit supports the adapter through three new public
extension methods (`DreamingReads.swift`) that follow the same
handle-resolution pattern as `recallTunnels`:

```swift
func recentRecallTraces(in handle: EstateHandle, since: Date, now: Date)
    async throws -> [RecallTraceItem]
func allTunnels(in handle: EstateHandle) async throws -> [Tunnel]
func allDrawers(in handle: EstateHandle) async throws -> [Drawer]
```

The adapter holds an `EstateHandle` and a `GeniusLocusKit` reference
and delegates the three `DreamingSubstrateReader` requirements:

1. `recentRecallTraces(since:now:)` → `GeniusLocusKit.recentRecallTraces(in:since:now:)` → `Estate.recentRecallTraces` → `DrawerStore.recentRecallTraces` — windowed reward-window query.
2. `coOccurrenceObservations()` → `GeniusLocusKit.allDrawers(in:)` → v1 room-grouping algorithm: drawers sharing a room are emitted as co-occurrence pairs.
3. `existingTunnels()` → `GeniusLocusKit.allTunnels(in:)` → `Estate.allTunnels` → `DrawerStore.allTunnels` — estate-wide tunnel set for duplicate suppression.

The Rust port implements the same adapter over a synchronous
`DrawerStore` trait reference; reads are snapshotted at construction
time to match the Rust `DreamingSubstrateReader` trait's sync method
signatures.



---

## § 9 — DreamingProposalSink adapter (EstateDreamingSink)

`EstateDreamingSink` is the production adapter that binds NeuronKit's
`DreamingProposalSink` protocol seam to the live GeniusLocusKit estate
write surface. It is declared in NeuronKit
for the same circular-dependency reason as `EstateDreamingReader`: a
conforming type must import NeuronKit, and GLK cannot import NeuronKit
without inverting the layering.

GeniusLocusKit supports the adapter through two new public extension
methods in `Brain/DreamingWrites.swift`:

```swift
func addDiaryEntry(in handle: EstateHandle, _ entry: DiaryEntry) async throws
func readDiaryEntries(in handle: EstateHandle, agentName: String, lastN: Int = 10) async throws -> [DiaryEntry]
```

The `addDiaryEntry` method builds a `DrawerStore` lazily from the estate's
retained `Storage` and caches it per handle, following the GrantStore pattern.
It substitutes `"no-embedding"` for an empty `embeddingModelID`
so autonomous daemon diary entries (which carry no vector) satisfy the
storage layer's non-empty invariant without modifying the daemon.

The `GeniusLocusKit` actor gains one internal property:
`diaryStores: [EstateHandle: DrawerStore]`, dropped in `close`.

The adapter delegates both `DreamingProposalSink` requirements:

1. `propose(_:)` → `GeniusLocusKit.propose(_:_:)` → `Estate.propose` → `DrawerStore.addProposal` — creates a real `Proposal` row.
2. `recordCycleDiary(_:)` → `GeniusLocusKit.addDiaryEntry(in:_:)` → `DrawerStore.addDiaryEntry` — creates a real `DiaryEntry` row.

The dreaming daemon emits real proposals
and diary entries through `EstateDreamingSink` over a live GLK estate.

**DreamingSignal cold-path.** `DreamingSignal.spec(daemonCycle:)` accepts a
`@Sendable (Date) async throws -> [ProposeFrame]` closure. The caller
constructs a `DreamingDaemon` (NeuronKit) with production adapters
(`EstateDreamingReader` + `EstateDreamingSink`) and passes
`daemon.triggerDreamingCycle(now:).proposalsEmitted` as the closure.
GeniusLocusKit cannot import NeuronKit (circular package dependency), so the
closure is the architectural bridge between the two packages. An empty result
(zero proposals) is correct for an estate with no co-occurrence candidates;
a daemon cycle error surfaces as a `.diagnostic` emission on the signal's
record rather than silencing the signal. `registerDefaultStandingSignals`
exposes a `dreamingCycle:` parameter (defaulted to `{ _ in [] }`) so
registration without a live daemon remains possible for test scaffolds.

The Rust port implements the
same adapter over a `DrawerStore` trait reference. Propose calls
`store.add_proposal` with a `LatticeAnchor::udc("dreaming")` placeholder;
record-cycle-diary calls `store.add_diary_entry`. Row IDs are deterministic:
`dreaming-<now>-<counter>` per the determinism rule (no RNG in engines).

## § DISTILLATION — Active converter and representation currency

> **Schema 19 (Encoder Rerank Program, ENC-W6B):** the stored distillation
> columns (`distilled`, `distilled_pipeline_version`, `distilled_token_count`,
> `distilled_at`, `distilled_source_digest`) and the drain lane
> (`moot_redistill`, `mootx01 redistill`, `distillItemsSweep`) are removed.
> Distillation is now inline at read time: `GeniusLocusKit.distilledRendering`
> calls `ContextDistiller` per request; no representation is stored.
> `bit 19` (`hasCurrentRepresentation`) is retired alongside the columns.
> The section below is retained as a spec record for schema versions prior to 19.

## § MATRIXT_HOURLY — T-matrix population signal

`TemporalCausalitySignal` is wired as signal 7 in the default
standing-signal set.

### Standing-signal inventory update (§11.2)

The six v1 standing signals documented in §11.2 of the architecture spec have
been extended to fourteen: six always-on signals and eight preference-gated
signals. There is no stored-distillation signal. The current
registration order (`registerDefaultStandingSignals` / `default_standing_signal_specs`) is:

| # | Signal name | Cadence | Estate preference | Purpose |
|---|------------|---------|-------------------|---------|
| 1 | dreaming-daemon | 604 800 s (weekly) | always on | NMF, eigenvalue, T-matrix cold-path |
| 2 | vector-similarity | 300 s (5 min) | always on | HNSW proximity clustering |
| 3 | contradiction-scout | 3 600 s (hourly) | always on | Content-conflict pass: BM25 lexical candidates (corpus lane) + drawer-keyed Hamming kNN (lane 1) + ConflictCue screen → proposed contradicts tunnels |
| 4 | consolidation-sweep | 86 400 s (daily) | `consolidation` | One bounded consolidation sweep (`consolidationSweepReport` / `consolidation_sweep_report`) |
| 5 | anomaly-flag-sweep | 3 600 s (hourly) | always on | Room-cohesion anomaly sweep: sets/clears bit 26 (isAnomalous) via char-3-shingle Jaccard z-scores |
| 6 | span-encode | 30 s | always on | Index content spans and set spanIndexed (bit 27) after successful storage |
| 7 | fact-extraction | 300 s (5 min) | always on (`fact_extraction` gates the duty, not the signal) | Bounded fact extraction over bit-28 debt; the default closure is inert until the extractor recipe is activated |
| 8 | contradiction-sweep | 3 600 s (hourly) | `contradiction_sweep` | Tiered conflict-tunnel proposer (`proposeConflictTunnels` / `propose_conflict_tunnels`): files `contradicts` tunnels with lifecycle `.proposed` |
| 9 | maintenance-daemon | 3 600 s (hourly) | `maintenance` | Tombstone grace: `MaintenanceDaemon.triggerMaintenanceCycle(now:categories: [.tombstone])` / `run_cycle_scoped(…, tombstone)`; the closure returns `tombstoneCandidates` |
| 10 | decay-sweep | 86 400 s (daily) | `maintenance` | Quiet-row decay: the same call with `[.decay]`; returns `decayCandidates` |
| 11 | by-reference-validity | 604 800 s (weekly) | `maintenance` | By-reference drift: the same call with `[.byReference]`; returns `byReferenceDrifts` |
| 12 | temporal-causality-fold | 3 600 s (hourly) | `adaptive_recall` | T-matrix population pass (`runTemporalCausalityFold(_:now:)` / `run_temporal_causality_fold`) |
| 13 | training-daemon | 3 600 s (hourly) | `adaptive_recall` | Training-daemon tick (`runTrainingTick(_:now:)` / `run_training_tick`; the daemon's threshold gate decides whether to enrich) |
| 14 | end-of-day-tournament | 86 400 s (daily) | `adaptive_recall` | `GeniusLocusKit.endOfDayTournament(_:now:)` / `EstateCoordinator::end_of_day_tournament` (`Brain/EndOfDayTournament.swift`, `brain/end_of_day_tournament.rs`): recall traces in `[now − 24h, now]` grouped by minute of `recalledAt`; in each group with two or more distinct UUID targets the first-listed drawer beats the rest (one `PreferenceObservation`); a `SubstrateML.BradleyTerryEstimator` seeded from the stored `recall_ratings` rows observes the batch and the resulting Bradley-Terry strengths are upserted into `recall_ratings` with `contests` carried forward; returns `TournamentReport(contests:ratedDrawers:)` |

A preference-gated signal is registered only when its estate preference is
on (absent = on): the host reads the preference and hands
`registerDefaultStandingSignals` / `default_standing_signal_specs` the live
cycle closure only then; with no closure the signal does not exist on the
scheduler, so an opted-out estate carries no such signal at all. The
governor tick no longer pumps the maintenance daemon: the three
maintenance-family signals are the maintenance engine's only cadence.
`defaultStandingSignalNames` / `default_standing_signal_names` lists the six
always-on names; `preferenceGatedStandingSignalNames` /
`preference_gated_standing_signal_names` lists the eight gated names.

(Table rows are ordered as `registerDefaultStandingSignals` registers them;
the # column is registration order, not the historical signal number.)
`TemporalCausalitySignal` is registered through `spec(foldCycle:)` only when
the host passes `foldCycle:`; there is no default registration for it.
`ContradictionScoutSignal` is wired live by the resident
daemon via `huntCycle:` around `GeniusLocusKit.huntContradictions` (see
`Brain/ContradictionHunt.swift` — BM25 lexical candidate mining on the
corpus lane (drawer-keyed Hamming kNN on lane 1), SubstrateML
`ConflictCue` screen, strong cues captured as `contradicts` tunnels with
lifecycle `.proposed` / originClass `.derived`, borderline pairs returned
for BYOAI adjudication, durable dedup against every existing contradicts
tunnel including withdrawn ones). `AnomalySweepSignal` (signal 5, P3a) is
wired via its live `spec(anomalyCycle:)` factory; the `anomalyCycle` closure
wraps `kit.anomalyFlagSweep(handle:threshold:now:)` with the estate handle
and surfaces the changed-drawer count as a diagnostic. The no-op `defaultSpec()`
is appropriate for `registerDefaultStandingSignals` when no live sweep context
is yet available; production callers re-register with the live factory at daemon
wiring time. Both Swift and Rust ports
have a tested sweep implementation.

### Cadence decision

Cookbook §6.4 specified a weekly T-matrix update on the dreaming daemon pass.
This was superseded with hourly cadence.
See `docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#54-matrix-t`.

### MatrixTier additions

`MatrixTier` gained:
- `temporalWatermarkHLC: HLC` — HLC of the last audit entry processed by
  `rebuildTemporal`. Old snapshots decode with a `.zero` fallback (custom
  `CodingKeys` + `init(from:)` with `decodeIfPresent`).
- `rebuildTemporal(from: UnifiedAuditLog) -> MatrixTier` — static method that
  calls `TemporalCausalityFold.fold` (SubstrateML) at the GeniusLocusKit
  boundary and applies deltas via `applyTemporalEvent`. Separate from
  `rebuild(from:)` because T crosses pairs of rows, not individual rows.

`lagBucket(forMinutes:)` on MatrixTier now delegates to
`TemporalCausalityFold.lagBucket(forMinutes:)` so the canonical bucket
function lives in SubstrateML (the single authoritative definition for conformance vectors).

### Package dependency

GeniusLocusKit/Package.swift gained a dependency on SubstrateML to access
`TemporalCausalityFold`. Layering is correct: GeniusLocusKit (composition) →
SubstrateML (algorithms). Justified by
the temporal-matrix cadence.

## § RAG_WIRING — RAG and vector seams

Both seams are wired in Swift and Rust.

### ExternalCorpus hybrid recall

`ExternalCorpus.hybridRecall(via:limit:now:)` routes recall through
CorpusKit's `Corpus` actor. Each external entry's content is used as the query
to `Corpus.recall(query:limit:now:)`, which fuses vector kNN and BM25 keyword
scores via Reciprocal Rank Fusion. The result per entry is `[CorpusHit]`, keyed
directly by canonical GLK `Drawer.id`, with optional vector and keyword
evidence. `ScoredChunk` is not part of this GLK path.

The existing `asRecallFrames()` method is preserved for the
LocusKit-only content-match path used by `verifyMigration` (estate
existence checking, not hybrid retrieval).

**Corpus construction:** GLK constructs one `LocusDrawerCorpusContentSource`
adapter over the open LocusKit Estate and injects it into CorpusKit's attached
constructor with `.wholeContent`. The storage supplied to CorpusKit contains
only derived retrieval state; it does not contain another copy of Drawer
content. `CorpusEnsemble.defaultEnsemble()` in Swift and `default_ensemble()`
in Rust return random indexing in the default build. Its fingerprints serve
dreaming and consolidation. The span encoder supplies the learned rerank stage.

**Embedding-provider selection:** `wireSubstores` reads `embedding_provider`
at wire time. The value `encoder` selects the registered span encoder in both
ports. Deferred providers are recorded in
[the retirement ledger](../decisions/DECISION_RETIRED_TECHNIQUES_LEDGER.md).

**Span encoder activation order:** when the key is `"encoder"`, the
ensemble is returned unchanged and the encoder is activated by
`wireSubstores` only after the Corpus and, on a GLK estate, the shared
VectorStore are registered. `activateSpanEncoder` installs the rerank stage
against that store; activating earlier would register the duty-side encoder
and silently leave recall lexical-only. Rust `estate_registry.rs` orders
`register_vector_store` → `wire_corpus_on_encoded` →
`apply_provisioned_embedding_provider` for the same reason.

**Registry seeding at open (3.2.0):** `activateSpanEncoder` /
`activate_span_encoder` seeds the bundled encoder (`EncoderModelSeed`,
`arctic-embed-s-w60`) as the active `encoder_models` row before it reads the
registry, whenever the manifest names the encoder and the registry holds no
active row. A freshly provisioned or served estate is therefore
encoder-active from its first open; the span rows themselves stay with the
span-encode standing signal and drain in the background, so the open stays
fast. An estate that already carries an active row keeps it (a later
audition winner is a row swap, never a reseed). A seed failure is logged
once and activation reads the registry as it stands. Upgrade keeps schema
migration and `--backfill-only`; its backfill builds the same row through
the same seam over a closed estate. Ruling 2026-09-04: upgrade never
creates content; seeding belongs to provision and serve.

**Default provisioning (2.25.0):** the span encoder is the default recall
stage. The two paths that bring an estate to the current format write
`embedding_provider = "encoder"` when the manifest names no provider:
`provision` (and every product create path) right after the open and before
`wireSubstores`, so the first open activates the encoder; and the
`mootx01 upgrade` span-encode step, so a migrated CE 1.0.x estate activates on
its next open. A named provider — the encoder or any other id — is never
overwritten, and a serve-time open of an existing estate never writes the
key, so an operator who cleared it keeps a lexical-only estate. Both ports:
`provisionDefaultEncoderIfAbsent(for:)` / `provision_default_encoder_if_absent`.

**Absent-key guarantee:** if the estate has no `embedding_provider` key
(or the value is nil/empty), the ensemble is byte-identical to the
pre-EMBED-PROV-E2 default. No migration required; no side effects.

**Unknown-ID fallback:** if the stored model ID is not in the
recognized set, an `OSLog.warning` is emitted (message includes the
unrecognised ID and estate UUID) and the ensemble is returned unchanged.
This prevents a silently-ignored selection from mislabeling benchmark arms.

**Port contract:** both ports activate the registered encoder. A provider
identity that is unavailable leaves the configured ensemble unchanged and
records the absence.

**Import domain:** `ExternalCorpus.swift` imports `CorpusKit`. RAG
retrieval always routes through CorpusKit per the kit-roles doctrine.

### VectorSimilaritySignal real SynapseKit queries

`VectorSimilaritySignal.spec(vectorStore:modelID:proximityThreshold:probeLimit:corpus:)`
produces the production signal spec. The emit closure captures the
`VectorStore` (and the estate's `Corpus`, when one is registered) and on
each five-minute fire:

1. Calls `VectorStore.recentItemIDs(limit: probeLimit)` (default 50) to
   sample the most recently filed candidate item IDs (newest-first — new
   captures are what need association screening; the earlier
   ascending-item_id enumeration was a static UUID-ordered window new
   content rarely entered on a large estate).
   **One-sided probe window:** probes are recency-sampled while neighbors
   are searched across the whole estate. Two dormant old items will never
   pair unless one was probed while recent. This is the documented
   limitation the `probeLimit` / `probe_limit` parameter exists to
   relieve — callers such as the dream associate step and benchmark
   protocol v2 can widen the window when a full-estate sweep is warranted.
2. Lane 1 — Drawer-keyed rows: for each candidate, retrieves its engram
   via `VectorStore.getVector(itemID:modelID:)` under the caller's
   `modelID` and calls `VectorStore.findNearest(probe:modelID:limit:5)`
   to find nearby rows.
3. Lane 2 — Corpus-derived rows (when `corpus` is supplied): the same probe is
   mined under CorpusKit's model IDs. Those rows are already keyed by
   `Drawer.id`; no `sourceIDs(forChunkIDs:)` map, chunk-owner join, or
   same-Drawer passage collapse exists in GLK 1.1.
4. Deduplicates pairs across both lanes on Drawer-pair keys and emits one
   `AssociateFrame` per pair whose Hamming distance ≤
   `proximityThreshold` (default 64 = 25% of 256 bits).
   Weight = 1 − distance / 256. Every emitted frame carries drawer ids —
   the `associate` verb rejects anything else (`drawerNotFound`).
5. Always emits a scan-summary `DiagnosticReport` with the candidate
   pair count.

The sentinel-only `defaultSpec()` factory is removed. The production
factory requires an injected `VectorStore` and `modelID`.

`DefaultStandingSignals.registerDefaultStandingSignals(in:vectorStore:
modelID:now:)` forwards the VectorStore and the estate's registered
Corpus (`corpusKits[handle]`) to `VectorSimilaritySignal.spec`. The Rust
governor does the same via `EstateCoordinator::corpus_for` →
`default_standing_signal_specs(vector_store, model_id, corpus)`.

**Import domain:** `VectorSimilaritySignal.swift` imports `SynapseKit`.

### GLK content and indexing lifecycle

Capture writes one Drawer through LocusKit. After that write commits, GLK
enqueues a `CorpusContentChange` containing Drawer id, revision/digest, and
cursor—never content text. CorpusKit resolves the Drawer through the injected
source, updates Drawer-keyed BM25/vectors/provider state, and advances its
checkpoint. Supersession, withdrawal, and expunge follow the same identity.
This change-driven index is rebuildable in full from LocusKit Drawers.
GLK may orchestrate SynapseKit directly for non-RAG vector work per the
kit-roles doctrine; row-similarity is Brain math, not RAG.

**Rust parity:** `VectorSimilaritySignal::spec(vector_store, model_id,
proximity_threshold, probe_limit, corpus, edge_checker)` mirrors the
Swift factory. `probe_limit: usize` (default `DEFAULT_PROBE_LIMIT = 50`)
is the fourth positional parameter after `proximity_threshold`.
`default_standing_signal_specs` passes `DEFAULT_PROBE_LIMIT` to keep
the registered default behavior identical to Swift.
`ExternalCorpus::hybrid_recall` routes through `corpus_kit::Corpus::recall`.

## § RECALL_GRAPH — Graph cache + preference store cold-path signals

Graph and preference columns are wired in RecallDirector.

### Overview

Two new registration protocols extend the recall substrate's cold-path
signal set. Both follow the pre-built-cache pattern established by
`MatrixTier`: caches are built offline by the dreaming/training cycle and
registered before recall; the director performs candidate-frontier lookups
only, never synchronous estate-wide analytics (spec §15).

### GraphCache protocol

`public protocol GraphCache: Sendable` — exposes one method:

```swift
func graphScore(for drawerID: String) -> Float
```

Returns a pre-computed graph centrality score for the drawer (e.g. from
random-walk stationary distributions or eigenvalue centrality built by the
dreaming cycle). Returns 0.0 when the drawer is not in the cache. The
caller must not perform any synchronous estate-wide graph traversal.

Registered via `registerGraphCache(_:for:)`. The `graph` buffer column in
`RecallCandidateBuffer` is populated in step 5.7 of `recallUnionBest`.
Column remains 0.0 when no cache is registered — correct, not an error.

### PreferenceStore protocol

`public protocol PreferenceStore: Sendable` — exposes one method:

```swift
func preferenceScore(for drawerID: String) -> Float
```

Returns a pre-trained preference weight for the drawer (e.g. from
Bradley-Terry or RecallTrace models built by the training daemon). Returns
0.0 when the drawer is not in the store. Must not trigger any synchronous
preference model update.

Registered via `registerPreferenceStore(_:for:)`. The `preference` buffer
column is populated in step 5.7. Column remains 0.0 when absent.

### Scoring

Both signals are scored under `RecallWeights.graph` weight (the
RecallWeights struct has no dedicated preference field; sharing the graph
budget gives each cold-path signal equal weight within that slice). The
scoring formula in `.matrixAware` mode is:

```
scores[i] += weights.graph * buffer.graph[i]
           + weights.graph * buffer.preference[i]
```

The unionBest `.matrixAware` matrix term also carries the end-of-day
tournament: `ratingWeight` (0.1; Swift `RecallDirector.ratingWeight`, Rust
`RATING_WEIGHT`) × the drawer's `recall_ratings.rating`, read through
`recallRatings(ids:)` / `recall_ratings` for every candidate in the buffer,
is added to the matrix signal. A drawer with no rating row contributes zero,
so an estate that has never run a tournament scores byte-identically to one
that has.

**Rust parity.** The Rust port mirrors this surface exactly (mission
glk-recall-graphpref-rust): `pub trait GraphCache: Send + Sync` /
`pub trait PreferenceStore: Send + Sync` (per-drawer `graph_score` /
`preference_score`), `EstateCoordinator.register_graph_cache` /
`register_preference_store`, and the per-candidate `col_graph[i]` /
`col_preference[i]` lookups in the unionBest `.matrixAware` score loop. Both
columns share the `weights.graph` slice as in Swift, and read 0.0 when no cache
is registered. The cache PRODUCERS (dreaming-cycle graph-centrality; Bradley-
Terry preference training) are absent in both ports — a separate future mission.

### Post-hydration shingle MMR

The MMR similarity term in step 10 is character-3-gram shingle Jaccard over
the candidate bodies hydrated at step 9.5 (a `.full` recall). The kernel is
SubstrateML `ShingleSimilarity`, which sits below GeniusLocusKit in the kit
graph; GeniusLocusKit carries no shingle math of its own.

Each hydrated body is shingled ONCE, right after step 9.5 fills
`mmrContentByID`, into `mmrShinglesByID`. Both MMR phases (the 2N working
view and the conditional 4N widening) compare precomputed sets through the
set overload `ShingleSimilarity.similarity(_:_:)` (`Set<String>` arguments).
The set overload is the same |∩| / |∪| the string overload computes, so the
selection order is identical to shingling per pair; only the cost changes.
Rebuilding both sets on every pairwise call measured 35 to 40 s of a 36 to
46 s `moot_memory_search` over a 13,817-drawer wing (about 410 hydrated
candidates, about 16,000 pairwise calls per query).

Fallback rule, unchanged: when either side of a pair has no shingle set
(bitmapOnly or structured hydration, an empty body, a candidate absent from
the pool, or a degraded step 9.5), that pair uses `glkSourceMaskJaccard`
over the two source-lane bitsets.

Shingle budget (3.9.0, both ports). The view is built under two constants:
a body cap of 4,096 scalars (`unionBestMMRBodyCapScalars` /
`UNION_BEST_MMR_BODY_CAP_SCALARS`, so a set holds at most 4,094 3-grams and
every step 10 intersection is bounded) and an aggregate budget of 1,000,000
shingled scalars per query (`unionBestMMRShingleBudgetScalars` /
`UNION_BEST_MMR_SHINGLE_BUDGET_SCALARS`). The budget is split evenly: every
non-empty body is shingled over the same prefix, the cap or the budget
divided by the number of non-empty bodies, whichever is shorter. When the
share is below the cap and at least one body is longer than the share, the
stage `unionBest.mmrBudget` is recorded; the cap alone shortening a body is
the measure, not a truncation. The even split keeps one similarity measure
for the whole pool: a body left without a set among bodies with sets would
fall to the sourceMask proxy, which reads a same-lane neighbour as an exact
duplicate and a cross-lane neighbour as unrelated, and the MMR would then
drop the lane's real hits for the unrelated-looking ones. One million
scalars is 244 full-cap bodies, or about 600 scalars per body across the
widest fused pool the lanes can supply (the lexical, locus and fingerprint
lanes at the 256 frontier ceiling plus the 4x over-fetched dense lanes), so
a `moot_memory_search` at its 500 hard ceiling stays inside it and the
shingle memory and the step 10 work are a constant of the build, not of the
estate. The helper is `GeniusLocusKit.unionBestMMRShingles(bodies:)` (the
RecallDirector extension) / `recall::union_best_mmr_shingles`, pinned by
`UnionBestBudgetStagesTests.swift` and `rust/tests/union_best_budget_stages.rs`;
the existing MMR pins are far inside both constants and do not move.

Similarity scale (COL-2). Each pick is the argmax of
λ·score − (1−λ)·ρ·maxSim, where ρ is the step 8.5 redistribution factor
(`RecallSignalBudget.redistribution` / `redistribution`) under `.matrixAware`
and 1.0 under every other scoring strategy, whose relevance term
(`buffer.final`, the normalised fused score) no budget touches. A
`.matrixAware` score with columns excluded is ρ× the score the same columns
produced before exclusion, while maxSim is a Jaccard in [0, 1] whatever the
budget did; an unscaled penalty therefore shrinks by ρ relative to relevance
exactly when columns drop out, and the MMR drifts toward relevance. Measured on
the MMR-2 fixture (12 bodies, limit 3, 2N view 6, ρ = 2.67 with locus, fieldFit,
matrix, graph and preference excluded): the unscaled penalty admitted two
near-duplicates of the query into the three hits; scaled, the working view is
the one the MMR selected on the pre-exclusion scale and the near-duplicates stay
out. With nothing excluded ρ is exactly 1.0 and the selection is byte-identical
to the pre-COL-1 pipeline. Both ports: Swift `similarityScale`, Rust
`union_best_mmr_select(.., similarity_scale, ..)`.

Rust: `recall_scored_multi_lane` runs the same stage for every UnionBest
scoring strategy (`union_best_mmr_select`, with `union_best_mmr_lambda` and
`union_best_mmr_bodies`): the same λ formula from `RecallWeights::adaptive`,
the same argmax and total-order tie-break (higher MMR score, then lower body
text, then id), the same 2N working view and conditional 4N widening, the
same three tie outcomes. The kernel is SubstrateML
`shingle_similarity::shingles` / `similarity_sets`, the conformance-gated
twin of the Swift set overload. Two port-specific facts:

- Body source. The Rust frame-admissible pool (`drawer_index`) is loaded
  through LocusKit `get_drawers_matching_frame`, which returns full rows for
  `Structured` and `Full` and strips the body for `BitmapOnly` only, so the
  bodies Swift reads at step 9.5 are already in hand; Rust builds the shingle
  sets from `drawer_index` for a `Full` recall and makes no second by-id
  read. The view is gated on `Full` exactly as Swift: a `Structured` or
  `BitmapOnly` recall runs MMR on the sourceMask proxy in both ports.
- Raw / rrf / discriminative. Swift runs the same candidate buffer for
  every scoring strategy: step 6 min-max normalises every column, `final`
  included (`final` is the max over the per-lane finals: locus ramp, graph
  0.5, BM25 score, Hamming similarity, dense cosine plus consensus boost);
  step 7 computes the union profile and step 8 the adaptive weights, so
  step 10 takes λ from `weights.diversity` regardless of scoring; step 9
  scores `.raw` and `.rrf` from the normalised `final` and `.discriminative`
  from the dense discrimination factor times it; step 10 feeds that score to
  MMR as the relevance term (similarity scale ρ = 1.0, no budget touches
  it); step 11 reports the normalised columns (locus, bm25, vector, dense)
  and the step 9 score on every hit. The Rust rrf/raw branch builds the
  same rows (`effective_locus_raw` carries the graph max), normalises the
  same columns, feeds the same score to MMR and writes the normalised
  columns and score onto the hit, so a unionBest hit reports the same
  `RecallScoreVector` in both ports under every scoring strategy. The
  returned `union_profile` for these scorings stays
  `RecallUnionProfile::ZERO`. UnionBest never takes the no-corpus
  locus-ranked fallback (`recall_scored_locus_ranked` serves Hybrid and
  CorpusOnly only): without a corpus or vector store the pipeline runs over
  the locus and graph lanes alone, as Swift does. Hybrid and CorpusOnly
  `.raw` is the ordered list merge in both ports: the locus list, then the
  BM25 list, then the vector list (BM25 then vector for CorpusOnly), dedup by
  id, cut at `limit`, with the entering list's score as each hit's `final`;
  their `.rrf` is the weighted reciprocal-rank fusion. Under every scoring a
  Hybrid or CorpusOnly hit carries per-signal lane columns: `locus` is the
  locus ramp `(frontierK - rank) / frontierK` when the locus lane supplied
  the hit, `bm25` the BM25 score when the BM25 lane supplied it, `vector` the
  Hamming similarity `(256 - distance) / 256` when the vector lane supplied
  it, and each column is 0 where its lane did not supply the hit; `final`
  alone carries the fused or merged score and the ranking reads `final`
  alone (`RecallHybridShapeTests` / `recall_hybrid_shape_parity`). Hybrid
  fuses the locus, BM25 and vector lanes and no other: the tunnel-expansion
  graph lane (step 4.35) belongs to unionBest, so a drawer only a tunnel
  would reach is not a Hybrid candidate, appears in no Hybrid `laneRanks`
  entry, and no Hybrid hit carries `locusGraph`, in both ports. CorpusOnly
  runs the BM25 and vector lanes alone. The unionBest
  `.matrixAware` branch seeds the `final` column the step 7 profile reads with
  the same per-lane max in both ports (Rust `col_final`), so the profile's
  top 16 is the same set Swift's `buffer.final` selects.

Cross-port pin: `Tests/Conformance/union_best_mmr_fixture.json` (four
near-duplicate bodies, eight diverse bodies, limit 3, `.full`,
`.matrixAware`), asserted verbatim by both ports; the expected order was
produced by the Swift build.

## § EstateAssociationRuleMining — Apriori + pairwise ARM

Adds two mining entry points to the public `GeniusLocusKit` surface via
a `public extension GeniusLocusKit` (same pattern as `MaintenanceReads`,
`RecallDirector`, etc.; gives access to `internal var matrixTiers` and
`internal var auditLogs`).

### Pairwise ARM entry point

```swift
func mineAssociationRules(
    estate: EstateHandle,
    thresholds: MiningThresholds
) -> [AssociationRule]
```

Reads the registered `MatrixTier` for the estate and delegates to
`SubstrateML.mineAssociationRules(matrix:activeRowCount:thresholds:)`.
Returns an empty array (no error) when no `MatrixTier` has been registered.

**MatrixTier → MatrixO adaptation** (private helper `adaptToMatrixO`):
1. Build vocabulary: sorted unique fieldPaths from `coOccurrence` keys,
   capped at 64.
2. Project each `MatrixValueCoord` to `(field: UInt8, value: UInt8)`:
   - `.integer(n)` → value = `UInt8(n & 0x3F)` (low 6 bits; safe for the
     `CooccurrenceKey` 6-bit value constraint).
   - `.bitmap(v)` where `v.nonzeroBitCount == 1` → value = bit position.
   - Multi-bit `.bitmap`, `.string`, `.bytes`, `.null` → skipped (no lossless
     6-bit encoding; intentionally omitted).
3. Emit both directed cells `(a,b)` and `(b,a)` from each upper-triangle entry.
4. Add diagonal `O[A,A] = liveRowCount` for each observed item (conservative
   upper-bound approximation for single-item support; full correctness requires
   a future mission that stores diagonal counts in `MatrixTier`).

### Apriori entry point

```swift
func mineAprioriRules(
    estate: EstateHandle,
    thresholds: AprioriThresholds
) async throws -> [AprioriRule]
```

Calls `currentAuditLog(in:)` to refresh the audit log, maps each
`UnifiedAuditEntry.afterValue` to a `RowAuditEntry` (SubstrateML-native),
calls `RowAttributeView.from(auditEntries:)`, and delegates to
`AprioriMining.mine(rows:thresholds:)`. Throws `estateNotOpen` when the
estate is unregistered; surfaces any error from `currentAuditLog`.

**Value mapping** (private helper `toRowAuditEntry`):
- `.bitmap(v)` → `.bitmap(v)` (pass-through; `RowAttributeView` expands bits).
- `.integer(n)` → `.integer(n)` (pass-through; `RowAttributeView` uses low byte).
- `.string`, `.bytes`, `.null` → `.null` (no categorical Item encoding).

### CognitionKit recipe wiring

`CognitionKit/AssociationRules.swift` gains a new `AprioriRules` recipe
struct alongside the existing `AssociationRules` recipe. `AprioriRules.run`
delegates to `kit.mineAprioriRules(estate:thresholds:)` with no math
duplication. Both recipes gate on the `associationRuleMining` capability.

---

## § EstateFormalConcepts — Bounded FCA + Implication Basis

Thin wrapper in `EstateFormalConcepts` that wires
bounded Formal Concept Analysis, cover-delta computation, and the D-G
canonical basis to live estates. All three entry points read the estate's
audit log via `currentAuditLog(in:)`, convert entries to `RowAuditEntry`,
build `RowAttributeView` rows (the shared row-replay shape), materialise a
`FormalContext`, and delegate to the provided `BoundedConceptMiner`.

```swift
// public extension GeniusLocusKit

/// Mine bounded formal concepts from the estate's audit log.
/// Returns [] for a fresh estate (silent, not an error).
func mineFormalConcepts(
    estate: EstateHandle,
    miner: BoundedConceptMiner
) async throws -> [FormalConcept]

/// Derive cover deltas (structural lens over the concept order) over the
/// mined concept set. Same pipeline as mineFormalConcepts; additionally
/// calls ConceptCoverDeltas.covering(concepts:). Returns empty cover
/// deltas for a fresh estate.
func formalConceptCoverDeltas(
    estate: EstateHandle,
    miner: BoundedConceptMiner
) async throws -> ConceptCoverDeltas

/// Derive the bounded Duquenne–Guigues canonical basis from the estate's
/// audit log. Every emitted implication is universally sound: every row
/// carrying all attributes in `premise` also carries all in `conclusion`.
/// Returns an empty basis for a fresh estate. `isTruncated` is true when
/// `maxImplications` terminated enumeration early.
func conceptImplications(
    estate: EstateHandle,
    miner: BoundedConceptMiner,
    maxImplications: Int,
    maxPremiseSize: Int
) async throws -> ConceptImplications
```

**Cover-delta contract**: the set returned is structural (cover-relation
lens, not Duquenne–Guigues canonical). It holds within the emitted
concept set but is not universally sound across all context rows — a
cover delta does NOT assert that every row carrying `lowerIntent` also
carries `addedAttributes`. See SUBSTRATEML_SPEC.md § 5.21 for the
full contract.

**Implication contract**: `conceptImplications` returns the bounded
Duquenne–Guigues canonical basis (SUBSTRATEML_SPEC.md § 5.21,
FormalConceptAnalysis). Every
emitted implication is sound and minimal. The basis may be incomplete when
`maxImplications` or `maxPremiseSize` bind.

**Multi-seed access**: pass a `BoundedConceptMiner` constructed with
`seedMode: .multi` to activate the 2-attribute-pair seed pass. The
wrapper does not gate or modify the miner — it delegates unchanged.

**Capability gating** belongs at the CognitionKit recipe layer
(`FormalConcepts.swift`), not here. This wrapper is a pure adapter.

### CognitionKit recipe wiring

`CognitionKit/FormalConcepts.swift`'s `FormalConcepts` recipe includes
`coverDeltas: ConceptCoverDeltas` and `implications: ConceptImplications`
in its `Output` type. Cover deltas are computed via
`ConceptCoverDeltas.covering(concepts:)` over the mined concept set.
Implications are computed via `ConceptImplications.conceptImplications`
with the bounding parameters from `Input.maxImplications` (default 200)
and `Input.maxPremiseSize` (default 4). Multi-seed is accessible by
constructing the `Input.miner` with `seedMode: .multi`. The recipe gates
on `.formalConceptAnalysis` (unchanged).

## § PROVISION — Composition-aware estate provisioning and lifecycle

### Overview

The `provision` method is the GLK-owned create+open+wire path for new estates.
It replaces the three-step caller pattern (`Estate.create` + `GLK.open` +
`registerCorpus`/`registerVectorStore`) with a single coordinated call that:

1. Seeds the LocusKit manifest with the kind-prefixed framework profile and
   zoom window.
2. Opens the estate through the standard coordinator path (issues an `EstateHandle`).
3. Wires sub-stores according to `EstateKind`; every Corpus is attached to the
   LocusKit-backed content source with whole-content indexing.

### EstateKind

| Kind          | LocusKit | Corpus | VectorStore |
|---------------|----------|--------|-------------|
| `.glk`        | yes      | yes    | yes         |
| `.corpusOnly` | yes      | yes    | no          |
| `.locusOnly`  | yes      | no     | no          |

### Framework profile encoding

The `frameworkProfile` parameter is stored in the manifest as
`"<kind.rawValue>:<frameworkProfile>"` (e.g. `"GLK:KnowledgeWork"`). This
encoding allows the estate kind to be inferred from the manifest after a process
restart without requiring a separate manifest key.

### EstateMountState

All open estates carry an `EstateMountState`:

| State       | Meaning                                           |
|-------------|---------------------------------------------------|
| `.mounted`  | Open and accepting new work.                      |
| `.quiesced` | Not accepting new work; estate still open.        |
| `.draining` | Finishing in-flight work; transitions to quiesced.|
| `.unmounted`| Transitional; estate closed immediately after.   |

`mountState(for:)` returns the current state, or `nil` for a stale handle.

### Lifecycle sequence

The expected admin-plane teardown sequence is:
```
provision → (operate) → quiesce → drain → destroy
```

`destroy` internally calls `close` if the estate is still open, then tears down
derived sub-store state. `Corpus.destroyRecallIndex()` clears BM25,
Corpus-scoped vectors, provider basis/counts, and checkpoints. Independent GLK
vector rows are deleted only under their declared lane/model ownership. The
canonical LocusKit Drawer store is handled by the explicit estate-destruction
policy; it is never preserved or deleted accidentally as a side effect of
Corpus cleanup. An unqualified `VectorStore.destroyAllVectors()` is not an
acceptable composed cleanup primitive.

### Invariants

- `provision` is idempotent at the "estate already exists" level: re-provisioning
  the same storage raises `.duplicateEstate`.
- Sub-store wiring failures in `provision` roll back by closing the handle before
  re-throwing, so no half-wired zombie estates are left in the registry.
- `quiesce` is idempotent: calling on an already-quiesced estate is a no-op.
- The existing `open` + `registerCorpus` + `registerVectorStore` caller path is
  migrated to require an attached whole-content Corpus. Registration rejects a
  standalone Corpus or any passage-enabled policy for a GLK estate.

---

## § ROLLUPS — Per-Estate Rollup Telemetry

### Overview

GeniusLocusKit emits per-estate rollup metrics through `IntellectusLib`
at the estate-coordination and lifecycle boundaries. All metrics are in
the `geniuslocus.estate.*` namespace to distinguish them from per-kit
metrics emitted by LocusKit (`locus.*`), SynapseKit (`vector.*`), and
CorpusKit (`corpus.*`).

### Off-path cost

Telemetry is gated by a single `Atomic<Bool>.load(.acquiring)` +
branch in `Intellectus.report(_:)`. When monitoring is disabled
(the default), the payload `@autoclosure` is never evaluated: zero
allocation, no lock, ~1 ns. Results are byte-identical whether
monitoring is on or off.

### Metric namespace

| Metric name | Description | Tags |
|---|---|---|
| `geniuslocus.estate.mount_state_transition` | Estate lifecycle state change | `estate_id`, `state` |
| `geniuslocus.estate.provision` | Estate provisioned (create + open + wired) | `estate_id`, `kind` |
| `geniuslocus.estate.noun_count` | Drawer count snapshot at admission | `estate_id` |
| `geniuslocus.estate.verb_error` | Verb error at estate boundary (remap) | `estate_id`, `verb` |

`state` values: `mounted`, `quiesced`, `draining`, `unmounted`.

`kind` values: `GLK`, `CorpusOnly`, `LocusOnly`.

### Emit sites

| Method | Metric emitted | Condition |
|---|---|---|
| `open()` | `mount_state_transition` (state=mounted) + `noun_count` | After registry insert |
| `close()` | `mount_state_transition` (state=unmounted) | After registry cleanup |
| `provision()` | `provision` (kind tag) | On wiring success only |
| `quiesce()` | `mount_state_transition` (state=quiesced) | After mount state update |
| `drain()` | `mount_state_transition` (state=draining) then (state=quiesced) | Both transitions emitted |
| `remap(verb:estateID:error:)` | `verb_error` | For nine ARIA verbs with non-empty estate_id |

`EstateNotOpen` routing errors (stale handle at `close`, `quiesce`,
`drain`) do NOT emit `verb_error` — those are routing errors, not
verb-surface errors. Only errors that pass through `remap` emit.

### Conformance

Swift and Rust implementations are parity-gated. The telemetry test
suites verify:
- §1 Disabled gate: no metric emitted when monitoring is OFF.
- §2 Mount-state transitions: open emits mounted, close emits unmounted.
- §3 Provision: provision metric with correct kind tag.
- §4 Lifecycle: quiesce emits quiesced; drain emits draining then quiesced.
- §5 Noun count: open emits noun_count=0 for fresh estates.
- §6 Verb error: stale handle at close does NOT emit verb_error.
- §7 Conformance: estate coordination results identical with monitoring ON vs OFF.

## § TOPO_REAL_GRAPH — Topology graph surface (relocated to NeuronKit)

The topology snapshot (`graphTopology`) originally shipped here as
`GeniusLocusKit.graphTopology(for:now:)`, calling SubstrateML directly to
work around the NeuronKit→GLK package cycle. That placement put analysis in
the composition layer — GLK's job is composing LocusKit/SynapseKit/CorpusKit
and coordinating estates, not running algorithms.

The analysis now lives in NeuronKit as the pure function
`NeuronKit.graphTopology(drawers:tunnels:facts:)` (Swift) /
`neuron_kit::topology_analysis::graph_topology` (Rust). The package cycle is
resolved by inverting the orchestration: the caller (aria-mcp, which depends
on both kits) performs the estate reads and tombstone-instant resolution,
then hands plain descriptors to NeuronKit. GLK contributes only its existing
raw read surface (`allDrawers` / `allTunnels` / `allKGFacts` via the estate)
and gained no new symbols for this feature.

See `NEURONKIT_SPEC.md` § TOPOLOGY_ANALYSIS for the full contract and
`ARIA_MCP_SPEC.md` for the `/api/graph` wire surface.

## § DORMANT_SURFACES — Estate read surface for NeuronKit

### Overview

This section specifies five estate-surface methods added to `GeniusLocusKit`
so NeuronKit can reach the substrate without bypassing the composition layer
(NeuronKit B-1 constraint). All five are actor-isolated `public` methods;
callers `await` each.

### B-1 constraint reminder

NeuronKit reads substrate data exclusively through the GeniusLocusKit estate
surface. It must not import LocusKit directly. The five methods in this
section are the B-1-mandated entry points for the two temporal-read
forwarding paths, the lag-pair derivation path, and the calibration
read/write paths.

### Method contracts

**glkFingerprintsCaptured(in:window:)**

Forwards to `DrawerStore.fingerprintsCaptured(in:)` for the estate identified
by `handle`. Uses the DrawerStore lazy-cache pattern established by
`DreamingWrites.swift`: the store is built from `storages[handle]` (not
`Estate.store`, which is internal to LocusKit) and cached in
`fingerprintStores[handle]`. Returns `[Fingerprint256]` in HLC-ascending
order within the window. Throws `.estateNotOpen` for a stale handle.

The Rust port mirrors this as `EstateCoordinator::glk_fingerprints_captured(
handle, start_epoch, end_epoch)`, which forwards through
`Estate::fingerprints_captured_in` to `DrawerStore::fingerprints_captured_in`
(windows are `(start, end)` epoch-seconds pairs rather than `ClosedRange<Date>`).
The Moment lens (CognitionKit) reads both its primary and comparison windows
through this surface in both ports — neither aria-mcp nor NeuronKit touches the
LocusKit store directly (B-1).

**glkFingerprintBitSeries(in:bit:bucketSeconds:bucketCount:endingAt:)**

Forwards to `DrawerStore.fingerprintBitSeries(bit:bucketSeconds:bucketCount:
endingAt:)` via the same lazy-cache pattern. Returns `[Bool]` of length
`bucketCount`, index 0 = oldest bucket. Throws `.estateNotOpen`, or
`.invalidContent` on invalid parameter values.

**glkEventLagPairs(in:window:lagBuckets:)**

Reads the estate's `UnifiedAuditLog` (in-memory `auditLogs[handle]`) and
returns all entries whose HLC physicalTime falls inside `window` as a
HLC-ascending `[TemporalAuditEntry]` in the shape `TemporalCausalityFold`
consumes. Conversion rules:

| `UnifiedAuditValue` | `TemporalFieldCoord.valueRepr` |
|---|---|
| `.bitmap(v)` | `"bitmap:\(v)"` |
| `.string(s)` | `"string:\(s)"` |
| `.integer(v)` | `"integer:\(v)"` |
| `.bytes(b)` | `"bytes:\(b.count)"` |
| `.null` | empty coord list |

Only `.capture` and `.expunge` verbs contribute field coordinates; all other
verbs produce an empty coord list (watermark advance, no causal pairs).
Returns `[]` rather than throwing if no audit log exists for the handle.
Throws `.estateNotOpen` for a stale handle.

The `lagBuckets` parameter is passed through to the caller; it does not
change which entries are returned but signals to the caller which lag-bucket
boundaries to use when feeding the result to `TemporalCausalityFold.fold`.

**glkCalibrationCurve(for:modelID:)**

Returns the `MatrixCalibrationCurve` for `modelID` from the in-memory
`calibrationRegistries[handle]`, or `nil` if no observations have been
recorded for that model. Throws `.estateNotOpen` for a stale handle.

**glkRecordCalibrationOutcome(for:modelID:claimedConfidence:succeeded:at:)**

Records one LLM prediction outcome against the calibration curve for
`modelID`. Applies 30-day-half-life lazy decay (math treatise §8) before
recording: the curve's bucket counts are multiplied by
`0.5^(elapsedDays / 30)` computed from the stored `updateTimestamps[modelID]`
and the supplied `now`. After recording, if a `MatrixPersistenceBackend` is
registered for `handle`, saves a `MatrixSnapshot` containing the updated tier
and calibration registry. Throws `.estateNotOpen` for a stale handle.

**registerMatrixPersistence(_:for:)**

Wires a `MatrixPersistenceBackend` to `handle`'s estate. On registration,
loads any existing snapshot and uses its `calibration` field to seed
`calibrationRegistries[handle]`; also restores `matrixTiers[handle]` from
the snapshot if no tier is already registered. Subsequent calls to
`glkRecordCalibrationOutcome` will persist after each write. Throws
`.estateNotOpen` for a stale handle.

### Decay rule (math treatise §8)

Decay is lazy and multiplicative. It is applied at write time by
`MatrixCalibrationRegistry.recordWithDecay`. The factor is
`0.5^(elapsedDays / halfLifeDays)` where `halfLifeDays = 30.0`. Decay is
skipped for sub-day intervals to suppress floating-point noise on rapid
successive calls. Only bucket `count` is decayed; `successRate` is a ratio
and does not change.

### Rust mirror

The Rust port provides a pure function `genius_locus_kit::event_lag_pairs`
and the `record_with_decay` / `apply_decay` methods on
`MatrixCalibrationRegistry` / `MatrixCalibrationCurve`. These are tested
against the same five-event fixture and calibration round-trip as the Swift
port.

## § FAIL_LOUD — Recall-Director Degradation Contract

### Background

The Recall Director is non-throwing by design (spec §7.8.1, LocusKit's
`RecallStream` contract). Before this section was written, recoverable errors
inside lane helpers (store failures, embedding errors, frontier-load errors)
were silenced with `try? ... ?? []`, making it impossible for callers to
distinguish an empty result set from a degraded one. Matrix, graph, and
preference scoring columns silently zeroed when the structured pool load
failed; the query appeared healthy.

### Degradation contract

A Recall Director stage is classified as one of two failure modes:

**Estate-unavailable failure** — the estate handle is stale or the estate is
not open. This throws `GeniusLocusKitError.estateNotOpen` before any lane
runs. No degradation path; the caller must handle the throw.

**Recoverable stage failure** — a store call, vector search, or embedding
call throws while the estate is alive. The query survives on whatever signals
remain. The stage name is appended to `GLKRecallResult.degradedStages` and
a telemetry counter is emitted so per-estate health dashboards can surface
persistent degradation.

### `GLKRecallResult.degradedStages`

A new `[String]` field on `GLKRecallResult`. Empty when every attempted
stage succeeded. Each element is a stage identifier of the form
`<lane>.<operation>`:

| Stage identifier | Trigger | Downstream effect |
|---|---|---|
| `vectorHamming.findNearest` | `VectorStore.findNearest` threw | Vector column absent from hit scores |
| `corpus.embed` | `corpus.embed` threw during sketch compile | Vector lane dark (no engram); same as above |
| `pool.getDrawers` | `estate.getDrawers` threw in step 5.5 of `recallUnionBest` | Matrix/graph/preference columns zero for this query |
| `pool.hydrateBodies.mmr` | `estate.hydrateBodies` threw in step 9.5 | MMR used sourceMask Jaccard proxy instead of content shingles |
| `subSpan.budget` | the step 5.8 aggregate sub-span window budget stopped before every candidate was scored | The unscored candidates keep their stored dense signal; their hits carry the explainer token `subSpan:budget` |
| `unionBest.mmrBudget` | the step 9.5 aggregate shingle budget shortened every body's shingled prefix below the body cap | The MMR compares shorter openings; every body still carries a set |
| `recall.cross_encoder_degraded` | an `apply` rerank directive could not run after the full unionBest pipeline (3.19.0; the reason is on `GLKRecallResult.crossEncoder.reason`) | The incoming order stands; the report says `degraded` |
| `pool.hydrateBodies.return` | `estate.hydrateBodies` threw in step 10.5 | Returned hits carry empty `content` for `.structured` recall |
| `hybrid.getDrawers` | `estate.getDrawers` threw in `recallHybrid` frontier load | BM25/vector-only hits absent; locus-indexed hits unaffected |
| `corpusOnly.getDrawers` | `estate.getDrawers` threw in `hydrateHits` | Result set empty (all fused candidates need this load) |
| `locus.liveRows.readFailed` | LocusKit `recall` bounded corpus scan failed (surfaced via `RecallStream.degradedStages`) | Locus lane contributed no rows for a reason OTHER than empty estate |
| `locus.roomFingerprints.readFailed` | LocusKit `recall` fingerprint-pruning room-fingerprint enumeration failed | as above (pruning path) |
| `locus.roomDrawerRead.readFailed` | LocusKit `recall` surviving-room drawer read failed | as above (pruning path) |
| `locus.bitmapEval.failed` | LocusKit `recall` bitmap evaluator threw | as above |

The four `locus.*` stages originate at the LocusKit `recall` boundary (LOCUSKIT
SPEC § 5 B-3): a failed internal read names the stage on `RecallStream`, and the
RecallDirector merges `stream.degradedStages` into `GLKRecallResult.degradedStages`
in every locus-draining lane (`locusOnly`, `hybrid`, `unionBest`, and the
no-corpus locus-ranked path). This is how a FAILED locus recall is
distinguished from a GENUINE-EMPTY estate (which records nothing).

#### Scoring-fallback stages

A second class of `degradedStages` identifier names a SCORING FALLBACK: the
caller requested a scoring strategy that is not a distinct implementation in
the active lane, so the director applied a simpler combiner. The query
succeeds; the stage is recorded so the caller can tell the requested scoring
was not the one applied (replacing what was previously a silent downgrade).
The genuinely-implemented combos record nothing: `unionBest` + `matrixAware`
is the full weighted pipeline; `unionBest` + `discriminative` is RRF scaled
by the dense saturation discount (a real implementation); `hybrid` /
`corpusOnly` + `rrf` is real RRF fusion; `locusOnly` / `hybrid` /
`corpusOnly` + `raw` is the raw merge.

| Stage identifier | Trigger | Applied fallback |
|---|---|---|
| `locusOnly.matrixAware` | `matrixAware` requested on `locusOnly` (no matrix pass) | raw bitmap-evaluator ordering |
| `corpusOnly.matrixAware` | `matrixAware` requested on `corpusOnly` (no matrix pass) | RRF fusion of BM25 + vector |
| `hybrid.matrixAware` | `matrixAware` requested on `hybrid` (no matrix pass) | three-way RRF fusion |
| `unionBest.rrf` | `rrf` requested on `unionBest` (no distinct RRF fusion across lane scores) | raw (`buffer.final`) lane-normalised score |
| `locusOnly.discriminative` | `discriminative` requested on `locusOnly` (no dense lane) | raw bitmap-evaluator ordering |
| `corpusOnly.discriminative` | `discriminative` requested on `corpusOnly` (no discrimination pass) | RRF fusion of BM25 + vector |
| `hybrid.discriminative` | `discriminative` requested on `hybrid` (no discrimination pass) | three-way RRF fusion |

Both ports emit the identical stage strings. The no-corpus collapse path
(Hybrid/CorpusOnly with no corpus/vector registered) keeps the requested
mode's stage name so the vocabulary is stable regardless of which internal
path served the query. `unionBest` + `matrixAware` never records a fallback
even on an estate with no corpus/vector — the weighted pipeline runs with zero
matrix columns, a real path, not a degrade. `unionBest` + `discriminative`
is also a real implementation: when no dense lane runs the factor is 1.0 and
the result is byte-identical to `rrf`, but no fallback stage is recorded.

#### Signed-weight fusion steering (RecallShape — 6b-modifiers)

`GLKRecallRequest.recallShape` (optional `RecallShape`) makes the RRF fusion
STEERABLE without changing the fusion algorithm. The fused score becomes
`fused(id) = Σ_L w_L · 1/(k + rank_L(id) + 1)` with `k = 60`, where each lane
`L` carries a SIGNED weight `w_L` from `RecallShape.laneWeights` keyed by a
stable lane identifier (`locus`, `bm25`, `hamming`, and, in the
`WholeRecordDense` build, `dense:<modelID>` for each held whole-record
signal). A lane whose key is absent defaults to `1.0`.

| Weight | Name | Effect |
|---|---|---|
| `w > 0` | FORWARD | the lane votes; larger `w` amplifies its rank mass (`1.0` neutral) |
| `w == 0` | EXCLUDE | the lane contributes nothing; an id whose only source is the excluded lane is dropped |
| `w < 0` | SUPPRESS | the lane's rank mass is SUBTRACTED, demoting a candidate it ranks high |

EXCLUSION (`w==0`) and SUPPRESSION (`w<0`) are DISTINCT operations and are
conformance-tested as such; neither is anti-similarity retrieval (which would
change which candidates the store returns — deferred to `6b-modifiers-antisim`).
Steering applies to the lanes that route through the weighted RRF combiner —
`hybrid` (locus/bm25/hamming) and `corpusOnly` (bm25/hamming) — AND to the
`unionBest` lane (6b-modifiers-core-2), which is the only lane where the
per-signal dense float signals fuse (the fold below exists only in the
`WholeRecordDense` build, 3.6.0; the default build has no whole-record float
lane and the aggregate `dense` column carries the sub-span cosine alone):

- **UnionBest dense consensus fold.** Each per-signal dense list, tagged by its
  `modelID`, is scaled by `w = weight("dense:<modelID>")`. `w==0` excludes the
  signal entirely (leave-one-out: no reciprocal-rank term, and its cosine is
  withheld from the aggregate `dense` column); `w<0` subtracts the signal's rank
  mass (demotion); only forwarding `w>0` signals raise the aggregate `dense`
  cosine. The consensus boost `max(0, total − best)` is computed over the SIGNED
  weighted terms; at all-1.0 it reduces exactly to the unweighted fold. An
  excluded signal no longer claims per-hit `denseSignals:` provenance; a
  suppressed signal still does (it contributed subtracted mass).
- **UnionBest weighted-column score.** The fixed lanes `locus`/`bm25`/`hamming`
  and the aggregate `dense` key additionally scale their column contributions on
  top of `RecallWeights.adaptive`: `w==0` zeroes a lane's column, `w<0` subtracts
  it. The matrix/graph/preference columns are ALSO shape-steerable
  (6b-modifiers-matrix-steer): `fieldFit`, `coOccurrence`, `temporal`, `graph`,
  and `preference` each scale their column with the same signed semantics, also
  composed on top of `RecallWeights.adaptive`. The combined matrix term
  `weights.matrix · (coOccurrence + temporal) · 0.5` is split so `coOccurrence`
  and `temporal` steer independently (each carries half the matrix budget); the
  neutral 1.0/1.0 path preserves the exact pre-steer combined expression, so a
  nil/all-ones shape is byte-identical. These five matrix keys are active ONLY in
  the `.matrixAware` weighted score — a NO-OP under `.raw`/`.rrf`, which read the
  lane-normalised rank score directly and never run the weighted formula. (Both
  ports populate `graph`/`preference` from a registered `GraphCache` /
  `PreferenceStore`; with a cache registered, steering those keys moves the live
  columns identically cross-port. Absent a cache the columns read 0.0 on both
  ports — the correct fresh-estate behaviour. The cache PRODUCERS remain absent
  in both ports.) See the recall-shape contract D-4 for the full cross-port boundary.
- **UnionBest column-budget keys (`signal:*`, COL-1).** Where the per-lane keys
  above SCALE a column's term, the `signal:` namespace steers the column's
  BUDGET: `signal:locus`, `signal:bm25`, `signal:vector` (the Hamming + dense
  pair), `signal:fieldFit`, `signal:matrix` (the coOccurrence + temporal pair),
  `signal:graph`, `signal:preference`, and `signal:agreement`; `signal:encoder`
  (2.21.0) is the span rerank stage switch — `0` skips the stage, it has no
  budget slice. Since 2.21.0 an ABSENT key resolves through
  `RecallShape.defaultWeight(for:)` / `RecallShape::default_weight`: `1.0` for
  every key except `signal:vector`, whose default is `0` — the whole-record
  vector column (Hamming + dense) is out of the fused score unless a shape sets
  the key (Encoder Rerank Program ruling: the span rerank stage carries the
  semantic signal), so a nil shape, an empty shape and `no_vector` fuse
  identically. A key at `0`
  EXCLUDES the whole column: its `RecallWeights.adaptive` budget leaves the
  included total and the remaining included columns are scaled by
  ρ = `total / includedTotal`, so the included columns keep summing to the total
  the optimizer assigned instead of standing as a zero term that silently
  inflates the fixed agreement and pinned bonuses (0.05). ρ is carried on the
  resolved budget as `redistribution` (1.0 when nothing is excluded) and step 10
  multiplies the MMR similarity term by it (see "Post-hydration shingle MMR"):
  exclusion changes the score's magnitude, never the relevance-versus-diversity
  balance the MMR admits candidates on. `1.0`/absent is neutral (the
  resolved budget is byte-identical to `RecallWeights`), `<0` suppresses and
  other positive values scale, neither triggering redistribution. Preference
  draws the graph slice (RecallWeights has no preference field), and
  `signal:agreement` has no budget slice: excluding it removes the bonus and
  redistributes nothing. The resolution is the pure function
  `RecallSignalBudget.resolve` (Swift) / `RecallSignalBudget::resolve` (Rust),
  pinned by seven shared f32 vectors on both ports. The keys are active ONLY in
  the `.matrixAware` weighted score.
- **Empty-store exclusion (automatic, COL-1 Part C).** Independently of any
  shape, a column whose signal store is empty for the recall is excluded with
  its budget redistributed, exactly as a `signal:*` key at `0` would do. Absence
  is read from the normalised buffer columns (an all-zero column is "no
  measurement"; a non-zero uniform column normalises to 0.5 and is NOT absent):
  `fieldFit`/`matrix` when no MatrixTier is registered or it produced no
  measurement, `graph` when no candidate has a graph score, `preference` when
  no candidate carries a mark. Two columns are absent by construction:
  - `locus` whenever the request carries query text. The locus column is the
    candidate's rank in the frame's `filedAt DESC` slice, and the pool is
    frame-filtered at step 5.5, so for a text query the column measures recency,
    not relevance. Without query text the recency rank is the requested
    ordering (a structured browse) and the column stays.
  - the matrix columns whenever the frame carries no bitmap predicates. The
    matrix anchor (`queryCoords`) is the top locus row's field signature, which
    is a QUERY signature only when predicates constrain that row; without
    predicates it is the newest drawer, and step 5.6 does not run.
  Measured on the aggregate ConvoMem wing (13,817 imported drawers, 120 seeded
  queries): excluding the locus column alone lifted nDCG@10 by 0.138 against
  its control, while excluding fieldFit, matrix, graph or preference moved it
  by at most 0.0005; the locus recency rank is the column that made
  `.matrixAware` (0.318) lose to `.raw` (0.431). The matrix anchor rule is
  correctness, not the measured cause. See the COL-1 report for the ablation
  table and the post-fix number.

A `nil` shape — or an all-1.0 shape — is BYTE-IDENTICAL to the prior uniform
fusion in EVERY lane including `unionBest` (the back-compat contract, proven by
conformance on both ports). `RecallShape` may also override the candidate-pool
depth via `frontierK`, clamped to the engine's `[64, 256]` envelope. Both ports
implement the identical signed formula and clamp.

#### Per-call frontier-K override (`GLKRecallRequest.frontierK`)

`GLKRecallRequest.frontierK` (Swift `Int?` / Rust `Option<usize>`) is a
per-call candidate-pool depth override with the HIGHEST precedence in the
three-level resolution order:

  1. `request.frontierK` — per-call, set directly on the request (highest).
  2. `recallShape.frontierK` — shape-level pool override (6b-modifiers).
  3. Engine formula — `min(max(limit × 4, 64), 256)` (lowest).

Like the shape-level override, the per-call value is clamped to
`[RecallShape.frontierKFloor, RecallShape.frontierKCeiling]` = `[64, 256]`
before the plan is built; a value outside the envelope degrades to the
nearest bound rather than failing. A `nil` value (the default) falls through
to the shape or engine formula. Use this when a recipe drives the pool size
from a runtime parameter but does not need to steer lane weights.

Both ports apply the same three-level resolution in the same order.

#### Anomalous-flag admission gate (`GLKRecallRequest.anomalousFilter` — §11.18)

`GLKRecallRequest.anomalousFilter` (Swift `Bool?` / Rust `Option<bool>`) is an
optional admission filter applied to recall hits BEFORE scoring:

- `nil` (default) — no filter; all hits pass through (passthrough gate).
- `true` — admit only hits whose hydrated drawer has `isAnomalous == true`
  (bit 26 of `operationalBitmap` set). Hits without a hydrated drawer
  (`hit.drawer == nil`, e.g. bitmapOnly hydration) pass through unconditionally.
- `false` — exclude hits whose hydrated drawer has `isAnomalous == true`.
  Same nil-drawer passthrough as above.

The gate is applied centrally in `recall(_:_:)` / `recall_scored` after all
lane results are collected, before trace writes and the dreaming enqueue. A
new `GLKRecallResult` is built with the filtered hit list; `laneRanks` and
all other result fields are preserved verbatim.

`anomalousFilter` does NOT interact with `frontierK`, `recallShape`, scoring,
or any other request parameter. It is purely an admission gate on the final
pre-scoring candidate list.

Rust: `with_anomalous_filter(filter: bool) -> Self` builder method.

**Behavioral contract:** when `anomalousFilter == nil`, the result is
byte-identical to an identical request with no filter set — the code path
skips the filter block entirely. Tests must verify this passthrough property.

#### Anti-similarity steering (`antiSimilarLanes` — 6b-modifiers-antisim; WholeRecordDense build)

Since 3.6.0 the field, the hook and the presets that use them compile only
under the `WholeRecordDense` trait / `whole-record-dense` feature.
`RecallShape.antiSimilarLanes` (Swift) / `anti_similar_lanes` (Rust) is a set of
DENSE lane keys (`dense:<modelID>`) whose OBJECTIVE flips from nearest to
FARTHEST. In the `unionBest` dense lane, a lane in this set queries CorpusKit's
`floatFarthestPerSignal` instead of `floatNearestPerSignal`: it surfaces the
most DISSIMILAR sources ("find things UNLIKE this") and forwards them as that
signal's voters in the SAME N-way RRF/consensus fold. This is DISTINCT from a
negative weight:

- **Anti-similarity** changes WHICH candidates the store returns (the farthest),
  then forwards them — a drawer the lane never retrieved under nearest can now
  carry dense provenance.
- **A negative weight** keeps the NEAREST candidates and SUBTRACTS their rank
  mass (demotes the similar) — it never retrieves a far drawer.

The two compose: a lane can be anti-similar AND signed (forward the dissimilar at
any strength, or suppress the dissimilar). An EMPTY set — or a `nil` shape — keeps
every lane nearest and is BYTE-IDENTICAL to the pre-antisim fusion (back-compat,
proven on both ports). Only `dense:<modelID>` keys are honoured (the fixed lanes
have no farthest variant). The distinctness invariant — anti-similar+positive ≠
nearest+negative — is conformance-gated on both ports.

#### Named preset roster (RecallShape.preset)

`RecallShape.preset(_:)` (Swift) / `RecallShape::preset` (Rust) resolves a roster
NAME to a documented signed-weight shape, so a recipe or an AI can pick a
deterministic steering vector by name instead of constructing one. `presetNames` /
`PRESET_NAMES` is the discoverable roster for the compiled build; `presetDescription` /
`preset_description` is the one-line emphasis text the ARIA tool surfaces.

A preset is a WEIGHT VECTOR over the existing fusion — it introduces NO new
substrate math, and every key it sets is a key the fusion already reads (the
signed-weight semantics above). `"balanced"` and any unknown name resolve to
`nil`/`None` — the uniform, unsteered fusion — so the resolution of "balanced" and
of an unknown name are deliberately the same (run with no steering). The roster:

- `balanced` — uniform (nil).
- `precise`: bm25 + dense up with a narrow frontier.
- `broad` — all retrieval lanes up, frontier widened to the ceiling.
- `lexical`: bm25 up with dense + hamming excluded.
- `not_lexical`: bm25 excluded.
- `fast` — hamming only, dense excluded.
- `jaccard` — binary lane scores Jaccard set-overlap/union instead of Hamming
  (length-normalized); all other lanes neutral.
- `structural` — locus up.
- `temporal` / `connection` / `field` / `preference` — the matrix/graph/preference
  column up (matrixAware scoring only).
- `anti_redundant`: bm25/hamming at -0.5 with a narrow frontier.
- `session_hybrid` — hybridRecall scoredLane path with temporal-window + speaker-
  aware post-processing; bm25 + dense + temporal amplified.
- `temporal_connection` — temporal 1.5 + coOccurrence 1.5; both matrix columns
  amplified together (matrixAware scoring only).
- `field_preference` — fieldFit 1.5 + preference 1.5; field match and user
  preference compound (matrixAware scoring only).
- `no_locus` / `no_field_fit` / `no_matrix` / `no_graph` / `no_preference` /
  `no_agreement` / `no_bm25` / `no_vector` — column-exclusion ablation presets
  (COL-1/NOVEC-1): each sets exactly one `signal:*` key to `0`, excluding that
  column of the matrixAware weighted score with its budget redistributed.
  Candidates from the excluded lane still enter the pool; only the scoring
  column is excluded and its budget redistributed. They exist so a harness arm
  can measure ranking WITHOUT a column through the ARIA verb that carries a shape
  (`moot_recall_shaped` takes a preset name, not an inline shape). Since 2.21.0
  `no_vector` names the default explicitly (the vector column is out unless a
  shape asks for it).
- `no_encoder` (2.21.0) — `signal:encoder` at `0`: the span rerank stage is
  skipped and the lexical list enters the pool in BM25 order. With the vector
  column out by default it fuses identically to `no_vector`; that identity is
  the stage's ablation gate on both ports. The name `cross_encoder` is RESERVED
  for the cross-encoder hook and is deliberately absent from the roster
  (unresolvable, so the tool rejects it as unknown) until an implementation lands.
- WholeRecordDense build only (3.6.0): `conceptual` (the whole-record
  distributional lanes up and bm25 down), `associative` (RI up with a wider
  frontier), `consensus` (every held whole-record signal up, narrow
  frontier), `ri_forward` (the random-indexing lane up), `whole_record_baseline`
  (every held whole-record signal at 1.0 over the default frontier; the
  audition arm), `anti_redundant_ri` (the anti_redundant suppression with the
  RI lane inverted to farthest), `float-l2` and `float-dot` (the whole-record
  float lane scores L2 distance or negative dot product instead of cosine).

The weights are SENSIBLE, DEFENSIBLE starting points the quality optimizer tunes
later — they are NOT canon. A preset's contract is its DIRECTION (which lanes it
forwards/excludes/suppresses/inverts and how it bounds the frontier), not the
literal float. Leave-one-out ablation is reachable WITHOUT a dedicated preset:
take any forward shape and zero one `dense:<modelID>` key. The dense per-signal
keys are surfaced as `RecallShape.DenseSignal.*` / `RecallShape::DENSE_*`
constants so a provider-id typo is a build error, not a silent no-op. Roster
resolution is conformance-gated on both ports (`RecallShapePresetTests.swift` /
`recall_shape_presets.rs`).

### Telemetry counters

Each degraded stage emits a `glk.recall.<stage>_degraded` counter tagged
with `estate_id` (and `lane` where a stage spans multiple lanes). Metric
names are constants on `GLKMetricName`:

- `glk.recall.vectorHamming.findNearest_degraded`
- `glk.recall.corpus.embed_degraded`
- `glk.recall.pool.getDrawers_degraded`
- `glk.recall.pool.hydrateBodies.mmr_degraded`
- `glk.recall.pool.hydrateBodies.return_degraded`
- `glk.recall.hybrid.getDrawers_degraded`
- `glk.recall.corpusOnly.getDrawers_degraded`

Scoring-fallback counters (same `estate_id` tag):

- `glk.recall.locusOnly.matrixAware_degraded`
- `glk.recall.corpusOnly.matrixAware_degraded`
- `glk.recall.hybrid.matrixAware_degraded`
- `glk.recall.unionBest.rrf_degraded`
- `glk.recall.locusOnly.discriminative_degraded`
- `glk.recall.corpusOnly.discriminative_degraded`
- `glk.recall.hybrid.discriminative_degraded`

### Test seam protocol

Each stage has a single-use `_testForce*Error` property on the `GeniusLocusKit`
actor, injected via `_inject(…:)` convenience methods visible to
`@testable import GeniusLocusKit`. Each seam is consumed (set to nil) on
the first recall call that reaches that stage's code path, so subsequent
calls behave normally.

### Relationship to `denseLaneStatus`

`denseLaneStatus` (Step 4.5, dense float lane) predates this section and
follows the same pattern but is specific to the dense float lane's
`FloatLaneOutcome` type. `degradedStages` generalises the pattern to all
remaining class-B sites. Both fields are present on `GLKRecallResult`;
they describe independent failure surfaces.

### Rust parity stage map

The Rust `recall_scored_multi_lane` path has a different lane structure from
Swift, so not every Swift stage identifier exists in the Rust port. Which
stages are present and the architectural reason for any absence:

| Swift stage ID | Rust present? | Rust disposition |
|---|---|---|
| `vectorHamming.findNearest` | YES | The multi-lane path pushes the stage ID and emits the `VECTOR_HAMMING_DEGRADED` counter on `VectorStore::find_nearest` failure |
| `corpus.embed` | YES | Same function pushes the stage ID and emits the `CORPUS_EMBED_DEGRADED` counter on embed failure |
| `pool.getDrawers` | NO | `recall_scored_multi_lane` builds `drawer_index` inline from `estate.recall(frame).collect_all()` (non-throwing); no separate by-id pool load step exists |
| `pool.hydrateBodies.mmr` | YES (stage), never emitted | The Rust UnionBest path runs the step 10 twin (`union_best_mmr_select`) on the bodies of the frame-admissible pool for a `Full` recall. Those bodies arrive with the pool load (`get_drawers_matching_frame` returns full rows for `Structured`/`Full`), so there is no separate MMR body read that can fail: a failed supplemental pool load surfaces as `locus.poolHydrate` and MMR runs on the sourceMask proxy for the ids it could not load, which is the degraded behaviour this Swift stage describes |
| `pool.hydrateBodies.return` | NO | The Rust path builds `drawer_index` from `estate.recall(frame)` and `get_drawers_matching_frame` at the request's hydration level; the returned top-k already carries its body, so there is no separate late body read to degrade |
| `hybrid.getDrawers` | NO | `estate.recall()` in Rust is non-throwing; no `getDrawers` call exists in the hybrid frontier path |
| `corpusOnly.getDrawers` | NO | same reason; the CorpusOnly drawer index is built from `estate.recall()` output |

**Hit provenance and explanation (both ports, 2.16.0).** For every hit
the scored path returns, `sources` names the candidate-SUPPLY lanes only:
locusBitmap, locusGraph, corpusBM25, vectorHamming, vectorDense, with an
empty set falling back to locusBitmap. The matrix, graph, and preference
columns are scoring signals; they travel in the score vector, never in
`sources`. `explanation` is filled per mode: UnionBest hits carry the
`RecallExplainer` block (Swift `RecallExplainer`, Rust
`recall_explainer::explain`) of four lines, `sources: <sorted raw values |
none>`, `score: <every column to two decimals> agreement=… final=…[ span:<best
span index>:<cosine to 3 dp>]` (the trailing `span:` token only on a hit the
span rerank stage scored, 2.21.0), `mode:
<effective mode> | scoring: <request scoring>`, `why: <content query |
bitmap filter match>[; BM25 and vector weighted high][; dense float cosine
match][; MatrixO cluster preserved][; temporal pattern matched][; graph
coherence signal active]`, followed by `denseSignals: vectorDense:<id>, …`
when the dense lane voted for the hit; Hybrid and CorpusOnly hits carry
the sorted source raw values; the locus-only fallbacks carry
`["locusBitmap"]`. The lines are what `moot_memory_search` prints under
each row for `explain: true`, and both ports assert them against
`Tests/Conformance/recall_explainer_fixture.json`.

**Span rerank stage, step 3.5 (both ports, 2.21.0 — Encoder Rerank Program,
contract sheet §8).** The unionBest lexical lane runs its internal BM25 call at
depth 1000 (`SpanRerankStage.lexicalDepth` / `span_rerank::LEXICAL_DEPTH`), never
at a multiple of `frontierK`: the `[64, 256]` clamp bounds the candidate pool
each lane hands the weighted score, not the lexical order the rerank reads. After
the content-deterministic sort of that list and before the pool cap, when the
lifecycle has registered a span encoder for the estate
(`registerSpanEncoder(_:spanVectors:head:for:)` / `register_span_encoder`), the
query has text, and neither `signal:encoder` nor the encoder's own
`dense:<modelID>` weight is `0`, the stage takes the head (`encoder_head` items,
default 30), encodes the query ONCE, reads the serving-generation int8 span rows
for the head items under the encoder's registry model id, and scores each item by
the best `Σ u_i × q_i × scale` over its spans (no renormalisation; the lowest span
index wins an exact tie). The hits are ranked cosine-descending (ties by BM25
rank) and fused back over the WHOLE lexical list by reciprocal-rank fusion with
`k = 60`: `score = 1/(60 + bm25Rank) + w/(60 + spanRank)`, `w` = the
`dense:<modelID>` weight (1.0 by default), `spanRank` over the hits only, ties by
BM25 rank; an item with no span rows under the active model keeps
`1/(60 + bm25Rank)`. The fused list REPLACES the lexical lane — its `bm25` column
carries the fused reciprocal-rank score, normalised at step 6 like every column —
and the pool cap keeps the fused top-`frontierK`. Each selected hit the stage
scored carries `spanHit` / `span_hit` (best span index, word bounds, cosine) for
the composer's evidence snippet and the explainer's `span:` token. A stage
failure (encoder or row read) leaves the lexical order standing, records
`spanRerank` on `degradedStages`, and surfaces no error (sheet §7 failure
contract). With no encoder registered the lane is byte-identical to the
pre-2.21.0 lexical lane. The whole-record vector column leaves the default fused
score (`signal:vector` defaults to `0`), so the stage is the default semantic
signal; `no_encoder` skips it. Parity: the shared fixture
`SynapseKit/Tests/Fixtures/encoder/span_rerank_parity.json` (50 dim-8 span rows,
20 queries, one BM25 head, expected fused orders; ties within 1e-4 cosine are the
ruled tolerance) is asserted by `SpanRerankParityTests.swift` and
`rust/tests/span_rerank_parity.rs`; the stage-in-lane behaviour by
`SpanRerankStageTests.swift` and `rust/tests/span_rerank_stage_parity.rs`.

**Cross-encoder stage, after the admission gate (both ports, 3.19.0;
`CROSSENCODER_SPEC.md`).** When `GLKRecallRequest.rerankDirective` /
`rerank_directive` is `apply` for a packaged profile, the director widens the
lanes' presentation cut to the manifest-clamped `limits.pool` (it raises the
lane request's limit to `limits.pool`; `frontierK` is unchanged) and, after
the §11.18 gate and before the
trace write and the dreaming enqueue, hands the first `pool` hits to
`CrossEncoderStage`: each of the first `head` hydrated candidates is paired
with up to `spans` span texts (its stored span rows ranked by cosine against
the query when a span rerank source is registered, else Spanner windows of
the content), scored by the packaged pair classifier, and the head is fused
back by `1/(k + incoming) + 1/(k + cross)` with `k = 60`; the hits are re-cut
to the caller's limit. The limits come from the manifest keys
`cross_encoder_pool`, `cross_encoder_head`, `cross_encoder_spans`, clamped to
the profile (50 / 30 / 3). The scorer loads on the first apply through the
model directory resolver and is dropped by `close`. A nil or `bypass`
directive is byte-identical to no field; every failure (no runtime, unknown
profile, no model, no query text, scorer failure) returns the incoming order,
reports `degraded` with its reason on `GLKRecallResult.crossEncoder`, and
records `recall.cross_encoder_degraded`. Parity: the shared fixture
`SynapseKit/Tests/Fixtures/encoder/cross_encoder_parity.json` (the lab's
reference orders plus tail and tie cases) is asserted by
`CrossEncoderStageTests.swift` and `rust/tests/cross_encoder_stage_tests.rs`.

**Sub-span dense refinement, step 5.8 (both ports, 2.16.0; bounded 3.9.0;
switched 3.10.0).** The step runs only when the request turns it on:
`GLKRecallRequest.subSpanScoring == .on` / `sub_span_scoring == On`. The
request default is off (sub-span scoring is an additive-cost stage, and
additive-cost features default off, ruling 2026-09-07); every internal
caller names the value at the call site, and the ARIA surface does not
expose it. With the switch off the dense column keeps whatever the dense
lane produced and no `subSpan.budget` stage can be recorded. With the switch
on, on the unionBest matrixAware pipeline, after the graph and preference
columns (step 5.7) and before column normalisation (step 6), when a
CorpusContentEngine is registered and the request carries query text, the
director scores the candidates in the buffer at sub-span granularity
(`CorpusContentEngine.scoreSubSpans` / `score_sub_spans`: transient
sentence-window vectors from the default signal's provider, max cosine
against the query, normalised `(cosine + 1) / 2`) and takes
`max(dense[i], subSpanMaxCosine[i])` as the dense column. The blend can only
raise the column. This is what gives a dense score to locus- and
BM25-supplied candidates the dense lane never ranked; a port that skips it
leaves those candidates with a zero dense column, lower fused scores, and
score ties at the presentation cut. An empty outcome (no float lane, source
unavailable) leaves the column unchanged; the step never throws.

The work is bounded by the CorpusKit `SubSpanBudget` (CORPUSKIT_SPEC: a
per-record byte cap of 16,384 bytes cut on a scalar boundary and an
aggregate budget of 1,024 sub-span embedding calls per query), not by the
candidate pool or the corpus. The director hands the candidates over in
priority order (BM25 score descending, then Hamming similarity descending,
then id ascending, a port-independent tie-break) so the lexical and
fingerprint evidence the refinement exists to rescue is scored before
recency-only supply, and both ports reach the same candidates. When the
aggregate budget stops the walk, the stage `subSpan.budget` is recorded,
the candidates it left without a window keep their stored dense signal,
and the explainer marks their hits with the score-line token
`subSpan:budget`. Pinned by `UnionBestBudgetStagesTests.swift` and
`rust/tests/union_best_budget_stages.rs` (switch on); the switch itself is
pinned by `SubSpanScoringSwitchTests.swift`, `rust/tests/sub_span_scoring_switch.rs`
and the shared fixture `Tests/Conformance/sub_span_scoring_switch_fixture.json`.

**Rust test seam protocol:** `inject_vector_hamming_error` and `inject_embed_error`
on `EstateCoordinator`, gated behind `#[cfg(any(test, feature = "test-seams"))]`.
The `test-seams` Cargo feature enables the seams for integration tests. The
force-tests cover the two present stages and the seam-not-applicable
(locusOnly) case.

## § DATASET_STORE_ACCESS — Raw dataset table surface

Dataset tables are raw backend tables stored below the belief layer
(drawers, tunnels, KGFacts). They are not part of the nine-verb ARIA
surface and carry no decay, audit, or provenance machinery — they are
opaque tabular payloads the host imports and owns.

GLK's role is narrow: providing a type-safe accessor seam so callers
can reach the estate's `DatasetStore` without touching the storage
backend directly. The behavioral contract for `DatasetStore` itself
(schema, query, import, expunge) lives in `LOCUSKIT_SPEC.md §
DATASET_STORE`.

### Accessor

`GeniusLocusKit.datasetStore(for: EstateHandle) throws -> any DatasetStore`

Returns the `DatasetStore` for the named estate. Throws `.estateNotOpen`
if the estate is not open; throws `StorageError.featureGated("datasetStore")`
if the estate's storage backend does not support the dataset tier. This
seam is Swift-only; the Rust port accesses the estate's storage backend
directly.

### Layered content fingerprints (MX-TAB-5)

`computeDatasetSignatures(handle:drawerId:columns:columnStats:sampledRows:now:)`
annotates the drawer that backs a dataset table with two SHA-256 fingerprints:

- **Tier 1 (table):** SHA-256 over the schema and a deterministic sample
  of up to 128 rows (domain tag 0x10). Detects schema drift and gross
  content changes.
- **Tier 2 (per-column):** SHA-256 per column over name, type, and a
  value-distribution sketch (domain tag 0x11). Detects per-column drift
  even when the row count is stable.

Both fingerprints are stored as vector slots on the drawer. The preimage
format is byte-identical between Swift (`Intake/DatasetSignatures.swift`)
and Rust (`rust/src/dataset_signatures.rs`); cross-leg anchor hash
vectors are locked in both test suites. See
`GENIUSLOCUSKIT_INTERFACE.md § Dataset store access` for the full API
surface.

## § 16: Retired adornment orchestration

Schema 19 removed adornment storage and the active-minter orchestration APIs.
The REM-ALPHA duty now indexes content spans.
[The retirement ledger](../decisions/DECISION_RETIRED_TECHNIQUES_LEDGER.md)
records the decision and the deferred library work.

## § TIERED_CONTRADICTION — Tier taxonomy, tiered search, candidate filing, and the review ladder

### Tier taxonomy

Every contradiction finding carries one of three epistemic classes
(`ContradictionTier`, raw values 1/2/3, from the SubstrateML
`ConflictCueKind.contradictionTier` mapping):

- **Tier 1 — typed proof** (`typedProven`): a `conflictProjectionSweep`
  ProvenContradiction. Constraints proved the conflict; no lexical
  score exists — the tier-1 lane ranks by endpoint-event recency, and
  the absence of a score is load-bearing (nothing may fold tiers into
  one ranked list by comparing across it).
- **Tier 2 — structural lexical cue** (`lexicalStructural`):
  negation_asymmetry, marker_revision, word_exclusion.
- **Tier 3 — value divergence** (`lexicalValue`): same claim shape,
  different value (value_divergence).

Tiers are epistemic classes, not score bands: a strong tier-3 lexical
cue never outranks a weak tier-1 typed proof.

### Tiered search (`tieredContradictionSearch` / `tiered_contradiction_search`)

One read-only search verb, two modes:

- **Synthesis** (`tier` nil/None): all three lanes run, then the
  assembler applies promote-to-highest-tier dedup on the
  case-canonical unordered pair key, backfills lower tiers from their
  over-fetch (fetch budgets K / 2K / 3K), and returns the three
  sections in tier order 1-2-3 — never interleaved.
- **Single tier**: ONLY that lane runs, with no cross-tier dedup — a
  purpose-run answers its own question, so a pair that is also a
  tier-1 proof still appears in a tier-3 run.

Retrieval runs ONCE per search: tiers 2/3 share one lexical pass (the
hunter's retrieval + ConflictCue screen, factored as
`lexicalTierScan` / `lexical_tier_scan`); tier 1 reads the typed
sweep. `topK` is clamped to 50 (`TieredContradictionCore.topKCeiling`
/ `TIERED_TOP_K_CEILING`); non-positive returns a deterministic empty
report. Tier-1 findings whose raw sensitivity ceiling exceeds
Elevated are filtered out and counted (`tier1CeilingFiltered`) — the
verb is an ungranted read surface. The search files nothing and
writes nothing.

### Candidate filing (`proposeConflictTunnels` / `propose_conflict_tunnels`)

One typed sweep plus the SAME shared lexical pass files PROPOSED
`contradicts` tunnels at every tier that survives the decline matrix.
Labels are tier-keyed: `dcp: <rule>@<version> result=<id>` (tier 1),
`tier2:<cue>@<cueVersion>` and `tier3:<cue>@<cueVersion>` (lexical
tiers; `conflictCueVersion` = 1 is the rejection-renewal key — a
version bump renews a rejected pair, the new engine is new evidence).
`lexicalTopK` (clamped like the search verb; 0 disables lexical
filing) budgets the lexical lanes. Typed findings above the Elevated
raw ceiling are never proposed and are counted apart
(`ceilingSkipped`).

**Decline matrix** (suppression of re-filing after rejection):

- a rejection at a HIGHER tier class (numerically lower) suppresses
  regardless of label — the rejected proof damns the maybe;
- a rejection at the SAME tier suppresses only the same renewal key;
- a rejection at a LOWER tier class never suppresses.

Live pairs (any label family) always dedupe. `hunter: `-labeled
tunnels sit outside the matrix label families.

### Review ladder (Rejected / Proposed / Endorsed / Accepted)

Model (AI) reviewers may ENDORSE (`endorseTunnel`) and OBJECT
(`objectToTunnel`). ONLY the user ACCEPTS: there is deliberately no
path from endorsements to lifecycle `.active` — edge activation stays
human-authoritative through `Estate.respondToTunnel(accept: true)`,
and no vote total activates anything.

- **Endorse**: one vote per distinct endorser (idempotent
  re-endorsement refreshes its timestamp only), sets the endorsed bit
  (14), sets the contested bit (15) when the ext ledger also holds a
  model objection. Lifecycle untouched.
- **Object**: with NO model endorsement on record the proposal
  WITHDRAWS (the AI-rejected path — the ledger's objection entry
  makes it reopenable; the decline matrix suppresses re-proposal at
  this tier and below, never above). With a model endorsement present
  the tunnel STAYS `.proposed` and the contested bit is set — genuine
  model disagreement is the most user-worthy queue position.

Both verbs fail loud on not-found, not-proposed, empty reviewer
identity, and corrupt ext ledgers. Reviewer identity is recorded on
every transition (including user accept/reject through
`respondToTunnel`).

**Review-queue ranking** (`ReviewQueueRanking` / `review_queue`):
tier class first, contested-first within a tier band, endorser
diversity weight (model family = the prefix before the first `-` or
`:`), then recency. Endorsement weight feeds this ranking only.

State lives on the tunnel (LocusKit): operational bits 14/15 and the
`ext` review ledger — see LOCUSKIT_SPEC.md § tunnel review state.

## § ESTATE_CATALOG — Estate catalog, records and manifests

The catalog is how every command and daemon finds an estate. It replaces
data-directory and database-path environment values: nothing reads a path
from the environment to locate an estate, and no process passes, stores or
moves the configuration directory.

**Configuration directory.** Computed from the platform and the product
identity (`<home>/Library/Application Support/<product folder>`, the folder
name from MootProductIdentity), fixed for the life of the install. The home
is the process family's, decided by a fact about the running process and
never by a build flag or an operator's environment value: the user's home
for an unsandboxed process (the CLI, its resident, moot-mgr, the direct
provider shell), the group container named by the process's own signed
entitlement for a sandboxed one (the Community or Pro app and its nested
helper), and the process's own container for a sandboxed process signed
without the group. Each family shares one catalog and cannot see the
other's; moving an install between families is the takeover recorded in
DECISION_INSTALL_TAKEOVER_2026-09-08. iOS follows the same rule.
It holds configuration files only: `estatecatalog.json` and, after the
flat-layout capsule has run, no estate content. Production code cannot
point the catalog anywhere else; a test seam redirects it and nothing else
does.

**Catalog file.** `estatecatalog.json`, file version 1, JSON with sorted
keys, written atomically. Three fields: `version`, `defaultLocation` (an
absolute path; `<configuration>/databases` on a fresh install) and
`estates`, an ordered list of `{name, path, backend?}` entries with absolute
paths. `backend` is `{"kind": "sqlite"}` or `{"kind": "postgresql",
"connectionString": "..."}` and is omitted for SQLite, so a file written
before the field existed reads as every estate on SQLite. A `postgresql`
entry without a non-empty connection string, a `sqlite` entry carrying one,
or an unknown kind is refused with the file. The configuration directory is
never recorded in the file; it is where the file is. A file that is missing, malformed, of another version, empty, or
whose default location is relative is refused with a named error. The
first entry is the active estate.

**Records.** An `EstateRecord` is a name, a directory, a kind and a
backend. A registered record is one the file lists. A transient record is
one `--db <path>/<name>` attached for a single invocation; transient records
never reach the file, never touch the Keychain, and are always SQLite. The
backend says where the database is: SQLite keeps `estate.sqlite` and its
sidecars inside the directory; PostgreSQL keeps the database at the
record's connection string and the directory holds only the manifest and
the process marker. Rename and relocate keep the backend; registering
names it once. Every file the estate owns is
derived from the record's directory by fixed names: `estate.json`,
`estate.pid`, `estate.sqlite` with its `-wal` and `-shm`,
`estate.queue.sqlite` with its `-wal` and `-shm`, `estate.vectors.vec`,
`encode.drain.lease`. The legacy `no-encrypt` marker is a derived name too,
read only by the upgrade that folds it into the manifest. The list of owned
files is the one list deletion, copy and inventory walk. A record's
selector argument, the value that names it again in another process, is
its name when registered and its directory path when transient.

**Selection.** `open()` loads the catalog and creates it on first run with
one registered record, `default` at `<defaultLocation>/default`. `open(selecting:)`
makes `--db <value>` the active estate for the invocation: a registered
name moves its record to the front; an unregistered name with a path
attaches a transient record at `path/name/`; an unregistered name without a
path is refused. A selector splits on the last path separator, expands a
bare `~` or a leading `~/` to the process home and nothing else (`~user` is
a literal component in both ports; the Rust port follows Linux conventions
and has no user-database lookup), and takes a relative pathname relative to
the working directory. An estate name is one path component: non-empty, not
`.` or `..`, no separators.

**Registered lookup.** `registeredRecord(selecting:)` (Rust
`registered_record_selecting`) answers whether a `--db <value>` names a
registered estate without selecting or attaching anything: a bare name is
looked up by name, a pathname by the canonical path of `path/name/`
(symbolic links resolved for the part of the path that exists, then
standardised), so a registered estate reached through a linked volume or an
alias resolves to its record. `record(atDirectory:)` (Rust
`record_at_directory`) is the directory form. Transient records are never
matched. `open(selecting:)` itself still attaches a transient record for any
pathname; a guard that must protect registered estates asks this question
first.

**Manifest.** Each estate directory carries `estate.json`, file version 1,
with exactly six keys: `fileVersion`, `name`, `schemaVersion`,
`formatVersion`, `encryption` (`encrypted` or `plaintext`) and `created`
(ISO8601 UTC, passed in; the catalog never reads the clock). A manifest
with any other key is refused before anything opens: a path, a redirect or
an unknown field could hide a rogue database under a manifest that looks
right. A manifest whose name is not the directory's name is refused, so a
directory renamed by hand is not adopted under a new name. Every owned file
that exists must be a regular file resolving inside the estate directory; a
symbolic link among them is refused. The manifest is the one file the
catalog writes inside an estate. The refresh every opener runs after the
migration catalog's prepare step (`EstateManifestRefresh`, both ports)
rewrites the manifest when it is missing or its recorded versions differ and
preserves `created`; a manifest that is present but refused is never
overwritten: the refusal goes to the caller, because replacing the file
would erase the evidence and reset `created`.

**Mutation.** Register (a bare name lands under the default location, a
pathname at `path/name/`), relocate (records only; the caller has moved the
files), rename, activate (move to the front) and remove (never the active
record; never touches files) each save the file. Changing the default
location is declared and refused in this version; the command that will
expose it runs over stdio only and refuses while any server is running.

**Boundary.** The catalog is pure storage over two JSON files. It never
opens a database, never stops a daemon, never reads the environment. Which
estates may be encrypted, and where keys live, is decided by the host from
the record's kind: registered estates may hold a key; transient estates are
plaintext. Both ports: the Rust twin is `genius_locus_kit::estate_catalog`
(`EstateCatalog`, `EstateRecord`, `EstateSelector`, `EstateManifest`) over
the same two JSON files, byte-compatible with the Swift writer (sorted keys).

## § ESTATE_OPEN_POSTURE — The at-rest open decision and key custody

One decision, beside the catalog, for every process that opens an estate:
the posture the estate's file requires and the key that goes with it.
serve, drain, dream, upgrade, db, the resident daemon and the app route
through it, so they cannot drift apart on encryption.

**The rule.** The decision is about a database file, so a record whose
backend keeps the database elsewhere (PostgreSQL) is refused with a named
error and the caller opens that backend directly; no key is minted for it.
An existing plaintext estate must keep opening; migration to encryption is
a separate user-initiated step (`mootx01 upgrade`), never implicit. For a registered estate: file absent and the manifest declares
plaintext, open plaintext and create plaintext; file absent otherwise,
provision a key and create encrypted; file present and ciphertext, load the
EXISTING key and fail closed when it is missing; file present and plaintext,
open plaintext. For a transient estate: plaintext only, and ciphertext is
refused whether or not a key exists for the path (a Keychain item in Swift,
a `db.key` beside the database in Rust): a transient estate has no custody
to use a key with. The ciphertext branch never mints a key:
minting would hand the database a wrong key for a file already encrypted
under another, and a caller that read the failed open as "no estate" could
create a plaintext file over the top. The absent branch and the ciphertext
branch therefore use different key calls.

**The manifest gate.** The record form of the decision reads the record's
`estate.json` for the plaintext declaration. A manifest the catalog refuses
(an unknown key, a foreign name, a symbolic link among the estate files)
refuses the open with a typed error (`manifestRefused`, carrying the
catalog's refusal; Rust `ManifestRefused`) rather than being read as "no
declaration". An absent manifest declares nothing, and the estate files are
still required to be regular files inside the directory.

**The table.** The decision table, one row per combination of record kind,
declaration, file state and key presence, is
`Tests/Conformance/estate_open_posture_fixture.json`, read by both ports'
posture tests; a row cannot change in one port without failing in the other.

**Classification.** The file's state (absent, plaintext, ciphertext) is read
from its header, never inferred from an attempted encrypted open. An empty
or truncated file is ciphertext, not absent, so no caller is invited to
overwrite a file it did not understand.

**Custody.** Apple platforms hold the key as a Keychain generic-password
item under the product's estate key service, scoped per estate by a hash of
the estate's standardized path. Because the account is the path, a key
follows a moved file: a capsule that moves an estate relocates the key to
the new path's account first (store under the new account, never
overwriting an item already there, then remove the old), so a run
interrupted at any point resumes with the key in place; a plaintext estate
has no key and nothing moves. The flat-layout capsule does this before its
database rename. A new key is minted into the shared access
group on macOS, so the app and a separately spawned server read one item,
and into the default group on iOS, which has no spawned peer and no
shared-group entitlement. Lookups probe the shared group and then the
default group, where estates keyed before the shared group existed keep
their key. Every key call returns exactly 32 bytes or throws; nothing
returns nil and nothing falls back to plaintext for a file that is not
plaintext. Only a registered estate may hold a Keychain key. Disposal
removes the item from both groups and is best effort: a missing item is not
an error, and a Keychain failure is reported, never allowed to stop a
teardown. The service and access-group strings are the product identity's,
spelled once.

**Harness builds.** Under the Swift compile condition
`MOOTX01_HARNESS_KEYFILE`, and under the Rust feature `harness-keyfile`, a
key file beside the database is consulted before the record's kind on every
branch and for every record, so a harness run never reaches Keychain custody
and may serve a converted transient estate. The file's state and the
manifest's declaration still decide as above: a declared-plaintext estate is
created plaintext, key file or not. Absent from every shipping binary in
both ports; no product crate or target enables either.

**Boundary.** The decision never prompts and never migrates; serve runs
under launchd with no TTY. Two estates that are not catalog records, the
resident daemon's and the app container's, take the URL form of the
decision with the machine's ownership stated by the caller. Both ports take
the same decision (`genius_locus_kit::EstateOpenPosture::resolve(record)` /
`resolve_file(database, registered, declares_plaintext)`); key custody
differs by platform: Swift holds the key in the Keychain, the Rust port keeps
`db.key` beside the database (`persistence_kit::ensure_install_key`), minted
for a registered estate only and consulted for a registered estate only.

## § FACT_EXTRACTION_DUTY — Bounded source-grounded extraction

GeniusLocusKit defines fact extraction as standing Signal 14,
`fact-extraction`. The signal fires every 300 seconds, has a 600-second
freshness target, and uses single concurrency.

**Activation contract (FACT_EXTRACTION_WIRE §2).** At estate open the
resident daemon resolves Signal 14's live state through a single decision
function (`resolveFactExtractionCycle` in Swift, equivalent in Rust) that
reads the estate's `fact_extraction` setting and the provisioned extractor and
applies one of three mutually exclusive cases:

1. **Setting is `.off`:** Signal 14 stays inert. The operator has disabled
   extraction for this estate. No activation call is made.
2. **Setting is `.on` and an extractor is available:** Signal 14 is live. The
   daemon calls `activateFactExtractor(_:recipeID:for:)` /
   `activate_fact_extractor` with the extractor and its recipe ID, then passes
   the live cycle closure as `factExtractionCycle:` /
   `fact_extraction_cycle`. The cycle calls `runFactExtractionBatch` /
   `run_fact_extraction_batch` on each signal tick.
3. **Setting is `.on` but no extractor is available:** Signal 14 stays inert.
   This is the common case in a fresh install where no model assets are
   installed. It is logged and treated as a normal operating condition, not an
   error — the daemon continues serving.

The recipe ID is derived from the extractor's model spec and encodes the
cross-port contract: `"\(providerID):\(modelID):\(modelVersion)"`. Changing
any field of the triple clears bit-28 debt estate-wide (reattaching the same
recipe is a no-op).

**Provider selection in product hosts.** `fact_extraction` is the on/off master
switch. When it is on, `fact_extractor` chooses exactly one provider:

1. **`apple`:** Apple Foundation Models on macOS and iOS when the system model
   reports available. The Rust product has no Apple provider and stays inert
   with one diagnostic line.
2. **`nuextract`:** CoreAI NuExtract in the hidden Swift child process on
   macOS, or Candle NuExtract in the sibling Rust worker on Linux. iOS has no
   NuExtract provider and stays inert with one diagnostic line.

The Apple product builds `MootFoundationModelsKit` unconditionally and the
`apps/mootx01` package floor is macOS 27. NuExtract first resolves settings
module path overrides, then the pinned model staged beside the product binary;
a transient estate reads only its own optional settings directory and does not
depend on the user's install-wide `config.json`. Both `serve` and `dream` use
the same provider builder and activation recipe. The detached dream finisher
runs one bounded fact-extraction batch before the REM queue gate, so Signal 14
debt progresses even when no dreaming job is pending.

That cycle calls `runFactExtractionBatch` / `run_fact_extraction_batch`; the
batch returns a zero result when the limit is non-positive or no extractor
recipe is registered in the running coordinator.

Each batch reads a bounded, drawer-ID-ordered selection of bit-28 extraction
debt. Empty and tombstoned drawers are skipped. The duty splits the unchanged
original body into source-exact overlapping chunks bounded by the active recipe,
bounds the candidate count, and grounds every candidate against that same
original body. The embedded NuExtract adapters request one fact per bounded
chunk and let the host assign trust metadata; a case-normalized evidence answer
may select only an exact original-source line containing both extracted
endpoints. An empty model response is a completed zero-fact extraction. A
non-empty response whose candidates are all ungrounded is a per-source failure
and leaves the drawer as retryable debt.

On macOS, the native NuExtract provider runs CoreAI only inside the hidden
`mootx01 coreai-nuextract-worker` child process; the long-lived host owns the
`FactExtractor` client and pipes, never the model or KV cache. Swift and Rust
workers use protocol version 2 with the same four-byte big-endian length plus
JSON request/response envelopes. The Swift client serializes requests, recycles
the child after a bounded request count, reaps it after 120 idle seconds, and
releases it explicitly on shutdown. Swift does not invoke Rust code.

Accepted candidates become source-anchored KGFacts with the evidence quote,
UTF-16 code-unit and UTF-8 byte offsets, source digest, extractor provider/model/schema
metadata, current search projection and version, and operational bitmap. The
duty retires stale machine-extracted facts for the same source and preserves
manual and imported facts. The KGFacts, extractor registry, projection fields,
and bit-28 store contract remain owned by
[LOCUSKIT_SPEC § FACT_EXTRACTION](LOCUSKIT_SPEC.md#-fact_extraction-fact-extractor-registry-kg_facts-evidence-and-projection-columns-factsextracted-bit-schema-v20).

Activation and settlement are idempotent. Reattaching the unchanged active
recipe creates no debt and returns zero; changing recipes clears bit 28 through
the LocusKit registry transaction. A batch reuses an active semantic match,
mints deterministic IDs for new facts, and adds a deterministic reactivation
ordinal when a retired ID already exists. Settlement sets bit 28 only when the
drawer content still matches the extracted source. A source change before
settlement leaves the drawer unsettled and retires facts newly filed from the
stale snapshot. Per-source extraction or storage failures fail open and
preserve debt for a later cycle.

## Sensitivity-withheld recall count

Every GLK-owned recall carrier — `GLKRecallResult`, `FederatedRecallResult`, and
`VagueRecallResult` — carries `withheldBySensitivity` / `withheld_by_sensitivity`.
It is the number of primary drawers that LocusKit's default-injected sensitivity
ceiling excluded while every other predicate in that carrier's request frame
admitted them. An explicit sensitivity predicate disables that default and
reports zero. Federated recall counts only the successfully grant-authorized
source estate's content-and-scope-admitted candidates; vague recall counts only
hop-1 primary vague candidates, never hydrated constituents. The count is
calculated from LocusKit's persisted candidate set; excluded drawers do not cross
the LocusKit boundary. Recall hits, scoring, ordering, and defaults are otherwise
unchanged.

## Counted endpoint hydration

`hydrateWithSensitivityCount` / `hydrate_with_sensitivity_count` forwards the
exact supplied candidate IDs and frame to LocusKit and returns
`GLKHydrationResult`: admitted drawers and the sensitivity-only count. GLK
performs no sensitivity classification or loaded-minus-admitted subtraction.
No rejected drawer or rejected-ID list crosses this API. For ARIA keystones,
the supplied population is the ranked topK endpoint IDs presented for hydration,
not all graph endpoints. Ranking and later provenance projection are unchanged.

## § RECALL_ROUTER — Recall router and Route 1 (cross-encoder conversation routing)

The recall director runs an ordered route list once per scored recall, before
the lane request is built and before `rerankDirective` / `rerank_directive` is
read. A request that already carries a directive is never re-routed.

### Route structure

Each route has three parts:

| part | type | Route 1 |
|---|---|---|
| preference key | estate manifest key (`"on"` / `"off"`, default `"on"`) | `cross_encoder_routing` |
| predicate | `(queryText: String) → Bool` | `isConversationQuestion(query)`: quoted speech, a speaker cue (said, told, asked, replied, mentioned), the "what did X say" form, or a conversation / transcript / chat / session / meeting / call reference; case-insensitive; the cue list is shared with Rust `CONVERSATION_CUES` |
| transform | `GLKRecallRequest → GLKRecallRequest` | set `rerankDirective = .apply(reason: "route:cross_encoder_routing")` (Swift) / `rerank_directive = RerankDirective::apply(Some("route:cross_encoder_routing"))` (Rust) — the degradable directive: the stage reranks the head when it can run and, when it cannot, reports the degrade reason and leaves the ordinary lane order standing. The fail-closed `.strictTranscript()` / `strict_transcript` directive (empty strict pool → zero rows) belongs to the `moot_memory_recall_transcript` operation alone; the router never sets it, so a routed ordinary question never loses results |

The director applies the first route whose preference is `"on"` (or absent —
absent defaults to `"on"`) and whose predicate is true, then stops. It does
not apply multiple routes to one request.

### `GLKRecallResult.route` / `route`

`String?` (Swift) / `Option<String>` (Rust). The preference key of the route
that transformed this request, or nil / `None` when no route fired. It is nil
for every non-scored recall path. Both ports expose it on `GLKRecallResult`
beside the existing `crossEncoder` / `cross_encoder` field.

### Preference `cross_encoder_routing`

Estate manifest key. Values `"on"` / `"off"`. Absent key defaults to `"on"`
(the product default). The director resolves every route's preference before
calling the router — `RecallDirector.provisionedRecallRoutePreferences(estate:)`
(Swift) / `EstateCoordinator::provisioned_recall_route_preferences` (Rust), one
manifest read per route in the list, using the same fail-quiet plain-string
read pattern as `fact_extraction` — and passes the resolved map keyed by
preference key. The router itself never reads the estate. The key the read
uses and the key the result reports are the route value's single
`preferenceKey` / `preference_key`.

Off means: the router returns the request unchanged. The cross-encoder stage,
the model, and the transcript operation are untouched by the preference.

### Implementation coordinates

| port | file | route value / list / apply | call site |
|---|---|---|---|
| Swift | `RecallRouter.swift` | `RecallRoute` (preferenceKey, predicate, transform); `crossEncoderRoute`; `recallRoutes: [RecallRoute]`; `applyRecallRoutes(_:preferences:)` walks the list | `RecallDirector.swift` before `let directive = routedRequest.rerankDirective` |
| Rust | `recall_router.rs` | `RecallRoute` (preference_key, predicate, transform); `CROSS_ENCODER_ROUTE`; `RECALL_ROUTES: &[RecallRoute]`; `apply_recall_routes(request, &preferences)` walks the list | `coordinator.rs` `recall_scored`, before the directive is read |

Adding a route is appending an entry to `recallRoutes` / `RECALL_ROUTES` with
its own preference key, predicate and transform. The apply function does not
change.

No manifest or dependency change required; `ContextDistillLib` was already a
dependency in both ports.

## Estate preferences

Every USER-OWNED estate switch is one `EstatePreferenceKey`, stored in the
estate manifest as the plain string `"on"` or `"off"` under the key's raw
value. `provisionPreference(_:_:for:)` writes `value.rawValue` via
`Estate.setMeta(key:value:)`; `provisionedPreference(_:for:)` reads
`Estate.meta(key:)` and returns `.on` for an absent key, an unrecognised
string, or a storage error. Rust: `EstateCoordinator::provision_preference(handle,
key, value)` writes `value.as_str()` via `Estate::set_meta`;
`provisioned_preference(handle, key)` reads `Estate::meta(key.as_str())` and
returns `On` under the same three conditions. ON is the ruled product default for every key;
seeding capsules (I-27 for `fact_extraction`, I-28 for the other five) write
the value explicitly — never overwriting a value already stored — so a later
default change cannot silently flip an estate already in use.

| `EstatePreferenceKey` case (Swift / Rust) | manifest key | allowed values | default |
|---|---|---|---|
| `.factExtraction` / `FactExtraction` | `fact_extraction` | on, off | on |
| `.consolidation` / `Consolidation` | `consolidation` | on, off | on |
| `.contradictionSweep` / `ContradictionSweep` | `contradiction_sweep` | on, off | on |
| `.crossEncoderRouting` / `CrossEncoderRouting` | `cross_encoder_routing` | on, off | on |
| `.maintenance` / `Maintenance` | `maintenance` | on, off | on |
| `.adaptiveRecall` / `AdaptiveRecall` | `adaptive_recall` | on, off | on |
| `.factExtractor` / `FactExtractor` | `fact_extractor` | nuextract, apple | nuextract |

`fact_extractor` selects the engine the fact-extraction duty uses. `fact_extraction` (on/off) remains the
master switch; `fact_extractor` controls which engine runs when the duty fires. Absent or unrecognised
values read as `nuextract`. No seeding capsule: absent reads as the default on every estate without a
migration step.

## Handle-scoped consumer access

All consumers and tests outside GLK address an estate only with an
`EstateHandle`. The stale-only read set is `listRooms(in:wing:)`,
`auditTrail(in:rowID:)`, `meta(in:key:)`, and the existing drawer, tunnel,
fact, and node-name reads. These reads preserve lower semantics; no universal
caller sensitivity filter is implied. The frame-filtered drawer read applies
its frame admission rule.

The mounted write set is `setMeta(in:key:value:)`,
`setSSCFacts(in:_:for:)`, and
`setSubjectRepresentation(in:drawerId:subject:pipelineVersion:at:)`.
Each rejects stale, quiesced, or draining handles before the lower write and
remaps lower-operation errors through GLK's verb boundary. SSC-fact and
subject writes return their updated-row counts. `expunge` remains the existing
`ExpungeVerbOutcome`-returning verb; no archive-specific expunge twin exists.

## Security repair contract

Production `reindexCorpus` / `reindex_corpus` and the resident dreaming retrain boundary load `corpus.lsa_retraining` settings once per attempt: `max_documents` defaults to 2048, `max_sweeps` to 30, and `timeout_milliseconds` to 30000. The content source admits at most the document cap plus one through a storage-level limited ID query before reading training bodies. Skipped training preserves the previous model and does not advance the dreaming vocabulary baseline. Rust runs the bounded engine outside the coordinator mutex; Swift training uses asynchronous provider jobs.

### Bounded accounting and dynamic signals

A scored recall's sensitivity-withheld count is candidate-relative, derived
from the retrieval work already performed. It is not a total estate count.
Each mode selects one primary candidate evaluation, so overlapping lanes do
not double count. Standing signals support idempotent removal together with
their subscriptions, enabling runtime preference reconciliation.

## Changelog

### 3.45.0 — 2026-09-15

Updated the security repair contract and cross-port API guarantees above.


### 3.44.0 -- 2026-09-15

Completed the handle-scoped consumer contract: documented `listRooms`,
`auditTrail`, `setMeta`, `setSSCFacts`, and `setSubjectRepresentation`, plus
the distinct stale-only read and mounted-write error behavior. I-3 now applies
the handle-and-verb-only rule to all consumers and tests outside GLK.

### 3.43.0 -- 2026-09-15

I-3 now names the access surface. AriaMcpKit reaches drawers, tunnels, facts
and estate meta through GLK's handle-scoped reads and holds no
`LocusKit.Estate`; the thirty `estate(for:)` sites it carried are gone. The
read surface is additive on the INTERFACE (3.38.0).

### 3.42.0 -- 2026-09-15

Drain and settle: the drain report (`drainStatuses` / `drain_statuses`)
ALWAYS carries a `fact_extraction` lane. Its `pending` is the estate's
fact-extraction debt — live drawers with content whose bit 28 (facts
extracted for the active recipe) is clear — and its `in_flight` is 0,
because extraction is the bounded batch inside a dreaming cycle, never a
queued job. The lane renders whether or not an extractor is registered (an
absent lane would read as "nothing owed"); the detail says when no
extractor is registered and the debt therefore cannot move. Every
`mootx01 dream` run performs one bounded batch and reports facts filed;
this lane is the product's statement of whether extraction is finished, so
a caller (the benchmark bulk build, a dream loop) settles an estate on the
lane reaching idle instead of running blind cycles. The lane is non-gating
for `encodeSettled` / `encode_settled` and for the benchmarker's encode
barrier denylist, like every row-debt lane. Both ports.

### 3.41.0 -- 2026-09-15

Product `serve` and `dream` hosts now consume both fact preferences and
activate the selected provider through the existing duty contract. Apple
Foundation Models serves `fact_extractor=apple` on Apple platforms; CoreAI
and the sibling Candle worker serve `fact_extractor=nuextract` on macOS and
Rust respectively. Transient estates resolve only their own optional settings
and the staged product model. NuExtract uses a bounded single-fact schema over
original source text; the duty emits deterministic UUID-form fact IDs. No
public GeniusLocusKit signature changes.

### 3.40.0 -- 2026-09-15

Adds the `fact_extractor` preference key (Swift `.factExtractor`, Rust `FactExtractor`; manifest key
`fact_extractor`). Allowed values: `nuextract` / `apple`; default: `nuextract`. No seeding capsule:
absent reads as `nuextract` without a migration step. `fact_extraction` (on/off) remains the on/off master
switch; `fact_extractor` picks the engine when the duty fires. Both ports gain `allowedValues` /
`allowed_values` and `defaultValue` / `default_value` on `EstatePreferenceKey`. The `provisionedPreference`
/ `provisioned_preference` pair falls back to `key.defaultValue` / `key.default_value()` for absent,
unrecognised, or out-of-allowed values. The `provisionPreference` / `provision_preference` pair refuses a
value outside `key.allowedValues` / `key.allowed_values()`.

### 3.39.0 -- 2026-09-14

The Swift package's default trait set is every migration capsule trait, so a
bare `swift test` runs each capsule test target with a non-zero count.
Consumers selecting a `MigrationFloor` are unchanged. Swift manifest only.

### 3.38.0 -- 2026-09-14

§ RECALL_ROUTER: Route 1's transform sets the degradable `apply` directive
(reason `route:cross_encoder_routing`) rather than the transcript operation's
fail-closed `strictTranscript` / `strict_transcript`. A routed ordinary
question keeps its lane order when the cross-encoder stage cannot run; strict
semantics stay with `moot_memory_recall_transcript`. Both ports.

### 3.37.0 -- 2026-09-14

§11.2 standing-signal table rewritten to the current fourteen-signal
registration order with an estate-preference column: the maintenance family
(`maintenance-daemon` tombstone grace, `decay-sweep` quiet-row decay,
`by-reference-validity` by-reference drift) runs one NeuronKit maintenance
category each under `maintenance`; `contradiction-sweep` (hourly, files
`.proposed` contradicts tunnels) under `contradiction_sweep`;
`consolidation-sweep` under `consolidation`; the adaptive-recall trio
(`temporal-causality-fold`, `training-daemon`, `end-of-day-tournament` —
Bradley-Terry ratings into `recall_ratings`, daily) under `adaptive_recall`.
A gated signal is registered only when its preference is on (absent = on);
the governor tick no longer pumps maintenance. The unionBest `.matrixAware`
matrix term adds `ratingWeight` (0.1) × the drawer's tournament rating, zero
without a rating row. `similarRecall` / `similar_recall` (the paraphrase
door over the whole-record LSA lane) joins the verb surface. The estate
preferences section cites I-28 alongside I-27.

### 3.36.0 -- 2026-09-14

Estate format V1_9 and the 1.8→1.9 preference-seed capsule (I-28), both
ports: `EstateFormatVersion.v1_9` / `V1_9` is current; the capsule seeds the
`consolidation`, `contradiction_sweep`, `cross_encoder_routing`,
`maintenance` and `adaptive_recall` preferences `"on"` where absent (never
overwriting a stored value), creates the `recall_ratings` table through the
schema ladder and stamps V1_9 as the last write of the chain. The 1.7→1.8
capsule now runs only for a stamp below V1_8.

### 3.35.0 -- 2026-09-14

Signal 7 (end-of-day-tournament) has an engine: `GeniusLocusKit.endOfDayTournament(_:now:)`
(`Brain/EndOfDayTournament.swift`) groups the day's recall traces by minute of
`recalledAt`, turns each group with two or more distinct UUID targets into one
`PreferenceObservation` (first-listed drawer wins), feeds them to a
`SubstrateML.BradleyTerryEstimator` seeded from the stored `recall_ratings` rows and
upserts the strengths with `contests` carried forward, returning
`TournamentReport(contests:ratedDrawers:)`. §11.2 row 7 records it. Swift.

### 3.34.0 -- 2026-09-14

Rust estate preferences generalised to match Swift: `EstatePreferenceKey` and
`EstatePreferenceValue` (module `estate_preference`) replace
`coordinator::FactExtractionSetting`, the `provision_preference` /
`provisioned_preference` pair replaces the fact-extraction accessor pair and
`FACT_EXTRACTION_META_KEY`; the 1.7→1.8 capsule seeds through
`provision_preference(handle, FactExtraction, On)`.

### 3.33.0 -- 2026-09-14

Swift estate preferences generalised: `EstatePreferenceKey` (six keys) and
`EstatePreferenceValue` replace `FactExtractionSetting`, and the
`provisionPreference` / `provisionedPreference` pair replaces the
fact-extraction accessor pair; the 1.7→1.8 capsule seeds through
`provisionPreference(.factExtraction, .on, for:)`. Rust surface unchanged.

### 3.31.0 -- 2026-09-14

§ RECALL_ROUTER: the implementation coordinates name the route value
(`RecallRoute`), Route 1 (`crossEncoderRoute` / `CROSS_ENCODER_ROUTE`), the
ordered list (`recallRoutes` / `RECALL_ROUTES`) and the apply function that
walks it; the preference is resolved per route by the director and passed to
the router as a map keyed by preference key. Adds the recall router: an ordered route list applied once per scored recall
before the lane request is built. Route 1 fires the cross-encoder
strict-transcript stage when the question reads as being about a conversation
(`isConversationQuestion`: quoted speech, a speaker cue, or a conversation
reference) and the `cross_encoder_routing` estate preference is `"on"` (the
default). `GLKRecallResult.route` / `route: Option<String>` carries the
preference key of the fired route, or nil / `None` when no route fired. Both
ports ship the router, the preference reader, and the result field.

### 3.30.0 -- 2026-09-14

FACT_EXTRACTION_WIRE §2 (Swift port): Signal 14 activates live in the
resident daemon. The activation contract is a single decision function with
three cases (setting=off → inert; setting=on + extractor → live; setting=on +
no extractor → inert). The recipe ID is `providerID:modelID:modelVersion`.
`MootProductIdentity.Settings` gains three parsed keys from the
`fact_extraction` JSON object: `coreai_asset`, `coreai_tokenizer`,
`model_version`. The resident daemon activates CoreAI NuExtract when its asset
paths are present in `config.json`; no other extractor is part of the daemon.
Apple Foundation Models (`MootFoundationModelsKit`) requires macOS 27 and
ships in `apps/Mootx01-App`, not in the `mootx01` CLI. The `apps/mootx01`
package minimum remains macOS 26.

### 3.29.0 -- 2026-09-14

### 3.27.0 -- 2026-09-13

Added the counted endpoint hydration API and admitted-rows-only result contract
for ranked topK keystones hydration.

Added the sensitivity-withheld count to every GLK recall result carrier in both
ports, including federated and vague recall.


### 3.26.0 -- 2026-09-13

Defines the Brain-layer fact-extraction duty, its inert resident Signal 14
wiring, opt-in schedule, gating, source-grounding, writes, failure handling,
and idempotence. Defines the
explicit fact-first recall decision stage, default thresholds, deterministic
scoring and qualification rule, and fallthrough contract in both ports.

### 3.25.0 -- 2026-09-13
GLK-CEILING: sensitivity ceiling enforced on the two write verbs that resolve a
target row without a prior sensitivity check. `expunge` and
`retireKGFact`/`withdraw_kg_fact` now refuse .restricted/.secret targets (any row
whose `adjectiveSensitivity.rawValue > AdjectiveSensitivity.elevated.rawValue`) by
throwing/returning the same error an absent-row target would produce — no existence
oracle is provided. The check uses an explicit case/raw-value comparison rather than
`isBulkExportable` so a future change to the bulk-export tier cannot silently shift
the security boundary. `expunge` reuses the step 0.5 pre-read; `retireKGFact` calls
`getKGFact` before `withdrawKGFact`; Rust `withdraw_kg_fact` uses an O(n) scan via
`all_kg_facts_including_retired` (acceptable for an infrequent write verb).

### 3.24.0 -- 2026-09-12

`withdraw_kg_fact` / `retireKGFact` signature widened. The Rust
`EstateCoordinator::withdraw_kg_fact` and the Swift `VerbSurface.retireKGFact`
both now accept `changed_by` / `changedBy` (non-empty string, required) and
`reason` / `reason` (optional string). Both delegate to `DrawerStore`'s widened
call which routes through `audit_gate::admit` / `AuditGate.admit` (verb
`Retract`) and emits a sealed audit row in the same transaction. Spec § B-15
updated with the new signature and audit contract.

### 3.23.0 -- 2026-09-10

This revision reconciles governed dataset filing and the signature-patch
contract and completes caller adoption of the typed tunnel boundary.
`fileDataset` / `file_dataset` is UDC-only across ports; Swift's richer lower
anchor remains outside that common surface. Typed capture and settlement cross
the mounted/stale gate. No review fields, synthetic audit signal or index, or
metadata broker was added.

### 3.22.0 -- 2026-09-10

Added the typed GLK write boundary in both ports: capture and settle tunnels,
capture dataset handles, stamp the fixed `aria.fdc.recalced_data_version` FDC
floor, and reanchor with explicit audit provenance. The mounted/stale gates
apply before each write. Tunnel settlement retains LocusKit's atomic lifecycle
and `reviewedBy` ledger update; reason and time are forwarded but remain
non-persisted. No schema migration, synthetic audit event, signal, index, or
generic metadata broker is introduced.

### 3.21.1 -- 2026-09-08

Wording only: cross-encoder stage description changed "to the profile's pool"
to "to the manifest-clamped `limits.pool`" to match the CROSSENCODER_SPEC.md
§ pool/head/spans terminology; no contract change.

### 3.21.0 -- 2026-09-08

The Windows base-directory adoption capsule, Rust only. The Swift base
directory is `<Application Support>/com.mootx01.ce` before the estate catalog
and after it, so the Swift port adopts a layout and never a base. The Rust
port is the reverse: its layout was always `databases/<name>/`, and on Windows
its base moved from `%LOCALAPPDATA%\MOOTx01` to
`%LOCALAPPDATA%\com.mootx01.ce`. Linux is unaffected; both sides resolve
`${XDG_DATA_HOME:-~/.local/share}/mootx01`. Contract: when the old base holds
any child, the capsule moves every child of it into the configuration
directory, refuses and touches nothing when any child's destination already
exists, removes the emptied old base, and does nothing on a host that never
had one or on a machine already adopted. Every child moves, not a named
subset, because the old base held the same roles the new one now holds: the
estate root, the LatticeLib novel-token pool with the merged
`WordClassTable.json` derived beside it, the moot-mgr history store and the
daemon port file. Each child is one atomic rename, so a run interrupted
between renames resumes on the next call. The capsule is compiled by every
build rather than gated on a migration floor, because the old base can hold an
estate of any format, and it runs before the catalog opens rather than inside
the migration chain, because the chain needs an estate the catalog can already
name. `install` and `upgrade` both call it, first, before their own catalog
open.

The novel-token pool directory is pinned in both ports. Apple resolves
`<Application Support>/com.mootx01.lattice/pool`
(`MootProductIdentity.Storage.latticeFolder` / `LATTICE_FOLDER`) in both,
because one Mac runs both ports and both must reduce into one writable
`WordClassTable.json`. Linux and Windows, where Swift has no target, resolve
`<configuration>/lattice/pool`.

The GeniusLocusKit package enables every capsule trait by default — both
layout traits and every `MigrationV1_x` format step — so a bare test run of
the package exercises every capsule; a consumer that selects a floor replaces
that set.

### 3.20.0 -- 2026-09-08

The open posture table is one table in both ports. A transient ciphertext
estate is refused whether or not a key exists for it (the Rust port
consulted `db.key` for a transient record; it follows the Swift rule and the
spec now). The record form refuses a manifest the catalog refuses with a
typed error instead of reading it as "declares nothing". The harness key
file is a compile condition in both ports (Swift `MOOTX01_HARNESS_KEYFILE`,
Rust feature `harness-keyfile`) and honours the plaintext declaration. The
table is pinned by `Tests/Conformance/estate_open_posture_fixture.json`,
read by both ports' tests. The manifest refresh never overwrites a manifest
it could not read. The selector expands a bare `~` and a leading `~/` only,
both ports. § ESTATE_CATALOG gains the registered lookup by canonical
directory (`registeredRecord(selecting:)` / `record(atDirectory:)`).

### 3.19.0 -- 2026-09-08

The retrieval-time cross-encoder stage (§ FAIL_LOUD stage paragraph and the
`recall.cross_encoder_degraded` row), both ports: the `apply` directive on
the recall request, the widened cut, span selection, the packaged pair
classifier, reciprocal-rank fusion, the lazy per-estate scorer, the manifest
limits and the report. Contract: `CROSSENCODER_SPEC.md`.

### 3.18.0 -- 2026-09-08

Rust twins of § ESTATE_CATALOG and § ESTATE_OPEN_POSTURE:
`genius_locus_kit::estate_catalog` and `estate_open_posture`, the
`genius_locus_kit_migrations::estate_manifest_refresh` step, and the
`moot-product-identity` crate over the shared `product_identity.json`
fixture. The Rust port's key custody stays `db.key` beside the database.
Estate selection in every Rust process is the catalog's; no environment
value selects an estate, its data directory, its posture or its federation.

### 3.17.0 -- 2026-09-08

The configuration directory's home is the process family's
(`MootProductIdentity.Storage.processHome`): the user's home when
unsandboxed, the group container named by the process's signed app-group
entitlement when sandboxed, the process's own container when sandboxed
without the group. Replaces the per-process container home of 3.15.0, under
which a sandboxed app and its nested daemon helper would each have had their
own catalog. Swift only.

### 3.16.0 -- 2026-09-08

The app-container capsule, Swift only. A pre-catalog Apple app build kept its
estate at `<Application Support>/mootx01/mootx01.sqlite` inside its
container; the catalog places the same estate at
`<configuration>/databases/default/estate.sqlite`, the configuration
directory being computed from the same container home. Contract: when the
legacy database exists and the active record is the registered default, the
capsule relocates the Keychain key to the new path's account, renames the
WAL and SHM sidecars under the catalog's names, renames the database last,
and removes the emptied legacy folder; a run interrupted at any point resumes
on the next call. When both databases exist it refuses and touches nothing.
The pre-catalog app wired no queue or vector sidecar, so the three files are
the whole estate. Trait `MigrationAppContainerToCatalog`, enabled by every
floor from 1.0 through 1.6, retired with the flat-layout capsule.

### 3.15.0 -- 2026-09-08

Two corrections to the catalog line. The configuration directory's home is
the process home (`NSHomeDirectory()`): the container inside a sandbox on
macOS and iOS, the user's home otherwise; the previous macOS-only call did
not compile for iOS. A key follows a moved estate file: `EstateOpenPosture.
relocateKey(from:to:)` moves the Keychain item to the new path's account
(idempotent, never overwriting), and the flat-layout capsule calls it before
its database rename, which it did not before; an encrypted 1.0.x estate moved
by the capsule would otherwise have failed closed on its next open. Swift only.

### 3.14.0 -- 2026-09-08

The estate record's backend. `estatecatalog.json` entries carry an optional
`backend` (`sqlite`, the default when absent, or `postgresql` with a
non-empty connection string); a malformed backend refuses the file. The
record's directory keeps the manifest and process marker on every backend;
the database files derived from it exist only for SQLite. Rename and
relocate preserve the backend. § ESTATE_OPEN_POSTURE refuses a PostgreSQL
record (no file, no key) instead of classifying an absent file as a new
encrypted estate. The kit reports the PersistenceKit backend each open
estate runs on (SQLite, PostgreSQL, InMemory) so the resident's estate
listing labels each estate from the kit rather than from the process
environment. Swift first; the Rust twin landed in 3.18.0.

### 3.13.0 -- 2026-09-08

§ ESTATE_OPEN_POSTURE added. The open posture and key custody that lived in
the mootx01 installer library move into the kit beside the estate catalog,
so the CLI commands, the resident daemon, the app and the maintenance tool
make one decision. The resident daemon and the app previously minted a key
whenever none was found, including for a ciphertext file whose key was
missing; they now fail closed like every other opener. The Keychain service
and access-group strings are the product identity's. Swift only.

### 3.12.0 -- 2026-09-08

§ ESTATE_CATALOG added: the estate catalog contract that the catalog
commits on this line implemented without a spec entry. Configuration
directory computed from the platform; `estatecatalog.json` (version 1,
absolute paths, ordered records, first is active); registered versus
transient records and the Keychain rule that follows the kind; the fixed
owned-file names derived from a record's directory; `--db` selection
rules; the `estate.json` manifest with its six allowed keys, name match,
regular-file and inside-the-directory checks; the mutation set and the
refused default-location move; the boundary (pure storage). Swift only.

### 3.11.0 -- 2026-09-08

The flat-layout capsule, Swift only. A 1.0.x Swift install kept its one
estate flat in the configuration directory (`estate.sqlite` and its
siblings beside `estatecatalog.json`'s future location); the estate catalog
places the same estate at `<configuration>/databases/default/`. The
capsule runs before any migration step opens the default record's database.
Contract: when the flat database exists and the active record is the
registered default, the capsule renames every flat estate file into the
record's directory, siblings first and the main database last, so a run
interrupted at any point resumes on the next call and a machine already
migrated does nothing. When the flat database and the record's database
both exist the capsule refuses and touches nothing; which estate is the
default is the operator's decision. The capsule never opens the database
and never stops a daemon; the host stops the resident around it, and stops
it unconditionally, because a flat estate predates the per-estate PID
marker the other steps read and a flat estate at the configuration
directory is the resident's estate by definition. The layout is detected by
the filesystem, so no estate format version separates the two layouts; the
capsule compiles under every migration floor from 1.0 through 1.6 and
retires when the product's floor rises above format 1.7. The Rust port
never wrote the flat layout and has no twin.

### 3.10.0 -- 2026-09-07

The unionBest step 5.8 sub-span dense refinement becomes a recall-request
switch, both ports. `GLKRecallRequest.subSpanScoring` (Swift
`GLKSubSpanScoring`, `.off` / `.on`) and `GLKRecallRequest.sub_span_scoring`
(Rust `GLKSubSpanScoring::{Off, On}`) gate the step together with the
existing conditions (unionBest matrixAware, a registered
CorpusContentEngine, non-empty query text). The request default is off;
every internal caller (CognitionKit recipes, AriaMcpKit memory_search and
synthesis, NeuronKit HybridRecall, the GLK verb surface) names the value
explicitly, and the ARIA surface exposes no argument for it. With the
switch off the dense column keeps the dense lane's value and no
`subSpan.budget` stage is recorded. CorpusKit's `scoreSubSpans` /
`score_sub_spans` and `SubSpanBudget` are unchanged. Pinned by
`SubSpanScoringSwitchTests.swift`, `rust/tests/sub_span_scoring_switch.rs`
and `Tests/Conformance/sub_span_scoring_switch_fixture.json`.

### 3.9.0 -- 2026-09-07

Two unionBest work bounds and the Rust migration entry gate, both ports. Step
5.8 (sub-span dense refinement) runs under the CorpusKit `SubSpanBudget` (a
16,384-byte per-record cap and 1,024 sub-span embedding calls per query) over
candidates in priority order (BM25 score, then Hamming similarity, then id);
a truncation records the stage `subSpan.budget` and the unscored hits carry
the explainer token `subSpan:budget`. Step 9.5 (the MMR shingle view) runs
under a 4,096-scalar body cap and a 1,000,000-scalar aggregate budget split
evenly over the pool's bodies; a share below the cap records the stage
`unionBest.mmrBudget`. The Rust
`run_migration_chain` reads the persisted estate format first and refuses a
stamp below the compiled floor or above the current format through
`MigrationChainError`, stamps an unstamped estate current, and dispatches
capsules from the detected version, as `GLKMigrationCatalog.prepare` does.

### 3.8.0 -- 2026-09-07

Estate format V1_7 and the 1.6→1.7 whole-record float vacuum capsule (I-26),
both ports. `EstateFormatVersion.v1_7` / `V1_7` is `current` / `CURRENT`. The
capsule deletes every `vectors` row of kind 1 and every `hnsw_graph` row,
rebuilds the binary sidecar from the surviving rows, releases the CorpusKit
representation claims on `vector_index` 1 and stamps V1_7; kind 0 and kind 2
rows are untouched. Under `WholeRecordDense` an estate whose manifest names
a whole-record provider keeps its rows and is stamped V1_7. `mootx01 upgrade`
gains the whole-record vacuum step (after the shared-content reclaim, before
the ssc facts backfill) that reports the reclaimed rows and bytes in one
line. LSA moves from the `DenseFamilies` switch to a switch of its own
(trait `LSA` / `MOOTX01_LSA`, cargo feature `lsa`, which enables
DenseFamilies): `DenseSignal.lsa` / `DENSE_LSA`, its membership in
`DenseSignal.all` / `DENSE_SIGNALS`, and the presets `lsa_forward` and
`anti_redundant_lsa` compile only under it, so the DenseFamilies roster
holds 37 names and the LSA roster 39. The family is dark and unproven since
2026-09-07 (DECISION_RETIRED_TECHNIQUES_LEDGER).

### 3.7.0 -- 2026-09-07

The whole-record dense float lane leaves the default build, both ports. The
span rerank stage (3.5.0, the Arctic span shape) is the one dense provider in
the product. The unionBest step 4.5 per-signal float lane, its
`dense:<modelID>` keys for held whole-record providers, the anti-similarity
hook (`antiSimilarLanes` / `anti_similar_lanes`), the float-lane metric
(`floatMetric` / `float_metric`), the `denseLaneStatus` / `dense_lane_status`
result marker, the `glk.recall.dense_lane_dark` counter and the presets
`conceptual`, `associative`, `consensus`, `ri_forward`, `anti_redundant_ri`,
`float-l2` and `float-dot` compile only under the `WholeRecordDense` trait
(`MOOTX01_WHOLE_RECORD_DENSE`) / the `whole-record-dense` cargo feature, which
`DenseFamilies` / `dense-families` enables. The default roster holds 26
names. Under the trait the roster gains those seven and `whole_record_baseline`
(every held whole-record signal at 1.0 over the default frontier: the audition
arm the harness measures the span stage against). The aggregate `dense`
column, its `"dense"` key, the span stage's `dense:<encoder modelID>` weight,
the `vector` Hamming lane and the `vectorDense` evidence-path vocabulary are
unchanged; in the default build `.discriminative` scoring equals `.rrf`
because no float lane computes a discrimination factor. `GLKRecallResult`
gains `replacing(hits:degradedStages:)`, the trait-agnostic way to derive a
result. The measurement that ruled the retirement is on the retired
techniques ledger (DECISION_RETIRED_TECHNIQUES_LEDGER).

### 3.6.0 -- 2026-09-07
Encoder span lane in the expunge destruction contract, both ports. The
`spanEncode` duty stores up to `maxSpans` int8 span vectors per drawer under
the encoder's own model id (`<model>-w<window>`); expunge step 2 and the
integrity sweep deleted only the distillation fingerprint lane and the corpus
model lane, so an erased drawer's span embeddings, dequantisation scales,
word bounds and content-version fingerprints stayed in the `vectors` table
while the erase audited as complete. Step 2 (§B-2a) and the sweep re-delete
(§B-2b 3a) now call `deleteSpanVectors` / `delete_span_vectors` for the
drawer under every `encoder_models` registry id plus the session's
registered encoder, between the distillation-lane and corpus-model deletes,
inside the same fail-closed block (a failure seals the orphan audit and
raises `crossKitVectorDeleteFailed`). The `spanEncode` duty re-reads the
drawer before each span write and skips a drawer that is missing,
tombstoned, or whose content no longer hashes to the encoded content
version, so an in-flight encode cannot recreate rows after an erase.
Pinned by `ExpungeEncoderLaneTests` / `expunge_encoder_lane.rs` (registry
lane, registered-encoder lane, sweep; a sibling's rows survive) and the
`SpanEncodeDutyTests` / `span_encode_duty` liveness tests.

### 3.5.0 -- 2026-09-07

Hybrid and CorpusOnly hit columns and the Hybrid lane roster, both ports.
Swift `recallHybrid` and `hydrateHits` (the `recallCorpusOnly` hit builder)
wrote the fused `final` into every lane column the hit's supplying lanes
owned, so a hybrid hit under `.rrf` read `locus == bm25 == vector == final`;
Rust reported each lane's own value. The Rust shape is the contract: a
Hybrid or CorpusOnly hit now carries the locus ramp, the BM25 score and the
Hamming similarity in their own columns, 0 where a lane did not supply the
hit, under every scoring, and `final` and the order do not change. On a
four-drawer text estate the three-lane hit, the two two-lane hits and the
locus-only hit read the same columns in both ports under Hybrid `.rrf`,
Hybrid `.raw` and CorpusOnly `.rrf` (`RecallHybridShapeTests` /
`recall_hybrid_shape_parity`). The Rust multi-lane path ran the step 4.35
tunnel-expansion lane for every mode and fused graph-only candidates into
Hybrid `.rrf` results that Swift `recallHybrid`, which has no graph lane,
never returns. The lane now runs for unionBest only: a drawer outside the
64-wide locus frontier that a tunnel from the newest drawer reaches is
absent from Hybrid `.rrf` hits and lane ranks in both ports, while
unionBest records it at graph rank 1 in both. Swift production code
changed for the columns; Rust production code changed for the lane roster.

### 3.4.0 -- 2026-09-06

Rust Hybrid and CorpusOnly `.raw` and the Rust unionBest `.matrixAware`
profile seed, both ports. The Rust Raw arm shared by Hybrid and CorpusOnly
scored a lane sum (locus ramp plus BM25 plus Hamming plus dense) and sorted
by it, where Swift `recallHybrid` and `recallCorpusOnly` merge the lane lists
in order (locus, BM25, vector; BM25, vector), dedup by id, cut at `limit` and
carry the entering list's score as `final`. Rust now performs the same merge:
a six-drawer text estate under Hybrid `.raw` returns the locus order with the
locus ramp as every final, and under CorpusOnly `.raw` the BM25 order with
the BM25 score as every final, in both ports (`RecallHybridRawMergeTests` /
`recall_hybrid_raw_merge_parity`). The Rust unionBest `.matrixAware` branch
seeded the `final` column the step 7 profile reads with the locus column
alone, where Swift reads `buffer.final`, the max over the per-lane hit
finals; on a buffer wider than 16 candidates the profile's top 16 differed.
Rust now seeds the column with the same per-lane max: a twenty-drawer text
estate whose four quiet drawers lead the locus ramp reports redundancy 1.0
in both ports (`RecallUnionProfileSeedTests` /
`recall_union_profile_seed_parity`); the locus seed reported 0.8667.

### 3.3.0 -- 2026-09-06

Rust unionBest score reporting parity for `.raw`, `.rrf` and
`.discriminative`. The Rust rrf/raw branch reported the un-normalised lane
values on the hit (locus ramp, BM25 score, Hamming similarity, dense cosine)
and a `final_score` that was the lane sum under raw and a reciprocal-rank
fusion under rrf, and it sent unionBest without a corpus to the locus-ranked
fallback. Swift reports the step 6 normalised buffer columns and scores all
three strategies from `buffer.final`. The Rust branch now builds the buffer
rows, normalises them, feeds the normalised `final` to MMR and reports the
normalised columns; unionBest always runs the full pipeline. A three-drawer
text-free unionBest recall reports locus and final 1.0 / 0.5 / 0.0 under raw
and rrf in both ports (`RecallUnionBestRawReportingTests` /
`recall_union_best_raw_reporting_parity`). Hybrid and CorpusOnly are
unchanged.

### 3.2.0 -- 2026-09-06

The `answer:auto` confidence gate reads the span rerank stage, both ports.
`GLKResultsPackager` derives m2 (lane agreement) as the normalised Spearman
footrule agreement between the lexical head order and the span order of the
span-scored hits in the top ten (`RecallHit.spanHit`: `bm25Rank` against the
cosine order; 1.0 for one scored hit, 0.0 for none), and m3 (span spread) as
the population standard deviation of those hits' span cosines (a single-hit
result keeps reading 1.0; fewer than two scored hits read 0.0). The gate,
its order and its thresholds are unchanged; the retired record-vector dense
lane (`score.dense`) and `unionProfile.signalAgreement` are no longer gate
inputs, so an estate with an active encoder produces real confidence values
where every multi-hit answer read WEAK. `SpanRerankHit` carries the item's
lexical rank (`bm25Rank` / `bm25_rank`). Registry seeding at open: the
activation path seeds the active `encoder_models` row from
`EncoderModelSeed` when the manifest names the encoder and the registry
holds none (see "Registry seeding at open" above); `GeniusLocusKit`
exposes `isSpanRerankRegistered(for:)` / `is_span_rerank_registered` so the
ARIA discrimination cap fires only when no encoder reranks the estate.
Conformance: `packager_golden_pins.json` version 2 (pins A-J) gates both
ports.

### 3.1.0 -- 2026-09-06

Estate format V1_6 and the 1.5→1.6 capsule (I-25), both ports. The retired
`corpus_index_state.composition_policy` column is dropped from every
populated estate: CorpusKit's checkpoint schema v4 drops it, the
`IndexCompositionColumnDropMigration` capsule replays that ladder on the
estate storage and stamps V1_6, and `mootx01 upgrade` (and every populated
open) reaches the capsule through the catalog. Floors 1.0 through 1.4 gain
the capsule; floor 1.5 compiles it alone. I-21 records the column as
dropped. Also: every aria-mcp Rust serve path (in-memory, SQLite,
PostgreSQL) now wires its estate through `wire_glk_substores`; the
registry's own copies of the wire body are gone, so the composite schema
open, the encode rider, the encoder activation and the eager queue mount
happen in one place, the same place Swift's `wireGLKSubstores` is.

### 3.0.0 -- 2026-09-06

Corrected default provider wiring and the standing-signal roster. Replaced
adornment orchestration with its retirement record. Preserved the live
random-indexing preset and the tiered-contradiction contract.

### 2.25.0 -- 2026-09-06

Default encoder provisioning, both ports. The Encoder Rerank Program hung
activation on `embedding_provider = "encoder"` but nothing in the product
wrote the key, so every shipped estate recalled lexical-only. `provision`,
the product create paths and the upgrade span-encode step now write it
when the estate names no provider (`provisionDefaultEncoderIfAbsent(for:)`
/ `provision_default_encoder_if_absent`); serve-time opens never do.

### 2.24.0 -- 2026-09-06

Span encoder activation order (Swift). `wireSubstores` activated the encoder
inside `applyProvisionedEmbeddingProvider`, before `registerVectorStore`, so
`activateSpanEncoder` never found the store and never registered the rerank
stage: a provisioned estate encoded spans in the duty but recalled
lexical-only. Activation now runs through `activateSpanEncoderIfProvisioned`
after the VectorStore (`.glk`) or the Corpus (`.corpusOnly`) is registered,
matching the Rust wire order. No public API change.

### 2.23.0 -- 2026-09-05

One index composition (CorpusKit spec 1.28.0). The stored index composition
setting retires: `IndexCompositionSetting.swift` and the Rust coordinator's
stored-setting block are gone (`storedIndexCompositionPolicy`,
`setIndexCompositionPolicy`, `seedIndexCompositionPolicyIfAbsent`,
`activeIndexCompositionPolicy`, `indexCompositionPolicyRowCounts`,
`indexCompositionPolicy(for:)`, the creation seed, and
`MOOT_INDEX_COMPOSITION`). `wireSubstores` / `wireGLKSubstores` and the Rust
`wire_substores` / `wire_glk_substores` lose `reindexPending` /
`reindex_pending`; `LocusDrawerCorpusContentSource` and
`LocusDrawerContentSource` lose their policy parameter (`new_with_policy`
gone). The 1.1→1.2 and 1.3→1.4 capsules and their traits / features
(`MigrationV1_1ToV1_2`, `MigrationV1_3ToV1_4`, `migration-v1-1-to-v1-2`,
`migration-v1-3-to-v1-4`) are removed; floors 1.1 through 1.4 now compile the
1.4→1.5 capsule only, and a 1.1-, 1.2-, 1.3- or 1.4-stamped estate runs that
capsule directly. I-20, I-21 and I-23 rewritten accordingly. An estate that
stored `index_composition_policy` still opens; the key is ignored, not
rewritten.

### 2.22.0 -- 2026-09-05

§ 16 marked dark behind `MOOTX01_MINERS` / `miners` (Encoder Rerank Program):
AdornmentPass, active-minter dreaming, result-composition adornment read, and
the conformance pins are no longer production behaviour. The section header and
its subsections are retained as a `MOOTX01_MINERS`-gated spec record. The
`spanEncode` duty (W4) now occupies the REM-ALPHA slot `AdornmentPass` held.

### 2.21.1 -- 2026-09-05
Encoder Rerank Program, MMR re-pin (both ports). The two unionBest MMR golden
pins (`union_best_mmr_fixture.json` and the shingle-once fixture) run under the
default lane budget, the whole-record vector column out of the fused score
(`signal:vector` = 0), and are re-pinned to the orders that budget produces:
the cross-port fixture returns the pre-COL-1 third slot with the near-duplicates
still out (the vector column had ranked one diverse body above another), and
the shingle-once fixture returns its two trailing-word near-duplicates as one
tie group under ruling 1 (bm25 alone ties them exactly; the vector tie-break
is gone). The 2.21.0 arrangement, the pins under their own `signal:vector` = 1.0
budget, is withdrawn. Gates: `UnionBestMMRCrossPortFixtureTests.swift`,
`UnionBestMMRShingleOnceTests.swift`, `union_best_mmr_parity.rs`, identical
orders on both ports.

### 2.21.0 -- 2026-09-05
Encoder Rerank Program, W3 (both ports). (1) The unionBest lexical lane reads
to depth 1000 and gains the span rerank stage (step 3.5): an encoder reranks the
lexical head by best int8 span cosine and reciprocal-rank fusion (k = 60, w =
1.0) reorders the lexical list before the pool cap; hits carry `spanHit` /
`span_hit` and the explainer's `score:` line gains `span:<index>:<cosine 3 dp>`
for scored hits (`recall_explainer_fixture.json` gains a span case). Registration:
`registerSpanEncoder(_:spanVectors:head:for:)` / `register_span_encoder`, dropped
on close. (2) `RecallShape.defaultWeight(for:)` / `RecallShape::default_weight`:
`signal:vector` defaults to `0` — the whole-record vector column is out of the
fused score unless a shape sets it; `signal:encoder` (`SignalKey.encoder` /
`SIGNAL_ENCODER`) skips the stage at `0`; `no_encoder` joins the roster and fuses
identically to `no_vector`; `cross_encoder` is reserved, not in the roster.
(3) The dense-family lane keys (`dense:ppmi-v1|lsa-v1|nmf-v1|fdc-v1`) and the
presets that steer them (`ppmi/lsa/nmf_forward`, `anti_redundant_lsa/nmf`) compile
only with the `DenseFamilies` trait / `dense-families` feature; `presetNames` /
`PRESET_NAMES` 37 → 33 (38 with the families). `DenseSignal.encoder` /
`DENSE_ENCODER` spells the encoder lane key `dense:minilm-l6-v2-w60`. (4) The
lexical-lane fix that motivated the depth rule lives in CorpusKit: Block-Max WAND
skipped past live candidates (a list carried past a document scored it later
without that list's contribution, or missed it), so BM25 #1/#2 on the ConvoMem
wing arrived as absent/#34; BMW now equals the exhaustive oracle on both ports
(`InvertedIndexBlockMaxTests.swift` / `inverted_index_tests.rs` SPARSE-5). The
MMR golden pins (`union_best_mmr_fixture.json`, shingle-once) run under their
own budget (`signal:vector` = 1.0) since they gate MMR admission, not the default
budget. Gates: `SpanRerankParityTests.swift` / `span_rerank_parity.rs`,
`SpanRerankStageTests.swift` / `span_rerank_stage_parity.rs`, preset and
signal-exclusion suites updated on both ports.

### 2.20.0 -- 2026-09-05
NOVEC-1 (both ports). Two ablation presets added to the named preset roster:
`no_bm25` sets `signal:bm25` to `0` and `no_vector` sets `signal:vector` to `0`.
Candidates from the excluded lane still enter the pool; only the scoring column is
excluded and its budget redistributed over the remaining columns. The BM25-vs-vector
share of the matrixAware-vs-raw gap was unmeasured because the harness carried no
preset that isolated each. `presetNames`/`PRESET_NAMES` 35 → 37. Parity gates:
`RecallShapePresetTests.swift` / `recall_shape_presets.rs` (count now 37);
`RecallShapeSignalExclusionTests.swift` / `recall_shape_signal_exclusion_parity.rs`
(ablation roster extended with the two new presets).

### 2.19.0 -- 2026-09-05
COL-2 (both ports). The unionBest step 10 MMR similarity term is scaled by
the step 8.5 redistribution factor ρ (`RecallSignalBudget.redistribution` /
`redistribution`, exactly 1.0 when no column is excluded) under
`.matrixAware`: each pick is the argmax of λ·score − (1−λ)·ρ·maxSim, so
column exclusion changes the score's magnitude but never the
relevance-versus-diversity balance the MMR admits candidates on. Before this
the 2.18.0 exclusions (ρ = 2.67 on the MMR-2 fixture) let two
near-duplicates of the query into a three-hit result in both ports. The Rust
explainer renders every score column plus `agreement=` and `final=` (3 dp),
byte-identical to Swift; `recall_explainer_fixture.json` carries an
`agreement` input per case and is re-pinned from the Swift output.
`union_best_mmr_fixture.json` and the near-duplicate pins are re-pinned
from the Swift output with the locus column out of text-query scoring; the
near-duplicates stay out of every pinned result.

### 2.18.0 -- 2026-09-05
COL-1 Part C (both ports). Automatic empty-store exclusion in the unionBest
`.matrixAware` weighted score: absent columns (all-zero after normalisation)
are excluded and their budget redistributed (`absentSignalColumns` /
`absent_signal_columns`). The locus column is excluded whenever the request
carries query text (its rank is recency, not relevance); step 5.6 matrix
scoring runs only when the frame carries bitmap predicates (the top-locus
anchor is otherwise the newest drawer). Mutation-controlled by
RecallShapeSignalExclusionTests (e)/(f) and the Rust twins.

### 2.17.0 -- 2026-09-05
COL-1 Part A (both ports). `RecallShape` gains the `signal:*` column-budget
key namespace (`signal:locus`, `signal:bm25`, `signal:vector`,
`signal:fieldFit`, `signal:matrix`, `signal:graph`, `signal:preference`,
`signal:agreement`): a key at 0 EXCLUDES the column from the unionBest
`.matrixAware` weighted score and redistributes its adaptive budget over the
remaining columns (`RecallSignalBudget`, step 8.5, pinned by seven shared f32
vectors). Six column-exclusion ablation presets (`no_locus`, `no_field_fit`,
`no_matrix`, `no_graph`, `no_preference`, `no_agreement`); roster 29 → 35. The
Swift explainer's per-hit `score:` line now renders every column (zero or not)
plus `agreement=` and `final=`; the Rust explain renderer lands with PAR-1. A
nil/all-ones shape stays byte-identical.

### 2.16.0 -- 2026-09-04
PAR-1: recall parity on populated estates, both ports. The Rust unionBest
matrixAware pipeline gains step 5.8, sub-span dense refinement
(`CorpusContentEngine::score_sub_spans` over every buffer candidate,
max-cosine blend into the dense column), the twin of the Swift step that
was the first differing lane in the measured drift: without it the Rust
dense column was zero for every candidate the dense lane had not ranked,
the fused scores sat lower (0.2981 against 0.3300 for the same top
drawer), and locus-only candidates tied at the cut. The
"Sub-span dense refinement" paragraph under the Rust parity stage map
records the contract. Rust `recall_scored_multi_lane` also fills `RecallHit.sources` with the five
candidate-supply lanes only (the matrix / graph / preference pushes are
gone; Swift never surfaced them) and fills `RecallHit.explanation` for
UnionBest hits through the new `recall_explainer` module, the twin of
Swift `RecallExplainer`, with the `denseSignals:` line kept after the
block; Hybrid and CorpusOnly hits carry the sorted source raw values as
the Swift hybrid path does. The "Hit provenance and explanation" paragraph
under the Rust parity stage map records the contract. Shared vector
`Tests/Conformance/recall_explainer_fixture.json`, asserted by
`RecallExplainerCrossPortFixtureTests.swift` and
`rust/tests/recall_explainer_parity.rs`. Swift production sources are
unchanged.

### 2.15.0 -- 2026-09-04
Rust union-best gains the greedy MMR stage, parity with Swift (MMR-2).
`recall_scored_multi_lane` runs `union_best_mmr_select` for every UnionBest
scoring strategy: λ = clamp(0.7 − (weights.diversity − 0.1) × 0.5, 0.5,
0.9) from `RecallWeights::adaptive`, argmax of λ·score − (1−λ)·maxSim with
the total-order tie-break, character-3-gram shingle Jaccard over sets built
once per hydrated body (SubstrateML `similarity_sets`) with the sourceMask
Jaccard fallback, the 2N working view, the conditional 4N widening and the
three tie outcomes. The rrf/raw/discriminative branch now computes the union
profile and adaptive weights for UnionBest to source λ. The "Post-hydration
shingle MMR" section describes both ports; the Rust parity stage map rows
for `pool.hydrateBodies.mmr` and `pool.hydrateBodies.return` state the body
source. New shared fixture `union_best_mmr_fixture.json`, asserted by both
ports. Additive: no public signature changes.

### 2.14.2 -- 2026-09-04
Swift unionBest step 10 shingles each hydrated candidate body once
(`mmrShinglesByID`, built right after step 9.5) and compares precomputed
sets through the SubstrateML set overload in both MMR phases. Same math,
same fallback to `glkSourceMaskJaccard`, same tie-breaks; the selection
order is byte-identical. `glkShingleSimilarity` is removed (its only
callers were the two MMR loops). Measured on the 13,817-drawer aggregate
ConvoMem wing (frozen serve, three `moot_memory_search` calls): 53.7 s,
43.7 s, 58.0 s before; 6.6 s, 2.2 s, 2.1 s after (the first call still
builds the BM25 index). The
"Post-hydration shingle MMR" section now states the SubstrateML
delegation and records that the Rust UnionBest path has no greedy MMR
stage; the Rust parity stage map rows for `pool.hydrateBodies.mmr` and
`pool.hydrateBodies.return` state the structural reason.

### 2.14.1 -- 2026-09-04
Default-wing seeding belongs to `provision` and `serve` only. The Rust
`upgrade` convergence step now opens the estate through
`EstateRegistry::new_sqlite_for_maintenance`, which omits
`seed_wings_non_fatal` and `register_default_minter_non_fatal`. Upgrade
is a migration vehicle: it converges existing content and creates none.
Swift was already correct (`GeniusLocusKit.open(storage:owner:)` does not
call `seedDefaultWings`). No behaviour change to `serve` or `provision`.

### 2.14.0 -- 2026-09-04

Estate format V1_5 and the `StorageLedgerKitIDMigration` capsule (the 1.4→1.5
capsule, I-24) carry the SynapseKit rename into populated estates. Root cause:
the vector tier's kit ids are stored values, one schema-version ledger row
each under `VectorKit` and `VectorKitClaims` in every estate, and a store that
finds no row under its declared id replays its ladder from version 0 against
the v6 layout (the v5→v6 rebuild folds every row's generation to 0, fails on
a serving/shadow key collision, and leaves a duplicate ledger row). The
capsule moves both rows to `SynapseKit` and
`SynapseKitClaims` through the new PersistenceKit primitive
`renameSchemaKit(from:to:)`, keeping version and applied-at, and stamps V1_5.
The rewrite runs first in the chain (before the 1.0→1.1 capsule, which opens
the vector store) and the stamp last; the stamp makes a pre-rename runtime
refuse the migrated estate instead of replaying. Floors 1.0 through 1.3 gain
the capsule; floor 1.4 compiles it alone. Both ports.

### 2.13.0 -- 2026-09-03

The index composition policy is a stored estate setting (I-23) and estate
format V1_4 with the `IndexCompositionSettingMigration` capsule (the 1.3→1.4
capsule) reach populated estates through the migration catalog. Root cause:
the policy was chosen per process from `MOOT_INDEX_COMPOSITION` at estate
open, so two processes could index one estate differently and nothing
recorded which policy an estate's rows were built under. Now `wireSubstores`
reads LocusKit manifest key `index_composition_policy` at every open;
`provision`, the catalog's fresh-estate branch, and the capsule seed it once
(the environment's valid policy id, else `.current`); `mootx01 db
composition --set` is the only way to change it and rebuilds every lane in
the same command. Floors 1.0, 1.1, and 1.2 gain the 1.3→1.4 capsule; floor
1.3 compiles it alone. Both ports.

### 2.10.0 -- 2026-09-02

Estate format V1_2 and the `IndexCompositionColumnMigration` capsule. Root
cause: `CorpusIndexStateStore.schemaDeclaration` reached version 3
with an addColumn for `composition_policy TEXT NOT NULL DEFAULT ''`. Populated
estates open CorpusKit only through the composite declarations
(`CorpusSchemaProfile.attachedDeclaration`,
`GeniusLocusKitSchema.estateSchemaDeclaration`), which carry an empty migrations
list; PersistenceKit records the bumped composite version and has nothing to
replay. Fresh estates receive the column from `CREATE TABLE`. This capsule fixes
populated estates by replaying the component kit's own schema ladder — idempotent
via `CREATE TABLE IF NOT EXISTS` + addColumn.

`EstateFormatVersion` gains `v1_2` (Swift) / `V1_2` (Rust);
`current`/`CURRENT` is now `v1_2`. The migration catalog dispatches three paths:
found == 1.0 → run 1.0→1.1 then 1.1→1.2; found == 1.1 → run 1.1→1.2; found
== 1.2 → already current. `SharedContentMigration` stamps `v1_1` explicitly
(not `.current`) so the 1.1→1.2 capsule is never skipped on resume. I-21 added.
Swift package traits: `MigrationV1_1ToV1_2`, `MigrationFloor1_0` (both
capsules), `MigrationFloor1_1` (1.1→1.2 only). Rust features mirror this.
The capsule runs only through the catalog (`GLKMigrationCatalog.prepare` in
Swift, `MigrationChainExt::run_migration_chain` in Rust), which every host open
already invokes; the upgrade command gains no migration step of its own.
`mootx01 upgrade --backfill-only` now exits non-zero when any of its four
data-directory steps fails, and the shared-content reclaim step applies the
ledger declaration before reading it, so an estate that never ran the 1.0→1.1
chain reads as "not pending" instead of failing on a missing table.

### 2.12.0 -- 2026-09-03

The active converter is intent-span v23.2 (`intentSpanV23Attributed` /
`IntentSpanV23Attributed`); the v22 ruleset stays in the library. New
§ DISTILLATION states the active converter and the one currency rule,
`distilledRepresentationIsCurrent` / `distilled_representation_is_current`:
bit 19 set AND converter ID equal AND `distilled_source_digest` equal to the
digest of the row's content. `distillItem` writes the source digest as the
fifth representation column; the sweep, the drain-stage rider, seeding, and
the awaiting-reindex probe key on the rule; the Rust sweep gains the
stale-room bypass the Swift sweep already had. Estate format V1_3 and the
`DistilledSourceDigestColumnMigration` capsule (I-22) carry the column to
populated estates through the catalog every host open already runs; the
upgrade command gains no step of its own. Swift package traits:
`MigrationV1_2ToV1_3`, `MigrationFloor1_2`; floors 1.0 and 1.1 now enable the
new capsule. Rust features mirror this. Both ports.

### 2.11.0 -- 2026-09-02

`runDistilledRepresentationConvergence` (Swift) and
`run_distilled_representation_convergence` (Rust) now use a two-key
eligibility gate for the reindex step. Before this version the gate was:
`regenerated > 0`. After this version the gate is:
`regenerated > 0 || awaiting > 0`, where `awaiting` is the count of drawers
whose `distilledAt` is strictly newer than their corpus index row's
`updatedAt` (or whose index row is absent). This detects the mid-run crash
scenario: sweep committed, process terminated, reindex never ran. Equal
timestamps (sweep and reindex share the same `now`) evaluate to zero (the
drawer is fully indexed). LocusOnly estates always return awaiting == 0 (no
corpus index to check).

New function `distilledRepresentationsAwaitingReindex(handle:)` (Swift) and
`distilled_representations_awaiting_reindex(handle:)` (Rust) expose the
second eligibility key directly for callers that need to probe it without
driving the full convergence step.

New LocusKit accessor `drawersWithRepresentations()` (Swift and Rust):
projection-only query — `id` and `distilledAt` — over active, non-empty
drawers where bit 19 (`hasCurrentRepresentation`) is set. No content
hydration. New CorpusKit accessor `allIndexStates()` (Swift and Rust):
all non-cursor corpus index state rows, keyed by contentID.

### 2.9.0 -- 2026-09-02

The stored distilled representation is produced by ContextDistillLib
(CDL-02, DECISION_CONTEXTDISTILLLIB_2026-09-02). `distillItem` hands the
verbatim content and the categorizer trailer computed from that content to
the intent-span converter and stores its text; the converter ID
(`GeniusLocusKit.distillationConverterID`) is written to
`distilled_pipeline_version` and is what every eligibility check compares,
so a converter bump regenerates every legacy row lazily through the sweep
and eagerly through the Redistill recipe. The coreference stage is gone:
the representation is exact source text by contract. The structural
fingerprint lane is unchanged (feature matrix, not text). The token count
stored is the library's estimate. `reindexCorpus` rebuilds every derived
lane after a redistill because the lexical lane admits trailer tokens
scanned from the distilled text. Both ports.
### 2.8.0 -- 2026-09-02

§ 16.1 concurrency lanes (codex finding 21): the Swift pass keys its
concurrent lanes by the resolved engine's identity, never by minter id, so
every minter sharing one engine shares that engine's `maxConcurrentMints`
budget; a width-1 engine stays serial across any number of active minters.
Lanes for distinct engines still overlap. Minters no engine serves keep a
width-1 lane of their own. Rust is unchanged (serial loop, one engine).

### 2.7.0 -- 2026-09-02

§ 16.1 provenance guard (codex finding 17): the pass persists a pair only
when the pair's minter id equals the minter identity of the engine that
would serve it; mismatched pairs are counted skipped, stay in debt, and are
logged once per distinct minter id per pass. Identity-less engines (no
engine, the Swift harness `CommandEngine`, the Rust MOOT_MINT_CMD seam)
leave the pass unguarded. Same rule in both ports. Activation state is
untouched; a startup reconciliation of stale identities remains an
operator ruling.

### 2.6.0 -- 2026-09-02

§ 16.1 batch ceiling (codex finding 16): one AdornmentPass invocation
never fetches more than `ADORNMENT_PASS_MAX_BATCH_SIZE` (5000) pairs; the
entry point clamps every caller's request in both ports, so a
caller-supplied batch size can never turn one call into an estate-wide
scan. The dark harness tools that drive the pass dispatch only behind the
`MOOTX01_MINT_TOOLS=1` launch gate (ARIA_MCP_INTERFACE 2.5.0).

### 2.4.0 -- 2026-08-31

Adornment row frames are minter-homogeneous: the pass buckets batchable
debt pairs per minter id before chunking into frames, and each frame is
answered by the engine resolved FOR that minter (multi-model mode routes
minters to dedicated engines; single-model resolution is unchanged). A
frame whose engine does not speak the row transport falls only its own
pairs to the single-record path — transport support is per engine,
never process-wide. Single-record generation passes the pair's minter
id through the miner seam.

### 2.3.0 -- 2026-08-28

DEFAULT-MINT-01 (operator ruling 2026-08-28: default minters run inline).
§16 gains the platform-default registration contract: every production
estate open registers the platform-default minter ACTIVE (Swift
apple-fm via the resident GoldMiner; Rust the candle quantized recipe)
through an upsert that never retoggles an existing row's is_active —
an operator's deactivation survives reopens. Pass generation resolves
through the resident GoldMiner engine chain (installed engine → platform
default → MOOT_MINT_CMD → none, with the deterministic mechanical
fallback guaranteeing a non-blank drawer always mints). The Rust port
runs one pass batch per dreaming cycle; both ports expose the dark
harness tools for audition minting.

### 2.2.2 -- 2026-08-26

§16.2 records the LocusKit sensitivity gate on the active-adornment
read: Restricted/Secret drawers contribute no adornments to
composition (codex finding 2026-08-26). No GLK code change — the gate
lives in LocusKit's joined batch read.

### 2.2.1 -- 2026-08-26

Hedging-vocabulary sweep (operator ruling 2026-08-25): normative prose now states facts as facts. No contract change.

### 2.2.0 -- 2026-08-26

RENAME-EMBED (#72): the provisioned embedding-provider model-ID table gains
`"neural-embed-v1"` → `NeuralEmbedProvider` (engine-neutral; NLTagger word
tokens mean-pooled over NLEmbedding word vectors, unnormalized; Swift only,
`#if canImport(NaturalLanguage)`; opt-in only — the default ensemble and the
absent/unknown-key guarantees are unchanged). Rust-divergence prose updated:
the engine-neutral backend now exists as the standalone `tools/neural-embed`
crate (renamed from the engine-leaking `candle-spike`); GLK Rust remains
provenance-only. Engine names removed from spec prose — the inference engine
is an invisible backend detail. Additive (MINOR).

### 2.0.0 -- 2026-08-25

Replaced the scalar, bitmask-selected AdornmentPass with per-active-minter debt
processing over LocusKit's normalized store. Defined zero/one/many runtime
activation, failure isolation by pair, batched active-adornment projection for
the ARIA result composer, and identical active-set use by synthesis.

### 1.50.0 -- 2026-08-24

Additive (Score-Transparent Ordering — SCORE-ORDERING mission):

`recallUnionBest` now implements a **windowed tie-resolution algorithm** at
the MMR presentation boundary. The algorithm operates in two phases:

- **Phase 1** — select 2N candidates via MMR, sort by `(score DESC, subject ASC)`.
- **Phase 2** — if a tie straddles the cut at position N, continue MMR to 4N:
  - If a score break is found within 4N: return the group above the break.
  - If the pool is **fully exhausted** before 4N: return the whole pool (deliberate
    expansion; pool-exhaustion is a deterministic answer, not a degradation).
  - If no break and pool has more items: return the **determinate prefix** (items
    unambiguously above the tie group) and append `"tie.nonDeterminate"` to
    `GLKRecallResult.degradedStages`.

`recallCorpusOnly` applies `(score DESC, subject ASC)` sort to its output before
returning, matching the unionBest presentation order.

Both the Swift and Rust ports implement the algorithm. The `tie.nonDeterminate`
sentinel is a string in `degradedStages` (no new struct field) so the AriaMCP
layer can surface the steering message without a breaking API change.

The `limit` parameter now specifies a **relevance floor**, not an exact count:
equal-scored results at the boundary are all returned, so the actual count may
exceed `limit` (pool-exhaustion case) or be below `limit` (non-determinate case).

### 1.47.0 -- 2026-08-22

Additive (front-door family — DoorManifest + door-config manifest key):

`DoorManifest` is the fourth optimizer-owned manifest key in the estate
config family, joining `lane_weights`, `recall_tuning`, and
`embedding_provider`. The manifest key is `"door_config"` and the value is
a JSON object `{"scoring":"<rawValue>"}`.

`GeniusLocusKit` actor gains two public methods:
- `provisionDoorConfig(_:for:)` — stores the `DoorManifest` emitted by
  the quality optimizer after a full-coverage arm comparison.
- `provisionedDoorConfig(for:)` — reads back the config, or `DoorManifest.default`
  (scoring = `matrixAware`) when absent. Fail-quiet: unknown scoring strings in
  stored JSON also return `.default`.

`RecallDirector` gains the `doorConfigMetaKey` static constant and a
`provisionedDoorConfig(estate:)` method (called by VerbSurface on every
`moot_memory_search` when neither `door` nor `scoring` is explicit).

Rust `EstateCoordinator` gains `DOOR_CONFIG_META_KEY`, `provision_door_config`,
and `provisioned_door_config` (after `apply_provisioned_embedding_provider`).
`DoorManifest` struct with custom serde helpers (GLKRecallScoring has no serde
derive; the helpers use `raw_value()`/string-match round-trip).

No estate migration required — absent key degrades to `matrixAware`.
The product never computes or overrides the selection (benchmarker/optimizer
split). ARIA_MCP 1.49/1.54 documents the `door` argument that consumes this.


### 1.46.0 -- 2026-08-21

Float-metric presets: two new named presets added to the `RecallShape` roster on
both ports. `float-l2` sets `floatMetric = "l2"`; `float-dot` sets
`floatMetric = "dot"`; all lane weights remain neutral (identical fusion to
`balanced` except for the float-lane distance function). Mirrors the
`jaccard`/`binaryMetric` pattern: only the distance function changes.

`presetNames` / `PRESET_NAMES` grows from 27 to 29 entries. The `moot_recall_shaped`
MCP tool picks up the two new names automatically (the tool description embeds the
roster at construction time from `RecallShape.presetNames`). Conformance gated on
both ports: `RecallShapePresetTests.swift` (count now 29) and
`recall_shape_presets.rs` (count now 29). MCP acceptance tested in
`RecipeToolsTests.swift` (`testShapedRecallFloatMetricPresetsAccepted`) and
`dispatch_tests.rs` (`recall_shaped_float_l2_preset_is_accepted`,
`recall_shaped_float_dot_preset_is_accepted`).

### 1.45.0 -- 2026-08-21

W2.5 M1 float unlock: `RecallShape` gains `floatMetric` (string, default `"cosine"`,
accepted values `"cosine"` | `"l2"` | `"dot"`; unknown values degrade silently to
cosine; Codable-additive — absent key decodes to `"cosine"`, never throws).

The metric is threaded through the full float/dense-lane query chain:
`RecallDirector.floatMetric(for:)` → `CorpusContentEngine.floatNearestPerSignal` /
`floatFarthestPerSignal` / `floatNearestPerSignalWithDiscrimination` →
`VectorStore.findNearestFloat` / `findFarthestFloat` → both code paths
(ramResident `FloatBruteForceIndex.search(metric:)` and diskBacked
`_floatScanFromTable` with inline per-metric distance dispatch).

Rust twin: `RecallShape.float_metric: String` field, `with_float_metric` builder,
`float_metric_for(shape:)` mapping fn in `coordinator.rs` that routes to
`FloatMetric::Cosine` / `L2` / `Dot`; threaded into `CorpusContentEngine` and
`VectorStore` float lane functions.

Conformance gated on both ports:
- Swift: `RecallShapeFloatMetricTests.swift` (12 tests) — GOLDEN PIN (absent key
  and explicit "cosine" produce byte-identical top-1), unknown degradation, l2/dot
  selectability with rank-divergence fixture.
- Rust: `recall_shape_float_metric_parity.rs` (8 tests) — same three gates.

Additive. `floatMetric` absent → `"cosine"` → behaviour byte-identical to pre-1.45.0.

### 1.44.0 -- 2026-08-21

EMBED-PROV-E2: embedding-provider manifest key consumption at wire time.

`wireSubstores` now reads the `embedding_provider` manifest key (written by
`provisionEmbeddingProvider`) at estate-open time and augments the embedding
ensemble. The single seam call site covers both `provision` and the serve
entry paths (`wireGLKSubstores`).

- `"apple-nl-v1"` → appends `.nlEmbedding(provider: AppleNLProvider())` to the
  base ensemble (Swift, `#if canImport(NaturalLanguage)` gate; no-op on
  non-Apple platforms).
- Absent key / empty value → ensemble unchanged (byte-identical to pre-EMBED-PROV-E2
  behavior; no side effects for every existing estate).
- Unknown model ID → `OSLog.warning` (ID + estate UUID), ensemble unchanged.

Rust: `apply_provisioned_embedding_provider` added to `EstateCoordinator`.
Reads the key; emits one provenance line to stderr when the key is non-empty;
returns without modifying any ensemble. Called from `EstateCoordinator::provision`
after wiring. Sanctioned divergence: Rust never selects an ML provider
(NaturalLanguage unavailable on Linux/Windows target platforms).

Additive. Zero existing callers affected.

### 1.43.0 -- 2026-08-20

- P3a: `AnomalySweepSignal` wired as signal 11 in the default standing-signal
  set, both ports. `registerDefaultStandingSignals` gains an `anomalyCycle`
  parameter (default no-op) that is forwarded to `AnomalySweepSignal.spec`.
  The standing-signal inventory table updated to 12 rows. Rust: new
  `brain/signals/anomaly_sweep.rs` and `brain/anomaly_flag_sweep.rs`; Rust
  `EstateCoordinator::anomaly_flag_sweep` implements the O(n²) per-room
  cohesion sweep over char-3-shingle Jaccard z-scores, mirroring the Swift
  twin. LocusKit Rust gained `Estate::set_anomalous_flag` (trait + InMemory,
  SQLite, PostgreSQL impls). `§11.18` now "Swift-only" note removed — both
  ports are parity-tested via `standing_signals_parity.rs` (23 tests) and
  `AnomalySweepSignalTests.swift` (7 tests).

### 1.42.0 -- 2026-08-20

- M4 single-derivation: the recall director is now the sole site that calls
  `QueryLatticeAnchor.derive(from:)` / `query_anchor()`. The result is stored
  on `GLKRecallResult.queryLatticeAnchor` / `query_lattice_anchor`. Callers
  MUST NOT re-derive the anchor from the query text; they read it off the
  result. This closes the two-path duplication between the GLK sketch
  compilation and the CognitionKit recipe layer. `locusOnly` and unanchorable
  queries carry `nil`/`None`.

### 1.40.0 -- 2026-08-20

- §11.18 anomalous-flag recall prefilter. Two new surfaces:
  1. `GLKRecallRequest.anomalousFilter: Bool?` (nil = passthrough, true =
     anomalous-only, false = exclude-anomalous) — admission gate applied
     centrally in `recall`/`recall_scored` BEFORE scoring, after all lane
     results are collected. Hits without a hydrated drawer pass through
     unconditionally. Rust: `with_anomalous_filter(filter: bool) -> Self` builder.
  2. `GeniusLocusKit.anomalyFlagSweep(handle:threshold:now:) async throws -> Int` —
     room-cohesion maintenance sweep that computes each drawer's mean
     char-4-shingle Jaccard similarity to its room peers (SubstrateML
     `ShingleSimilarity.similarity`), derives z-scores
     (`AnomalyDetection.zScore`), and sets/clears bit 26 (`isAnomalous`) on
     each drawer. Rooms below `anomalySweepMinRoomSize` (3) have bit 26
     cleared on all members. Default threshold 2.0 (≈ −2σ). Returns count
     of changed drawers. O(n²) per room; idempotent (skip-write when bit
     already correct). Deterministic: `now` threaded from the caller.

### 1.38.0 -- 2026-08-20

- W2.5 Track R(a) — attributed reward-cycle traces. The recall-trace
  write moves from the inner locus frame to the director's central
  writer in `recall`/`recall_scored`: for external-origin requests the
  director writes one trace row per SURFACED hit (capped by
  `traceLimit ?? limit`) carrying the fused score, `door` (from the
  request), `composition` (request's, else "<mode>/<scoring>"), and
  `laneRanks` (the target's 1-based rank in each lane's final
  pre-fusion candidate list, packed via
  `RecallTraceItem.packLaneRanks`). Pre-R(a), fused lanes traced the
  locus scan's leading rows, which need not match the fused result —
  the re-homing is a fidelity fix. Internal-origin behavior unchanged
  (zero trace rows, B-10a). A trace-write fault stays fail-closed and
  surfaces as degraded stage "recall.trace_write_failed".

### 1.28.0 -- 2026-08-13
GLK supplies `EstateThetaBasisRetrainHook` to NeuronKit's `AutonomicGovernor` at
composition time. The hook's `retrain(now:)` implementation calls
`GeniusLocusKit.reindexCorpus(handle:now:)` — the existing public reindex surface.
No new GLK public API; the composition wiring is in `AutonomicGovernor.swift`.
No invariant change: `reindexCorpus` already existed and its contract is unchanged.
See NEURONKIT_SPEC § 12.6.1 for the hook design.

### 1.27.0 -- 2026-08-13

- C3 reindex-completion marker: the reindex chokepoint (`reindexMissing`
  tail in Swift `EncodeIntake`; the `moot_reindex` completion tail in the
  Rust vertical) seals one estate-anchored `reindexComplete` marker per
  completed backfill, flag-gated with the A2/A3 markers
  (`MOOTX01_ENCODE_MARKERS`). Marker failure warns and never fails the
  reindex. Alongside it, the composition layer exposes the estate-wide
  audit page (`auditEvents(_:after:limit:)` / `audit_events`) — handle
  validation plus the LocusKit pass-through — as the C3/A6
  timing-derivation paging seam for `moot_timing_report`.

### 1.26.0 -- 2026-08-13

- Audit-marker recording (A2/A3): the encode drain worker seals one
  `encodeComplete` marker per drain unit and the dreaming seam brackets
  each cycle with `dreamStart`/`dreamEnd`, both flag-gated by
  `MOOTX01_ENCODE_MARKERS` (default ON; `off` disables both — one
  recording facility). Markers are best-effort: a marker failure never
  fails the drain or the cycle. An artifact built with recording off
  cannot yield INGEST/CYCLE timings and must fail loudly at measurement
  rather than report nothing.

### 1.25.0 -- 2026-08-07

New § TIERED_CONTRADICTION (MXE-CT3): the three-tier contradiction
taxonomy (`ContradictionTier` 1/2/3 — typed proof, structural lexical
cue, value divergence), the `tieredContradictionSearch` read verb
(synthesis + single-tier modes, one shared lexical retrieval pass,
topK clamp 50, Elevated ceiling filter), the extended
`proposeConflictTunnels` all-tier filing pass with tier-keyed labels
and the decline matrix, the review ladder
(Rejected/Proposed/Endorsed/Accepted; `endorseTunnel` /
`objectToTunnel`; endorse never activates — user-only activation),
and `ReviewQueueRanking`.

### 2.1.0 -- 2026-08-26

Associate-sweep ladder cut (operator ruling): each probe's kNN neighbour
list is truncated only on a DISTANCE BOUNDARY, never inside a tie
group. Rungs with `units` = the neighbour budget: fetch units×3 and
cut at the first boundary at or after `units`; else fetch units×6 and
look again; else cut at the last boundary INSIDE `units` (the longest
determinate prefix); else — the whole pool is one tie group — the
probe contributes ZERO pairs and the sweep report's new
`nonUniqueProbes` count records it (surfaced on the dream association
line). An exhausted pool (store returned fewer rows than requested) is
complete and returned whole. Rationale: candidates with byte-identical
vectors tie on distance AND content hash, so a mid-group cut falls to
the per-run random UUID — per-run stable but not cross-run stable
(REPLAY_DRIFT_RCA 2026-08-26); the ladder makes the association pair
set identical across independent provisionings of the same content.
`AssociateSweepReport` gains `nonUniqueProbes` ↔ `non_unique_probes`
(both ports). Behavioral (MINOR).

### 1.24.0 -- 2026-08-05

Dream associate step: the vector-similarity pairing runs as an
on-demand verb (`associateSweep` ↔ `associate_sweep`) sharing one
implementation with the standing signal (ProximityScanCore ↔
proximity_scan_candidates). Coverage: a probe limit, or None/nil for
the full estate (post-import recovery for pairs the one-sided recency
window can never examine — two dormant items associate only through a
full-coverage sweep). A store-less estate reports zeros, never errors.
Probe order is recency with id tiebreak, so same-seed estates write
the same associations.

### 1.23.0 -- 2026-08-05

- **1.37.0 (2026-08-20)** — W2.5 S4 Option C (the ruled option): MatrixTier gains DECAYED O/T projections (§8.13) beside the canonical Int64 counts — per-contribution exp(−age·ln2/τ) at the maintenance pass clock (τ_O 60d co-activation, τ_T 30d temporal, §6.8), recomputed IN FULL every rebuildDerivedAccelerators (exp-factor composition is not fp-associative, so no incremental merge). Codable/snapshot additive; encoded only when computed. RecallShape.matrixWeighting ("counts" default | "decayed") switches the matrixAware read — arm surface only, defaults byte-identical. Rust twin mirrors (projections in-RAM, recomputed on load path; binary snapshot carries counts only). The Rust-only dead MatrixTier::apply_decay (zero call sites, O 365d/T 90d contradicting §6.8) is REMOVED — superseded by this design.

- **1.36.0 (2026-08-20)** — Pipeline p2.3-det — coreference stage A (W2.2, accepted design A1): the per-item sweep resolves THIRD-PERSON pronouns in the distilled rendering against a session antecedent pool (anchored entities of up to 5 preceding same-room items within 30 min, categorizer selection rules). Substitution fires only when the pool holds exactly one compatible-class candidate (thing vs person via Q5 ancestry); "her" is excluded (object/possessive ambiguity); the verbatim body and trailer facts are untouched. Single-item distill callers pass an empty pool (identity); the version bump retroactively re-distills via the bit-19/version sweep.

- **1.35.0 (2026-08-20)** — Provisioned lane weights (W2.5 Track R(b)): the estate manifest key `lane_weights` carries OPTIMIZER-OWNED default per-lane weights (JSON, lane key → signed float). The recall path resolves every lane-weight read with shape-explicit > provisioned > neutral-1.0 precedence — fixed RRF lanes, dense per-model modifiers, and union column multipliers alike. Absent/malformed provision fails quiet to today's neutral fusion. The product only consumes; the quality optimizer emits (benchmarker/optimizer split).

- **1.34.0 (2026-08-20)** — Consolidation composeAndDistill threads per-sentence constituent timestamps (offset-mapped over the joined cluster text) into DistillationInput, activating the pipeline's TypedDecayWeighting branch for cross-item clusters (W2.5 S6, DISTILLATION_MATH_DIFFUSION §2). The per-item sweep keeps nil timestamps on purpose — one item's sentences share a single timestamp, so equal ages cancel (wdf ≡ df). Sentence segmentation is unchanged; unlocatable sentences fail quiet to the uniform branch.

- **1.33.0 (2026-08-20)** — QueryLatticeAnchor (W2.5 Track S): public query-side §8.3 lattice-anchor derivation using the categorizer's own selection rules (multi-word phrase pre-pass over the vendored labels, then the first anchoring noun — same pinned stopwords, min length, and root-class skip). Returns the drawer-space FDC code + Wikidata Q-ID; unanchorable queries return the empty anchor. Rust twin brain::enrichment_stage::query_anchor.

- **1.32.0 (2026-08-20)** — RecallShape gains `binaryMetric` ("hamming" default | "jaccard"; unknown degrades to hamming; Codable-additive via custom decoder) applied to the engram and distillation-fingerprint lanes of the scored path. New shaped preset "jaccard" (21st): identical fusion, Jaccard set-overlap scoring on the binary lanes.

- **1.31.0 (2026-08-20)** — Pipeline p2.2-det: multi-word entity pre-pass — greedy longest-match (5..2-word n-grams) against the vendored multi-word labels before single-token anchoring; matched tokens consumed. Contract change → lazy re-distill.

- **1.30.0 (2026-08-20)** — Distillation pipeline p2.1-det: the categorizer prefers the vendored Wikidata facts when the anchor carries a Q-ID — kind from the first QIDClosure taxonomic ancestor label, place + country from P17 — with the FDC frame label retained as the fdc fact and kind fallback. Rendering contract change → version bump re-distills lazily.

- **v1.29.0 (2026-08-20)** — Distillation pipeline contract p2-det (DECISION_DENSE_LANE_ENRICHMENT Wave 2, stage B): the p1 rendering gains a deterministic categorizer trailer — HMM noun classification → EideticLib FDC anchor (root class "000" skipped) → frame label + first-ancestor label, rendered in grammar v1 (labels comma-truncated to stay grammar-safe), capped at 6 deduplicated facts. Facts derive from the VERBATIM content; the trailer rides the distilled lane only, where CorpusKit's trailer lexical supplement admits it to BM25. distilled_token_count now measures the enriched rendering. The version bump re-distills estates lazily via the existing sweep.

- **VectorSimilaritySignal probe window parameterized.**
  `spec(...)` gains `probeLimit: Int = defaultProbeLimit` (Swift) /
  `probe_limit: usize` (Rust) controlling how many item IDs are sampled
  from the VectorStore on each five-minute pass. Default 50 keeps
  resident behavior byte-unchanged. `defaultProbeLimit` (Swift) /
  `DEFAULT_PROBE_LIMIT` (Rust) replace the formerly private
  `maxProbeCount` / `MAX_PROBE_COUNT` constants.
  **One-sided probe window documented:** probes are recency-sampled
  (newest first) while neighbors are searched across the whole estate.
  Two dormant old items never pair unless one was probed while recent —
  widening `probeLimit` relieves this constraint. Expected callers:
  dream associate step, benchmark protocol v2.
  SPEC section §VectorSimilaritySignal updated to describe the
  parameterized probe limit and one-sided window limitation.

### 1.22.0 -- 2026-08-04

- **B-2a partial-expunge scope (MXE-FA).** Step 1 is documented as
  returning the full `ExpungeOutcome` (unsealed event + refused sibling
  ids); step 2's vector fan-out is scoped to actually-scrubbed members
  (refused accepted siblings keep content AND vectors); the verb returns
  the new `ExpungeVerbOutcome`, and the binding invariant is recorded: no
  layer reports success for an expunge that refused a sibling.
  `defragVagueItem` / `defrag_vague_item` raise
  `.underlyingEstateFailure` on a partial vague cascade. Stale
  `sealAudit:` phrasing on the Swift step-1/direct-caller paths corrected
  to the shipped two-method surface.

### 1.21.0 -- 2026-08-03

Deterministic Contradiction Projection (DCP M2-M6). The Brain layer
gains the typed proving lane over KGFacts: projection (active facts on
registered dimensions become ConflictSignatures; exclusions counted,
never dropped), the in-memory (key, dimension) coordinate index with a
per-bucket cap and truncation diagnostics, the pure sweep
(project → index → evaluate; accepted ACTIVE supersedes tunnels convert
overlap to HistoricalSuccession), typed tunnel proposals (proven
findings file PROPOSED contradicts tunnels labeled
`dcp: <rule>@<version>`; live pairs suppress; a withdrawn typed
rejection is durable per rule@version — a version bump files a new
instance; withdrawn lexical guesses never suppress typed proofs), the
controlled meeting-decision filing seam (dcp-meeting-v1 grammar,
replay-safe deterministic fact ids, ACTIVE filing posture), and
Replaces-reference supersession filing. Everything is a pure
read except the explicitly write-labeled proposal/filing verbs.

### 1.20.0 -- 2026-08-02

Rider-default ruling: the Apple subject rider is ON BY DEFAULT at the
HOST layer — `mootx01 serve` auto-registers the miniLLM producer unless
`MOOTX01_SUBJECT_RIDER=0` (`mootx01 install --subject-rider-off`);
model unavailability logs and continues. Kit semantics are unchanged
(GLK never auto-registers at open). Dreaming DISPATCHES the backfill:
every dreaming trigger (moot_dream verb both ports; the mootx01 dream
command) runs one bounded subject sweep after its cycle when a producer
is registered and debt is non-zero. The benchmarker's encode-barrier
denylist gains `subject_backfill` accordingly.

### 1.19.0 -- 2026-08-02

Apple miniLLM subject rider (progressive recall PR-10) — the sanctioned
miniLLM feature's first landing, single-function by doctrine (subjects
only). `MiniLLMSubjectProducer` runs on the first-party on-device
Foundation Models surface (Apple-first, migrate-when-able), gated by
`canImport` + availability; output post-passed and admitted ONLY
through the SubjectRegister gate (a misbehaving model degrades to
no-op). Enablement is user-settable via `enableAppleSubjectRider(for:)`
(the tagger precedent — never silently mandatory; nothing
auto-registers, pinned by the dark-default tests). Trust ladder:
`SubjectProducer.regeneratesPipelines` (default empty) — the Apple
rider regenerates only consolidation-v1/seed-v1; ai-v1 rows are never
overwritten. Rust: `regenerates_pipelines` trait default; lane still
dark. Verified live on-device where the model is present (conditional
test).

### 1.18.0 -- 2026-08-02

Subject-backfill rider seam (progressive recall PR-09; SIBLING lane to
distillation — the lane-name reservation pre-decided the shape, flagged
for review). The coordinator carries a per-estate `SubjectProducer`
registry; `subjectBackfillSweep` runs bounded deterministic batches
(produce → SubjectRegister-validate → setSubjectRepresentation),
refuses while no producer is registered, and skips inadmissible output
without storing it. The `subject_backfill` drain lane renders ONLY
while a rider is registered (barrier safety; the benchmarker non-gating
denylist gains the name in the mission that first enables a rider). The
Rust lane is DARK: seam compiled, no producer ships, gate pinned by
test. No producer ships in Swift either — the Apple miniLLM producer is
the PR-10 rider.

### 1.17.0 -- 2026-07-30

MXE-BB (ee#49): migration circuit breaker for `runSharedContentMigration`.
After `sharedContentCircuitBreakerThreshold` (= 3) consecutive identical
failures — same `SharedContentMigrationError.briefDescription` at the same
committed `SharedContentMigrationState` — the migration is parked and
`runSharedContentMigration` throws `SharedContentMigrationError.migrationParked`
on all subsequent calls, preventing moot-mgr from respawning into the same
fatal error at 100 % CPU. A code-version change (the compile-time
`sharedContentMigrationVersion` token) auto-clears the park, giving the
updated binary a fresh attempt without operator intervention. The explicit
operator path is `clearParkedSharedContentMigration(handle:now:)`. The
observable state is queried via `sharedContentMigrationIsParked(handle:)`.
Circuit-breaker state is stored as an optional `circuitBreaker` field in the
migration record (backward-compatible: old records decode with `nil`).
Both Swift and Rust ports ship identical behavior gated by the same threshold.

### 1.16.0 -- 2026-07-20

- Established one canonical GLK content row: LocusKit owns Drawers and GLK
  injects a LocusKit-backed content source into CorpusKit.
- Made CorpusKit passage/chunk production dark in GLK and changed Corpus
  retrieval/vector identity to `Drawer.id` directly.
- Replaced the legacy chunk-owner translation lane and broad vector teardown
  language with Drawer-keyed indexing and ownership-scoped deletion.
- Added the pre-1.1 migration gate: remove redundant Corpus copies, rebuild
  derived state, verify, then enable the Corpus lane.

### 1.14.0 -- 2026-07-16
MX-TAB dataset surface documented (shipped 2026-07-11/12, not previously
in the spec): added `§ DATASET_STORE_ACCESS` covering the
`datasetStore(for:)` accessor seam and the layered content fingerprint
contract (`computeDatasetSignatures` — Tier 1 table SHA-256, Tier 2
per-column SHA-256, byte-identical preimage both legs).

### 1.13.0 -- 2026-07-12
VectorSimilaritySignal corpus lane (both ports at parity): the signal spec
gains an optional `corpus` parameter
(`spec(vectorStore:modelID:proximityThreshold:corpus:)` /
`spec(vector_store, model_id, proximity_threshold, corpus)`). When the
estate has a registered Corpus, the five-minute pass ALSO mines the
chunk-keyed corpus vector lane — the only row population production
estates hold — mapping chunk kNN hits back to owning drawers via
`Corpus.sourceIDs(forChunkIDs:)` / `source_ids_for_chunks` and collapsing
same-drawer chunk pairs, so every `AssociateFrame` carries drawer ids.
Previously the signal scanned only drawer-keyed rows under its modelID and
silently emitted nothing on real installs (same defect class as the
contradiction hunter's corpus-lane fix, ad0b215b).
`registerDefaultStandingSignals` forwards `corpusKits[handle]`; the Rust
governor forwards `EstateCoordinator::corpus_for` (promoted to `pub`)
through `default_standing_signal_specs` (new third parameter). Tests:
Swift `corpusLaneEmitsDrawerLevelAssociations` (asserts the persisted
association endpoints are the owning drawers) ↔ Rust
`corpus_lane_emits_drawer_level_associations` (asserts same-drawer chunk
pairs collapse to exactly one cross-drawer associate).

### 1.12.0 -- 2026-07-09
AUDIT-ALERT-RESTORE (the option-1 ruling). `UnifiedAuditLog` gained
`rejectedEntryCount` (Rust `rejected_count()`) — a monotonic counter,
excluded from structural equality, incremented at the same `add`
ingress choke point that already rejects content-hash-mismatched
entries (I-11). No change to the rejection defence itself; this is
observability only, added because secfix 5101e112's ingress rejection
had made NeuronKit's audit-chain integrity monitor's alerting
structurally unreachable (a rejected entry never reaches
`AuditChainVerifier`, so the chain walk always reported vacuously
valid). I-11 and B-9/B-10 updated to describe the current ingress path
(`auditLog(for:)` / `currentAuditLog(in:)`, under the storage-residency rule —
the doc previously named the removed `feedAuditLog(for:)`
per-drawer walk) and the new counter. See NEURONKIT_SPEC.md § 9 C-4/C-12.

### 1.11.0 -- 2026-06-28
Security fixes (secfix/c-glk-remaining): two correctness and safety invariants added.

**G5 — Wing-scoped topology privacy (`recallTunnels`)**
`recallTunnels(_ handle:, wing:)` previously called `provider.treeEdges(scope: nil)` and
stamped ALL returned edges with the queried wing's label, leaking foreign-wing node IDs into
every wing's tunnel stream. The fix resolves child node IDs against `estate.resolveNodeNames`
and retains only edges whose child maps to the queried wing. Root→wing structural nodes are
excluded (they resolve to the estate root, not the queried wing); only room-level containment
edges are emitted. The G1 read-once invariant is preserved — `treeEdges` is still called
EXACTLY ONCE; `resolveNodeNames` is a separate NodeStore read.
New test: `nodeTreeNative_g5_wingScoped_foreignEdgesExcluded` (Swift) verifies disjoint
containment sets across two real wings.

**G6 — `reindexMissing` unbounded fan-out cap**
`reindexMissing` now caps total enqueued jobs at `GeniusLocusKit.reindexMaxJobs` (10 000,
`EstateCoordinator::REINDEX_MAX_JOBS` in Rust). Large estates (200k+ drawers) previously
could flood the encode queue in a single call, starving live captures. Callers repeat the
call to continue backfill; the cap is a per-call ceiling, not a total lifetime ceiling. The
existing `enqueueChunk` constant (1 024) remains the per-fsync unit and is unaffected.
New tests: constant value assertion + cap enforcement test (both ports).

### 1.10.0 -- 2026-06-25
Additive (T1 — encode mode): `setEncodeSpeed(_:for:)` forwards an import's
declared encode SPEED (foreground/background) onto the estate corpus drain. Pure
orchestration — no new verb, no mutation of stored state, no byte-identity
change; the speed governs only the drain's embed concurrency (size-gated write
strategy is unaffected).

### 1.9.0 -- 2026-06-25
Additive (T6 — drain status): new public `drainStatuses(_:)` accessor + the
`DrainStatus` value type. Read-only aggregation of the estate's long-running
background drains (today only the corpus encode drain), assembled by observing
each drain's frontiers via `Corpus.ingestQueueDepth`. Validates the handle
(`EstateNotOpen` on a stale handle). No new verb, no mutation, no change to
byte-identity; backs the `moot_drain_status` MCP tool.

### 1.8.0 -- 2026-06-22
GLK_BATCH1: `captureBatch(_:_:)` now delegates to `Estate.captureBatch` (LocusKit
B-1a) instead of opening `rowStore.beginTransaction()` then calling per-item
`capture()`. SQLiteBackend tracks open transactions via `inTransaction`; the old
pattern threw `StorageError.transactionConflict` on any SQLite estate. The new
path opens ONE `storage.transaction()` for all fresh-lineage drawers via
`DrawerStore.insertFreshBatch`, falls back to per-item `addDrawerCovered` for
supersession frames, and runs post-insert coverage identical to single-item
`capture`. BM25/vector lanes remain dark until `moot_reindex` / `moot_dream`.

### 1.7.2 -- 2026-06-19
One-door FDC classification seam (fix/fdc-capture-seam): `capture(_:_:mode:)` /
`capture_with_mode` now classifies the `latticeAnchor.udcCode` at the seam before
filing the drawer, when the incoming frame carries the canonical unclassified sentinel
`"000"` (the UDC three-digit root) and non-empty content. Classification runs
`EideticLib.lookup` / `Fdc::encode_anchor` (deterministic, pinned LatticeLib
artifacts). Callers that previously classified per-call (file_memory's direct
`FDC.encodeAnchor` / `Fdc::encode_anchor`, vault import's `EideticLib.lookup`) have
been simplified to pass the `"000"` sentinel; the seam is the single classification
site for all capture paths. An explicit non-sentinel `udcCode` on the incoming frame
is preserved unchanged — the seam does not override a pre-classified anchor. When
content is UNRESOLVED (no FDC code returned), the sentinel remains so the drawer
files cleanly. The canonical sentinel is corrected from the incorrect child node
`"000.000"` to the UDC root `"000"` in all sentinels, test helpers, and comments
across the codebase.

Invariant (one-door): two capture behaviors are equal ONLY if they traverse the SAME
functional call tree. All call sites — `moot_file_memory`, vault import
(`DrawerMapping.makeCaptureFrame`), and branch promotion — funnel through
`capture(_:_:mode:)` / `capture_with_mode`, which is now the sole FDC classification
site. Parity: `GeniusLocusKit/Intake/EncodeIntake.swift` (Swift) and
`GeniusLocusKit/rust/src/intake.rs` (Rust); test parity in
`FdcCaptureTests.swift` / `error_message_and_fdc_tests.rs`.

### 1.7.1 -- 2026-06-19
Additive (FINDING-1b cluster C): `tombstonedLineageIDs(_ handle:)` added to the GLK verb surface (B-1-compliant passthrough for VaultKit). Delegates to `Estate.tombstonedLineageIDs()` → `DrawerStore.tombstonedLineageIDs()`, which issues a storage-tier `.isNotNull(tombstonedAt)` predicate and reads `lineageID` from raw rows without a full decode — deliberately avoiding timestamp-format parsing, which is sensitive to the format difference between `ISO8601DateFormatter()` (no fractional seconds, used by `expungeGated`) and `LKISO8601` (fractional seconds). Returns `Set<UUID>` of cluster C lineage IDs. Parity: `EstateCoordinator::tombstoned_lineage_ids` in the Rust port.

### 1.7.0 -- 2026-06-17
Added invariant I-16 (composite schema version = sum of component versions, derived in both ports): after the the forward-compatible ext-slot contract `ext` pre-provisioning the composite is 7 (LocusKit v2 + SynapseKit v3 + CorpusKit/BundleStore v2). The `grants` table gained the the forward-compatible ext-slot contract `ext` forward-compat slot. Pre-ship pre-provisioning during the 1.0.0 free-migration window.

### 1.6.1 -- 2026-06-17
Clarification (parity-sweep-batch #12): noted that the Rust port now mirrors the
`glkFingerprintsCaptured(in:window:)` method contract as
`EstateCoordinator::glk_fingerprints_captured(handle, start_epoch, end_epoch)`
(forwarding through `Estate::fingerprints_captured_in`), so the Moment lens reads
its windows through the GLK surface in both ports (B-1). No behavioural change to
the contract — the per-window fingerprint read was already specified; this records
the Rust surface that realises it.

### 1.6.0 -- 2026-06-17
Additive (GLK-RECALL-SHAPE-PRESETS): documented the NAMED PRESET ROSTER on
`RecallShape`. `RecallShape.preset(_:)` / `RecallShape::preset` resolves one of 19
roster names to its documented signed-weight shape; `presetNames` / `PRESET_NAMES`
and `presetDescription` / `preset_description` are the discoverable surface. Each
preset is a weight vector over the EXISTING fusion (no new engine math); `balanced`
and any unknown name resolve to the unsteered uniform fusion. Added the
"Named preset roster" subsection under the signed-weight steering section. No
behavioural change to the fusion engine — the roster only names weight vectors the
engine already honours. Conformance: `RecallShapePresetTests.swift` /
`recall_shape_presets.rs`.

### 1.5.0 -- 2026-06-17
Brought the Rust port to parity on the `GraphCache` / `PreferenceStore` recall-
consumption surface (mission glk-recall-graphpref-rust, closing the recall-shape contract D-4). The
`graph` / `preference` columns are no longer hardcoded `0.0` in Rust: the port now
defines the two traits (`Send + Sync`, per-drawer score lookup),
`register_graph_cache` / `register_preference_store`, and per-candidate
`col_graph` / `col_preference` lookups in the unionBest `.matrixAware` score loop
(both sharing the `weights.graph` slice, Swift parity). Corrected the per-port
note that previously claimed the Rust columns were dark. Cache producers remain
absent in both ports (future mission).

### 1.4.0 -- 2026-06-17
Extended `RecallShape`'s steerable surface to the FULL set of recall scoring
columns (mission 6b-modifiers-matrix-steer). The five matrix/graph/preference
columns — `fieldFit`, `coOccurrence`, `temporal`, `graph`, `preference` — are now
shape-steerable in the `unionBest` `.matrixAware` weighted score, with the same
signed semantics (1.0 neutral, 0 excludes, <0 suppresses) composed on top of the
adaptive `RecallWeights` budget. The combined matrix term is split so
`coOccurrence`/`temporal` steer independently; the neutral path preserves the
exact pre-steer expression so a nil/all-ones shape is byte-identical (proven both
ports). The matrix keys are a no-op under `.raw`/`.rrf`. The stale "Matrix/graph/
preference columns are NOT shape-steerable" statement is removed. See the recall-shape contract.
ADDITIVE (MINOR).

### 1.3.0 -- 2026-06-17
Added the anti-similarity steering contract (mission 6b-modifiers-antisim):
`RecallShape.antiSimilarLanes` / `anti_similar_lanes` flips a dense lane's
objective to FARTHEST in the `unionBest` lane, querying CorpusKit
`floatFarthestPerSignal` and forwarding the most DISSIMILAR sources into the
RRF/consensus fold. DISTINCT from a negative weight (which demotes the nearest);
the two compose. Empty/nil ⇒ every lane nearest ⇒ byte-identical to the
pre-antisim fusion. The distinctness invariant is conformance-gated on both
ports. ADDITIVE (MINOR).

### 1.2.0 -- 2026-06-17
Changed (6a-iii-wire): the production default recall ensemble is now the five
distributional signals (RI/PPMI/LSA/NMF/FDC) at every provision/open site, replacing the
single deterministic hash lane. `provision` takes `embeddingModels: [EmbeddingModel]`
(Swift, default `CorpusEnsemble.defaultEnsemble()`) / `embedding_models:
Vec<EmbeddingModelConfig>` (Rust, app supplies `default_ensemble()`). Recall is the
multi-signal default; the trainable signals train+persist on first ingest/reindex.

### 1.1.1 -- 2026-06-17
Clarification (6b-modifiers-core-2): the signed-weight steering now applies to the
`unionBest` lane too — the only lane where the per-signal dense float signals fuse.
The per-signal `dense:<modelID>` weights scale each signal's reciprocal-rank term
in the dense consensus fold (`w==0` excludes the signal — leave-one-out, also
withholding its cosine from the aggregate `dense` column; `w<0` subtracts its rank
mass; only forwarding `w>0` signals raise the aggregate cosine), and the fixed
`locus`/`bm25`/`hamming`/`dense` keys scale the unionBest weighted columns. An
excluded signal no longer claims per-hit `denseSignals:` provenance; a suppressed
signal still does. A nil/all-1.0 shape stays byte-identical to the pre-steer
unionBest output. No public API change — wires the already-public dense weights
that 6b-modifiers-core left inert in unionBest.

### 1.39.0 -- 2026-08-20
W3 additive selector registrations (both ports). (a) Five new named presets:
`anti_redundant_ri`, `anti_redundant_lsa`, `anti_redundant_nmf` — per-signal
anti-similarity variants with the same bm25/hamming suppression pattern as
`anti_redundant` but inverting RI, LSA, or NMF to FARTHEST respectively;
`temporal_connection` — temporal 1.5 + coOccurrence 1.5 for matrixAware scoring;
`field_preference` — fieldFit 1.5 + preference 1.5 for matrixAware scoring.
`PRESET_NAMES`/`presetNames` grows from 22 to 27 entries. (b) Per-call
`GLKRecallRequest.frontierK` (Swift `Int?` / Rust `Option<usize>`) per-call
candidate-pool depth override with three-level precedence: request > shape >
engine formula, clamped to `[64, 256]`. Both ports implement the same resolution
order. Tests added for all new presets and for the per-call override.

### 1.1.0 -- 2026-06-17
Additive (6b-modifiers-core): documented the signed-weight fusion steering
contract (`RecallShape`). The RRF combiner gains a per-lane signed weight
(`fused(id) = Σ_L w_L · 1/(k + rank_L(id) + 1)`): `w>0` forward, `w==0` exclude,
`w<0` suppress/demote — exclusion and suppression are distinct and conformance-
tested. Steering applies to the `hybrid` and `corpusOnly` RRF lanes; `unionBest`
stays unweighted this revision. A nil/all-1.0 shape is byte-identical to the
prior uniform fusion. `RecallShape` also carries a clamped `frontierK` pool-depth
override `[64, 256]`. Anti-similarity (true farthest-K) is deferred to
`6b-modifiers-antisim`.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.

### 1.49.0 -- 2026-08-23

ADORNMENT mission: dream-time AdornmentPass (SPEC_ADORNMENT).

**§11.2 standing signals — signal 13:**
`AdornmentPassSignal` (signal 13, `.single` concurrency, hourly schedule)
drives `AdornmentPass.run` over the default estate. The third governor
closure `adornmentCycle` is re-added in both ports so
`registerDefaultStandingSignals` now takes three Option closures (hunt,
anomaly, adornmentCycle) in the same commit as the signal registration.

**AdornmentPass §:**
- Fetches active drawers with `adornmentRequired` (bit 27) set, up to
  `defaultBatchSize` (50) per invocation.
- Invokes `invokeAdornmentCommand` (AdornmentLib MOOT_MINT_CMD seam) for
  each drawer's content.
- Validates via `AdornmentValidators.validateDate` (AV-6/AV-7: year-token
  containment gate). Over-length output (> `ADORNMENT_MAX_LENGTH`) is a
  validation failure — never truncate.
- On success: writes `adornment` field + bitmask code (0b001 = apple gen-1)
  and clears bit 27 via `setAdornment(drawerId:adornment:bitmaskCode:)`.

**Staleness semantics:**
- Body-mutating verbs (`capture`, `update`, `forget`) set `adornmentRequired`.
- Engine-family mismatch at dream time sets `adornmentRequired` for rolling
  regeneration (new family uses different bitmask codes).

**GLK harness API:** `runAdornmentPass(handle:batchSize:maxAdornmentLength?:now:)`
(harness-only overload; retired with the adornment pass, see 2.22.0).

### 1.48.0 -- 2026-08-22
PACKAGER mission: `GLKResultsPackager` — post-recall, pre-presentation packager.

**New types (Swift + Rust, both ports):**
- `PackagerAnswerMode` — `never` (default, byte-identical) / `always` / `auto`.
- `PackagerConfidenceLevel` — `CONFIDENT` / `INTERMEDIATE` / `WEAK`.
- `GLKResponseLevel` — `L0AnswerOnly` / `L1Full` / `RowsOnly`.
- `GLKConfidenceSignals` — four gate signals: m1 (top-margin), m2 (lane agreement),
  m3 (dense spread), m4 (word-boundary containment ≥60%).
- `GLKAnswerBlock` — answer text, confidence label/level, citation ids, signals.
- `GLKPackagedResult` — level, optional answer block, rows, total count.
- `PackagerThresholds` — seven tunable gate parameters with spec defaults
  (t1=0.25, t2=0.50, t1′=0.05, t3′=0.10, c=0.20, k_min=3, k_max=20).
- `GLKResultsPackager` — `package(result:mode:composedAnswer:thresholds:)` entry point.

**Gate decision (order is load-bearing):**
1. `answer:never` → fast path, all hits as rows, no gate computation.
2. WEAK if m1 < t1′ OR m3 < t3′.
3. CONFIDENT if m1 ≥ t1 AND m2 ≥ t2 AND m4 = true.
4. INTERMEDIATE otherwise.

**Score-cliff row cutoff:** Walk from index k_min to k_max; stop when
`gap[i] ≥ c × stddev(scores[0..k_max])`.

**`RecallTuningManifest` additions:**
Seven new packager threshold fields (`packager_t1`, `packager_t2`,
`packager_t1_prime`, `packager_t3_prime`, `packager_c`, `packager_k_min`,
`packager_k_max`) with fail-quiet serde defaults. No estate migration required.
`packager_thresholds()` accessor returns a `PackagerThresholds` value.

**Dependency:** `GLKResultsPackager` takes `composedAnswer: String?` injected
by the ARIA layer (AriaMcpKit). It does NOT import CognitionKit.

### 1.41.0 -- 2026-08-20
M3: `GLKRecallScoring` gains a fourth variant `discriminative`. The mode computes RRF fusion identically to `.rrf`, then scales every composite score by `denseDiscriminationFactor` ∈ [0, 1] — the mean relative spread of nearest cosines across all dense signals, clamped via the 0.15 saturation threshold. No matrix steer, fieldFit, graph, or preference signals are applied. `unionBest + discriminative` is a genuine implementation; the three non-`unionBest` modes surface named degradation stages (`locusOnly.discriminative`, `corpusOnly.discriminative`, `hybrid.discriminative`) and fall back to their existing combiner. Scoring-fallback table extended with three new rows; three new telemetry metric names added.
### 2.5.0 -- 2026-09-02
CDL-03: `LocusDrawerCorpusContentSource` (Swift) / `LocusDrawerContentSource`
(Rust) now accept an `IndexCompositionPolicy` and compose lexical and dense text
per the policy. Active adornments are fetched via `Estate.activeAdornments(drawerIDs:)`
when any lane requests them. The digest remains keyed on verbatim `drawer.content`
(idempotence anchor unchanged). `EstateLifecycle` reads `MOOT_INDEX_COMPOSITION`
env var at estate open and threads the policy to both the source and
`CorpusContentConfiguration`; absent/unrecognised → `.current`.
`GeniusLocusKit.indexCompositionPolicy(for:)` accessor added.

### 3.29.0 -- 2026-09-14

3.30.0: FACT_EXTRACTION_WIRE activates Signal 14 live in the resident daemon. The resident host resolves the active extractor at estate open through a single decision function (three cases: setting=off → inert; setting=on, extractor available → live with recipe activation; setting=on, no extractor → inert, not an error). The recipe ID is `providerID:modelID:modelVersion`. MootProductIdentity.Settings gains three new parsed keys: `fact_extraction.coreai_asset`, `fact_extraction.coreai_tokenizer`, `fact_extraction.model_version`. At this version the resident composition supplied CoreAI NuExtract only when its asset keys were present in config.json. FACT_EXTRACTION_WIRE: retires the explicit fact-first recall pre-stage. The fact
layer moves to its own door (`moot_fact_search`); the `recallFactFirst` /
`recall_fact_first` entry point and `FactFirstRecallStage`, `FactRecallFamily`,
`FactFirstRecallDecision`, and `FactFirstRecallThresholds` are removed from both
ports. The fact-extraction duty (§ FACT_EXTRACTION_DUTY) is unchanged.

### 3.28.0 -- 2026-09-14

FACT_EXTRACTION_WIRE: adds estate format V1_8 and the 1.7 → 1.8 migration capsule (I-27).

`EstateFormatVersion.v1_8` / `EstateFormatVersion::V1_8` is the new CURRENT
estate format (minor bump; old value was V1_7). `EstateFormatVersion.current`
/ `EstateFormatVersion::CURRENT` now resolves to v1_8.

`FactExtractionSetting` (Swift enum `String, Sendable, Equatable, CaseIterable`;
Rust `FactExtractionSetting` impl `Default, PartialEq, Eq, Clone, Copy, Debug`)
defines the two states: `.on` / `On` (raw "on", the default) and `.off` / `Off`
(raw "off"). Absent key → `.on` (the opt-out inversion: ON is the ruled product default;
the capsule seeds the value explicitly so a later default change cannot
silently flip an estate already in use).

Meta key `"fact_extraction"` (Swift `GeniusLocusKit.factExtractionMetaKey`;
Rust `EstateCoordinator::FACT_EXTRACTION_META_KEY`) is stored in the estate
manifest via `Estate.setMeta(key:value:)` and read via `Estate.meta(key:)`.

Accessor pair on the verb surface (both ports):
- `provisionFactExtraction(_ setting:, for:)` / `provision_fact_extraction(handle, setting)`:
  writes `setting.rawValue` / `setting.as_str()` via `setMeta`.
- `provisionedFactExtraction(for:)` / `provisioned_fact_extraction(handle)`:
  reads `meta(key:)`, returns `.on` / `On` for absent or unrecognised strings.

Migration capsule `GLKMigrationV1_7ToV1_8` / `FactExtractionSettingMigrationExt`:
Step 1 seeds `fact_extraction = "on"` only when absent (leaving any already-stored
value untouched). Step 2 stamps V1_8. Registered as the new last step of
`runCompiledChain` / `run_compiled_chain`, gated behind the new
`GLK_MIGRATION_V1_7_TO_V1_8` compile-time define (Swift package trait
`MigrationV1_7ToV1_8`; Rust feature `migration-v1-7-to-v1-8`).

Floor features `MigrationFloor1_7` / `migration-floor-1-7` added (compile only
the 1.7 → 1.8 capsule). All lower floors (1.0 through 1.6) include the new
capsule in their `enabledTraits` / feature dependencies.
