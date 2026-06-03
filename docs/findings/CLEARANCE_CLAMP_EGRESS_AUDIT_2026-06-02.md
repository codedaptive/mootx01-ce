# CLEARANCE_CLAMP_001 — Egress-Completeness Security Audit

> **Pre-product calibration (Bob, 2026-06-02).** MOOTx01 is not a shipping
> product — there are no live estates, federation peers, or real classified
> data. The severities below model the *eventual* shipping threat surface, not
> live exposure. Read this as a **design-propagation checklist**: the egress
> surfaces that must adopt the clearance pattern AS EACH IS BUILT. Nothing here
> is an active leak or a merge blocker. The one item that is load-bearing now,
> independent of product stage, is the elevated-sensitivity conformance vectors
> in CLEARANCE_CLAMP_001 Mission A — that is a correctness test of the clamp
> primitive, not a shipping gate. G2 (federation push) is an ungated API on an
> unbuilt/unwired feature: gate it when federation is built, or bake a cheap
> reject-Private default now as a placeholder — not a blocker either way.

**Date:** 2026-06-02  
**Author:** Perkins  
**Commit audited:** main HEAD da4b1ce  
**Invariant under review:** SECURITY.md:15 — "Recall is constrained by [classification] on every read."

---

## 1. Threat Model

**Attack:** Clearance bypass — a caller reads rows above their sensitivity ceiling, either directly (row content returned) or by inference (aggregates or similarity search revealing the existence or relationships of above-clearance rows).

**Threat actors in scope:**

- An MCP client (e.g., an AI agent calling ARIA_MCP tools) that omits a sensitivity claim or supplies a lower-clearance claim than the rows it wants to reach.
- A federation peer that receives replicated rows above its clearance via the ConvergenceKit engine.
- Any consumer that reads VectorKit `find_nearest` results derived from above-clearance drawers — content not returned, but existence and topological relationships are revealed.
- A future PersistenceKit RAM cache that serves raw rows before the clearance gate.

**Attack vectors by class:**

1. **Clearance bypass (direct):** A caller calls a noun-specific scoped read (`kg_facts_for_drawer`, `proposals_for_target`, `associations_from`, `learned_references_from_source`, `read_diary`) that returns the fact/reference/entry itself — if the fact carries an elevated `adjective_bitmap` sensitivity the caller is not cleared for, the content crosses the boundary.
2. **Inference leak (vector):** `VectorStore::find_nearest` returns `drawer_id` + `distance` for every row under a `model_id`. No content is returned, but the identity and proximity of secret-sensitivity drawers is revealed in the distance ranking.
3. **Federation exposure:** `FederationSyncEngine::push` ships the raw `outbox` of `SyncRecord`s to every registered peer. A `SyncRecord` contains a `SyncValueMap` that is a verbatim copy of the PersistenceKit row (all column values, including `adjective_bitmap` and `content`). No clearance gate checks exportability or sensitivity before shipping.
4. **Matrix aggregates:** `MatrixTier` is populated by folding the `UnifiedAuditLog` via `EnrichmentPipeline::run`. The audit log is the per-estate write history — it is not filtered by caller clearance.

**BYOAI model:** Holds. No API key surfaces reviewed carry credential exposure risk. The audit is about data egress to callers and peers, not AI credential handling.

---

## 2. Egress-Completeness Table

### Path A — DrawerStore::recall (drawer rows via BitmapEvaluator)

**Status: GATED TODAY**

`BitmapEvaluator::evaluate` (`bitmap_evaluator.rs:249`) auto-injects `Filter::SensitivityAtMost(Normal)` whenever the caller's `RecallFrame` contains no sensitivity constraint (`insert_defaults`, line 256). This is the current gate. It covers the drawer-typed path: `Estate::recall` → `DrawerStoreCore::all_drawers` → `BitmapEvaluator::evaluate`.

The proposed DrawerStoreCore clamp will lift this gate to the decode boundary so every read from raw storage passes through it, not only the `BitmapEvaluator` path. That is the right architectural direction.

**Gap:** The clamp as described covers the drawer egress path. The five other noun paths below are not covered by `BitmapEvaluator`.

---

### Path B — DrawerStore::kg_facts_for_drawer

**Status: UNGATED — NEEDS CLAMP**

