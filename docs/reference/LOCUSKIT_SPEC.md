---
title: LocusKit Specification
version: 1.12.0
status: active
date: 2026-08-02
description: "Behavioral specification for LocusKit: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
package: LocusKit
relates_to:
  - LOCUSKIT_INTERFACE.md  (the API surface this spec contracts)
  - GENIUSLOCUS_ARCHITECTURE_SPEC.md  (§ estate model, bitmap layouts, recall pipeline, audit reconstruction)
  - PERSISTENCEKIT_SPEC.md  (the storage protocol LocusKit binds to)
  - SUBSTRATELIB_SPEC.md  (fingerprint math used by container pruning)
  - ARIALEXICONLIB_SPEC.md  (the verb vocabulary the estate surface serves)
purpose: |
  LocusKit is the structured-memory and knowledge-graph tier for one
  estate. It owns the four nouns the substrate stores — Drawer (the
  atomic, content-immutable memory unit), KGFact, DiaryEntry, and
  Tunnel — together with the Estate actor that opens storage, validates
  the manifest, and applies the nine ARIA verbs (capture, recall,
  mutate, withdraw, expunge, reanchor, propose, associate, learn). It
  encodes all boolean and categorical row state in Int64 bitmaps (no
  Bool stored properties), keeps an append-only bitmap-audit trail with
  HLC-keyed forward-fold historical reconstruction (via AuditLogFold), and
  prunes recall with per-container OR fingerprints. It depends on PersistenceKit for
  storage and SubstrateLib for fingerprint math; it does not coordinate
  multiple estates (that is GeniusLocusKit). The companion INTERFACE
  document carries the signatures.
---

# LocusKit Specification

## § 1 — What this package is

LocusKit is the single-estate memory tier. An estate is one self-contained
spatial-memory store: a body of verbatim content (`Drawer` rows) organised
into wings and rooms, cross-linked by typed `Tunnel`s, annotated with
`KGFact` triples and `DiaryEntry` records, and reachable through a recall
pipeline that filters on three Int64 bitmaps per row. The `Estate` actor is
the only handle a caller holds; it owns a `DrawerStore` (the
PersistenceKit-backed CRUD layer) and a `ContainerFingerprintStore` (the
recall-pruning aggregate), validates the manifest's bitmap-layout version on
open, and exposes the nine ARIA verbs as its method surface.

GeniusLocusKit composes N estates and runs the Brain layer; LocusKit alone
is exactly one estate, with no awareness of federation, grants, or
cross-estate recall (spec invariant I-13 of the architecture spec keeps
cross-estate access in the ARIA access surface, not the substrate).

This package is a **Kit**: it manages state and lifecycle. The `Estate`,
`DrawerStore`, `ContainerFingerprintStore`, and `NodeBundleStore` actors own
a live storage connection and mediate every read and write; the noun value
types they move are immutable `Sendable` structs.

## § 2 — Scope

This specification defines:

- The four nouns — `Drawer`, `KGFact`, `DiaryEntry`, `Tunnel` — their
  field contracts, and the immutability of `Drawer.content`.
- The three per-row Int64 bitmaps (adjective § 5.5, operational § 5.6,
  provenance) and the rule that all boolean/categorical row state lives
  in them, decoded through computed accessors only.
- The `Estate` lifecycle: `open`/`create`/`close`, manifest validation,
  and the bitmap-layout-version compatibility gate.
- The nine ARIA verbs and which are implemented at this revision.
- The recall pipeline: `RecallFrame`, the `Filter` algebra,
  `HydrationLevel`, `Ordering`, the paged `RecallStream`/`RecallPage`
  contract, and container-fingerprint pruning.
- The append-only audit trail and HLC-keyed historical reconstruction
  (`auditTrail`, `bitmapState` via `AuditLogFold.projectStateAt`).
- The `Manifest`/`ManifestValues` key-value contract and the
  `LocusKitSchema` registration handed to PersistenceKit.
- The `Estate` consumer metadata surface (`meta`/`setMeta`) — the public,
  durable, lowest-level key-value primitive over the manifest table that upper
  layers persist their own state through (the daemon-state persistence contract). Consumers MUST namespace
  keys to avoid collision with the typed v1 `ManifestKey` set; values survive
  restarts (the manifest table is durable).
- The Swift ⇄ Rust conformance obligation and the documented port gap.
- LocusKit's role as the canonical Drawer content and identity owner when it is
  composed into GeniusLocusKit.

This specification does NOT define:

- API signatures — those live in `LOCUSKIT_INTERFACE.md`.
- Storage mechanics, the SQLite dialect, or the `Storage` protocol —
  see `PERSISTENCEKIT_SPEC.md`.
- Fingerprint / Hamming / SimHash math — see `SUBSTRATELIB_SPEC.md`.
- The FDC classifier itself — see `FDC_ENCODER_CANONICAL.md`. LocusKit
  stores a lattice anchor per drawer; it does not own the classification.
- Multi-estate coordination, grants, federation, the Brain layer, or
  vector recall — see `GENIUSLOCUSKIT_SPEC.md` and
  `VECTORKIT_SPEC.md`.
- The ARIA grammar the verbs realise — see `ARIALEXICONLIB_SPEC.md`.

## § 3 — Position in the kit family

```
SubstrateLib   PersistenceKit
       \            /
        \          /
         LocusKit            ← one estate: nouns, verbs, recall, audit
            ▲
            │ composed by
            ├── GeniusLocusKit   (N estates, grants, Brain layer)
            └── NeuronKit        (recall algorithms, dreaming, maintenance)
                    ▲
                    └── aria-mcp (estate exposed over MCP)
```

**Depends on:** `PersistenceKit` (the `Storage` protocol and
`SchemaDeclaration`), `SubstrateLib` (`Fingerprint256`, `HyperplaneFamily`,
`CountVector256` for container pruning and bundle materialisation). Metal is
not used here.

**Consumed by:** `GeniusLocusKit` (the heaviest consumer — owns estate
handles and verb fan-out), `NeuronKit` (recall, diary, tunnels, recall
traces), and `aria-mcp` (lifecycle + capture/recall over the wire).

## § 4 — Invariants

**I-1 (one estate per handle):** an `Estate` is exactly one estate. It
holds no reference to any other estate and performs no cross-estate read or
write. Multi-estate coordination is GeniusLocusKit's concern.

**I-2 (no Bool stored properties on nouns):** every boolean and categorical
attribute of `Drawer`, `KGFact`, `DiaryEntry`, `Tunnel`, and
`RecallTraceItem` is encoded as a bit or bit-field inside an `Int64` bitmap
column (`adjectiveBitmap`, `operationalBitmap`, `provenance`/
`provenanceBitmap`). Bool surfaces only as a computed property backed by a
bitmap bit (e.g. `Drawer.isPinned` via feature-flag bit 12,
`RecallTraceItem.used` via bit 0, `Tunnel.hasInverse` via bit 12).

**I-3 (drawer content immutable at core):** `Drawer.content` is stored
verbatim — no truncation, no normalisation — and is never mutated in place.
A revision is a new drawer sharing the prior `lineageID`; the predecessor's
state flips to `.superseded` through the supersession cascade rather than
being edited. Verbs change a drawer's bitmaps, never its content bytes.

**I-4 (modelID tagging):** every drawer and diary entry carries an
`embeddingModelID` from creation, even before any embedding is generated, so
vectors produced by different embedders can never be compared accidentally.
`capture` rejects an empty `embeddingModelID`.

**I-5 (every drawer carries a lattice anchor):** `Drawer.udcCode` is `TEXT
NOT NULL DEFAULT ''` at storage; `capture` rejects an empty
`latticeAnchor.udcCode`. The no-anchor sentinel is the empty string, not
nil, so the column stays non-null and migrations remain mechanical.

**I-6 (determinism — `now` passed in):** every engine computation is a pure
function of its inputs. Wall-clock time enters only at the outermost public
verb boundary, where `Date()` is read once and threaded downward as an
explicit `now:` parameter to every store method. No `DrawerStore`,
`ContainerFingerprintStore`, evaluator, or validator reads the clock
internally.

