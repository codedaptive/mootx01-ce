---
id: CLEARANCE_CLAMP_DECISION_v1.0_2026-06-02
date: 2026-06-02
status: decision
author: Kong (architecture review, root-level, read-only)
verdict: BUILDABLE
scope: packages/kits/LocusKit (both legs), packages/kits/GeniusLocusKit (Rust coordinator), packages/kits/PersistenceKit (layering invariant, no code)
supersedes: ESTATE_RECALL_CLEARANCE_DECISION_v1.0_2026-06-02.md  (verdict RESHAPED → this is the buildable design)
relates_to:
  - MATRIX_ACCESSOR_DECISION_v1.0_2026-06-02.md  (fold-from-recall precedent; governs derived surfaces, NOT this clamp)
  - GLK_RUST_ESTATE_RECALL_001  (the mission re-shaped, now Mission B)
  - SWIFT_LEXICON_GAPS_001  (Swift honest-refusal arms for the same nouns)
verified_against: HEAD da4b1ce, both legs
---

# The Clearance Clamp — Single Chokepoint Over `adjective_bitmap`

Supersedes the RESHAPED estate-recall memo. That memo correctly
diagnosed the gap (clearance enforcement is drawer-only; four nouns
carry the same sensitivity nibble with no enforcement path) and
correctly blocked the unfiltered `all_*` primitive. It left the
solution as "filter-threaded estate reads, mirror the drawer chain,
generalize the gate." This memo resolves that into a buildable design
and the mission structure. The verdict is **BUILDABLE as specified.**

## Assessment

