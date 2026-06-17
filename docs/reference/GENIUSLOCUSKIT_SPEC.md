---
title: GeniusLocusKit Specification
version: 1.1.1
status: active
date: 2026-06-17
description: "Behavioral specification for GeniusLocusKit: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - GENIUSLOCUSKIT_INTERFACE.md  (the API surface this spec contracts)
  - GENIUSLOCUS_ARCHITECTURE_SPEC.md  (§ 7.8 verb surface, § 11 standing signals, § 12 matrix tier, § 15 kit composition; invariants I-13, I-15)
  - LOCUSKIT_SPEC.md  (the single-estate tier GLK composes)
  - VECTORKIT_SPEC.md  (the vector tier composed per estate)
  - CORPUSKIT_SPEC.md  (the RAG-bundle tier composed per estate)
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
CognitionKit) or an access surface (aria-mcp) needs from the substrate
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
- The unified nine-verb surface and how each verb dispatches to its
  estate body, governed by the lexicon's § 7.2 acceptance matrix.
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

- API signatures — those live in `GENIUSLOCUSKIT_INTERFACE.md`.
- Single-estate nouns, bitmaps, the recall pipeline, container pruning,
  or the per-kit bitmap-audit trail — see `LOCUSKIT_SPEC.md`.
- Embeddings and ANN search — see `VECTORKIT_SPEC.md`.
- RAG bundle composition — see `CORPUSKIT_SPEC.md`.
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
                                  └── aria-mcp     (estate exposed over MCP;
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
architecture):** the composed kits (LocusKit, VectorKit, CorpusKit) are
reached only through GLK's estate verb surface. NeuronKit and CognitionKit
MAY import LocusKit to name read-only value types (e.g. `Drawer`,
`ContentKind`) in their inputs and outputs, but never call a LocusKit,
VectorKit, or CorpusKit estate/verb/storage surface directly; all substrate
access is a verb applied to an `EstateHandle`. This is the structural form
of the architecture's layering rule and is the reason the verb surface, not
the composed kits, is GLK's consumed contract.

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

**I-15 (cross-version parity):** the Swift and Rust versions are
conformance-gated against shared test vectors across the whole surface —
the verb vocabulary, the audit log/projection/recovery, the scheduler
emission ordering, the matrix tier, the training daemon, and the grant,
federation, branch, and migration surfaces. Value-level results must
agree; neither version leads.

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

Step 1 (LocusKit storage, `estate.expunge(sealAudit: false)`): validates the
confirmation flag and S-3 state gate, tombstones the drawer row, and zeroes
the content blob — atomically. The gate produces an `AuditEvent` (substrate
truth) but does NOT append it to the audit log yet.

Step 2 (GLK orchestration, cross-kit vector delete): when a `Corpus` is
registered for the estate, calls `Corpus.remove(sourceID: rowID)` to purge
the drawer's BM25 index entries and all vector embeddings from the Corpus's
internal VectorStore; when a standalone `VectorStore` is also registered
(`.glk` kind), additionally calls
`VectorStore.deleteAllVectors(itemID: rowID, modelID: corpus.modelID)` to
invalidate the standalone store's resident array (the two stores share the
same backing SQLite table but maintain separate in-memory bitmaps). When no
Corpus or VectorStore is registered (`.locusOnly` kind), Step 2 is a no-op.

Step 3 (audit seal):
- **On success (steps 1+2 both complete):** GLK calls
  `estate.sealExpungeAudit(event)`, which appends the gate-produced event
  to the substrate audit log as `verb = "tombstone"`. The audit record is
  honest: the full expunge (storage + cross-kit delete) succeeded.
- **On step-2 failure:** GLK calls `estate.sealExpungeOrphanAudit(...)`,
  which appends an `"expungeOrphan"` event to the substrate audit log, then
  throws `VerbError.crossKitVectorDeleteFailed`. The audit record is honest:
  the storage half succeeded but the cross-kit vector delete did not. The
  caller must NOT report the row as fully deleted.

