---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: GeniusLocusKit
kind: Kit
relates_to:
  - GENIUSLOCUSKIT_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md  (§ 7.8 verb surface, § 11 standing signals, § 12 matrix tier, § 15 kit composition; invariants I-13, I-15)
  - LOCUSKIT_SPEC_v0.8.md  (the single-estate tier GLK composes)
  - VECTORKIT_SPEC_v0.8.md  (the vector tier composed per estate)
  - CORPUSKIT_SPEC_v0.8.md  (the RAG-bundle tier composed per estate)
  - QUEUEKIT_SPEC_v0.8.md  (the serial-lane dispatch substrate the scheduler owns)
  - ARIALEXICONLIB_SPEC_v0.8.md  (the verb/noun/adjective vocabulary the surface conforms to)
  - ARIA_MCP_SPEC_v0.8.md  (the access surface that mediates cross-device federation, I-13)
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
  VectorKit, CorpusKit, PersistenceKit, QueueKit, and AriaLexiconLib; it
  never reaches around them. The companion INTERFACE document carries
  the signatures.
---

# GeniusLocusKit Specification

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
CognitionKit) or an access surface (ARIA_MCP) needs from the substrate
flows through the `GeniusLocusKit` actor: the verb surface, the
lattice-scoped read fan-out, the grant-gated federated read, the unified
audit log, COW branching, and the migration API. The composed kits —
LocusKit, VectorKit, CorpusKit — are reached only through this layer's
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

- The multi-estate lifecycle: `open(storage:owner:)`, `close(_:)`,
  `estate(for:)`, `handles`, `openEstateCount`, and the duplicate-UUID
  refusal.
- The unified nine-verb surface and which verbs dispatch to a live
  LocusKit body vs. raise `VerbError.notSupportedByEstate` at this
  revision.
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

This specification does NOT define:

- API signatures — those live in `GENIUSLOCUSKIT_INTERFACE_v0.8.md`.
- Single-estate nouns, bitmaps, the recall pipeline, container pruning,
  or the per-kit bitmap-audit trail — see `LOCUSKIT_SPEC_v0.8.md`.
- Embeddings and ANN search — see `VECTORKIT_SPEC_v0.8.md`.
- RAG bundle composition — see `CORPUSKIT_SPEC_v0.8.md`.
- The job-queue mechanics the scheduler dispatches over — see
  `QUEUEKIT_SPEC_v0.8.md`.
- Cross-device federation, the MCP wire protocol, and answer-assembly
  scope filtering — see `ARIA_MCP_SPEC_v0.8.md`. GLK enforces the binary
  read gate locally; the wire boundary is the access surface's job
  (I-13).
- The hybrid-recall, dreaming, Bradley-Terry, and reward algorithms a
  standing signal's `emit` closure may call — those live in NeuronKit.
  GLK provides the scheduler and the emission contract, not the
  algorithms.
- The ARIA grammar the verbs realise — see `ARIALEXICONLIB_SPEC_v0.8.md`.

## § 3 — Position in the kit family

```
  AriaLexiconLib  LocusKit  VectorKit  CorpusKit  PersistenceKit  QueueKit
         \           \         |          /            /            /
          \           \        |         /            /            /
           +-----------+-------+--------+------------+------------+
                                  |
                            GeniusLocusKit       ← N estates, Brain layer,
                                  ▲                 grants, branches, migration
                                  │ composed by
                                  ├── NeuronKit    (recall/dreaming algorithms;
                                  │                 signal emit closures)
                                  └── ARIA_MCP     (estate exposed over MCP;
                                                    cross-device federation)
```

**Depends on:** `AriaLexiconLib` (the verb/noun/adjective vocabulary and
acceptance matrix), `LocusKit` (the single-estate tier and its nouns,
frames, recall stream, manifest, schema), `VectorKit` and `CorpusKit`
(the per-estate vector and RAG tiers it composes), `PersistenceKit`
(`Storage`, schema declaration, and the in-memory backend the scheduler
mounts its queue on), and `QueueKit` (the serial-lane dispatch substrate
the scheduler owns one of per estate). Metal is not used here.

**Consumed by:** `NeuronKit` (the heaviest consumer — owns the
`GeniusLocusKit` actor, drives verbs, reads the unified audit log,
authors signal `emit` closures, derives branches) and `ARIA_MCP` (drives
verbs and the grant-gated federated read over the wire).

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
architecture):** the composed kits (LocusKit, VectorKit, CorpusKit) are
reached only through GLK's estate verb surface. NeuronKit and
CognitionKit never import LocusKit, VectorKit, or CorpusKit directly; all
substrate access is a verb applied to an `EstateHandle`. This is the
structural form of the architecture's layering rule and is the reason
the verb surface, not the composed kits, is GLK's consumed contract.