**I-7 (dates stored as TEXT ISO8601):** every date column —
`filedAt`, `eventTime`, `recalledAt`, `changed_at`, `created_at`,
`last_modified`, tombstone timestamps — is stored as a TEXT ISO8601 string,
never REAL. Rationale: human readability, string sortability, timezone
correctness.

**I-8 (audit trail is append-only):** the `bitmap_audit` table accepts only
INSERTs; BEFORE-triggers reject UPDATE and DELETE
(`trg_bitmap_audit_no_update` / `trg_bitmap_audit_no_delete`). Every state
mutation writes its audit row inside the same transaction as the mutation —
there is no observable window in which a bitmap change exists without its
audit entry.

**I-9 (bitmap-layout-version gate):** `Estate.open` refuses storage whose
manifest `bitmap_layout_version` differs from
`Estate.expectedBitmapLayoutVersion`, throwing
`EstateError.manifestMismatch`. Bitmap bit positions are part of the on-disk
contract; a mismatch requires an explicit migration before the kit reads the
data.

**I-10 (storage is injected):** `Estate.open`/`create` take an `any Storage`,
never a file path. The kit depends only on the PersistenceKit protocol and
never constructs a concrete backend; the caller owns the connection's
lifecycle.

**I-11 (cross-port parity):** the Swift and Rust version are conformance-gated against shared behaviour. Where the ports differ in shape (async vs sync, SQLite vs in-memory store), the *value-level results* of capture, recall filtering, bitmap encode/decode, and audit-log reconstruction must agree. Neither version leads. See § 8 for the documented surface gap.

**I-12 (`ext` forward-compat slot, the forward-compatible ext-slot contract):** every persistent entity table
carries exactly one nullable `.json` column named `ext`, reserving migration-free
space for future per-row typed metadata (federation, encryption, custody). In 1.0
`ext` is inert — written NULL / omitted on insert and never read; it carries no
behavior. The slot was provisioned across all persistent entity tables during the
1.0.0 free-migration window (`keys` gained it at LocusKit schema v2). `ext` is
excluded from regenerable/cache/bookkeeping tables (manifest, container_fingerprints,
node_bundles). See the forward-compatible ext-slot contract for the full inclusion/exclusion list.

**I-13 (canonical GLK content owner):** when an Estate is composed into GLK,
LocusKit's `Drawer` row is the one canonical stored representation of that
content and `Drawer.id` is its canonical identity. CorpusKit may index the
Drawer only through a GLK-owned adapter over LocusKit reads and change events;
it may not persist a second verbatim document, passage, or chunk copy. This
composition rule adds no CorpusKit dependency to LocusKit and does not change
LocusKit's ability to operate standalone.

## § 5 — Behavioral contracts

**B-1 (capture validation, then write):** `capture` validates that
`content`, `room`, `latticeAnchor.udcCode`, `addedBy`, and
`embeddingModelID` are non-empty (throwing `LocusKitError.invalidContent`
naming the violated rule) before any storage call, assembles the operational,
adjective, and provenance bitmaps from the frame's named slots, writes the
drawer, and OR-folds its bitmaps into the per-container fingerprint aggregate.
The provenance bitmap (cookbook §2.5) carries `sourceType` (bits 0–5),
`provenanceChannel` (bits 6–11), `confirmation` (bits 18–23), `confidence`
(bits 24–29), and `provenanceSensitivity` (bits 30–35) from the frame. All five
default to raw 0, so a frame that leaves them unset produces a zero-provenance
drawer byte-for-byte identical to one captured before any provenance slot
existed; a daemon capturing already-confirmed content with a known confidence
band records `confirmation` / `confidence` at birth rather than via a later
`confirm` mutation or enrichment pass. The capture-time write windows match the
drawer's `confirmation` / `confidence` read accessors exactly (round-trip +
default-byte-identity conformance-gated in both ports).

**B-1a (batch capture — single transaction):** `captureBatch` applies the same
frame-validation rules as `capture` to every frame, then writes all fresh drawers
(those whose `lineageID` has no active predecessor) inside a single
`storage.transaction(isolation: .serializable)` via `DrawerStore.insertFreshBatch`.
Frames whose `lineageID` matches an active predecessor are written per-item via
`addDrawerCovered` (see B-2). Post-insert, `captureBatch` OR-folds coverage and
updates Merkle roots for each fresh-batch drawer, identical to the per-item
`capture` path. HLC timestamps are stamped before entering the transaction closure
to comply with actor-isolation rules. Callers must invoke `moot_reindex` /
`moot_dream` to rebuild BM25/vector lanes; batch import intentionally skips the
encode queue.

**B-2 (supersession cascade):** when `CaptureFrame.lineageID` matches an
active predecessor, capture fires the cascade atomically inside one
`BEGIN IMMEDIATE` transaction — the predecessor flips to `.superseded`, a
bitmap-audit row is written, and a `supersedes` tunnel is created. When
`lineageID` is nil, a fresh UUID is stamped so each drawer is its own lineage
(architecture spec § 5.10).

**B-3 (recall is non-throwing; the stream is the failure boundary):**
`recall` returns a `RecallStream` and never throws. An internal-read fault does
NOT silently collapse to a genuine-looking empty result. Instead, when an
internal read fails — the bounded corpus scan (`liveRows`), the fingerprint-
pruning room-fingerprint enumeration, a surviving room's drawer read, or the
bitmap evaluator — `recall` records a NAMED stage on `RecallStream.degradedStages`
(`degraded_stages` in Rust) and emits an empty (or short) page sequence. A
GENUINE-EMPTY estate (every read succeeded, no rows matched) emits an empty
single-page sequence with `isLast == true` and an EMPTY `degradedStages`. The
two are therefore DISTINGUISHABLE at the stream: a non-empty `degradedStages`
means a FAILED read (or a lost reward-path trace, below), an empty one means a
clean result. Read/eval stage vocabulary (stable, cross-port):
`locus.liveRows.readFailed`, `locus.roomFingerprints.readFailed`,
`locus.roomDrawerRead.readFailed`, `locus.bitmapEval.failed` — these four
accompany an EMPTY result (the failed read produced no candidates). One further
stage, `recall.trace_write_failed`, covers the opt-in reward-path TRACE WRITE
(B-10): unlike the read/eval stages it fires AFTER reads and evaluation succeed,
so the result is POPULATED and returned normally and the stage records only that
the trace write was lost. The GLK `RecallDirector` merges all of these into
`GLKRecallResult.degradedStages`. Callers needing the rows behind a fault still
go through the store directly; callers needing only to tell failed-from-empty
read `degradedStages`.

**B-4 (filter chain is conjunction):** a `RecallFrame.filterChain` is `[Filter]`
interpreted as implicit AND (equivalent to `Filter.all(chain)`). When the
chain carries no state filter the evaluator prepends `currentlyBelieve`; no
trust filter prepends `trustworthy`; no sensitivity filter prepends
`.sensitivityAtMost(.elevated)`. No confirmation filter is inserted by
default; callers request `.userConfirmed`, `.unconfirmed`, or other
provenance filters explicitly. "No filter" therefore defaults to
currently-believed, action-trustworthy content across any confirmation state
within the Normal tier.

**B-4.1 (recall defaults — tier-aligned sensitivity ceiling):** the default
insertions described in B-4 are the no-claims posture for a caller
that has not asserted access entitlements. The sensitivity default
`.sensitivityAtMost(.elevated)` is the Normal-tier ceiling per the data-movement contract
Decision 2 and the normative tier mapping: Normal tier encompasses
`.normal` and `.elevated`; `.restricted` (Private tier) and `.secret` (Secret
tier) are excluded from default recall. `restricted` and `secret`
drawers are reachable only when the caller explicitly constrains the
sensitivity axis, e.g. `.sensitivity(.secret)` or
`.sensitivityAtMost(.secret)`.