The `"tombstone"` and `"expungeOrphan"` substrate verb strings both map to
`UnifiedAuditVerb.expunge` in the unified log (via `AuditBridge`/`verb_from_str`).
Consumers needing to distinguish a clean expunge from a partial one must read
the substrate audit trail directly (the verb string is preserved there as-is).

Direct LocusKit callers (bypassing GLK) use `estate.expunge(sealAudit: true,
default)` and retain the historical single-step atomic contract — the audit
is sealed inside `estate.expunge`, as before.

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
   a. Re-attempt the cross-kit vector+corpus delete (same logic as §B-2a step 2).
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

**B-14 (migration orchestration; ingestion retired to VaultKit):** GLK
ships two migration verbs. `verifyMigration` issues one content-match
recall per corpus entry and returns `.identical` only when every entry
is recallable, else `.diverged` with the missing entries. `runParallel`
returns a `ParallelRunHandle` that routes captures per
`ParallelCaptureMode` until `stop()`. Mass data ingestion is NOT a GLK
verb: per ADR-007 Decision 1 the flat import verb is
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
- `withdraw_kg_fact` sets bits 0–5 of the fact's `adjective_bitmap` to
  `State::Withdrawn` (raw 18), preserving bits 6+ (sensitivity, exportability,
  trust, flags). After withdrawal `g_state_cluster = 18 ≥ 7`, so the fact is
  excluded from the `recall_kg_facts` active filter. The row is never deleted.
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
| `VerbError.crossKitVectorDeleteFailed` | LocusKit storage expunge succeeded but the cross-kit vector delete (Corpus.remove / VectorStore.deleteAllVectors) threw | surface immediately, never swallow — a surviving embedding of content the user believed was irreversibly destroyed is a privacy breach; the row's verbatim content is already zeroed but the caller must NOT report the row as fully deleted |
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

**C-1 (lifecycle + isolation):** `open`/`close`/`estate(for:)` admit,
remove, and resolve estates by handle; a duplicate UUID is refused
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

## § MATRIXT_HOURLY — T-matrix population signal

`TemporalCausalitySignal` is wired as signal 7 in the default
standing-signal set.

### Standing-signal inventory update (§11.2)

The six v1 standing signals documented in §11.2 of the architecture spec have
been extended to seven with the addition of `TemporalCausalitySignal`:

| # | Signal name | Cadence | Purpose |
|---|------------|---------|---------|
| 1 | dreaming-daemon | 604 800 s (weekly) | NMF, eigenvalue, T-matrix cold-path |
| 2 | maintenance | 3 600 s (hourly) | Tombstone cleanup, orphan detection |
| 3 | vector-similarity | 300 s (5 min) | HNSW proximity clustering |
| 4 | decay-sweep | 86 400 s (daily) | O/T matrix multiplicative decay |
| 5 | byReference-validity | 604 800 s (weekly) | Broken reference detection |
| 6 | end-of-day-tournament | 86 400 s (daily) | Bradley-Terry reward signal |
| **7** | **temporal-causality-fold** | **3 600 s (hourly)** | **T-matrix population pass** |

Signal 7 is registered via `TemporalCausalitySignal.defaultSpec()` in
`registerDefaultStandingSignals`. Production callers replace it with
`TemporalCausalitySignal.spec(foldCycle:)` to wire a live fold closure.

### Cadence decision

Cookbook §6.4 specified a weekly T-matrix update on the dreaming daemon pass.
This was superseded with hourly cadence.
See `docs/decisions/DECISION_MATRIXT_HOURLY_CADENCE_2026-06-04.md`.

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
function lives in SubstrateML (single source of truth for conformance vectors).

### Package dependency

GeniusLocusKit/Package.swift gained a dependency on SubstrateML to access
`TemporalCausalityFold`. Layering is correct: GeniusLocusKit (composition) →
SubstrateML (algorithms). Justified by
DECISION_MATRIXT_HOURLY_CADENCE_2026-06-04.md.

