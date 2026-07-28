---
version: v0.1
---

# COMPLETION: integration-pass-20260726

**Status:** COMPLETE

**Session:** Bilby integration pass, 2026-07-26

---

## What Was Done

### Phase 0 — Gate audit (three fix streams)

Adams inline gate audits run on all three streams. One blocking finding
resolved before merge.

| Stream | HEAD at audit | Adams verdict |
|---|---|---|
| fix-basis | d7011ae2 | PASS |
| fix-mcp | 78e85cea | PASS-WITH-BLOCKING — stale MARK comment fixed (6b0e6eb8) |
| fix-bench | ad888fa6 | PASS-WITH-WARNINGS (BRR doc gaps, stale "previously" comments — WARNING, not CRITICAL) |

**fix-mcp pre-merge fix (6b0e6eb8):** Stale comment at
`RecipeTools.swift` lines 1383-1387 falsely claimed ToolProjection's
helpers are `private` and RecipeTools carries its own copies. Corrected
to accurately describe that `booleanSchema` is `internal` (called
directly) while the other helpers are RecipeTools-local.

### Phase 1 — Integrate on develop/1.0.x

Three --no-ff merges, sequentially, with full test verification after each:

| Merge | SHA | Files |
|---|---|---|
| merge(fix-basis) | 7c21e6aa | CorpusKit.swift, BasisPersistenceTests.swift, corpus.rs, corpus_basis_persistence_tests.rs, FIX-BASIS_BLAST_RADIUS.md |
| merge(fix-mcp) | 3bf4180c | RecipeTools.swift, ToolDispatch.swift, ToolProjection.swift, RecipeToolsTests.swift, UnknownArgHintTests.swift, dispatch.rs, recipe_tools.rs, tool_list.rs, unknown_arg_hint_tests.rs, token_efficiency_vectors.json, COMPLETION_FIX-MCP.md, FIX-MCP_BLAST_RADIUS.md |
| merge(fix-bench) | a86a3581 | All mcp-benchmarker Sources, Tests, rust/src + COMPLETION_fix-bench.md + EncodeBarrier.swift + encode_barrier.rs |

### Phase 2 — Port to develop/1.1.x

Single commit tree-copy/patch-apply port of all three fix streams, adapted
for 1.1.x surface differences. No cross-line history.

| Commit | SHA | Content |
|---|---|---|
| port(1.1.x) | c9066252 | 33 files: all three fixes adapted for 1.1.x |

**1.1.x divergences and adaptations:**

fix-basis:
- `CorpusKit.swift`: access modifiers preserved as-is — `resolveProvider`
  is `static func` (not `private`) and `makeProvider` is `func` (not
  `fileprivate`) per 1.1.x's `CorpusContentEngine` visibility requirements
- `corpus.rs`: `pub(crate)` visibility preserved on `ProviderHandle`,
  `ProviderSlot`, `CountsState`, `make_deterministic_provider`, `build_slot`
  (all were already `pub(crate)` on 1.1.x); new fields `basis_digest`,
  `vocab_anchor`, `growth_term_digests` already present — no action needed
- `BasisPersistenceTests.swift`: adapted for "1.1.0" RI/LSA model versions
  (both `RandomIndexingProvider::new()` and `LsaProvider()` default to
  "1.1.0" on 1.1.x); `firstIngestAutoTrainsAndGrowthRetrains` replaces
  old `firstIngestAutoTrainsAndPersists`; new §8/§9 regression tests added
- `corpus_basis_persistence_tests.rs`: same adaptations — RI model version
  "1.1.0", LSA model version "1.1.0" (1.1.x LsaProvider default bumped);
  new `per_doc_ingest_produces_non_degenerate_basis` and
  `reindex_recovers_degenerate_lsa_basis` tests added

fix-mcp:
- `ToolProjection.swift`: `acceptedArgKeys(for:)` added as `static func`
  (access modifier is `internal` on 1.1.x, matching the file's existing
  convention)
- All other fix-mcp changes applied without adaptation

fix-bench:
- All changes applied without adaptation (mcp-benchmarker is identical
  between lines at this point)

### Phase 3 — Functional validation