**I-4 (queue authority):** GLK holds exactly one QueueKit instance per
estate, inside that estate's `StandingSignalScheduler`, mounted on a
dedicated in-memory backend. NeuronKit and CognitionKit never import
QueueKit. The scheduler is the only owner of the dispatch lane; signal
work reaches the substrate only by being enqueued and drained on that
lane.

**I-5 (single serial lane per estate):** each estate's scheduler drains
its queue through a single drainer at `.serializable` isolation
(DECISION_STANDING_SIGNAL_SCHEDULER_2026-05-21). Exactly one job is
claimed at a time, FIFO; two signals' emissions against one estate never
interleave at job grain. There is no per-signal queue and no
cross-estate lane.

**I-6 (federation is mediated at the access surface — I-13):** the
substrate does not communicate with other substrates. GLK's
"federated read" is strictly device-local: both the source and the
requester are estates already open in the same kit instance. GLK opens
no socket, performs no handshake, and exposes no `federateWith(remote:)`
API; crossing the device boundary is ARIA_MCP's concern. What GLK
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
identical IDs and dedupe on merge.

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

**I-15 (cross-port parity):** the Swift and Rust ports are
conformance-gated against shared test vectors for the surfaces both
implement — the verb vocabulary, the audit log/projection/recovery, the
scheduler emission ordering, the matrix tier, and the training daemon.
Neither port leads; value-level results must agree. Where the ports
differ in shape (async actor vs. synchronous struct) or in coverage (the
grant, federation, branch, and migration surfaces are Swift-only at this
revision), § 8 documents the gap.

## § 5 — Behavioral contracts

**B-1 (open composes then registers):** `open(storage:owner:)` opens a
`LocusKit.Estate` over the supplied storage, reads its manifest, derives
the `EstateHandle` (validating the UUID and the zoom window), refuses a
duplicate UUID, then registers the estate, retains its storage for the
grant surface, and mints an empty `UnifiedAuditLog`. `close(_:)` flushes
the estate, drops the registry entry, the audit log, and the grant
surface; a refusing flush still drops the entry so a dead handle never
lingers.

**B-2 (verb dispatch and error normalisation):** each verb resolves the
handle through `estate(for:)` first (so a stale handle uniformly raises
`estateNotOpen` regardless of substrate state), then dispatches to the
LocusKit body. `capture`, `recall`, and `withdraw` reach live LocusKit
bodies. `mutate`, `expunge`, `reanchor`, and `learn` dispatch to LocusKit
stubs that throw, which the GLK boundary normalises to
`VerbError.notSupportedByEstate(verb:)`. `propose` and `associate` are
substrate-driven (Brain-layer) and have no LocusKit body; GLK validates
the handle and raises `notSupportedByEstate` directly. `expunge` with
`confirmation == false` and `reanchor` with neither target raise
`VerbError.expungeNotConfirmed` / `.emptyReanchor` at the boundary before
dispatch. Any other LocusKit error becomes
`VerbError.underlyingEstateFailure`; a `GeniusLocusKitError` passes
through unchanged.

**B-3 (recall drains to an array):** the GLK `recall` verb drains
LocusKit's `RecallStream` fully and returns a materialized `[Drawer]`,
matching the shape of `fanOutRecall` and `federatedRecall` so the three
recall surfaces compose predictably. Callers needing page-at-a-time
access reach the underlying estate through `estate(for:)`.

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
without a verb call. Because the `propose`/`associate` verbs raise
`notSupportedByEstate` until the Brain-layer bodies ship, a routed
emission records `routedButVerbStubbed` rather than `routed`, making the
pending state visible in `signalStatus`.

**B-7 (federated read is fail-closed, grantee-scoped):** `federatedRecall`
resolves both handles (stale either side → `estateNotOpen`), consults the
**source** estate's grant store, keeps active grants naming the requester
as grantee (none → `crossEstateReadRefused(.noActiveGrant)`), requires at
least one unexpired at `now` (all expired → `.grantExpired`), and only
then reads the source estate and returns its drawers plus the authorizing
grant. A revoked grant is already dropped from `active()`, so a read after
revocation lands on `.noActiveGrant`. Scope-level row narrowing is not
applied here — `grant.scope` rides back as advisory metadata (the access
surface narrows).