`DrawerStoreCore::kg_facts_for_drawer` (`drawer_store_inmemory.rs:1463`) queries PersistenceKit storage directly with predicates on `sourceDrawerID` and `g_state_cluster`. No predicate on `adjective_bitmap` sensitivity bits (6–11). The method returns every `KGFact` for a drawer regardless of the fact's own sensitivity level.

Attack: a caller requests facts for a `Normal`-sensitivity drawer. That drawer's extracted facts may have been filed with `AdjectiveSensitivity::Secret` (e.g., a fact extracted from a secret passage). The caller gets the secret fact content.

`KGFact` carries a full `adjective_bitmap` (confirmed in `kg_fact.rs:88`). The gate does not read it on egress.

**Will the proposed clamp cover this?** Only if it is applied at the `DrawerStoreCore` boundary for all noun types, not just drawer rows. The clamp is described as "noun-agnostic by design, reusable" — the implementation must explicitly apply it to this path.

---

### Path C — DrawerStore::proposals_for_target

**Status: UNGATED — NEEDS CLAMP**

`DrawerStoreCore::proposals_for_target` (`drawer_store_inmemory.rs:1524`) queries on `targetRowID` only. `Proposal` carries `adjective_bitmap` (`proposal.rs` field visible at line 2605 of inmemory). No sensitivity predicate.

Same attack shape as B. A proposal for a `Normal`-visible target row may itself carry `Secret` sensitivity.

---

### Path D — DrawerStore::associations_from / associations_to

**Status: UNGATED — NEEDS CLAMP**

`DrawerStoreCore::associations_from` and `associations_to` (`drawer_store_inmemory.rs:1587, 1615`) filter on `sourceWing`/`sourceRoom` and `tombstonedAt IS NULL`. No sensitivity predicate. `Association` carries `adjective_bitmap` (confirmed at line 2572).

---

### Path E — DrawerStore::learned_references_from_source

**Status: UNGATED — NEEDS CLAMP**

`DrawerStoreCore::learned_references_from_source` (`drawer_store_inmemory.rs:1679`) filters on `sourceCatalogID` and `tombstonedAt IS NULL`. No sensitivity predicate. `LearnedReference` carries `adjective_bitmap` (confirmed at line 2791).

---

### Path F — DrawerStore::read_diary / read_diary_in_wing

**Status: NO-SENSITIVITY-AXIS (advisory flag, not a blocking gap)**

`DiaryEntry` has no `adjective_bitmap` field. Confirmed in `diary_entry.rs`: the struct has `operational_bitmap` (operational axes — `DiaryEventClass`, `DiarySeverity`, `DiaryActorClass`, `DiaryBatchMembership`, `requires_followup`) but no sensitivity axis. `read_diary` and `read_diary_in_wing` query by `agentName` + `tombstonedAt IS NULL`.

**Flag:** DiaryEntry carries no sensitivity axis. This is either a deliberate design choice (diary is always agent-scoped and never sensitivity-classified) or a missing axis. The design intent must be documented. If diary entries can ever carry sensitive content (e.g., an agent's diary recording a secret drawer's content), the absence of the sensitivity axis is a structural gap. Advisory, not blocking — the current data model has no sensitivity axis on DiaryEntry, so there is nothing to gate.

---

### Path G — ConvergenceKit FederationSyncEngine::push (federation egress)

**Status: UNGATED — BLOCKING**

`FederationSyncEngine::push` (`federation.rs:250-272`) takes every `SyncRecord` from `self.state.outbox` and broadcasts it to all registered peers. The `SyncRecord` is a full row copy (`SyncValueMap` with all column values). There is no check of:

- `AdjectiveExportability` — whether a row is `Private` (non-exportable) or `Public`.
- `AdjectiveSensitivity` — whether a row exceeds the receiving peer's clearance.
- Grant model — what the receiving estate is permitted to see.

The federation `enqueue` method (`federation.rs:213`) that feeds the outbox also performs no clearance check.

The dispatch layer returns `error_result("not yet implemented: federation requires the grant model")` for `moot_cross_estate_recall` at the MCP tool surface. However, this only blocks the *pull-initiated* tool path. The *push* path is live code: a caller that calls `enable` + `enqueue` + `push` directly on the engine can ship any row, including `Private` and `Secret` rows, to any registered peer.