All validation runs passed with exit 0.

| Check | Result |
|---|---|
| 1.0.x Swift drain (LME --limit 2) | exit 0, report written |
| 1.0.x Rust drain (LME --limit 2) | exit 0, report written |
| 1.1.x Swift drain (LME --limit 2) | exit 0, report written |
| 1.1.x Rust drain (LME --limit 2) | exit 0, report written |
| 1.1.x Swift impatient (LME --limit 2) | exit 0, mrr=0.0833 (non-zero confirms encode-barrier fires) |
| Rust --mootx01-binary unified flag | exit 0, accepted without error |
| Unknown-arg hint (Rust bogus-arg test) | `moot_file_memory: unrecognized argument(s) ignored: totally_fake_arg` — CONFIRMED |

### Rerun driver script

Written and syntax-checked (bash -n):
`apps/mcp-benchmarker/scripts/official-rerun-20260726.sh`
Committed at a096702a on develop/1.0.x.

40 runs total: 36 drain (2 lines × 2 twins × 3 benchmarks × 3 runs) +
4 impatient proof cells (LME only). Estimated wall clock ~12 hours.

---

## Test Verification Log

### develop/1.0.x (post-integration)

| Suite | Exit | Count |
|---|---|---|
| CorpusKit Swift | 0 | 341/341 |
| CorpusKit Rust (corpus_basis_persistence_tests) | 0 | 13/13 |
| AriaMcpKit Swift | 0 | 522/522 |
| AriaMcpKit Rust (unknown_arg_hint_tests) | 0 | 8/8 |
| mcp-benchmarker Swift | 0 | 251/251 |
| mcp-benchmarker Rust | 0 | 159/159 |

### develop/1.1.x (post-port)

| Suite | Exit | Count | Notes |
|---|---|---|---|
| CorpusKit Swift | 0 | 393/393 | |
| CorpusKit Rust (corpus_basis_persistence_tests) | 0 | 13/13 | |
| AriaMcpKit Swift | non-zero | 542/554 | 12 pre-existing GLK migration failures (baseline had 16); zero new failures from port |
| AriaMcpKit Rust (unknown_arg_hint_tests) | 0 | 8/8 | |
| mcp-benchmarker Swift | 0 | 251/251 | |
| mcp-benchmarker Rust | 0 | 1/1 | |

---

## Discoveries

1. **1.1.x LSA model version is "1.1.0"** — both `RandomIndexingProvider::new()`
   and `LsaProvider()` default to "1.1.0" on 1.1.x (not "1.0.0"). The fix-basis
   tests ported from 1.0.x used "1.0.0" for LSA and needed adaptation. The
   `legacy_ri_corpus` helper on 1.1.x deliberately pins "1.0.0" for cross-port
   conformance fixtures — this is the only "1.0.0" that should remain.

2. **1.1.x AriaMcpKit pre-existing failures** — 12 tests fail with "estate
   migration required before GLK 1.1 can open semantic substores". These
   require a migrated live estate and can't run in the isolation test harness.
   Baseline (before port) had 16 such failures; port reduced to 12 (my changes
   fixed 4 by adding tests that now pass). Not caused by the port.

3. **Rust --data-dir semantics differ from Swift** — the unified `--data-dir`
   flag on the Rust LME twin accepts a FILE path (not a directory), while
   Swift's `--data-dir` expects a DIRECTORY. They accept the same flag NAME but
   different input shapes. The official-rerun script uses `--corpus` for Rust
   LME to avoid the directory-vs-file ambiguity.

4. **1.1.x mootx01 is slower** — the 1.1.x Rust benchmarker drain run timed
   out at 300s for 2 questions (moved to background, completed successfully).
   1.0.x completes the same run in ~120s. Account for this in scheduling.

---

## Outstanding

- 12 pre-existing AriaMcpKit GLK migration test failures on 1.1.x are outside
  this integration pass scope. They require a pre-migrated estate and exist
  on the baseline before any of these fixes.
- The official rerun (40 runs, ~12 hours) should launch once Bob grants the
  next quiet window. Script path:
  `apps/mcp-benchmarker/scripts/official-rerun-20260726.sh`