**B-8 (grant issue/revoke is signed, persisted, audited, custody-gated):**
`issueGrant` gates the custody mode first (modes 3/4 require confirmed IP
clearance; mode 4 then raises `hardwareNotSupported`), loads the estate's
Ed25519 identity, builds and signs the grant over a canonical
pipe-delimited payload, persists it to the estate's `grants` table,
derives the scope key per custody mode (mode 1 retains in the vault and
returns nil; modes 2 and 3 return the key and retain nothing), and
appends a `grantIssued` audit entry. `revokeGrant` writes the revocation
record, drops any mode-1 vault key (cryptographic clawback), and appends
a `grantRevoked` entry. Both append HLC-stamped entries that sort cleanly
and cannot break the chain.

**B-9 (audit feed, projection, recovery):** `feedAuditLog(for:)` pulls the
estate's LocusKit-tier audit rows, bridges them to `UnifiedAuditEntry`
values, and merges them into the estate's G-Set (idempotent by content
hash, I-11). `AuditProjectionFold.project` folds the HLC-ordered log into
per-row state; the asOf variant folds only entries at or before a cutoff
HLC. `AuditRecovery.rebuild` replays the log into a `UnifiedProjection`
and `verify` compares a rebuilt projection against an expected one
field-by-field. All are order-independent given HLC (I-12).

**B-10 (chain verification):** `verifyAuditChain(_:)` feeds the log, then
runs `AuditChainVerifier.verify`, returning an `AuditChainReport` per the
NeuronKit § 3.5 contract: `valid == true` and `firstBrokenAt == nil` on a
clean chain (including an empty one); on the first entry whose stored ID
does not match its recomputed content hash or whose HLC reverses,
`valid == false` with `firstBrokenAt` set to that entry's timestamp.

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

**B-14 (migration is zero-loss):** `importFromMemPalace` opens a fresh
estate and captures every corpus entry with non-empty content as a
drawer; entries with empty content are recorded in
`MigrationReport.unmappedConcepts`, never silently dropped, so the mapped
and unmapped counts sum to the corpus size. `verifyMigration` issues one
content-match recall per entry and returns `.identical` only when every
entry is recallable, else `.diverged` with the missing entries.
`runParallel` returns a `ParallelRunHandle` that routes captures per
`ParallelCaptureMode` until `stop()`.

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
| `VerbError.notSupportedByEstate` | a verb whose substrate body has not shipped (`mutate`/`expunge`/`reanchor`/`learn`/`propose`/`associate`) was invoked | surface; the verb is in the vocabulary but unimplemented at this revision |
| `VerbError.underlyingEstateFailure` | a live verb dispatch failed in LocusKit | surface; normalised so LocusKit's taxonomy does not cross the boundary |
| `VerbError.rejectedByLexicon` | a `(verb, noun)` pair the § 7.2 acceptance matrix rejects | surface; same shape whether the rejection is lexical or substrate |
| `VerbError.emptyReanchor` / `.expungeNotConfirmed` | a frame fails a boundary precondition before dispatch | surface; a deliberate two-step / non-no-op protocol guard |
| `GrantError` | a gated custody mode, a missing identity key, an expired/revoked/decayed grant, or an absent grant id | surface; modes 3/4 are gated, mode-3 decay past threshold is unrecoverable (no partial recovery) |
| `MigrationError` | an unreadable corpus, a capture on a stopped parallel run, or a closed target estate | surface; a migration-surface fault isolated from the estate error space |
| `MatrixPersistenceError` | a matrix snapshot could not be loaded or saved | surface; the snapshot is corrupt or the backend is unavailable |

All categories are programmer/protocol or substrate-fault conditions, not
silent fallbacks. `GeniusLocusKitError` is the coordinator/lifecycle
surface; `VerbError` is the verb-dispatch surface; `GrantError`,
`MigrationError`, and `MatrixPersistenceError` are the additive
sub-surfaces (declared standalone because Swift cannot add enum cases by
extension).

## § 7 — Conformance requirements

**C-1 (lifecycle + isolation):** `open`/`close`/`estate(for:)` admit,
remove, and resolve estates by handle; a duplicate UUID is refused
(`duplicateEstate`); a stale handle resolves to `estateNotOpen`; no
operation crosses an estate boundary except `federatedRecall` (I-1, I-2,
B-1).

**C-2 (verb surface + lexicon conformance):** the nine verbs dispatch per
B-2, normalising stub and boundary errors to the documented `VerbError`
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
persists, and audits; `revokeGrant` clamps mode-1 keys and audits; modes
3/4 are gated before any key work; mode-3 decay past threshold raises
`keyDecayed` (B-7, B-8).

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