An explicit sensitivity constraint on the filter chain suppresses the default
rather than AND-ing against it. A chain that carries `.sensitivityAtMost(.secret)`
receives no additional sensitivity default; the caller's ceiling is the sole
gate. This is the classifier-suppressed pattern: when the caller constrains an
axis, the evaluator trusts that constraint and does not impose an additional
floor.

Claim-driven default adjustment (future aria-mcp): access claims supplied by an
authenticated aria-mcp caller can LOWER the default ceiling — for example, a
grant set that does not include elevated content would cause the evaluator to
insert `.sensitivityAtMost(.normal)` instead. The default is the conservative
no-claims posture. The plumbing for claim-driven default adjustment is reserved
and is not present at this revision.

**B-5 (paged stream contract):** the first page is produced when iteration
begins; later pages lazily on each `next()`. Page size is
`RecallFrame.limit` or the default 50, clamped to at least 1. `pageIndex` is
zero-based; exactly the final page has `isLast == true`. An empty corpus
yields a single final page with `rows.isEmpty` and `isLast == true`.

**B-6 (hydration applied at emission):** `HydrationLevel.bitmapOnly` strips
`content` to `""` while preserving every other field (notably all three
bitmaps); `.structured` and `.full` return the row unchanged at this
revision (`.full` diverges only when the blob tier ships).

**B-7 (container pruning is sound):** when the chain carries a prunable
filter, recall walks per-container OR fingerprints — a wing-level test can
drop a whole wing in one comparison, a room-level test a room — before
fetching rows. The aggregate covers every active container (backfilled on
open, OR-in per capture) and over-approximates each container's bits, so a
survivor is never wrongly dropped; an absent fingerprint is treated as
surviving, never empty.

**B-7a (per-drawer fingerprint lattice block — qidClosureHash live):** the
per-drawer structural fingerprint (`EstateFingerprintFamilies.fingerprint`)
populates the lattice block's taxonomic-closure facet, `qidClosureHash`, from
the drawer's `wikidataQID`: the `FNV.hash16` of the sorted-numeric,
`"|"`-joined transitive P31/P279 ancestor closure
(`LatticeLib.QIDClosure.ancestors(of:)`, a pinned offline Wikidata snapshot;
the runtime never re-queries). A drawer with no QID or whose QID has no
ancestors takes the deterministic null `0` — identical to the pre-#7b value, so
fingerprints change only for drawers whose QID carries ancestors. The facet is
no longer null-by-deferral. Both ports compute the closure and hash identically
(same edges, BFS, numeric sort, `"|"`-join, `FNV.hash16`); cross-port
conformance holds.

**B-8 (withdraw preserves upper axes):** `withdraw` clears the state field
(bits 0–3 of the adjective bitmap) and OR-s in `State.withdrawn`, leaving
sensitivity / exportability / trust untouched, and writes the mutation plus
its audit row atomically.

**B-8a (expunge sealAudit parameter — deferred audit seal for GLK orchestration):**
`Estate.expunge(rowID:reason:confirmation:now:sealAudit:)` accepts an optional
`sealAudit: Bool = true` parameter (Rust: `seal_audit: bool`). When `true` (the
default for direct LocusKit callers), the gate-produced `AuditEvent` is appended
to the substrate audit log inside the call, preserving the historical single-call
atomic contract. When `false` (used by the GLK orchestration path), the
storage mutation (tombstone, content zeroed, bitmaps written) commits atomically,
but the audit event is returned unsealed. The caller is responsible for calling
one of two sealing methods after determining step-2 success or failure:

- `sealExpungeAudit(_ event: AuditEvent)` (success path): appends the gate-
  produced event as `verb = "tombstone"` — the success audit is honest.
- `sealExpungeOrphanAudit(rowID:successEvent:now:)` (failure path): constructs and
  appends an `"expungeOrphan"` event — the audit honestly records the partial state
  (storage succeeded, cross-kit delete did not). If this seal call also fails, the
  error is NOT swallowed: it is propagated to the GLK boundary (folded into the
  Rust `CrossKitVectorDeleteFailed.reason` string; logged at OSLog `.fault` in
  Swift before rethrowing the step-2 error).
- `sealExpungeOrphanAuditSynthetic(rowID:now:)` (sweep path): used by the GLK
  integrity sweep after a crash-window row is detected. Constructs the "expungeOrphan"
  event from current drawer state (bitmaps + lattice anchor) rather than from the
  original gate event (which was lost). Sweep events carry `beforeBitmaps: nil` /
  `before_bitmaps: None` to mark them as crash-window remediation rather than
  live-expunge orphans.
- `tombstonedRowsWithoutExpungeAudit()` (sweep path): queries for tombstoned
  drawers that have no "tombstone" or "expungeOrphan" audit event. Returns the
  crash-window set for the GLK sweep to remediate. A storage failure is fatal
  (the caller cannot enumerate the orphan set; propagates via `GeniusLocusKitError`).

Both `"tombstone"` and `"expungeOrphan"` substrate verb strings map to
`UnifiedAuditVerb.expunge` in the GLK unified log (`AuditBridge` / `verb_from_str`),
so downstream consumers see the storage-level expunge in both cases. The raw verb
string is preserved in the substrate audit trail for forensic inspection.

Direct callers (not via GLK) use `sealAudit: true` and are unaffected.

**B-9 (HLC-keyed forward-fold reconstruction):** `bitmapState(rowID:asOf:)`
reconstructs a row's three bitmaps at a specific HLC (hybrid logical clock)
by forward-folding the row's audit log via `AuditLogFold.projectStateAt`
(SubstrateML, cookbook § 5.3). The audit log is replayed in HLC order from
the genesis capture event forward; events at or before `asOf` are included.
State is keyed on HLC, not wall-clock (§11 clock decision;
the clock-triangle time model). An `asOf` before the genesis event
throws `drawerNotFound`. The parameter label is `asOf:` and the type is
`HLC`, not `Date`. Both legs (`EstateAudit.swift` / `estate_audit.rs`) call
the substrate primitive; no XOR arithmetic appears in the kit layer.

**B-10 (recall trace hook):** trace writes are opt-in via `RecallFrame.traceLimit`.
`traceLimit = nil` (the default) writes NO trace rows — internal scans and
VaultBridge-style full-estate reads must not accumulate reward data.
`traceLimit = n` writes at most the first n surfaced rows as
`RecallTraceItem` rows (`used == false`); the later two-source reward path
sets `used = true` for rows the caller acted on, feeding Bradley-Terry
weighting in NeuronKit. Only the GLK RecallDirector primary locus call sets
`traceLimit`; all other callers leave it nil. A trace-write failure is
FAIL-CLOSED: it does not throw and does not empty the result — the caller still
receives its rows — but the lost trace is surfaced as the `recall.trace_write_failed`
degraded stage (B-3) so the reward sweep's missing input is observable rather than
silently swallowed. A genuine successful trace write records no stage.

**B-10a (HARD RULE — trace origin):** the read log records
EXTERNAL experience only. Reads performed on behalf of an external consumer —
a human or an outside AI system arriving through the ARIA access surface —
are the only reads that may write recall traces. Internal reads NEVER trace:
maintenance and autonomic functions (dreaming, standing signals, the matrix
tier, the training daemon), recipe and lens internals, migration and vault
scans, and regression/benchmark harnesses all leave `traceLimit = nil`.
Rationale: the reward pipeline learns from experience WITH users; a system
tracing its own internal reads trains on its own reflection, and re-opens
the unbounded-growth failure the opt-in + bound + retention-prune mechanism
was built to close. Enforcement: request origin is asserted at the ARIA
boundary and flows down — the director never assumes it. Conformance: an
internal read producing a trace row is a defect.

**B-11 (scan cap honors explicit limits):** the scan bound is
`max(frame.limit ?? 0, recallCandidateCap)`. Director-style callers
(limit ~20) keep the 256 floor; explicit large-limit callers (e.g. limit
10_000_000 for a full-estate VaultBridge scan) get a true full scan so no
drawer is silently truncated.