**Attack path:** Attacker registers as a federation peer, then calls `enqueue` with a row swept from local storage (including above-clearance rows), then calls `push`. The engine signs and broadcasts the record without inspecting sensitivity or exportability.

**Impact:** A `Secret`, `Private` row crosses the federation boundary. User content the user marked non-exportable leaves the estate. This is the highest-impact finding in this audit — it directly violates the SECURITY.md guarantee: "what you mark `private` does not cross the perimeter."

**Mitigation required:** Before the clamp mission merges, the federation push path must gate on `AdjectiveExportability::Private` (reject enqueue or filter outbox) and on sensitivity ceiling. The grant model referenced in the dispatch scaffold is the right long-term fix. The short-term minimum is: `enqueue` must reject rows with `AdjectiveExportability::Private` and rows with `AdjectiveSensitivity` above `Normal`, with a documented clearance claim mechanism as the unlock path.

This finding is BLOCKING.

---

### Path H — VectorKit::find_nearest (inference leak)

**Status: INFERENCE-SURFACE — UNGATED, ADVISORY**

`VectorStore::find_nearest` (`vector_store.rs:224`) queries the `vectors` table by `model_id` and returns a list of `(drawer_id, distance)` matches. The `vectors` table stores one row per `(drawer_id, model_id)` pair — it does not store the drawer's `adjective_bitmap`.

**Attack:** An above-clearance drawer (e.g., `AdjectiveSensitivity::Secret`) has its embedding filed in the `vectors` table. A caller with `Normal` clearance sends a probe vector. `find_nearest` returns the secret drawer's `drawer_id` in the result set, ranked by Hamming distance. The caller learns: (a) that a secret drawer exists, (b) its ID, (c) its proximity to their query. This is an inference leak: content is not returned, but existence and topological relationships are revealed.

**The `vectors` table does not carry `adjective_bitmap`** (schema confirmed in `vector_store.rs:76-108`: columns are `id`, `drawer_id`, `model_id`, `model_version`, `engram`, `filed_at`). The gate cannot be applied inline.

**Mitigation options:**
1. Add `adjective_bitmap` to the `vectors` table and filter on it in `find_nearest` — mirrors the proposed DrawerStoreCore clamp.
2. Post-filter: after `find_nearest` returns, join against the drawer store and filter by sensitivity. Requires cross-store coordination.
3. Store separate vector indices per sensitivity tier (architectural change).

Option 1 is the cleanest and aligns with the clamp mission's direction.

**Classification:** Advisory. The inference leak is real, but it requires the attacker to know or discover the `model_id` in use and have MCP access. The current VectorKit has no live MCP surface for similarity search (the `NearVector` filter in `BitmapEvaluator` surfaces an error: "nearVector requires VectorKit — not yet implemented"). The leak path is not MCP-reachable today. Advisory pending VectorKit MCP activation.

---

### Path I — CorpusKit BundleStore

**Status: NO-SENSITIVITY-AXIS**

`BundleStore` (`bundle_store.rs`) stores the `chunks` table: `(id, source_id, start_offset, length, text, hlc, metadata, created_at)`. No `adjective_bitmap` column. Corpus chunks are text fragments derived from source documents; they inherit no sensitivity axis from the drawer they were chunked from. The sensitivity of a chunk is implicitly the sensitivity of its source drawer.

**Gap:** If chunks are derived from above-clearance drawers, the chunks table exposes their content without any sensitivity predicate. Whether this is an exploitable gap depends on whether `source_id` is ever a drawer ID with elevated sensitivity. This must be decided at architecture level (Kong lane) before the clamp mission closes. For now: NO-SENSITIVITY-AXIS, Advisory.

---

### Path J — NodeBundleStore / ContainerFingerprintStore

**Status: NO-SENSITIVITY-AXIS**

`NodeBundleStore` stores aggregate count-vectors per `(wing, room, bundleKind)` — no row-level content, no sensitivity axis. `ContainerFingerprintStore` stores OR fingerprints of active rows per container — used for container pruning in `BitmapEvaluator::container_survives`, no content exposure.

Neither exposes row content. Not a direct clearance bypass threat.

---

### Path K — MatrixTier (aggregates)

**Status: INFERENCE-SURFACE — FOLD-RULE GOVERNED, ADVISORY**