**C-12 (cross-port, I-15):** the Swift and Rust ports produce identical
value-level results for C-2 (verb vocabulary), C-4 (scheduler ordering),
C-5 (audit/projection/recovery), C-6 (matrix), and C-7 (training) against
the shared `glref` vectors. The grant, federation, branch, and migration
surfaces are Swift-only at this revision (§ 8) and are out of the
cross-port gate until the Rust port adds them.

## § 8 — Out of scope

- Single-estate nouns, bitmaps, recall pipeline, per-kit audit trail →
  `LOCUSKIT_SPEC_v0.8.md`.
- Embeddings and ANN search → `VECTORKIT_SPEC_v0.8.md`.
- RAG bundle composition → `CORPUSKIT_SPEC_v0.8.md`.
- Job-queue claim/lease/drain mechanics → `QUEUEKIT_SPEC_v0.8.md`.
- Fingerprint / Hamming / HLC / audit-CRDT math primitives →
  `SUBSTRATELIB_SPEC_v0.8.md`. (`UnifiedHLC`, `UnifiedAuditLog`, and the
  in-module SHA-256 are local mirrors held inside GLK because its
  Package.swift does not pull SubstrateLib directly; the byte shapes match
  the SubstrateLib reference so the conformance relationship is preserved.)
- The ARIA grammar and acceptance matrix → `ARIALEXICONLIB_SPEC_v0.8.md`.
- Cross-device federation, the MCP wire protocol, and per-scope
  answer-assembly row filtering → `ARIA_MCP_SPEC_v0.8.md` (I-6/I-13).
- Hybrid recall, dreaming, Bradley-Terry, reward sweeps, and the signal
  `emit` algorithms → `NEURONKIT_SPEC_v0.8.md`. GLK provides the scheduler
  and emission contract; NeuronKit provides the cognition inside the
  closures.

**Documented port gap (I-15).** The two ports realise the shared contract
with different host shapes, and the difference is intentional:

- **Concurrency.** The Swift surface is the `GeniusLocusKit` actor with
  `async` methods; the Rust port is synchronous — `EstateCoordinator` is a
  plain struct, the verb surface is a stateless `Surface` struct returning
  `Result<…, VerbError>`, and the scheduler is `SerialLaneScheduler`.
- **Time.** Swift threads `now: Date` from the verb/tick boundary; the
  Rust engines take an explicit clock parameter, pushing the read entirely
  to the caller — a stricter realisation of the same determinism rule.
- **Surface coverage.** The Rust port covers the verb vocabulary, the
  audit log/projection/recovery, the scheduler and the six default signal
  specs, the matrix tier, and the training daemon. It does **not** yet
  implement the grant model, the scope-key vault / Lagrange-decay key, the
  grant-gated federated read, COW branching, or the MemPalace migration
  API — those are Swift-only at this revision and are tracked as the Rust
  port's outstanding surface.
- **Naming.** Swift `glkDeriveBranch` / `registerStandingSignal`; Rust
  `snake_case` plus scheduler types re-exported under a `Scheduler*`
  prefix (`SchedulerSignalSpec`, etc.) to avoid collision with the verb
  module.

These are *shape* and *coverage* differences; the value-level results
C-12 gates are required to agree on the surfaces both ports implement.

## § 9 — Open questions

- The substrate-driven verbs `propose` and `associate` are declared on the
  surface but raise `notSupportedByEstate` until the Brain-layer bodies
  ship; the scheduler routes to them today and records
  `routedButVerbStubbed`. The wiring is complete ahead of the bodies.
- `mutate`, `expunge`, `reanchor`, and `learn` dispatch to LocusKit stubs
  that throw; GLK normalises the stub error. They become live when their
  LocusKit owning missions land (see `LOCUSKIT_SPEC_v0.8.md` § 9).
- The `grants` schema persists only the custody-mode discriminant, not a
  mode-3 grant's threshold/share/drift associated values; a decoded mode-3
  grant is faithful in its discriminant only, and its
  `experimentalIPClearanceConfirmed` flag is reconstructed, not authentic
  caller intent — the IP-clearance gate must key only off a caller-supplied
  `GrantOptions`, never a decoded `Grant`.
- The Rust port's grant/federation/branch/migration surfaces are
  outstanding (§ 8); until they land the cross-port gate covers the verb,
  audit, scheduler, matrix, and training surfaces only.
- The production estate-internal share feed for custody mode 3
  (Appendix B.3) is out of scope; the shipped `ReferenceDecayShareProvider`
  is a deterministic seeded reference, not a live evolving feed (ENC-03).

---

*End of GeniusLocusKit Specification v0.8.*