**B-12 (frame-aware by-id load):** `getDrawers(ids:matchingFrame:hydrationLevel:)`
(Swift) / `get_drawers_matching_frame(ids, frame)` (Rust) is an O(candidates)
by-id load that applies the frame's filter chain through the SAME
`BitmapEvaluator` pipeline `recall` uses — so the returned `admissible` set is
exactly the frame-filtered subset of `ids`, with the default insertions of B-4
(implied `currentlyBelieve`/`trustworthy`/sensitivity ceiling — NO confirmation
default; see B-4) and tombstone exclusion applied identically. A frame override (e.g.
`.usedToBelieve`) admits the corresponding non-active drawers, just as it does
on the full `recall` path. The result also reports `loadedIDs` (Swift) /
`loaded_ids` (Rust): every id whose row physically loaded, REGARDLESS of the
frame filter. This is the contract that lets a caller gate a drop on load
success — an id that loaded but is absent from `admissible` failed the frame
filter (drop it); an id absent from `loadedIDs` did not load (a transient or
partial read) and must be degraded gracefully, never dropped. The
GLK RecallDirector uses this to build its corpus/vector hydration `drawerIndex`
so a withdrawn drawer is dropped from default recall but surfaces under a
`.usedToBelieve` frame — identical to the Rust recall path whose `drawer_index`
is derived from a frame-filtered `estate.recall(frame)` scan.

**B-16 (GLK content-source projection):** GLK projects the existing Drawer
read/capture/mutation lifecycle into CorpusKit's `CorpusContentSource` contract.
The projection exposes canonical id, current content, revision/digest metadata,
and an incremental cursor without transferring ownership. Corpus indexing and
recall results remain keyed by `Drawer.id`; LocusKit never imports CorpusKit or
writes CorpusKit tables.

## § 6 — Error model (conceptual)

| Category | Trigger | Recovery posture |
|---|---|---|
| `LocusKitError.databaseUnavailable` / `.sqliteError` | the backing store cannot open, or a SQLite call returns non-OK | surface; carries the verbatim `sqlite3_errmsg` for logging |
| `LocusKitError.invalidContent` | a capture/verb slot violates a non-empty or content rule | surface; the message names the violated rule and is part of the contract |
| `LocusKitError.drawerNotFound` / `.tunnelNotFound` / `.diaryEntryNotFound` / `.recallTraceItemNotFound` | a verb references an id that is absent | routine query miss; the caller decides whether it is an error |
| `LocusKitError.disciplineViolation` | an illegal state transition, a forbidden bitmap combination, or an expunge without confirmation | surface; names the rule (carries `from`/`to` State raw values) |
| `LocusKitError.schemaTooNew` | on-disk schema version newer than this build | surface; reserved for the migration workflow, not thrown at this revision |
| `LocusKitError.corruptStoredValue` | a stored TEXT value in a required column (e.g. `drawers.lineageID`, a `.timestamp` column, or the manifest `estate_uuid`) is present but cannot be parsed to its declared type | surface fail-loud; never substitutes a default (random UUID, epoch-0 date, node 0). An ABSENT value (legitimate fresh state) is distinct and does NOT throw — only a present-but-unparseable value is corruption |
| `LocusKitError.notSupported` | a verb targets a feature not implemented in this revision | surface; distinguishes "code missing" from "data missing" (`*NotFound`) |
| `EstateError.emptyOwnerIdentifier` | `OwnerCredentials.ownerIdentifier` is empty | surface before any storage call — structurally distinct from a substrate fault |
| `EstateError.substrateUnavailable` | the store could not be opened or created | surface; wraps the underlying diagnostic |
| `EstateError.manifestMismatch` | a manifest value (notably `bitmap_layout_version`) is incompatible (I-9) | surface; requires a migration mission before the estate can be read |

All categories are programmer/protocol or substrate-fault conditions, not
silent fallbacks. `EstateError` is the estate-lifecycle surface;
`LocusKitError` is the substrate/verb surface.

## § 7 — Conformance requirements

**C-1 (bitmap round-trip):** for every noun, encoding a set of named
adjective/operational/provenance axis values and decoding them through the
computed accessors returns the original values; unrecognised raw values fall
back to each axis's documented neutral case (e.g. `State.active`,
`Trust.verbatim`, `CaptureChannel.typed`). No accessor is partial.

**C-2 (capture invariants I-3/I-4/I-5):** `capture` stores `content`
verbatim, rejects empty `embeddingModelID` and empty `udcCode`, and stamps a
fresh `lineageID` when none is supplied; a matching active `lineageID` fires
the supersession cascade atomically (B-2).

**C-3 (recall pipeline):** the filter chain evaluates as conjunction with the
documented default-filter insertion (B-4, B-4.1); pruning never drops a
surviving container (B-7); the paged stream honours the page/`isLast`/hydration
contract (B-5, B-6). The sensitivity default must be `.sensitivityAtMost(.elevated)`
(not `.normal`); see B-4.1 for the tier rationale and the explicit-override
suppression rule.

**C-4 (audit append-only + reconstruction):** every state mutation writes
its audit row in the mutation's transaction (I-8); `bitmapState` reconstructs
past state by HLC-keyed forward-fold via `AuditLogFold.projectStateAt` (B-9);
the audit log rejects non-INSERT writes at the storage level.

**C-5 (manifest gate):** `Estate.open` admits storage only when
`bitmap_layout_version` equals `expectedBitmapLayoutVersion`, otherwise
throws `manifestMismatch`; `open`/`create` reject an empty owner identifier
before touching storage (I-9, error model).

**C-6 (determinism):** running any verb twice with identical inputs and the
same injected `now` produces identical stored rows and audit deltas; no
engine reads the system clock internally (I-6).

**C-7 (cross-port, I-11):** the Swift and Rust version produce identical
value-level results for C-1…C-4 and C-6 against shared behaviour, allowing
for the documented surface gap (§ 8). A value-level divergence fails the
conformance gate.

**C-8 (GLK shared-content composition):** the GLK adapter conformance fixture
must prove that capture/change/delete are observed under the original
`Drawer.id`, that Corpus recall returns that same id, and that indexing creates
no second verbatim-content row. The fixture runs against both ports.

## § 8 — Out of scope

- The `Storage` protocol, SQLite dialect, triggers as a mechanism →
  `PERSISTENCEKIT_SPEC.md`.
- Fingerprint / Hamming / SimHash / count-fold math →
  `SUBSTRATELIB_SPEC.md`.
- The FDC classification encoder → `FDC_ENCODER_CANONICAL.md`.
- Vector embeddings and ANN recall → `VECTORKIT_SPEC.md`.
  Relevance-ranked recall is a GLK-level operation delivered through
  NeuronKit/HybridRecall on top of VectorKit; LocusKit's `Ordering` enum
  does not include a relevance case because LocusKit has no scoring signal.
  Callers that need relevance ordering must use GLK RecallDirector.
- N-estate coordination, grants, cross-estate recall, branches, the Brain
  layer → `GENIUSLOCUSKIT_SPEC.md`.
- Hybrid recall, dreaming, maintenance, reward sweeps → NeuronKit.
- The ARIA grammar the verbs realise → `ARIALEXICONLIB_SPEC.md`.

**Cross-version shape contract (I-11).** The Swift and Rust versions realise
the same contract with different host shapes:

- **Concurrency.** Swift verbs and stores are `actor`-isolated and `async`;
  the Rust version is synchronous (`pub fn ... -> Result<...>`), serialising
  access through the backend's internal mutex.
- **Time.** Swift reads `Date()` once at the verb boundary (I-6) and threads
  it down; the Rust verbs take `now: i64` as an explicit parameter, pushing
  the clock read entirely to the caller — a stricter realisation of the same
  determinism rule.