The `MatrixTier` (`matrix.rs:102`) holds `co_occurrence`, `field_presence`, and `temporal_causality` as `i64` counts. It is populated by `EnrichmentPipeline::run` which folds the `UnifiedAuditLog` directly (`pipeline.rs:76`). The audit log is the estate's full write history — it is not filtered by caller clearance.

**MATRIX_ACCESSOR_DECISION fold-from-recall rule:** The design decision (referenced in the mission prompt) states the matrix must derive only from clearance-bounded recall, never raw storage. In the current code, `EnrichmentPipeline::run` folds `log.entries_since(high_water_mark)` — this is the raw per-estate audit log, not a clearance-bounded recall result. If the estate's audit log contains events for above-clearance rows, those events' `after_value` bitmap fields (which can carry field path + bitmap values) contribute to the matrix.

**Impact:** A caller reading the matrix tier (if exposed) could infer that certain field-path / bitmap-value combinations co-occur, which might reveal that above-clearance rows with particular sensitivity/trust/state bit patterns exist. The information is coarse (no content, no IDs) but statistically non-trivial if the estate is large.

**Current exposure:** The matrix tier is not exposed via any MCP tool today. It is consumed internally by GeniusLocusKit training signals. Advisory.

**Required action:** The MATRIX_ACCESSOR_DECISION's fold-from-recall rule must be mechanically enforced before the matrix tier gains any external egress surface. The implementation must ensure `EnrichmentPipeline` only ingests audit events from drawers that passed a clearance-bounded recall — or excludes audit events for above-clearance rows at the pipeline's input boundary.

---

## 3. Gate Universality Assessment

**Is the gate UNIVERSAL after the DrawerStoreCore clamp?**

No. The proposed clamp on the DrawerStoreCore read/decode boundary will cover:
- Drawer egress (Path A) — already gated, will be structurally reinforced.
- Noun-specific scoped reads (Paths B–E) — ONLY if the clamp implementation explicitly applies to `kg_facts_for_drawer`, `proposals_for_target`, `associations_from`, `learned_references_from_source`. This is the implementer's primary obligation.

The gate will NOT be universal after the clamp unless the following are also addressed:

| Gap | Severity |
|---|---|
| Federation push (Path G) — Private/Secret rows ship to peers | BLOCKING |
| VectorKit find_nearest inference leak (Path H) | Advisory (not MCP-reachable today) |
| CorpusKit chunks inherit no sensitivity axis from source drawer (Path I) | Advisory |
| MatrixTier folds raw audit log including above-clearance events (Path K) | Advisory |

**The residual hole Perkins most suspects — federation — is confirmed.** The push path is live, signs records, and broadcasts without any clearance check. This is not a theoretical future concern; it is reachable today by any caller with direct engine access.

---

## 4. Security Acceptance Criteria

The implementer mission for CLEARANCE_CLAMP_001 must meet ALL of the following before merge:

**C-1. Noun-path clamp coverage**
The `DrawerStoreCore` clamp must apply to all five noun-scoped reads: `kg_facts_for_drawer`, `proposals_for_target`, `associations_from`, `learned_references_from_source`, and any future noun-scoped accessor added to `DrawerStore`. The implementation must not rely on callers to apply sensitivity filtering post-hoc.

**C-2. Fail-safe property — must be tested**
A read path that forgets or omits the clearance ceiling must return `≤ Normal` rows, never open access. The fail-safe is: no sensitivity claim → `SensitivityAtMost(Normal)` injected. This must be exercised by a conformance vector that:
- Inserts a row with `AdjectiveSensitivity::Elevated` (and `Restricted`, and `Secret`).
- Performs a recall with no sensitivity filter.
- Asserts the elevated row is NOT returned.
- Performs a recall with `SensitivityAtMost(Elevated)`.
- Asserts the elevated row IS returned.
This must cover BOTH legs (Swift and Rust) and BOTH the drawer path and at least one scoped noun path (kg_facts recommended as the highest-risk noun).

**C-3. Federation push gate (BLOCKING — pre-condition to merge)**
`FederationSyncEngine::enqueue` must reject rows with `AdjectiveExportability::Private`. Until the grant model ships, this is the minimum correctness bar. A `Secret` or `Restricted` sensitivity row must also be rejected from the outbox unless the receiving peer's clearance ceiling has been declared and matched. This may be scaffolded as "enqueue rejects above-Normal sensitivity absent an explicit clearance grant" until the full grant model lands.

