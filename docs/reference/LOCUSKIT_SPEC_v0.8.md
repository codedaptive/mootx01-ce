---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: LocusKit
kind: Kit
relates_to:
  - LOCUSKIT_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md  (§ estate model, bitmap layouts, recall pipeline, audit reconstruction)
  - PERSISTENCEKIT_SPEC_v0.8.md  (the storage protocol LocusKit binds to)
  - SUBSTRATELIB_SPEC_v0.8.md  (fingerprint math used by container pruning)
  - ARIALEXICONLIB_SPEC_v0.8.md  (the verb vocabulary the estate surface serves)
purpose: |
  LocusKit is the structured-memory and knowledge-graph tier for one
  estate. It owns the four nouns the substrate stores — Drawer (the
  atomic, content-immutable memory unit), KGFact, DiaryEntry, and
  Tunnel — together with the Estate actor that opens storage, validates
  the manifest, and applies the nine ARIA verbs (capture, recall,
  mutate, withdraw, expunge, reanchor, propose, associate, learn). It
  encodes all boolean and categorical row state in Int64 bitmaps (no
  Bool stored properties), keeps an append-only bitmap-audit trail with
  XOR-fold historical reconstruction, and prunes recall with
  per-container OR fingerprints. It depends on PersistenceKit for
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
- The append-only `bitmap_audit` trail and XOR-fold historical
  reconstruction (`auditTrail`, `bitmapState`).
- The `Manifest`/`ManifestValues` key-value contract and the
  `LocusKitSchema` registration handed to PersistenceKit.
- The Swift ⇄ Rust conformance obligation and the documented port gap.

This specification does NOT define:

- API signatures — those live in `LOCUSKIT_INTERFACE_v0.8.md`.
- Storage mechanics, the SQLite dialect, or the `Storage` protocol —
  see `PERSISTENCEKIT_SPEC_v0.8.md`.
- Fingerprint / Hamming / SimHash math — see `SUBSTRATELIB_SPEC_v0.8.md`.
- The FDC classifier itself — see `FDC_ENCODER_CANONICAL_v1.0.md`. LocusKit
  stores a lattice anchor per drawer; it does not own the classification.
- Multi-estate coordination, grants, federation, the Brain layer, or
  vector recall — see `GENIUSLOCUSKIT_SPEC_v0.8.md` and
  `VECTORKIT_SPEC_v0.8.md`.
- The ARIA grammar the verbs realise — see `ARIALEXICONLIB_SPEC_v0.8.md`.

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
                    └── ARIA_MCP (estate exposed over MCP)
