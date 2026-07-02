---
status: decided
question: How should the LSA and NMF distributional embedding providers scale their basis training to real-world corpora (tens of thousands of distinct terms) so that a reindex/retrain does not hang in a computationally-infeasible dense factorization over the full vocabulary?
authors: MOOTx01 maintainers
date: 2026-07-01
relates_to:
  - docs/decisions/ADR-019-apple-nl-embedding-providers.md
  - docs/decisions/ADR-021-recall-driven-dreaming-queue.md
  - docs/reference/CORPUSKIT_SPEC.md
supersedes: none
context:
  - Discovered on a 38k-drawer MemPalace import: the post-import drain pegs one core in JacobiSVD/JacobiSvd and never converges. Root cause is LSA/NMF building a DENSE term-document matrix over the FULL vocabulary (~29k distinct terms), making a fixed-sweep dense factorization ≈10^15 ops — infeasible.
  - Affects both dense-factorization providers (LSA via SVD, NMF via ALS); RI (random projection), PPMI (windowed co-occurrence), and FDC (stateless) already scale and are unchanged.
  - Changes which columns LSA/NMF factor and adds a stored reduced-vocab artifact; it does NOT change the fixed-sweep Jacobi/ALS kernels (cross-port bit-identity preserved), only the size of the matrix fed to them.
  - No change to the drawer/LocusKit authoritative store; this is entirely the CorpusKit RAG-accelerator layer.
---

# ADR-022 — LSA/NMF reduced-vocabulary scaling (cap + defer + shared reduced vocab)

## Question

LSA and NMF are two of the five default recall signals (RI / PPMI / LSA / NMF / FDC).
Both build a **dense** term-document matrix over the **full** corpus vocabulary and
factor it (SVD for LSA, ALS for NMF). On a real corpus the vocabulary is tens of
thousands of distinct terms, so the fixed-30-sweep dense factorization is ~10^15 ops
— it never finishes, and because the dreaming daemon runs the retrain synchronously,
the whole encode drain hangs and `moot_drain_status` starves.

How do we make LSA/NMF training scale without breaking their cross-port
bit-identity or their recall contribution?

## Decision

**Train LSA and NMF over a stored, shared, IDF-reduced vocabulary — computed once per
reindex, frozen with the basis — and defer the retrain to one reindex at the end of a
bulk import.**

1. **Reduced vocabulary (cap).** A reindex first computes a **top-K reduced
   vocabulary** by informativeness (IDF / IDF-mass, excluding stopword-low and
   df=1-noise bands) from the full maintained counts, and **stores it** as an ordered
   term→column map. LSA/NMF factor the `docs × K` matrix instead of `docs × full-vocab`.
   Capping K (target ~1–3k) drops the factorization from ~10^15 into the
   seconds-to-minutes range.

2. **Shared across LSA and NMF (default).** The reduced-vocab **selection is computed
   once and shared** by both providers. Term informativeness is a property of the
   corpus, not of the factorization method; LSA↔NMF vectors are never compared, so
   nothing forces a split. Each provider still builds its **own matrix** over that
   shared vocab (LSA: signed TF-IDF `docs × terms`; NMF: non-negative `terms × docs`),
   and the selection **method + K remain optimizer-parameterized** so the quality
   gauntlet may diverge them later with evidence (ablate-don't-guess). Default: shared.

3. **Stored, not recomputed at use.** The reduced vocab is part of the **frozen model**
   (`basis + reduced-vocab-map`), regenerated together at reindex and **read-only
   between**. A single-record add / query **projects onto the frozen basis using the
   stored map** — it never re-ranks or re-selects. Recomputing from live (drifting)
   counts would misalign the projection with the frozen basis and silently corrupt
   embeddings. This is a correctness requirement, not an optimization.

4. **Defer during bulk import.** A bulk import (palace / vault) **suppresses the
   auto-reindex while draining** and triggers **exactly one** reindex at completion,
   rather than letting the vocab-drift probe fire the expensive retrain repeatedly
   mid-drain (the sprint's deferred-index pattern, applied to provider training).

5. **Rebuild = select + refactor + re-embed all.** A reindex re-selects the reduced
   vocab, re-factors LSA and NMF, **and re-embeds every drawer** into the new space
   (the new vocab/basis is a new coordinate system; old item vectors are stale). The
   re-embed is O(N), parallelized via the existing cap-worker fan-out.

6. **RI / PPMI / FDC unchanged.** RI (per-term FNV random projection) is vocab-free and
   is the scalable catch-all that covers terms outside the LSA/NMF reduced vocab (OOV)
   between reindexes. PPMI is windowed; FDC is stateless. None participate in the cap.

## Rationale

- **The factorization is non-incremental.** SVD/NMF bases cannot be updated by folding
  in a term/doc (every singular vector moves), which is exactly why LSA/NMF need a
  periodic bulk rebuild while RI/PPMI fold in. So the lever is to make the rebuild
  **cheap (cap)**, not incremental — the math forbids incrementalizing it.
- **RI already provides the scalable full-vocab dense lane.** LSA/NMF are refinement
  votes (2 of ~8 fusion lanes); recall degrades gracefully to RI+PPMI+FDC+BM25 if
  they're capped or absent. So aggressive capping is safe.
- **Capping aligns with documented intent.** `DefaultEnsemble` already documents LSA as
  "truncated SVD"; the full-vocab matrix was the drift, not the design.
- **Bit-identity preserved.** The fixed-sweep Jacobi/ALS kernels in SubstrateML are
  unchanged; only the input matrix is smaller. The reduced-vocab selection is
  deterministic (stable IDF ranking with a documented tie-break), so cross-port
  conformance holds.

## Consequences

- **Storage:** adds a stored reduced-vocab (term→column map) per estate, frozen with
  the basis (a small table or the `ext` BLOB on `corpus_provider_basis`; a few thousand
  entries). No change to authoritative drawer/LocusKit tables.
- **Recall quality:** LSA/NMF see only the top-K informative terms; rare terms are OOV
  for them (covered by RI). Expected net-neutral-to-positive (dropping df=1 noise).
- **Conformance:** the reduced-vocab selection needs its own canonical test vectors
  (deterministic top-K, Swift == Rust); the factorization kernels' vectors are unchanged.
- **Scope:** the reduce+store function and the LSA/NMF matrix-build change live in
  CorpusKitProviders (Swift + rust-providers), next to RI; the defer-during-bulk +
  reindex-once wiring is in the import/drain orchestration. The drift trigger, RI, PPMI,
  FDC, BM25, and the drawer store are untouched.
- **Open knobs (optimizer):** K, the selection method (IDF vs IDF-mass vs df-band), and
  whether LSA/NMF ever diverge their vocab — all parameterized, default shared.