- **Store backends.** The Swift `DrawerStore` is a concrete actor over any
  injected `Storage`; the Rust version realises the same store contract
  through a `DrawerStore` trait. Both legs are conformance-gated to identical
  value-level results. The Rust version also surfaces helper shapes the Swift
  version keeps internal (`BitmapAuditPair`, `RoomBundle`, `RoomLevelEntry`).
  The Rust trait carries `withdraw_kg_fact`
  (mirroring the Swift `withdrawKGFact` present on the actor); the
  trait default returns `DatabaseUnavailable` so existing implementations are
  not broken — only `DrawerStoreCore` carries the live bitmap update logic.
  Most empty-success reads default fail-loud
  (`DatabaseUnavailable`). Two reads — `all_drawers` and
  `room_level_fingerprints` — instead carry NO default at all: per the SDK
  compile-enforcement ruling, a backend that forgets a corpus-scan /
  container-fingerprint read must fail to COMPILE rather than fail loud at
  runtime, matching the Swift surface where both are bare actor members.
  Because the durable newtypes
  (`SqliteDrawerStore`, `PostgresDrawerStore`) hand-forward each method to
  their inner `DrawerStoreCore` with no `Deref`, every such method MUST be
  explicitly forwarded; for the fail-loud-default reads an omitted forward
  inherits the default and hard-errors on a real estate, and for the two
  compile-required reads an omitted implementation is a build error. The
  newtype-forwarding contract is therefore an invariant: no durable-backend
  read method may inherit a trait default (and the two compile-required reads
  have no default to inherit).
  The Swift leg has no trait-default mechanism (`DrawerStore` is one concrete
  actor implementing every method directly), so this fail-loud-default posture
  is structurally Rust-only; Swift reaches the same durable behaviour by
  implementing every method against its injected `Storage`.

- **KG-fact active filter — single source of truth.** The active KGFact
  recall paths (`allKGFacts()` / `all_kg_facts`, `kgFacts(forDrawerID:)` /
  `kg_facts_for_drawer`, and the GLK `recallKGFacts` / `recall_kg_facts`
  pass-throughs) return the **RowState Cluster-A** set — the
  currently-believed states `active`/`pending`/`contested`/`accepted`.
  The `g_state_cluster` generated column stores the raw 6-bit RowState
  (`adjectiveBitmap & 0x3F`, 0–63), so the active predicate is
  `g_state_cluster < RowState.activeClusterUpperBoundRaw`
  (Rust `RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW`) — the cluster-B floor,
  16, sourced from the `RowState` automaton in `SubstrateTypes`, never a
  hand-rolled literal. The boundary equals RowState Cluster-A for every
  defined raw, so both ports and both backends (SQLite WHERE predicate and
  the in-memory `StoragePredicate::Lt`) classify identically; a conformance
  test pins `g_state_cluster < bound` to `RowState.cluster(ofRawState:)`
  `.isActive` across all 64 raws. The retired/historical (Cluster B, 16+)
  and terminal (Cluster C, 32+) states are excluded from active recall but
  remain visible through `allKGFactsIncludingRetired` / the
  `moot_fact_timeline` path.

- **KG-fact adjective axes — full Drawer parity.** `KGFact` shares the
  four-axis adjective-bitmap encoding with `Drawer` (cookbook §2.3 / §5.5)
  and exposes all four axes as computed accessors in both ports: `state`
  (bits 0–5), `adjectiveSensitivity` / `adjective_sensitivity` (bits 6–11),
  `exportability` (bits 12–17), and `trust` (bits 18–23). Each decodes a
  6-bit field with the same fail-closed fallback as the corresponding
  `Drawer` accessor (`.active` / `.normal` / `.private_` / `.verbatim` for
  unrecognised raws), so a fact and its source drawer answer the same
  retrieval-layer adjective predicates identically. Conformance: a
  shared-bitmap vector setting a distinct non-default value on each axis
  asserts every accessor reads only its own field (no mask/shift cross-talk),
  pinned in both `kg_fact.rs` and `KGFactTests.swift`.

These are *shape* differences; the value-level results that C-7 gates are
required to agree.

## § 9 — Verb-noun acceptance

The nine verbs are not uniformly legal on every noun. Legality is defined by
the acceptance matrix (`AriaLexiconLib.Acceptance`, architecture spec § 7.2),
which is data so a conformance harness checks both ports agree:

| Noun | Accepts |
|---|---|
| `Drawer` | capture, reanchor, mutate, withdraw, expunge, recall |
| `Tunnel` | capture, mutate, withdraw, expunge, recall |
| `KGFact` | mutate, withdraw, expunge, recall |
| `DiaryEntry` | recall |
| `Proposal` | mutate, withdraw, expunge, recall |
| `Association` | mutate, expunge, recall |
| `LearnedReference` | learn, mutate, withdraw, expunge, recall |
| `Vector` | (none — substrate-managed, not verb-addressable) |

- `mutate` carries the `MutationKind` axis with nine implemented cases:
  - **Confirmation axis** — `confirm`: writes `userConfirmed` to provenance
    bits 18–23.
  - **State axis** — `reject` (→ rejected), `contest` (→ contested),
    `resolve` (contested → active; guard: only from contested), `accept`
    (→ accepted; guard: trust ≥ canonical per cookbook §9.5.1),
    `supersede` (→ superseded), `revive` (historical Cluster-B → active per
    §9.3). `revive` restores any terminal-but-recoverable state to active:
    `decayed`, `withdrawn`, and `expired` revive unconditionally; `superseded`
    revives only when no living successor (a Cluster-A row sharing the
    `lineageID`) holds the lineage head — otherwise the guard raises
    `disciplineViolation` naming the lineage conflict, because two active
    rows at one lineage position is a domain contradiction (§6.2). Live
    (Cluster-A) and terminal (`rejected`/`tombstoned`) states refuse with a
    named `disciplineViolation`, never `notSupported`. The automaton
    (SubstrateLib `RowStateAutomaton`) legalizes all four Cluster-B → active
    transitions via `.observe`; the superseded lineage rule is enforced one
    layer up in LocusKit's revive guard, which has store access.
  - **Adjective axis** — `correctSensitivity(AdjectiveSensitivity)`: rewrites
    bits 6–11; `correctTrust(Trust)`: rewrites bits 18–23;
    `correctExportability(AdjectiveExportability)`: rewrites bits 12–17
    (cookbook §2.3, 6-bit scale-gapped field; raw 0 = `.private_`, raw 32 =
    `.public_`). This is the only post-capture write path for the exportability
    axis — a drawer is born private by default and is promoted or demoted via
    this mutation. `filter:exportable` recall returns drawers whose bits 12–17
    equal raw 32 (`.public_`).
  - All cases route through `DrawerStore.mutateState` or
    `DrawerStore.mutateAdjective`, which validate via `AuditGate.admit` and
    append one sealed `AuditEvent` atomically.

**the data-movement contract Decision 2 — Privacy-tier mapping on the sensitivity axis:**
The the data-movement contract three-tier model maps onto the existing four-value
`AdjectiveSensitivity` axis without adding new bits or schema changes.
The normative mapping is:

| `AdjectiveSensitivity` | Raw | the data-movement contract tier | Bulk-channel rule |
|---|---|---|---|
| `.normal` | 0 | Normal | Free bulk export |
| `.elevated` | 16 | Normal | Free bulk export |
| `.restricted` | 32 | Private | Bulk requires owner-held key (v1.0 gold) |
| `.secret` | 48 | Secret | Never rides bulk channels |

Three computed predicates on `AdjectiveSensitivity` encode this mapping
(Swift: `var isBulkExportable: Bool`, `var requiresOwnerKeyForBulk: Bool`,
`var isExcludedFromBulk: Bool`; Rust: identical `fn` equivalents). The
predicates are mutually exclusive and collectively exhaustive: exactly
one is `true` for every variant. Cite: the data-movement contract Decision 2.
- `learn` is legal only on `LearnedReference`: it records a learned reference
  through the LRF noun substrate. `Estate.learn(_:now:)` derives the
  reference's genuine lattice anchor from its `SourceCatalogEntry` (the
  `source` slot of `LearnFrame`), catalogs the source durably in
  `source_catalog` if not already present, and persists a `LearnedReference`.
  It fails loud (`invalidContent`) only on a genuinely invalid input — an
  empty reference handle. No sentinel anchor is ever fabricated.
- `propose` / `associate` are realised through the `Proposal` and
  `Association` noun stores and the tunnel/KG-fact paths, not as dedicated
  `Estate` verb methods.