```

**Depends on:** `PersistenceKit` (the `Storage` protocol and
`SchemaDeclaration`), `SubstrateLib` (`Fingerprint256`, `HyperplaneFamily`,
`CountVector256` for container pruning and bundle materialisation). Metal is
not used here.

**Consumed by:** `GeniusLocusKit` (the heaviest consumer — owns estate
handles and verb fan-out), `NeuronKit` (recall, diary, tunnels, recall
traces), and `ARIA_MCP` (lifecycle + capture/recall over the wire).

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

**I-11 (cross-port parity):** the Swift and Rust version are conformance-gated against shared behaviour. Where the ports differ in shape (async vs sync, SQLite vs in-memory store), the *value-level results* of capture, recall filtering, bitmap encode/decode, and XOR-fold reconstruction must agree. Neither version leads. See § 8 for the documented surface gap.

## § 5 — Behavioral contracts

**B-1 (capture validation, then write):** `capture` validates that
`content`, `room`, `latticeAnchor.udcCode`, `addedBy`, and
`embeddingModelID` are non-empty (throwing `LocusKitError.invalidContent`
naming the violated rule) before any storage call, assembles the operational
and adjective bitmaps from the frame's named slots, writes the drawer, and
OR-folds its bitmaps into the per-container fingerprint aggregate.

**B-2 (supersession cascade):** when `CaptureFrame.lineageID` matches an
active predecessor, capture fires the cascade atomically inside one
`BEGIN IMMEDIATE` transaction — the predecessor flips to `.superseded`, a
bitmap-audit row is written, and a `supersedes` tunnel is created. When
`lineageID` is nil, a fresh UUID is stamped so each drawer is its own lineage
(architecture spec § 5.10).

**B-3 (recall is non-throwing; the stream is the failure boundary):**
`recall` returns a `RecallStream`. Substrate faults collapse to an empty result
set rather than an error: an empty single-page sequence with `isLast == true`
is the uniform signal that no rows matched. Callers needing to distinguish
empty-corpus from fault go through the store directly.

**B-4 (filter chain is conjunction):** a `RecallFrame.filterChain` is `[Filter]`
interpreted as implicit AND (equivalent to `Filter.all(chain)`). When the
chain carries no state filter the evaluator prepends `currentlyBelieve`; no
trust filter prepends `trustworthy`; no provenance filter prepends
`userConfirmed`. "No filter" therefore defaults to currently-believed,
action-trustworthy, user-confirmed content.

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

**B-8 (withdraw preserves upper axes):** `withdraw` clears the state field
(bits 0–3 of the adjective bitmap) and OR-s in `State.withdrawn`, leaving
sensitivity / exportability / trust untouched, and writes the mutation plus
its audit row atomically.

**B-9 (XOR-fold reconstruction):** `bitmapState(rowID:at:)` reconstructs a
row's three bitmaps as of a past timestamp by XOR-folding each post-`at`
audit delta `(prior XOR new)` back into the live value (architecture spec
§ 6.8). XOR is associative and commutative, so any ordering yields the same
result. A timestamp preceding the drawer's `filedAt` collapses onto
`drawerNotFound`.

**B-10 (recall trace hook):** each row a recall returns gets one
`RecallTraceItem` (`used == false`); the later two-source reward path sets
`used = true` for rows the caller acted on, feeding Bradley-Terry weighting
in NeuronKit. Trace-write failures are silenced so a storage fault cannot
break the caller's result.

## § 6 — Error model (conceptual)

| Category | Trigger | Recovery posture |
|---|---|---|
| `LocusKitError.databaseUnavailable` / `.sqliteError` | the backing store cannot open, or a SQLite call returns non-OK | surface; carries the verbatim `sqlite3_errmsg` for logging |
| `LocusKitError.invalidContent` | a capture/verb slot violates a non-empty or content rule | surface; the message names the violated rule and is part of the contract |
| `LocusKitError.drawerNotFound` / `.tunnelNotFound` / `.diaryEntryNotFound` / `.recallTraceItemNotFound` | a verb references an id that is absent | routine query miss; the caller decides whether it is an error |
| `LocusKitError.disciplineViolation` | an illegal state transition, a forbidden bitmap combination, or an expunge without confirmation | surface; names the rule (carries `from`/`to` State raw values) |
| `LocusKitError.schemaTooNew` | on-disk schema version newer than this build | surface; reserved for the migration workflow, not thrown at this revision |
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
documented default-filter insertion (B-4); pruning never drops a surviving
container (B-7); the paged stream honours the page/`isLast`/hydration
contract (B-5, B-6).

**C-4 (audit append-only + reconstruction):** every state mutation writes
its audit row in the mutation's transaction (I-8); `bitmapState` reconstructs
past state by XOR-fold (B-9); UPDATE/DELETE on `bitmap_audit` is rejected by
trigger.

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

## § 8 — Out of scope

- The `Storage` protocol, SQLite dialect, triggers as a mechanism →
  `PERSISTENCEKIT_SPEC_v0.8.md`.
- Fingerprint / Hamming / SimHash / count-fold math →
  `SUBSTRATELIB_SPEC_v0.8.md`.
- The FDC classification encoder → `FDC_ENCODER_CANONICAL_v1.0.md`.
- Vector embeddings and ANN recall (`Ordering.byRelevanceDesc`) →
  `VECTORKIT_SPEC_v0.8.md`. Vector-tier filtering and relevance ordering
  are provided when VectorKit composes in.
- N-estate coordination, grants, cross-estate recall, branches, the Brain
  layer → `GENIUSLOCUSKIT_SPEC_v0.8.md`.
- Hybrid recall, dreaming, maintenance, reward sweeps → NeuronKit.
- The ARIA grammar the verbs realise → `ARIALEXICONLIB_SPEC_v0.8.md`.

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
    (→ accepted; guard: trust ≥ canonical per S-1 cookbook §9.5.1),
    `supersede` (→ superseded), `revive` (Cluster B → active; guard: only
    from Cluster B; automaton supports decayed → observe → active per §9.2;
    withdrawn/expired require a follow-up automaton extension).
  - **Adjective axis** — `correctSensitivity(AdjectiveSensitivity)`: rewrites
    bits 6–11; `correctTrust(Trust)`: rewrites bits 18–23.
  - All cases route through `DrawerStore.mutateState` or
    `DrawerStore.mutateAdjective`, which validate via `AuditGate.admit` and
    append one sealed `AuditEvent` atomically.
- `learn` is legal only on `LearnedReference`: it records a learned reference
  drawer through the LRF noun substrate.
- `propose` / `associate` are realised through the `Proposal` and
  `Association` noun stores and the tunnel/KG-fact paths, not as dedicated
  `Estate` verb methods.
- A verb applied to a noun outside its accepted set is rejected by the
  acceptance check before any storage call.

---

*End of LocusKit Specification v0.8.*