## § RAG_WIRING — RAG and vector seams

Both seams are wired in Swift and Rust.

### ExternalCorpus hybrid recall

`ExternalCorpus.hybridRecall(via:limit:now:)` routes recall through
CorpusKit's `Corpus` actor. Each corpus entry's content is used as
the query to `Corpus.recall(query:limit:now:)`, which fuses vector
kNN and BM25 keyword scores via Reciprocal Rank Fusion. The result
per entry is a `[ScoredChunk]` list with both `vectorScore` and
`keywordScore` sub-scores.

The existing `asRecallFrames()` method is preserved for the
LocusKit-only content-match path used by `verifyMigration` (estate
existence checking, not hybrid retrieval).

**Corpus construction:** the caller constructs the `Corpus` actor
from the same `Storage` backing the estate so chunk embeddings index
the estate's content. The default embedding model is `.deterministic`
(no CoreML required).

**Import domain:** `ExternalCorpus.swift` imports `CorpusKit`. RAG
retrieval always routes through CorpusKit per the kit-roles doctrine.

### VectorSimilaritySignal real VectorKit queries

`VectorSimilaritySignal.spec(vectorStore:modelID:proximityThreshold:)`
produces the production signal spec. The emit closure captures the
`VectorStore` and on each five-minute fire:

1. Calls `VectorStore.findByKeyword("", limit: 50)` to sample up to
   50 candidate drawer IDs.
2. For each candidate, retrieves its engram via
   `VectorStore.getVector(drawerID:modelID:)`.
3. Calls `VectorStore.findNearest(probe:modelID:limit:5)` to find
   nearby rows.
4. Deduplicates pairs and emits one `AssociateFrame` per pair whose
   Hamming distance ≤ `proximityThreshold` (default 64 = 25% of 256
   bits). Weight = 1 − distance / 256.
5. Always emits a scan-summary `DiagnosticReport` with the candidate
   pair count.

The sentinel-only `defaultSpec()` factory is removed. The production
factory requires an injected `VectorStore` and `modelID`.

`DefaultStandingSignals.registerDefaultStandingSignals(in:vectorStore:
modelID:now:)` forwards the VectorStore to `VectorSimilaritySignal.spec`.

**Import domain:** `VectorSimilaritySignal.swift` imports `VectorKit`.
GLK may orchestrate VectorKit directly for non-RAG vector work per the
kit-roles doctrine; row-similarity is Brain math, not RAG.

**Rust parity:** `VectorSimilaritySignal::spec(vector_store, model_id,
proximity_threshold)` mirrors the Swift factory. `default_standing_signal_specs`
now accepts an `Arc<VectorStore>` and forwards it to the signal.
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

### Post-hydration shingle MMR

The MMR similarity proxy in step 10 is upgraded to post-hydration shingle
overlap. When `drawerIndex[id]?.content` is non-empty, `glkShingleSimilarity`
(3-gram Jaccard) replaces the pre-hydration `glkSourceMaskJaccard` fallback.
For bitmapOnly hydration or drawers without content, sourceMask Jaccard is
retained. GeniusLocusKit reimplements shingle similarity locally (`glkShingleSimilarity`
/ `glkShingles`) because it cannot import NeuronKit (circular package dependency).

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
3. Wires sub-stores (Corpus, VectorStore) according to `EstateKind`.

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

`destroy` internally calls `close` if the estate is still open, then tears
down sub-stores: `Corpus.destroyRecallIndex()` (BM25 cleared, vectors deleted)
and `VectorStore.destroyAllVectors()`. BundleStore chunks are NOT deleted
(append-only invariant — verbatim content survives for audit purposes).

### Invariants

- `provision` is idempotent at the "estate already exists" level: re-provisioning
  the same storage raises `.duplicateEstate`.
- Sub-store wiring failures in `provision` roll back by closing the handle before
  re-throwing, so no half-wired zombie estates are left in the registry.
