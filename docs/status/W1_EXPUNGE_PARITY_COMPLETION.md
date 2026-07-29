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

## Addendum fix: integrity sweep distillation lane scrub (`660e4599`)

The finding deferred at original completion was approved for immediate fix.
Both `runExpungeIntegritySweep` (Swift, `VerbSurface.swift`) and
`run_expunge_integrity_sweep` (Rust, `coordinator.rs`) were missing
`deleteAllVectors(id, distillation-features-v1)` in the crash-window re-delete
step. An orphaned structural fingerprint in the distillation lane leaked a
content-derived signature past the destruction contract
(SPEC_DISTILLATION_STORAGE §7.2/§8).

Fix applied to both legs: distillation lane delete added BEFORE the corpus-model
lane delete, UNCONDITIONAL on corpus presence — matching the ordering already
present in the main expunge path (landed in Fix 2 above).

**S4 test added to both suites:**
`sweepRemediatesOrphanedDistillationLaneEntry` (Swift) /
`s4_sweep_remediates_orphaned_distillation_lane_entry` (Rust)
— distill drawer → crash-window → assert lane entry exists → sweep → assert
lane entry gone + remediated_count == 1.

---

## Test results

| Suite | Baseline | Final | Delta |
|-------|----------|-------|-------|
| GLK Swift | 637 | 638 | +1 (S4 sweep test) |
| GLK Rust (`cargo test --all`) | 450 | 453 | +3 (E9, E10, S4) |
| LocusKit Rust (`cargo test --all`) | 896 | 897 | +1 (gate-reject conformance) |

Final run (addendum): GLK Swift 638 passed / 0 failed; GLK Rust all ok / 0 failed.

---

## Conformance results

Test harness: manual verification against Swift contract (no cross-language
vector test harness exists for this mission scope).

**Bitmap verification:** No bitmap accessors or bitmap columns were modified.

**Reference cross-check:**
- Reference files read: `DrawerStore.swift` (lines 1411–1424 gate-reject branch),
  `VerbSurface.swift` (lines 739–780 lineage fan-out, 755–770 distillation lane)
- Cookbook sections: §B-2a (expunge ordering), §9.5 S-3 rule, SPEC_DISTILLATION_STORAGE §7.2/§8
- Deviations from reference: none — Rust behavior now matches Swift exactly

---

## Files modified

| File | Change |
|------|--------|
| `packages/kits/LocusKit/rust/src/drawer_store_inmemory.rs` | Fix gate-reject branch: zero content + clear representation |
| `packages/kits/LocusKit/rust/tests/drawer_store_sqlite.rs` | Add gate-reject conformance test |
| `packages/kits/GeniusLocusKit/rust/src/coordinator.rs` | Add lineage_chain fan-out in step 2; add distillation lane scrub in sweep re-delete |
| `packages/kits/GeniusLocusKit/rust/tests/expunge_vector_orphan.rs` | Add E9 + E10 parity tests; update header |
| `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Verbs/VerbSurface.swift` | Add distillation lane scrub to sweep re-delete |
| `packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/ExpungeIntegritySweepTests.swift` | Add S4 sweep distillation lane test |