The invariant SECURITY.md:15 ("recall is constrained by classification
on every read") is kept today for drawers because every drawer egress
funnels through `BitmapEvaluator::evaluate`, which injects
`SensitivityAtMost(Normal)` when the caller supplies no ceiling
(`bitmap_evaluator.rs:249-258`, Swift mirror `:234`). The evaluator is
hard-typed `&[Drawer]` (`:159-163`; Swift `[Drawer]`, `:148-152`), so
KGFact / Proposal / Association / LearnedReference never reach it. Their
per-noun reads filter on lifecycle (`g_state_cluster < 7`) and foreign
keys, never on sensitivity (`drawer_store_inmemory.rs:1463-1488` and the
sibling reads). They serialize `adjective_bitmap` (`:2479` KGFact, `:2572`
Association, `:2605` Proposal, `:2791` LearnedReference) — the identical
nibble at bits 6-11 (`ADJ_SENS_MASK = 0x3F << 6`, scale-gapped 0/16/32/48,
`adjectives.rs:78`, `from_raw` `:200`) — but never compare it. The fix is
not five new gates. It is **one** noun-agnostic clamp applied at **one**
read boundary, made unbypassable by construction.

## The resolved design

**1 — Single chokepoint.** The clamp is a free function over a raw
`adjective_bitmap` plus a ceiling, applied at the read-egress boundary in
`DrawerStoreCore` (the storage-agnostic verb-logic core in
`drawer_store_inmemory.rs` that `SqliteDrawerStore` and
`PostgresDrawerStore` both delegate through — `drawer_store_sqlite.rs:75`,
`drawer_store_postgres.rs`). Verified scope correction: the brief's "N
`row_store().query()+decode` sites" is ~50 query calls, most of which are
CRUD writes, single-row `get_*`, manifest/taxonomy. **Do not consolidate
all of them.** The clamp belongs on the **collection-returning reads of
sensitivity-bearing nouns** — the per-noun recall reads
(`kg_facts_for_drawer`, `proposals_for_target`, `associations_from/_to`,
`learned_references_from_source`) and the new estate-wide reads Mission B
needs. Specify the seam as one private helper —
`query_clamped<T>(table, predicate, ceiling, decode_fn) -> Vec<T>` — that
every sensitivity-bearing collection read routes through. The drawer path
keeps routing through `BitmapEvaluator::evaluate` (its clamp is already
there and richer); the helper is the equivalent floor for the nouns the
evaluator cannot type. One helper, not copy-pasted predicates: the
copy-paste is the original failure mode.

**2 — Noun-agnostic clamp.** The comparison is `from_raw((adj &
ADJ_SENS_MASK) >> ADJ_SENS_SHIFT) <= ceiling` — pure function of an
`i64` and an `AdjectiveSensitivity`, zero noun coupling. Only the
evaluator's *type signature* is drawer-bound; the sensitivity comparison
already exists noun-free (`threshold_compare` over `ADJ_SENS_MASK`,
`bitmap_evaluator.rs:439`). Extract it as `pub(crate) fn
sensitivity_clamp(adjective_bitmap: i64, ceiling: AdjectiveSensitivity)
-> bool` in `adjectives.rs` (where the nibble layout already lives), so
any egress path — federation, vector, corpus (the clearance-pattern propagation TODO) — adopts
the same function, not a re-derivation. **Note (comment-fidelity, not
load-bearing):** `bitmap_evaluator.rs:433` comments "adjective bits 4-7"
while the constants and `adjectives.rs:16` say bits 6-11. The constants
are authoritative; the comment is stale. Mission A should correct it
while in the file.

**3 — Default-Normal, fail-safe threading.** Resolved: thread a
`Default`-able recall-context value, not a bare param, not a re-used
`Filter` chain. Recommendation: a small `struct ClearanceCeiling(pub
AdjectiveSensitivity)` with `impl Default` returning `Normal`, carried on
the existing recall context the per-noun reads already receive (or added
as a defaulted field). Justification against the alternatives:
  - *Bare param* — every one of the 38 Rust call sites (~30 tests, ~1 prod
    = coordinator) must pass it explicitly; a forgotten arg is a compile
    error (good) but the migration is 38 hand-edits and a test that
    constructs the ceiling wrong fails open silently. Rejected.
  - *Re-use `Filter::SensitivityAtMost`* — couples the noun reads to the
    drawer filter machinery the memo just established they cannot use;
    invites the next author to reach for the whole evaluator. Rejected.
  - *`Default`-able value* — call sites that don't thread it get `Normal`
    by construction (`ClearanceCeiling::default()`), so the read fails
    **closed**, the exact inverse of today's drawer-only fail-open bug.
    The migration is mechanical: existing sites compile unchanged if the
    field is `#[serde(default)]`/`Default`; only the one prod caller
    (coordinator) threads a real ceiling when ARIA_MCP claims arrive.
    **Recommended.**
The property that matters is locked: **a read path that forgets the
ceiling clamps to ≤Normal, never opens.** This must be a conformance
assertion, not a convention.

**4 — Cache-ready layering invariant (LOCKED CONTRACT).** Stated on the
record as a binding architectural constraint, costing zero code now:
  - The clearance gate lives **ABOVE** storage, in `DrawerStoreCore`. It
    is **NEVER** pushed into PersistenceKit.
  - PersistenceKit stays **clearance-blind** — it caches and returns raw
    rows and knows nothing of `adjective_bitmap`. (Confirmed: PersistenceKit
    has no sensitivity concept; `RowStore::query` returns raw rows.)
  - A future PersistenceKit RAM row-cache slots **BELOW** the gate,
    evicted on write via the existing `StorageObserver`
    (`PersistenceKit/rust/src/observer.rs:51`, `storage.rs:75`; Swift
    `StorageObserver.swift:57`, `Storage.swift:17`). Both legs already
    carry the observer hook.
  - **NEVER cache post-clamp (clearance-filtered) results.** A cache keyed
    below the gate is clearance-agnostic and correct for all callers; a
    cache of filtered results would serve one caller's ceiling to another.
Getting this layer wrong forecloses the safe cache Bob is considering.
Getting it right costs nothing today. This is the highest-leverage line
in the memo.

**5 — Two-leg, atomic.** Swift `BitmapEvaluator.evaluate` is identically
drawer-typed (`:148`). The generic clamp + the consolidated helper land on
both legs in one atomic mission (Mission A). Conformance vectors are
mandatory and **MUST include ELEVATED/Restricted/Secret rows** proving the
nouns do NOT return absent an explicit claim, byte-identical both legs. A
vector suite without elevated-sensitivity rows passes a broken clamp and
is rejected. Sequencing: Swift leads the design surface (CognitionKit
lens-parity doctrine), Rust mirrors; the accessor is internal, so
conformance is by output comparison, not wire.

**6 — DiaryEntry is out of scope.** Confirmed: `DiaryEntry` has
`operational_bitmap` only (event class bits 0-3, `diary_entry.rs:73-79`);
**no sensitivity axis exists.** The clamp has nothing to bound. DiaryEntry
CANNOT ride the universal clamp. It is named out-of-scope here; a
sensitivity-axis schema decision for DiaryEntry is its own future item
(its own mission, both legs, schema migration) and is a prerequisite to
any `all_diary_entries()`. The honest-refusal arm for diary stays until
then. This is the single most dangerous deferral — a cross-agent diary
read has the weakest existing control (wing naming convention only) and
the highest-value content. Do not let it slip into Mission B.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Clamp applied at some noun reads, missed at others (the original drawer-only failure, recurring per-noun) | High | Single `query_clamped` helper; conformance vector exercises *every* sensitivity-bearing read path with elevated rows. Adams/Newton verify no sensitivity-bearing collection read bypasses the helper. |
| A call site forgets to thread the ceiling → fails open | High | `Default`-able `ClearanceCeiling` ⇒ default is `Normal` ⇒ fails closed by construction. Conformance asserts the no-ceiling path returns ≤Normal. |
| Mission B (flip stubs live) bundled with Mission A | Med | Hard split. The clamp is the work; the flip is plumbing. Bundling re-creates the matrix-decision temptation ("the read is cheap"). |
| DiaryEntry rides Mission B because it's "also a recall stub" | High | Named out-of-scope here. Mission B flips four stubs, not five. Diary stays refused. |
| Future cache caches filtered results | Med | Layering invariant §4 locked now, before any cache exists. |

**Non-obvious risk (the one nobody named):** the `Default`-able ceiling
makes the migration safe — but it also makes the *test corpus* the only
thing standing between "fails closed" and "nobody ever exercised the
elevated path." Because `Normal` is both the default ceiling *and* the
default row sensitivity (`from_raw` falls back to `Normal`,
`adjectives.rs:200`), a corpus seeded entirely with `Normal` rows passes
whether the clamp works or not — every row is ≤ every ceiling. The clamp
can be completely inert and green. The conformance vectors must contain
rows at Elevated/Restricted/Secret **and** assert their absence from
default-ceiling reads; otherwise the gate is decorative and the suite
certifies nothing. This is the exact failure that let the drawer-only bug
live: the gate existed, looked enforced, and the four nouns were never in
a test that would have noticed. Make the elevated-row assertion the
acceptance gate, not a nice-to-have.

## Dependencies

- **Depends on:** `adjective_bitmap` nibble layout (bits 6-11, stable);
  `AdjectiveSensitivity::from_raw` (`adjectives.rs:200`); `DrawerStoreCore`
  delegation model (sqlite/postgres newtypes); `StorageObserver` hooks
  (both legs, for the future cache).
- **Affects:** the four GLK coordinator recall stubs (`coordinator.rs:410`
  kg_facts, `:428` diary, `:446` proposals, associations, learned_refs) —
  Mission B flips four of five; the ARIA_MCP recall tool surface (schemas
  already correct, stub→live returns rows under same schema, not a wire
  break).
- **Conflicts with:** the rejected unfiltered `all_*` primitive (blocked by
  the superseded memo — do not resurrect). **Does NOT govern** derived
  surfaces: matrix-tier aggregates and vector similarity are Perkins'
  scope under the fold-from-recall precedent (MATRIX_ACCESSOR_DECISION) —
  those leak through *aggregate statistics over recalled rows*, a
  different mechanism than this direct-row clamp. The clamp is the floor
  for direct noun egress; the fold is the floor for derived surfaces. Do
  not conflate them.

## Recommendation

**VERDICT: BUILDABLE as specified.** Two missions, hard split.

**Mission A — the clamp (Newton, substrate lane, parallel Swift/Rust).**
- *Tier:* Tier 1 (primitive-touching — `adjective_bitmap` egress), **atomic
  exception** (the clamp function, the helper consolidation, and both legs
  must land together or one leg ships an ungated noun). Justify atomicity
  in the BRR.
- *Build:* (1) `pub(crate) sensitivity_clamp(adjective_bitmap, ceiling)`
  in `adjectives.rs` + Swift mirror; (2) `ClearanceCeiling` Default-Normal
  value; (3) `query_clamped` helper in `DrawerStoreCore`; (4) route the
  four per-noun sensitivity-bearing reads through it; (5) conformance
  vectors with Elevated/Restricted/Secret rows asserting absence from
  default-ceiling reads, byte-identical both legs; (6) correct the stale
  bits-4-7 comment at `bitmap_evaluator.rs:433`.
- *Blast radius, Rust:* `adjectives.rs`, `bitmap_evaluator.rs` (comment +
  possible extraction reuse), `drawer_store_inmemory.rs` (the helper + 4
  read sites). *Swift:* `Adjectives.swift`, `BitmapEvaluator.swift`,
  `DrawerStore.swift`. Plus shared conformance vectors. The 38 call sites
  are unchanged-by-default (the migration's point).
- *Review:* **Perkins reviews before merge.** The conformance vectors are
  the artifact under review; a suite without elevated rows is rejected.

**Mission B — flip the stubs live (Newton, after A merges).**
- *Tier:* Tier 1, ≤5 edits. Flip the **four** sensitivity-bearing
  coordinator stubs (`coordinator.rs:410/446` + associations + learned_refs)
  from `NotSupportedByEstate` to clamped estate-wide reads now that a
  clearance-safe read exists. The four ARIA_MCP dispatch arms follow the
  same schema.
- *DiaryEntry stub stays refused* — blocked pending the sensitivity-axis
  schema decision (separate future item).
- *Never bundle with A.* A proves the gate; B exposes it.

## Notes for the audit trail

- This memo supersedes ESTATE_RECALL_CLEARANCE_DECISION_v1.0 on the
  *solution*, not the *diagnosis* — the prior memo's finding (gate is
  drawer-only; four nouns carry the same nibble ungated) is affirmed and
  load-bearing. The change is from "filter-threaded per-noun reads
  mirroring the evaluator" to "one noun-agnostic clamp at one egress
  boundary." Reason: per-noun filter-threading re-introduces the
  copy-paste that caused the original bug; a single generic clamp is
  unbypassable by construction and adoptable by the federation/vector/
  corpus paths the propagation TODO tracks.
- The layering invariant (§4) is the durable artifact. If a future
  PersistenceKit RAM cache is built, it slots below the gate and evicts on
  the existing StorageObserver. Never cache post-clamp results. This was
  locked here at zero cost; reversing it later is expensive.
- If a future change generalizes `BitmapEvaluator::evaluate` to accept any
  sensitivity-bearing noun, the `query_clamped` helper can fold into it —
  revisit this memo then. Until then the helper is the floor the typed
  evaluator cannot provide.
- The trap that hid the original bug: `Normal` is both the default ceiling
  and the default row sensitivity, so an all-`Normal` corpus certifies
  nothing. Elevated-row vectors are the real acceptance gate.
- Verified against HEAD da4b1ce, both legs.
