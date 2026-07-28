# MOOTx01 1.0.x vs 1.1.x — benchmark comparison (2026-07-26 → 2026-07-28)

Diagnostic, not publication. 50-question samples, seed 20260725, LongMemEval
variant `s`; scratch estates (plaintext opt-out); background encoding with the
lane-evidence drain barrier; both Swift and Rust harness twins. Lines measured:
develop/1.0.x @ 58cbcb96, develop/1.1.x @ its exact-strategy port commit.

## Headline

1. **Ingest throughput: 1.1.x is ~3× faster.** Full 50-question LME runs
   (ingest + encode + drain + queries): 1.1.x 12–14 min vs 1.0.x 27–38 min.
   The CorpusContentEngine rewrite plus the restored embed fan-out
   (boundedConcurrentMap, stream/fix-fanout) delivers the intended speedup.
   Pre-fix, 1.1.x was ~5× SLOWER (serial drain loop); the fan-out restoration
   plus batched commit/fetch (fix-ingest-tail) reversed it.
2. **LME recall: a real ~0.28 gap against 1.1.x.** After every harness defect
   found this weekend was fixed, 1.0.x scores any@5 0.82–0.92 while 1.1.x
   sits at 0.56–0.62 — twin-agreed, strategy-independent. This is an engine
   difference, not a measurement artifact (see "What was ruled out").
3. **The gap is type-profiled.** 1.1.x failures concentrate in
   temporal-reasoning (7/13 fail) and single-session categories;
   multi-session questions barely suffer (2/14). Investigation lead: the
   wholeContent index unit and temporal/validity handling on chat-turn
   corpora vs 1.0.x's design.

## LongMemEval (any@5 / MRR, 50q)

| Cell | 1.0.x | 1.1.x |
|---|---|---|
| Swift, documented protocol (`auto`) | **0.86** / 0.675 | **0.58** / 0.419 |
| Rust, documented protocol (`auto`) | **0.88** / 0.719 | **0.58** / 0.403 |
| Swift, legacy bare search | 0.92 / 0.718 | 0.56 / 0.420 |
| Rust, legacy bare search | 0.82 / 0.642 | 0.60 / 0.409 |
| Swift impatient (inline encode) | 0.88 / 0.786¹ | — (superseded cells only) |

¹ pre-strategy run; impatient cells for the fixed 1.1.x engine were cut in
favor of the strategy comparison (basis fix is proven by unit regression
tests; re-queue if desired).

`auto` = the program's documented client protocol (ordering:byRelevanceDesc,
escalate to moot_recall_precise on `discrimination: low`). On 1.0.x it tightens
variance around ~0.87; on 1.1.x it changes nothing — 1.1.x failures are not
low-discrimination-flagged, and precise does not rescue them.

## LoCoMo (any@5, 50q, exact-only runner — no consolidation involved)

| Twin | 1.0.x (N=3 mean) | 1.1.x (N=1) |
|---|---|---|
| Swift | 0.240 | 0.140 |
| Rust | 0.207 | 0.160 |

Weak on both lines (open_domain-heavy sample); 1.1.x trails here too.

## LMEB (nDCG@10)

| Twin | 1.0.x (N=3 mean) | 1.1.x (N=1) |
|---|---|---|
| Swift | 0.465 | 0.398 |
| Rust | 0.464 | 0.468 |

Roughly at parity (twin spread on 1.1.x N=1 within noise).

## What was ruled out before calling the LME gap real

Chronologically, each was found, fixed, and the gap persisted:

1. Wrong write key (`"n"` vs `impatient`) silently dropped → unknown-args now
   hint loudly (fix-mcp).
2. Degenerate first-doc basis on inline encode → three-state basis logic,
   both engines (fix-basis, fix-fanout Part 2); proven by regression tests
   and healthy probes.
3. Drain barrier accepting empty/unparseable status as idle → shape parser +
   loud abort (4f2cb650).
4. Premature-idle race (lane not yet registered) → lane-evidence barrier
   (fix-harness).
5. Keychain prompts inflating wall-clocks → plaintext scratch estates
   (fix-harness); throughput numbers re-measured clean.
6. **moot_consolidate contaminating the exact arm** — consolidation subsumes
   source drawers out of default search (probe: answer at rank 2
   pre-consolidate, absent from top-20 after; 330 factoids from 550 turns).
   The runner consolidated before the exact query with arm=both default;
   fixed to exact-first ordering. This was the largest single distortion.
7. Undocumented-protocol querying — bare moot_memory_search is documented as
   broad/time-ordered retrieval; the harness now implements the documented
   client protocol (`--exact-strategy auto`). Improved 1.0.x; no effect on
   1.1.x.
8. JacobiSVD trailing-worker crash under growth retrains (latent since the
   parallel-SVD commit) → one-line guard (203971e9); was killing servers
   mid-run.

Also fixed en route: GLK migration test debt (554/554 now), report
self-documentation fields, tokens-per-result metric (the dense/exact byte
ratio ≈1.0 was format arithmetic, not failed distillation), estate snapshot
cache, twin CLI unification.

## Token efficiency (LME two-arm)

Dense (`moot_recall_distilled`) vs exact payload BYTES ratio ≈ 0.92–1.00 — an
artifact of format asymmetry (300-char factoid prose vs 120-char previews +
per-factoid framing), not of distillation quality. The corrected
tokens-per-result metric shows the structural ~2.5× per-item format cost.
Judge-based accuracy-per-token remains future work (judge hook is wired).

## Limitations

- 50-question samples; single machine; N=1 for most cells (N=3 where noted).
- 1.1.x LoCoMo/LMEB cells are N=1 from the 20260727 run.
- 1.0.x LME run-to-run spread is wide (0.82–0.92 across the weekend's valid
  cells); treat per-cell deltas <0.06 as noise.
- The 30 abstention questions are excluded per upstream methodology.
- LoCoMo/LMEB runners predate the strategy work (bare search only).

## Open product questions (for Bob)

1. **1.1.x LME recall gap** (~0.28, temporal-heavy): needs an engine-level
   investigation (index unit granularity / temporal handling), now cleanly
   reproducible via `--exact-strategy auto` on any 1.1.x scratch estate.
2. **Consolidation semantics**: 330 factoids from 550 chat turns, and
   consolidated originals stop surfacing in default search. Intended?
   (This is also user-visible behavior, independent of benchmarks.)
3. Publication posture: 1.0.x numbers (LME any@5 ~0.87 documented-protocol)
   are the only line fit for external comparison today.

## Artifact index

- 20260728-lme-strategy/ (both lines) — the strategy comparison cells
- 20260728-lme-uncontaminated/ — first post-consolidate-fix cells
- 20260727-invalidated-rerun/ — drain-grid cells (locomo/lmeb valid; LME
  cells superseded by the consolidate fix)
- 20260726-official-rerun/ — overnight quiet grid (1.0.x locomo/lmeb means;
  LME cells superseded)
- docs_internal/findings/FINDING_11X_INGEST_FANOUT_2026-07-27.md — fan-out
  diagnosis (full Kinsta report)