**C-4. Conformance vectors must include elevated-sensitivity rows**
The clamp mission's conformance test vectors (both legs) must include:
- At least one `KGFact` with `AdjectiveSensitivity::Secret` attached to a `Normal`-sensitivity drawer.
- A recall that asserts the secret fact is NOT returned under `Normal` clearance.
- A recall with elevated clearance that asserts the secret fact IS returned.
This proves the clamp gates at the fact level, not only the drawer level.

**C-5. DiaryEntry sensitivity axis decision**
Before the clamp mission closes, the team must document whether `DiaryEntry` intentionally carries no sensitivity axis. If diary entries can contain above-clearance content (e.g., an agent recording observations about a secret drawer), the absence is a structural gap. The decision must appear in a decision doc (`docs/decisions/`). The clamp mission cannot close this gap mechanically; it must document the design intent.

---

## 5. Cache Prerequisite Finding

**Question:** Is the post-clamp posture cache-ready for a future PersistenceKit RAM row-cache?

**Current posture:** NOT cache-ready.

**Why:** A PersistenceKit RAM cache is safe only if every egress path gates above the cache. The cache would hold raw rows (including above-clearance rows) and serve them to any reader. If the gate is in the `BitmapEvaluator` (as today), a cache sitting below `BitmapEvaluator` but above raw storage would serve pre-gated results only for the drawer path. The five noun-specific paths (B–E) currently have no gate; a cache serving those paths would expose above-clearance rows.

**What must close before a RAM cache is safe:**

1. The DrawerStoreCore clamp must gate ALL egress paths (Paths B–E included), not just the drawer path. Only then does "every egress gates above the cache" hold.
2. The federation push gate (Path G) must be in place. A cache that accelerates federation pushes would otherwise serve raw rows to peers.
3. The VectorKit `vectors` table must carry `adjective_bitmap` or use a post-filter against a gated drawer lookup. A vector cache without this would serve proximity relationships for above-clearance rows.

**Cache readiness verdict:** After the clamp lands and the blocking federation finding is resolved, the drawer path and noun-scoped paths will be cache-ready. VectorKit will not be cache-ready until the inference leak is resolved. The matrix tier is not cache-relevant (it does not serve rows). DiaryEntry is cache-safe (no sensitivity axis; scope is agent-scoped only).

**Cache design requirement (for future implementer):** The cache must hold raw rows below every gate, and must evict on write (a write that changes a row's sensitivity level must invalidate cached reads for that row). The gate must run above the cache on every egress, not inline in the cache lookup.

---

## 6. Consolidated Gap List

| # | Path | Status | Mission scope |
|---|---|---|---|
| G1 | Noun-scoped reads (kg_facts, proposals, associations, learned_refs) | UNGATED | THIS MISSION — must adopt clamp |
| G2 | Federation push — no exportability/sensitivity gate | UNGATED — BLOCKING | THIS MISSION — pre-condition to merge |
| G3 | VectorKit find_nearest — no sensitivity axis in vectors table | INFERENCE LEAK — Advisory | Follow-on (not MCP-reachable today) |
| G4 | CorpusKit chunks — no sensitivity axis, source not linked | Advisory | Follow-on or architecture decision |
| G5 | MatrixTier — folds raw audit log, fold-from-recall rule not enforced | Advisory | Follow-on (no external egress today) |
| G6 | DiaryEntry — no sensitivity axis, design intent undocumented | Advisory | Decision doc required before close |

---

## 7. Verdict

**BLOCKING — G2 (federation push) must be resolved before the mission merges.**

The noun-specific scoped reads (G1) are the primary structural work of the clamp mission. They are ungated today but not currently exposed via live MCP tools (the coordinator stubs return `NotSupportedByEstate`). They must be clamped before those stubs are promoted to live handlers.

The federation push (G2) is live code, reachable today, with no clearance gate. It will ship Private and Secret rows to federation peers without inspection. This is a direct violation of the SECURITY.md guarantee. BLOCKING.

VectorKit, CorpusKit, and MatrixTier findings are advisory. None are MCP-reachable or externally exposed today. They must be addressed before the respective surfaces gain live external egress.

The gate is not universal today and will not be universal after the clamp unless G2 is resolved in this mission.