- `propose` stamps genuine provenance: `Estate.propose(_:now:)` writes all
  five proposal operational axes (cookbook §2.4) into the proposal's
  `operationalBitmap` — `ProposalKind` (bits 0–5) and `ProposalTargetObjectType`
  `.drawer` (bits 6–11) from the verb, plus the three provenance axes
  `ProposalConfirmationSource` (bits 12–17), `ProposalGeneratedByClass`
  (bits 18–23), and `ProposalConfidenceBucket` (bits 24–29) supplied through
  `ProposeFrame.confirmation` / `.generatedBy` / `.confidence`. These windows
  are no longer hard-zeroed: a daemon-emitted proposal can record its true
  producer class and confidence rather than inheriting the raw-0 fallback
  (`.human` / `.dreamingDaemon` / `.null`). Those raw-0 values remain the
  frame defaults, so a frame that leaves the provenance slots unset produces
  a byte-identical operational bitmap to the pre-wiring behaviour. The bit
  windows match the `confirmationSource` / `generatedByClass` /
  `confidenceBucket` read accessors exactly (round-trip + default-byte-identity
  conformance-gated, both ports).
- A verb applied to a noun outside its accepted set is rejected by the
  acceptance check before any storage call.

---

## § 10 — Self-report telemetry

`DrawerStore` (via `DrawerStoreCore`)
emits `locuskit.*` metrics via IntellectusLib when monitoring is enabled.
Off by default (the global enabled gate is `false`); the off-path cost is
one `AtomicBool` load + branch per emit site (~1 ns, negligible).

**Design invariant:** telemetry MUST NOT affect results. All nine emit sites
return byte-identical values whether monitoring is on or off. The emit call is
placed after the operation completes, at the operation boundary; it never
participates in the result computation path.

### Metrics emitted

| Metric name | Value | Tags | Emitted by |
|---|---|---|---|
| `locuskit.drawer.capture_latency_ms` | Wall time for the `addDrawer` round-trip (ms) | `estate=<UUID>` | `addDrawer` / `add_drawer` |
| `locuskit.drawer.capture_count` | 1.0 per successful capture | `estate=<UUID>` | `addDrawer` / `add_drawer` |
| `locuskit.drawer.query_latency_ms` | Wall time for the drawer query (ms) | `estate=<UUID>`, `query=<label>` | `drawersIn(wing:)`, `drawersIn(wing:room:)`, `allDrawers()` |
| `locuskit.drawer.query_result_count` | Drawer rows returned (f64) | `estate=<UUID>`, `query=<label>` | `drawersIn(wing:)`, `drawersIn(wing:room:)`, `allDrawers()` |
| `locuskit.kgfact.add_count` | 1.0 per successful KGFact insert | `estate=<UUID>` | `addKGFact` / `add_kg_fact` |
| `locuskit.kgfact.query_result_count` | KGFact rows returned (f64) | `estate=<UUID>`, `query=<label>` | `kgFacts(forDrawerID:)`, `allKGFacts()` |
| `locuskit.tunnel.add_count` | 1.0 per successful tunnel insert | `estate=<UUID>` | `addTunnel` / `add_tunnel` |

### Tags

- `estate`: UUID string of the estate. Every metric carries this tag so
  per-estate statistics are queryable. Tests filter by estate tag to isolate
  emissions across concurrent test suites.
- `query`: short label identifying the query variant. Present on all query
  metrics. Values: `"wing"` (`drawersIn(wing:)`), `"wing_room"`
  (`drawersIn(wing:room:)`), `"all"` (`allDrawers()`, `allKGFacts()`),
  `"drawer"` (`kgFacts(forDrawerID:)`).

### Off-path cost

When monitoring is disabled (the default):
- Swift: `Intellectus.report(_:)` evaluates its `@autoclosure` argument
  only when `_enabled.load(.relaxed) == true`. One atomic load + branch.
  `Date().timeIntervalSince1970` start-time captures in `addDrawer` and
  `drawersIn` are unconditional (one `Date()` call per operation on the
  disabled path).
- Rust: the `report!` macro expands to `if Intellectus::is_enabled() { … }`.
  One `AtomicBool::load(Acquire)` + branch. `Instant::now()` captures in
  `add_drawer` and `drawers_in_wing` are unconditional.

### Parity

The Swift and Rust ports emit the same seven metric names with the same
tag keys and values. The `ts` field is epoch seconds (f64) in both ports.
Value semantics: latency_ms is wall-clock milliseconds (f64); count metrics
are f64 with integer values.

---

## § 11 — Temporal Read APIs

Two read-only methods on `DrawerStore` that feed substrate algorithm layers.
No schema changes — purely additive reads against existing columns.

### § 11.1 `fingerprintsCaptured(in:)` / `fingerprints_captured_in`

Returns the `Fingerprint256` of every non-tombstoned drawer whose effective
capture time falls within a closed date window, in ascending `id` order.

**Purpose:** feeds the MomentSummary OR-fold (predicate π₁ — capture-time
window membership). The caller OR-reduces the returned fingerprints into a
single summary fingerprint for a temporal segment.

**Two-clock handling:** a drawer's effective capture time is
`eventTime` when present, or `filedAt` when `eventTime` is NULL. The
implementation uses an OR-predicate so both columns are checked:
`(eventTime IS NOT NULL AND eventTime IN [lower, upper])
 OR (eventTime IS NULL AND filedAt IN [lower, upper])`.

**Ordering:** ascending `id` column (TEXT UUID string, lexicographic). Both
legs agree: Swift `ORDER BY id ASC`; Rust uses the same in-memory sort key.

**Swift signature:**
```swift
public func fingerprintsCaptured(in window: ClosedRange<Date>) async throws -> [Fingerprint256]
```

**Rust signature:**
```rust
fn fingerprints_captured_in(&self, start_epoch: i64, end_epoch: i64)
    -> Result<Vec<Fingerprint256>, LocusKitError>
```

### § 11.2 `fingerprintBitSeries` / `fingerprint_bit_series`

Returns one `Bool` per time bucket (oldest bucket first): whether any
non-tombstoned drawer captured in that bucket has the requested fingerprint
bit set.

**Purpose:** feeds the FFT rhythm spectrum. The caller passes the bit-series
array to the FFT to extract a periodicity signal for a given fingerprint
feature.

**Bucket layout** (index `i` ∈ `[0, bucketCount)`):
```
lower_i = endingAt − (bucketCount − i) × bucketSeconds
upper_i = endingAt − (bucketCount − i − 1) × bucketSeconds
```
Interval: `[lower_i, upper_i)` — lower inclusive, upper exclusive — so a
capture exactly on a shared boundary belongs to the later (higher-time)
bucket. The final bucket uses `[lower, endingAt]` (inclusive on both ends).

**Bit layout:** `block0` carries bits 0–63, `block1` 64–127, `block2`
128–191, `block3` 192–255.

**Determinism:** `endingAt` / `ending_at` is always caller-supplied. Neither
leg reads system time inside the method.

**Validation:**
- `bit > 255` → `LocusKitError.invalidContent` / `LocusKitError::InvalidContent`
- `bucketSeconds < 1` → same error
- `bucketCount == 0` → returns `[]` (not an error)

**Swift signature:**
```swift
public func fingerprintBitSeries(
    bit: Int, bucketSeconds: Int, bucketCount: Int, endingAt: Date
) async throws -> [Bool]
```

**Rust signature:**
```rust
fn fingerprint_bit_series(
    &self,
    bit: usize,
    bucket_seconds: i64,
    bucket_count: usize,
    ending_at: i64,
) -> Result<Vec<bool>, LocusKitError>
```

---

## § 12 — Trace-reward write verbs

### § 12.1 `markRecallTracesUsed(target:since:now:)` / `mark_recall_traces_used`

Marks every recall-trace row whose `target` field equals the supplied
drawer-id AND whose `recalledAt` timestamp is within `[since, now]` as
**used** by setting bit 0 of `operationalBitmap` (the `flagUsed` bit) and
updating `updatedAt` to `now`.

