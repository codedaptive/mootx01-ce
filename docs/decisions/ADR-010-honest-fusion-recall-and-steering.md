---
status: decided
question: How does semantic recall deliver meaning-based retrieval honestly before a learned embedding model exists, and how is recall steered through ARIA without leaking mechanism into the grammar?
authors: MOOTx01 maintainers
date: 2026-06-16
relates_to:
  - docs/reference/CORPUSKIT_SPEC.md
  - docs/reference/VECTORKIT_SPEC.md
  - docs/reference/GENIUSLOCUSKIT_SPEC.md
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
  - docs/reference/ARIA_MCP_SPEC.md
supersedes: none
context:
  - The dense/vector lane currently runs the `.deterministic` FloatSimHash hash projection, which CorpusKit SPEC §9.2 declares "suitable for tests and offline contexts; not for semantic retrieval," yet `recall_provenance` reports `dense_lane:active`. That is a silent semantic claim — a clean paraphrase query (zero shared tokens) matches nothing while the lane claims to be live.
  - No learned embedding model is wired on any port (MLX is Apple-only; no ONNX/candle runtime on Rust). VectorKit SPEC §5 B-12 already says a provider with no real float vector must opt out (throw `embeddingFailed`) rather than return "a silently-wrong projection."
  - The goal is *what* recall does (retrieve by meaning), not *how*. The substrate already computes honest meaning-bearing signals: FDC lattice classification, and SubstrateML has NMF. RecallDirector already fuses lanes with RRF.
---

# ADR-010 — Honest classical-fusion semantic recall + ARIA recall steering

## Context

Semantic recall is the product, but the only "embedding" present is a
deterministic hash (FloatSimHash) that captures surface form, not meaning,
while falsely reporting the dense lane as active. A real learned encoder is
not yet built (parked). The question is two-fold: (1) how to deliver honest
meaning-based retrieval *now*, with the math already in the substrate, and
(2) how the AI steers recall through ARIA without the interface exposing
implementation.

## Decision

### D-1 — The dense/semantic lane is an honest classical fusion

Retire the FloatSimHash float projection as a "semantic" source (it is the one
dishonest option — it models nothing). Drive a meaning-relatedness lane from
honest deterministic signals the substrate can compute:

1. **FDC lattice co-classification** (already computed: HMM tagger → EideticLib →
   FDC code). Drawers near the query's FDC address are topically related.
2. **LSA/LSI** and 3. **Random Indexing** (streaming LSA, suited to a growing
   estate), 4. **NMF** (present in SubstrateML), 5. **PPMI co-occurrence query
   expansion → BM25**.

These are honest *because they genuinely model co-occurrence/topical/categorical
structure*, and they are labelled as classical-distributional — never as a neural
embedding.

### D-2 — Fusion is rank-fusion / ensemble consensus

Combine the per-method ranked lists with RRF (already in RecallDirector), or
CombMNZ-style consensus that rewards a candidate appearing across **diverse**
views. Refinements that are part of this decision: soft consensus (not hard
top-K intersection, which empties out); weight by signal *diversity* (FDC +
distributional + lexical complement each other; three distributional methods ≈
one vote); and **the degree of consensus is itself a confidence score**.

### D-3 — A learned encoder is ADDITIVE later, not a swap

When a real encoder (MiniLM/MPNet/EmbeddingGemma; Apple `NLEmbedding`/CoreML, or
ONNX/candle on Rust) is wired, it registers as **one more selectable provider /
voter** in the same fusion — the strongest single signal, but the ensemble of
classical + neural beats neural-alone (catches what the encoder misses, supplies
consensus confidence, and stays robust where no inference runtime exists). A
cross-encoder **reranker** over the fused top-K is the optional ceiling above it.
The real-model selection is out of scope here (parked; separate ADR).

### D-4 — The quality optimizer owns the fusion weights

Which signals to include and how much each is worth is learned by the
ablation/combination optimizer on the real corpus, not hand-fixed. New providers
(the encoder) join as additional candidates for the optimizer to weight.

### D-5 — Recall steering through ARIA = "Option D": goal and effort, never mechanism

- **Methods**: baked into RecallDirector, hidden, optimizer-owned. The AI never
  selects the math.
- **Intent** (precise / associative / deep): expressed through the existing
  **recipes** (`list_recipes`) — named, optimizer-tuned pipelines.
- **Effort**: a bounded, monotone **`tier`** adjective on the recall verb
  (`fast` / `standard` / `deep`) — an AI-overridable hint with a sane auto
  default. `fast` = BM25 + FDC; `standard` = + distributional fusion; `deep` =
  wider candidate pool + reranker. ARIA stays one verb + adjectives.

## Consequences

- `recall_provenance` must report the dense semantic lane honestly: classical
  fusion when that is what ran, the contributing signals, and a confidence
  derived from consensus — never `dense_lane:active` for a bare hash.
- RecallDirector gains the classical-signal providers and the `tier` parameter;
  GLKRecallRequest carries `tier`; ARIA_MCP recall tools accept it.
- Spec updates required (per VERSIONING §5): CORPUSKIT_SPEC / VECTORKIT_SPEC
  (provider/lane semantics + opt-out), GENIUSLOCUSKIT_SPEC (RecallDirector fusion
  + `tier`), ARIA_MCP_SPEC (recall `tier` adjective), each with a version bump +
  changelog.

## Alternatives considered

- **Expose recall methods as AI-selectable modes** — rejected: the AI would guess
  weights the optimizer already tuned, and it bloats the ARIA grammar.
- **Bake everything, no steering** — rejected: the AI legitimately knows intent
  and effort the system cannot infer (throwaway lookup vs critical research).
- **Keep FloatSimHash but relabel it honestly** — rejected: it still injects
  non-semantic ranking noise; an honest classical fusion both removes the noise
  and delivers real relatedness.
- **Go fully dark until a learned model exists** — rejected once it was clear the
  substrate already computes honest meaning signals (FDC, NMF); dark would
  needlessly discard real retrieval capability.

## Changelog

- 2026-06-16 — v1.0.0 — Initial decision (D-1…D-5). Implementation tracked as the
  recall-fusion follow-on; the capture→encode→index wiring it depends on is a
  separate prerequisite fix (VaultKit import → `capture(mode:.regular)` +
  reindex).
