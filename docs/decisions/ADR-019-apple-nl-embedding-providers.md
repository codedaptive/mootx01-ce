---
status: decided
question: "Should CorpusKit expose Apple NaturalLanguage embedding providers (NLEmbedding and NLContextualEmbedding) as additional opt-in lanes alongside the existing CoreML and distributional providers?"
authors: MOOTx01 maintainers
date: 2026-06-24
relates_to:
  - docs/decisions/DECISION_EMBEDDING_INFERENCE_SEAM_2026-06-12.md
  - docs/decisions/ADR-010-honest-fusion-recall-and-steering.md
  - docs/reference/CORPUSKIT_SPEC.md
  - docs/reference/CORPUSKIT_INTERFACE.md
supersedes: none
context:
  - DECISION_EMBEDDING_INFERENCE_SEAM_2026-06-12 chose CoreML as the Apple local embedding path and established the encoder lane as additive (never a swap). The three CoreML slots (miniLM/mpNet/embeddingGemma) are unfed — every shipped path runs the deterministic FloatSimHash provider.
  - Apple NaturalLanguage (NLEmbedding / NLContextualEmbedding) provides on-device semantic embedding without requiring a bundled CoreML model file. Both are system framework APIs — already present on macOS 12+/iOS 15+ — and are therefore a zero-dependency path to a real semantic lane.
  - The existing .nlTagger novel-token divergence in FDCProvider already establishes the sanctioned pattern for Apple-system-framework Swift-only code: gate with #if canImport(NaturalLanguage), no Rust counterpart, parity held by the classical (deterministic) providers.
---

# ADR-019: Apple NaturalLanguage Embedding Providers

## Context

`DECISION_EMBEDDING_INFERENCE_SEAM_2026-06-12` established that the encoder lane
is a selectable signal family, not a single baked-in model. It chose CoreML as the
Apple local embedding path (`.miniLM`, `.mpNet`, `.embeddingGemma` slots) but
deferred the real model to v1.1. The slots exist and are structurally correct; they
are simply unfed today.

Apple `NaturalLanguage` provides two embedding APIs that do not require a bundled
CoreML model file:

1. **`NLEmbedding.sentenceEmbedding(for:)`** — OS-bundled sentence similarity model
   (word-vector + sentence-level pooling). Available macOS 12+/iOS 15+. No download
   required. Lower quality; always immediately available.

2. **`NLContextualEmbedding`** — on-device transformer model that produces contextual
   per-token representations, mean-pooled to a sentence embedding. Available
   macOS 13+/iOS 16+. Requires a per-language downloadable asset; may not be
   present on first use.

Both are Apple system framework APIs. `DECISION_EMBEDDING_INFERENCE_SEAM_2026-06-12`
specified that Apple adapters are the Apple-platform path; it was silent on
`NaturalLanguage` as an embedding source (only specifying CoreML). This ADR adds
them as ADDITIVE opt-in lanes, not replacing the CoreML slots.

## Decision

Add two new `EmbeddingProvider` conformers to `CorpusKitProviders`
and two new `EmbeddingModel` cases, gated `#if canImport(NaturalLanguage)`:

1. **`NLEmbeddingProvider`** / **`.nlEmbedding`**
   - model_id: `"apple-nlembedding-v1"`, version: `"1.0.0"`
   - projection seed: `0x4150_4E4C_454D_4231` ("APNLEMB1")
   - Float lane: `NLEmbedding.vector(for:)` cast to `[Float]`, L2-normalised
   - Absent lane: when OS has no model for the language, `embedFloat` returns `[]`
     (standard opt-out contract — no crash, no throw)

2. **`NLContextualEmbeddingProvider`** / **`.nlContextualEmbedding`**
   - model_id: `"apple-nlcontextual-v1"`, version: `"1.0.0"`
   - projection seed: `0x4150_4E4C_4354_5831` ("APNLCTX1")
   - Float lane: `NLContextualEmbedding.embeddingResult(for:language:)`, token
     vectors mean-pooled, L2-normalised via `FloatVecOps.l2Normalize`
   - Absent lane: when the asset is not downloaded or the language is unsupported,
     `embedFloat` returns `[]` — never blocks on a download, never throws

