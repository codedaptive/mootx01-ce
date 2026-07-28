---
version: v0.1
---

# W1_EXPUNGE_PARITY Completion Report

**Mission:** Bring Rust expunge to parity with Swift — fix the gate-rejected
sibling content scrub in LocusKit storage layer and add GLK coordinator lineage
fan-out for cross-kit vector deletes.

**Stream:** `stream/w1-expunge-parity`
**Worktree:** `/Users/bob/devlop/mootx01-ce-w1-expunge-parity`
**Blast Radius commit:** `51ed0918`
**Fix 1 commit:** `d415d30d`
**Fix 2 commit:** `6495185b`

---

## Divergences fixed

### Fix 1 — LocusKit gate-reject branch (`d415d30d`)

**File:** `packages/kits/LocusKit/rust/src/drawer_store_inmemory.rs`

`DrawerStoreCore::expunge_gated` was silently skipping the content and
representation scrub when a lineage sibling's tombstone gate rejects (S-3:
Accepted → Tombstoned is forbidden). This violated the destruction contract
(secfix/ws2-coredelete): verbatim content MUST be zeroed unconditionally
even when the state machine refuses the transition.

The gate-reject `else` branch now:
- Zeroes `content` (empty string)
- NULLs all four distilled representation columns via `insert_cleared_representation`
- Refreshes `content_fingerprint`
- Preserves `adjectiveBitmap` / state (gate rejection stands)

Mirrors Swift `DrawerStore.expungeGated` lines 1411–1424.

**Conformance test added** (`packages/kits/LocusKit/rust/tests/drawer_store_sqlite.rs`):
`expunge_gate_rejected_sibling_content_and_representation_zeroed`
— D1 promoted to Accepted with all four representation columns populated;
D2 added to same lineage (D1 NOT superseded: Accepted g_state_cluster=3 is
NOT < 3); expunge(D2) exercises gate-reject branch on D1; asserts
D1.content == "" + four distilled columns NULL + D1.state remains Accepted.

### Fix 2 — GLK coordinator lineage fan-out (`6495185b`)

**File:** `packages/kits/GeniusLocusKit/rust/src/coordinator.rs`

`EstateCoordinator::expunge` step 2 was calling `corpus.remove_content` and
`vs.delete_all_vectors` only for `row_id` (the head). Swift's
`VerbSurface.expunge` calls `estate.lineageChain(for: frame.rowID)` and fans
the delete over ALL lineage members. Predecessor versions' Corpus BM25 entries
and VectorStore entries (semantic embeddings, distillation-features-v1 lane
fingerprints) survived an expunge, leaking content-derived representations.

Fix: resolve `estate.lineage_chain(row_id)` before the step-2 closure; loop
over all IDs. Fallback to `[row_id]` when chain is empty (no lineageID or row
not found), matching Swift's `lineageIds.isEmpty ? [frame.rowID] : lineageIds`.

**Parity tests added** (`packages/kits/GeniusLocusKit/rust/tests/expunge_vector_orphan.rs`):

- `e9_expunge_of_undistilled_drawer_is_no_op_for_lane` — E9 parity with Swift
  `expungeOfUndistilledDrawerSucceeds`: no lane entry, expunge succeeds,
  drawer is tombstoned.

- `e10_expunge_scrubs_lane_entries_across_lineage` — E10 parity with Swift
  `expungeScrubsLaneEntriesAcrossLineage`: v1 (Superseded) and v2 (Active)
  both distilled; expunge(v2) fans out over lineage; both lane entries gone.

---

## Finding: integrity sweep missing distillation lane scrub (both Swift + Rust)

Both `runExpungeIntegritySweep` (Swift) and `run_expunge_integrity_sweep`
(Rust) are missing the distillation lane scrub in the re-delete step. They are
in parity — both equally miss it. This is NOT a twin divergence. Fix requires
adding `delete_all_vectors(row_id, distillation_lane_model_id)` to BOTH sweeps
in a follow-up mission. Deferred.

---

## Test results

| Suite | Baseline | Final | Delta |
|-------|----------|-------|-------|
| GLK Swift | 637 | 637 | 0 (no Swift code modified) |
| GLK Rust (`cargo test --all`) | 450 | 452 | +2 (E9, E10) |
| LocusKit Rust (`cargo test --all`) | 896 | 897 | +1 (gate-reject conformance) |

All suites: 0 failed, 0 ignored.

---

## Conformance results

Test harness: manual verification against Swift contract (no cross-language
vector test harness exists for this mission scope).

**Bitmap verification:** No bitmap accessors or bitmap columns were modified.

**Reference cross-check:**
- Reference files read: `DrawerStore.swift` (lines 1411–1424 gate-reject branch),
  `VerbSurface.swift` (lines 739–780 lineage fan-out)
- Cookbook sections: §B-2a (expunge ordering), §9.5 S-3 rule
- Deviations from reference: none — Rust behavior now matches Swift exactly

---

## Files modified

| File | Change |
|------|--------|
| `packages/kits/LocusKit/rust/src/drawer_store_inmemory.rs` | Fix gate-reject branch: zero content + clear representation |
| `packages/kits/LocusKit/rust/tests/drawer_store_sqlite.rs` | Add gate-reject conformance test |
| `packages/kits/GeniusLocusKit/rust/src/coordinator.rs` | Add lineage_chain fan-out in step 2 |
| `packages/kits/GeniusLocusKit/rust/tests/expunge_vector_orphan.rs` | Add E9 + E10 parity tests; update header |