**Purpose:** feeds the dreaming daemon's reward sweep. The sweep reads
`recentRecallTraces`, maps `used → 1.0` / `unused → 0.0` per target, and
passes the signal to Bradley-Terry. Without this verb the reward pipeline
sees only 0.0 for every surfaced drawer.

**B-10a alignment:** only the ARIA boundary calls this verb — it is invoked
from the GLK pass-through `markRecallUsed` which is invoked by aria-mcp
only when a dereference verb (withdraw/update/confirm/move) acts on a
drawer-id that appears in the session-scoped surfaced-recall ledger.
Internal callers MUST NOT call `markRecallTracesUsed`.

**v1 scope:** positive-only marking; no negative marking in v1.

**Return value:** the count of rows actually updated (0 if the drawer has
never been surfaced in the given window).

**Determinism:** `now` is always caller-supplied; the method never reads the
system clock.

**Error model:** throws / returns `LocusKitError` on storage failure. A
zero-row update is not an error.

**Swift signature:**
```swift
public func markRecallTracesUsed(target: String, since: Date, now: Date) async throws -> Int
```

**Rust signature:**
```rust
fn mark_recall_traces_used(
    &self,
    target: &str,
    since: i64,
    now: i64,
) -> Result<usize, LocusKitError>
```

**Backend coverage:** `DrawerStoreCore` implements the method (SQL UPDATE
path for the two SQLite-backed stores; in-memory scan for
`InMemoryDrawerStore`). `SqliteDrawerStore` and `PostgresDrawerStore`
delegate to their inner `DrawerStoreCore`.

---

### § 12.2 `countRecallTraces()` / `count_recall_traces`

Returns the total number of rows in the `recall_trace` table for the
estate.

**Purpose:** estate-status reporting. aria-mcp's `moot_estate_status` tool
includes this count so operators can verify trace accumulation is occurring
and retention-prune is working.

**Error model:** throws / returns `LocusKitError` on storage failure.

**Swift signature:**
```swift
public func countRecallTraces() async throws -> Int
```

**Rust signature:**
```rust
fn count_recall_traces(&self) -> Result<usize, LocusKitError>
```

---

## § 13 — Dataset handle behavioral contracts

The MX-TAB-4 dataset-handle feature introduces `contentKind == .dataset` drawers
managed through the dedicated Estate extension in `DatasetHandle.swift` /
`estate_verbs.rs`. Three behavioral contracts govern this surface.

**B-13 (authorized creation seam — FDC-classifier barring):**
`contentKind == .dataset` drawers may only be created through
`Estate.captureDatasetHandle(...)` / `Estate::capture_dataset_handle(...)`. The FDC
classifier (`moot_n_fdc` / `runReclassifyFDC`) is explicitly barred from emitting
`contentKind .dataset`; dataset handles are skipped during every reclassification
sweep. The ordinary `capture(_:CaptureFrame)` verb does not set `contentKind` to
`.dataset` — `CaptureFrame` has no `contentKind` parameter (it predates the dataset
kind). This seam assembles the correct operational bitmap (`ContentKind.dataset` raw 7
in bits 6–11), structures the `DatasetHandleContent` JSON payload, and stamps the
sentinel `embeddingModelID = "dataset-handle"` (satisfying the non-empty invariant
I-4 while signalling to the VectorKit encode pipeline that no embedding should be
generated). Any path other than `captureDatasetHandle` that produces a `.dataset`-kind
drawer is a conformance defect.

**B-14 (sensitivity floor — operator convention, v1):** rows appended to the backing
dataset table are expected to carry sensitivity at or below the handle drawer's
`sensitivity` tier (`AdjectiveSensitivity`). This is an operator convention in v1 —
no per-row enforcement exists in the LocusKit or PersistenceKit layer at this revision.
MX-TAB-5 will add column-level row-sensitivity gating. The handle itself participates
in the normal recall pipeline under its adjective bitmap sensitivity field; individual
dataset rows stored in the PersistenceKit `DatasetStore` are not recallable through the
drawer recall pipeline and are not subject to bitmap-sensitivity filtering.

**B-15 (handle lifecycle — withdrawal vs. erase, and the expunge cascade):**
`Estate.resolveActiveDatasetHandle` / `Estate::resolve_active_dataset_handle` returns
the cluster-A (currently-believed: `active`/`pending`/`contested`/`accepted`) non-tombstoned
handle for a given `datasetId`. Withdrawal of a handle is a belief-state change only: the
backing dataset table is NOT dropped by `withdraw` or by a state-axis `mutate`. A full
erase — dropping both the handle drawer and the backing dataset table — requires routing
through GLK `VerbSurface.expunge`, which implements the erase cascade in two steps:

1. Reads the handle's `DatasetHandleContent` JSON BEFORE the storage expunge zeroes the
   blob (via `drawerById`) to extract the `datasetId`, then calls
   `DatasetStore.dropDataset(id:)` to drop the backing table.
2. After the storage expunge commits, appends a supplementary audit event recording the
   table-drop (via `appendAuditEvent` / `append_audit_event`), carrying verb
   `"datasetTableDrop"` and the `datasetId` as reason context.

`drawerById` and `appendAuditEvent` are `public extension Estate` methods consumed
exclusively by GLK in this cascade path; they are not intended for general direct use.
Direct callers that need only belief-state withdrawal use `Estate.withdraw` / the
normal verb surface.

## § 14 — Subject representation behavioral contracts

The subject is a one-sentence, AI-facing summary of a drawer's content —
the assertion field of the progressive-recall dense row (UUID · subject ·
FDC code · WikiQID · event_time). Schema v12 stores it as three nullable
`drawers` columns (`subject`, `subject_pipeline_version`, `subject_at`)
that are written and cleared together, mirroring the distilled quad's
NULL-together lifecycle.

- **B-17 (returned, never searched):** the subject is presentation data.
  No index, no generated column, no bitmap bit, no recall filter, and no
  container-fingerprint rollup may reference it. It exists so a consuming
  AI can decide which rows are worth pursuing — it is never an input to
  ranking or matching math.
- **B-18 (length contract):** `setSubjectRepresentation` /
  `set_subject_representation` reject an empty subject or one longer than
  120 characters (`DrawerStore.subjectLengthContract` ↔
  `SUBJECT_LENGTH_CONTRACT`; both ports count characters, not bytes). The
  cap keeps the dense row's per-row cost near-uniform.
- **B-19 (atomic set):** the trio is populated by ONE UPDATE statement.
  `subject_pipeline_version` records producer provenance (e.g. `ai-v1`,
  `minillm-v1`) and is the regeneration lever; `subject_at` is the
  generation instant, passed in as a parameter (I-6 determinism — never
  read from a clock inside the store).
- **B-20 (content-write invalidation):** every write that changes or
  erases `content` NULLs the trio in the same statement it NULLs the
  distilled quad — a subject must never describe content that no longer
  exists. Erasure paths (`expungeGated`) scrub it; dataset-content
  updates clear it for regeneration.
- **B-21 (NULL is the debt marker):** NULL `subject` on a live,
  non-empty-content drawer means "subject debt" — eligible for backfill.
  `countMissingSubject(pipelineVersion:)` / `count_missing_subject`
  report the debt as NULL-subject rows plus rows whose
  `subject_pipeline_version` differs from the requested producer. There
  is no presence bit: the operational feature-flag region (bits 12–23)
  is fully assigned, and the NULL predicate is already exact.

*End of LocusKit Specification.*

## Changelog

### 1.12.0 -- 2026-08-02

Subject pipeline harness (progressive recall PR-09). § 14 additions:
B-22 (presence debt vs regeneration debt: `countSubjectDebt` is the
NULL-only lane observable; `countMissingSubject(pipelineVersion:)`
remains the producer-contract regeneration count), B-23 (the sweep
enumerator `subjectDebtBatch(limit:)` is deterministic — filedAt ASC,
id ASC — and settled-work skip is structural), B-24 (the AI-facing
register is ONE shared testable gate, `SubjectRegister`: 1–120 chars,
single-line, trimmed, narrative-frame prefix lint; conformance pins
verdicts on both legs and NEVER model output text). Provenance tiers
documented at the pipeline-version constants (ai-v1, minillm-v1,
consolidation-v1, seed-v1).