**Both providers are item-local:** the vector is a pure function of the input text,
computed once on write. No trainable basis, no counts, no shadow-swap machinery.
They do NOT conform to `TrainableEmbeddingBasis`. They sit in the same category as
`FDCProvider` — stateless, compute-once-on-write.

**Neither joins the default ensemble.** `CorpusEnsemble.defaultEnsemble()` remains
the five distributional/FDC signals (RI/PPMI/LSA/NMF/FDC). The NL cases are
strictly opt-in: a caller constructs the provider and passes it as
`.nlEmbedding(provider:)` or `.nlContextualEmbedding(provider:)`.

## Sanctioned Swift/Rust Divergence

`NaturalLanguage` is an Apple system framework — the same class as Metal in
`SubstrateLib`. The "zero external Swift package dependencies" rule is about
third-party packages, not Apple system frameworks. Rust has no counterpart to
`NLEmbedding` / `NLContextualEmbedding`, and that is correct: Rust targets
Windows/Linux (x86_64/aarch64), not Apple platforms.

The divergence is gated `#if canImport(NaturalLanguage)` in:
- `CorpusKitProviders/NLEmbeddingProvider.swift`
- `CorpusKitProviders/NLContextualEmbeddingProvider.swift`
- `CorpusKit/CorpusKit.swift` (the two `EmbeddingModel` cases)

This is the SAME mechanism already established for the `.nlTagger` novel-token
fallback in `FDCProvider`. Cross-port parity is preserved because the conformance
baseline (SPEC invariant I-7) is the classical deterministic providers — not the
NL lanes, which are platform-specific enhancements.

## Storage (no schema change)

The `vectors` table keys by `model_id`. Each provider is a new `model_id` partition
(`apple-nlembedding-v1`, `apple-nlcontextual-v1`). Swift writes these rows; Rust has
none. The schema is identical on both ports; only the data differs by platform. No
new column, no adjacent table.

## Recall integration

Both providers conform to `EmbeddingProvider` and integrate with the
fusion/scoring layer like any other lane. The present/absent lane handling
(`FloatLaneOutcome.unavailableProviderOptOut`) already exists and covers the NL
absent-asset case correctly. No recall-layer changes required.

## Relationship to DECISION_EMBEDDING_INFERENCE_SEAM_2026-06-12

This ADR ADDS providers alongside (not replacing) the CoreML slots. The seam
decision's key properties are preserved:

- Encoding is additive, never a swap (ADR principle retained).
- Both providers are text-in (the seam contract).
- Provenance is stored with every vector via the `model_id` (invariant I-4).
- No cross-space comparison: NL providers key to their own `model_id` partitions,
  isolated from CoreML, deterministic, and distributional vectors.

The CoreML slots remain the "bring-your-own-bundled-model" path; the NL providers
are the "cheap, immediate" Apple-native path. They coexist; ADR-010 already
establishes the encoder lane as additive.

## Rejected alternatives

- **Add these providers to the default ensemble.** Rejected: the NL providers
  are Apple-only. A default ensemble change would make the default differ between
  Apple and Rust builds — asymmetric defaults are a source of cross-port surprises.
  Opt-in preserves symmetric defaults while making the Apple enhancement available.
- **Proactively download the contextual asset from inside embed calls.** Rejected:
  network fetches as a side effect of embed are not acceptable. Asset management
  is the host app's responsibility. The provider opts out gracefully when the asset
  is absent.

## Status

**Decided** (2026-06-24). Implemented in this commit; tests verified green at
310 tests (baseline 284, delta +26).

## Changelog

- **1.0.0 (2026-06-24)** — Initial decision.