- `quiesce` is idempotent: calling on an already-quiesced estate is a no-op.
- The existing `open` + `registerCorpus` + `registerVectorStore` caller path is
  unchanged. All existing callers continue to work. `provision` is purely additive.

---

## § ROLLUPS — Per-Estate Rollup Telemetry

### Overview

GeniusLocusKit emits per-estate rollup metrics through `IntellectusLib`
at the estate-coordination and lifecycle boundaries. All metrics are in
the `geniuslocus.estate.*` namespace to distinguish them from per-kit
metrics emitted by LocusKit (`locus.*`), VectorKit (`vector.*`), and
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
the composition layer — GLK's job is composing LocusKit/VectorKit/CorpusKit
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
is the full weighted pipeline; `hybrid` / `corpusOnly` + `rrf` is real RRF
fusion; `locusOnly` / `hybrid` / `corpusOnly` + `raw` is the raw merge.

| Stage identifier | Trigger | Applied fallback |
|---|---|---|
| `locusOnly.matrixAware` | `matrixAware` requested on `locusOnly` (no matrix pass) | raw bitmap-evaluator ordering |
| `corpusOnly.matrixAware` | `matrixAware` requested on `corpusOnly` (no matrix pass) | RRF fusion of BM25 + vector |
| `hybrid.matrixAware` | `matrixAware` requested on `hybrid` (no matrix pass) | three-way RRF fusion |
| `unionBest.rrf` | `rrf` requested on `unionBest` (no distinct RRF fusion across lane scores) | raw (`buffer.final`) lane-normalised score |

Both ports emit the identical stage strings. The no-corpus collapse path
(Hybrid/CorpusOnly with no corpus/vector registered) keeps the requested
mode's stage name so the vocabulary is stable regardless of which internal
path served the query. `unionBest` + `matrixAware` never records a fallback
even on an estate with no corpus/vector — the weighted pipeline runs with zero
matrix columns, a real path, not a degrade.

#### Signed-weight fusion steering (RecallShape — 6b-modifiers)

`GLKRecallRequest.recallShape` (optional `RecallShape`) makes the RRF fusion
STEERABLE without changing the fusion algorithm. The fused score becomes
`fused(id) = Σ_L w_L · 1/(k + rank_L(id) + 1)` with `k = 60`, where each lane
`L` carries a SIGNED weight `w_L` from `RecallShape.laneWeights` keyed by a
stable lane identifier (`locus`, `bm25`, `hamming`, and `dense:<modelID>` for
each held dense signal). A lane whose key is absent defaults to `1.0`.

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
per-signal dense float signals fuse:

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
  it. Matrix/graph/preference columns are NOT shape-steerable (RecallShape
  addresses the retrieval lanes only).

A `nil` shape — or an all-1.0 shape — is BYTE-IDENTICAL to the prior uniform
fusion in EVERY lane including `unionBest` (the back-compat contract, proven by
conformance on both ports). `RecallShape` may also override the candidate-pool
depth via `frontierK`, clamped to the engine's `[64, 256]` envelope. Both ports
implement the identical signed formula and clamp.

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
| `pool.hydrateBodies.mmr` | NO | MMR hydration is not yet implemented in the Rust port |
| `pool.hydrateBodies.return` | NO | same reason as above |
| `hybrid.getDrawers` | NO | `estate.recall()` in Rust is non-throwing; no `getDrawers` call exists in the hybrid frontier path |
| `corpusOnly.getDrawers` | NO | same reason; the CorpusOnly drawer index is built from `estate.recall()` output |

**Rust test seam protocol:** `inject_vector_hamming_error` and `inject_embed_error`
on `EstateCoordinator`, gated behind `#[cfg(any(test, feature = "test-seams"))]`.
The `test-seams` Cargo feature enables the seams for integration tests. The
force-tests cover the two present stages and the seam-not-applicable
(locusOnly) case.

*End of GeniusLocusKit Specification.*

## Changelog

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