### 1.11.0 -- 2026-08-02

Added § 14 — Subject representation behavioral contracts (progressive
recall PR-01). Five new clauses: B-17 (subject is returned, never
searched/indexed/mathed), B-18 (120-character length contract, both
ports counting characters), B-19 (atomic trio set with pipeline-version
provenance), B-20 (content-write invalidation — the trio NULLs with the
distilled quad), B-21 (NULL subject = backfill debt; no presence bit —
`countMissingSubject` counts NULL + producer-version mismatch). Schema
v12 adds the three nullable `drawers` columns with a v11 → v12
addColumn migration.

### 1.10.0 -- 2026-07-20

- Defined LocusKit as the canonical Drawer content and identity owner in GLK.
- Added the dependency-inversion rule: GLK adapts LocusKit to CorpusKit's
  content-source protocol; neither kit imports the other.
- Added conformance coverage proving Drawer identity preservation and absence
  of duplicated Corpus content.

### 1.9.0 -- 2026-07-16
Added § 13 — Dataset handle behavioral contracts. Three new behavioral clauses:

- **B-13 (authorized creation seam — FDC-classifier barring):** `contentKind == .dataset`
  drawers may only be created through `Estate.captureDatasetHandle`. The FDC classifier
  is barred from emitting this content kind; dataset handles are skipped during
  reclassification. The ordinary `capture(_:CaptureFrame)` verb is not a valid path for
  dataset drawers.
- **B-14 (sensitivity floor, v1):** rows in the backing dataset table are expected at or
  below the handle's sensitivity tier. Operator convention only — no per-row enforcement
  yet; MX-TAB-5 will add column-level gating.
- **B-15 (handle lifecycle — withdrawal vs. erase cascade):** withdrawal is belief-state
  only (backing table not dropped). Full erase routes through GLK VerbSurface.expunge,
  which reads `DatasetHandleContent` via `drawerById` BEFORE zeroing the blob, drops the
  backing table, then appends a supplementary `"datasetTableDrop"` audit event via
  `appendAuditEvent`. Contracts `drawerById` and `appendAuditEvent` as GLK-exclusive
  cascade methods.

### 1.8.0 -- 2026-07-16
- **B-9 corrected**: XOR-backward-fold description replaced with the shipped
  implementation — `AuditLogFold.projectStateAt` (SubstrateML, forward-fold
  in HLC order from genesis). `bitmapState` parameter label is `asOf:` (not
  `at:`), type is `HLC` (not `Date`). Wall-clock is not the ordering axis.
- **C-4 corrected**: "XOR-fold (B-9)" updated to "HLC-keyed forward-fold via
  `AuditLogFold.projectStateAt` (B-9)".
- **B-12 corrected**: removed `userConfirmed` from the B-4 default-insertions
  list; B-4 explicitly states no confirmation default is inserted.

### 1.7.0 -- 2026-06-25
Documented the `Estate` consumer metadata surface (`meta`/`setMeta`): the public,
durable, lowest-level key-value primitive over the manifest table that upper
layers (e.g. NeuronKit's dreaming/maintenance daemons) persist their own state
through, rather than reaching around the substrate to a host-owned store
(Interface Rules; resolves the "future verb surface" the manifest accessor
anticipated). See the daemon-state persistence contract and `LOCUSKIT_INTERFACE.md` 1.11.0. Additive, both ports.

### 1.6.0 -- 2026-06-22
GLK_BATCH1: Added `B-1a (batch capture — single transaction)` behavioral clause.
`Estate.captureBatch(_:)` writes all fresh-lineage drawers in a single
`storage.transaction(isolation: .serializable)` via `DrawerStore.insertFreshBatch`,
avoiding the nested-transaction conflict (`StorageError.transactionConflict`) that
arises when per-row `capture()` is called inside a `rowStore.beginTransaction()`
block on a SQLite backend. Frames with an active predecessor fall back to per-item
`addDrawerCovered`. Post-insert coverage and Merkle root rollup match the
single-item `capture` path.

### 1.5.0 -- 2026-06-17
Expanded contract B-1: `capture` now assembles the provenance bitmap (cookbook
§2.5) alongside the operational and adjective bitmaps, writing `confirmation`
(bits 18–23) and `confidence` (bits 24–29) from the two new `CaptureFrame` slots
in addition to the already-written `sourceType`, `provenanceChannel`, and
`provenanceSensitivity`. All five provenance slots default to raw 0, so an
existing caller produces byte-identical zero-provenance drawers; a daemon
capturing already-confirmed content with a known confidence band records both at
birth instead of relying on a later `confirm` mutation or enrichment pass.
Additive and behaviour-preserving; round-trip + default-byte-identity
conformance-gated in both ports (`EstateVerbTests.swift` ↔ `estate_verbs.rs`).
No invariant or recall-default change. (Separately: corrected stale
`BitmapEvaluator.evaluate` doc comments in both ports that claimed recall hands
in `allDrawers()` and that fingerprint pruning § 7.9.4 step 1 was deferred —
container OR-fingerprint pruning has shipped in the recall path and the
evaluator already receives the pruned candidate set; comment-only.)

### 1.4.0 -- 2026-06-17
Added contract B-7a: the per-drawer fingerprint's lattice-block `qidClosureHash`
facet is now live (mission #7b), hashing `FNV.hash16` of the sorted-numeric,
`"|"`-joined transitive P31/P279 ancestor closure of the drawer's `wikidataQID`
(`LatticeLib.QIDClosure`, a pinned offline Wikidata snapshot — runtime never
re-queries). No-QID / no-ancestor rows keep the deterministic null 0, so only
drawers whose QID carries ancestors change fingerprint. Both ports compute it
identically; cross-port conformance preserved. No schema change; no new
invariant — the facet was previously null-by-deferral and is now populated.

### 1.3.0 -- 2026-06-17
Documented that the `propose` verb now stamps genuine proposal provenance. `Estate.propose(_:now:)` wires the three previously hard-zeroed operational axes — `ProposalConfirmationSource` (bits 12–17), `ProposalGeneratedByClass` (bits 18–23), and `ProposalConfidenceBucket` (bits 24–29) — from the new `ProposeFrame.confirmation` / `.generatedBy` / `.confidence` slots into the proposal operational bitmap, alongside the existing kind (0–5) and target-object-type (6–11) axes (cookbook §2.4). The bit windows match the read accessors exactly; the three frame defaults (`.human` / `.dreamingDaemon` / `.null`, all raw 0) reproduce the pre-wiring bitmap byte-for-byte. Additive and behaviour-preserving; round-trip + default-byte-identity conformance-gated in both ports. Added the "propose stamps genuine provenance" contract bullet to § 9.

### 1.2.0 -- 2026-06-17
Documented `KGFact` full adjective-axis parity with `Drawer`: `KGFact` now exposes `state`, `adjectiveSensitivity` (`adjective_sensitivity` in Rust), `exportability`, and `trust` accessors over the shared four-axis adjective bitmap (cookbook §2.3 / §5.5), each with the Drawer-matching fail-closed fallback. Added the "KG-fact adjective axes — full Drawer parity" contract paragraph and its shared-bitmap conformance requirement. Additive accessor surface; no schema change, no new invariant.

### 1.1.1 -- 2026-06-17
Clarified the store-backend posture: `all_drawers` and `room_level_fingerprints` are now compile-required `DrawerStore` reads (no trait default) on the Rust leg, matching the Swift surface; the rest of the read surface retains the fail-loud `DatabaseUnavailable` default. Updated the newtype-forwarding-contract paragraph accordingly. No behaviour change; no new invariant.

### 1.1.0 -- 2026-06-17
Added invariant I-12 (the `ext` forward-compat slot, the forward-compatible ext-slot contract): every persistent entity table carries one nullable `.json` `ext` column, inert in 1.0; `keys` gained it at schema v2. Pre-ship pre-provisioning during the 1.0.0 free-migration window.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
