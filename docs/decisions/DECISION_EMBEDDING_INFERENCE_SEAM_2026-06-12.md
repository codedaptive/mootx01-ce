---
status: decided
version: 1.1.0
question: How does the substrate obtain semantic embeddings — and how do we keep embedding inference a selectable signal family rather than a single baked-in model that collapses the product into fancy RAG?
authors: MOOTx01 maintainers
date: 2026-06-12
relates_to:
  - docs/reference/CORPUSKIT_SPEC.md
  - docs/reference/CORPUSKIT_INTERFACE.md
  - docs/reference/VECTORKIT_SPEC.md
  - docs/decisions/DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.md
supersedes: none
context:
  - Production-construction census (2026-06-12) found every shipped path builds the deterministic embedding provider (FNV→FloatSimHash projection vectors, "not semantically meaningful" per its own doc). No CoreML/MLX/remote model, no real tokenizer, no inference closure is wired in any shipped app including the iOS host. Semantic recall today ranks on hash noise — conformance-grade, not production-grade.
  - The CorpusKit substrate already exposes three model slots (.miniLM/.mpNet/.embeddingGemma), each taking a host-supplied inference closure. The flexibility primitive exists; it is unfed.
  - Binding the product to one fixed embedding model reduces it to a RAG pipeline with extra steps. The differentiator is that embedding is ONE ablatable evidence source inside a multi-signal recall ecology (lexical, structural, temporal, KG, bitmap, trust), and the model itself is a tunable knob the quality optimizer selects over.
---

# Embedding Inference as a Selectable Signal Family

## Context

The motivating question is **not** "pick a model." It is "make embedding
inference a selectable signal family." A single baked-in embedder gives us
one vector space, one notion of similarity, top-k — i.e. fancy RAG. The
substrate's value is that embedding similarity is one evidence source among
many, and *which* embedder(s) contribute, and how heavily, is configuration
the Brain/optimizer layer tunes — not a build constant.

The census
confirmed the substrate is correctly built with a host-injected inference seam,
but every shipped construction path uses the deterministic provider with no
real semantic model wired behind it. The deterministic provider is the permanent
federation-grade vector lane (correct and intended for that role); the gap is
that no *semantic* model is wired. Claiming "semantic recall" to beta users on
the deterministic lane's surface/lexical (hash-projection) vectors would be an
unbacked capability claim.

## Decision

Five decisions are settled and stand on their rationale:

1. **Primary seam is text-in.** The product-wide embedding contract is
   `embed(text: String) async throws -> [Float]` (and batch form). The
   *provider* owns tokenization, because the provider owns the embedding
   space. CorpusKit does not own WordPiece/SentencePiece; forcing it to would
   make every model integration a tokenizer-port project — backwards.

2. **Tokens-in is a provider-private optimization, never the global API.** A
   local bundled provider may internally do `tokenize(text) -> [Int32]` then
   `infer(tokens) -> [Float]`, but that is inside the provider adapter, not the
   product-wide contract. The existing `([Int32]) -> [Float]` slots are
   demoted to an internal implementation detail of token-based adapters.

3. **Embedding choice is an optimizer-selected signal family, not a build
   constant.** Recall may query one or more embedding spaces; recipe/optimizer
   config chooses the weights. Embedding-model choice is ablatable like any
   other recall signal.

4. **No deterministic-only beta semantic claim.** The deterministic provider is
   never silently branded as semantic recall. It is, however, permanent
   federation-grade infrastructure (the byte-identical cross-device/cross-port
   vector lane federation requires) in addition to its conformance/test/offline
   roles — it is not a temporary stand-in. Any surface that presents "recall by
   meaning" must be backed by a real provider, or must not make the claim.

5. **Provider provenance is stored with every vector and shown on recall
   status.** Mismatched embedding spaces are never compared accidentally;
   result envelopes expose which lane/provider produced the ranking.

## The provider contract

CorpusKit exposes a **`TextEmbeddingProvider` registry**. Each provider
declares a descriptor:

| Field | Meaning |
|---|---|
| `providerID` | The adapter (e.g. `coreml.local`, `byo.openai`, `ollama.local`, `deterministic`) |
| `modelID` | The model (e.g. `text-embedding-3-small`, `all-MiniLM-L6-v2`) |
| `embeddingSpaceID` | Identity of the vector space — vectors are only comparable within one `embeddingSpaceID` (composition below) |
| `dimension` | Vector dimension |
| `tokenizerID` | Tokenizer used (provider-internal; recorded for provenance) |
| `version` | Provider/model version, for invalidation |
| `locality` | `local` \| `remote` — does content leave the device? |
| `privacyClass` | Privacy tier of sending content to this provider (gates against entity sensitivity) |

### `embeddingSpaceID` composition

`embeddingSpaceID` is **NOT** `modelID`. Two providers with the same model name
can produce non-comparable vectors. The space identity must encode at least:
**model family + version, tokenizer, runtime/backend, pooling/projection
behaviour, dimension, normalization, and provider-adapter version.** The
controlling rule: **different runtime ⇒ different space.** "all-MiniLM-L6-v2 via
CoreML" and "all-MiniLM-L6-v2 via ONNX" share a `modelID` but are NOT the same
`embeddingSpaceID` — comparing their vectors is silently wrong. This is a
cross-platform federation hazard (an estate synced across an Apple host and a
Windows host could otherwise mix incomparable vectors under one model name), so
the composition is part of the contract, not an implementation detail.

The primary method is `embed(text:) -> [Float]` (plus a batch form). Token-based
adapters implement tokenization internally and never expose it.

## Stored-vector provenance

Stored vectors carry `embeddingSpaceID` (at minimum) plus enough of the
descriptor to (a) refuse cross-space comparison, (b) detect a stale space after
a model/version change, (c) report provenance on recall. This is a schema
expansion — free pre-v1.0 (fresh CREATE, no
migration machinery required, since the schema is unfrozen pre-release and no shipped data exists to migrate). Vectors lacking provenance (today's deterministic
ones) decode as `providerID=deterministic` / a reserved `embeddingSpaceID` so
they are never silently compared against a real space.

## Recall over multiple spaces

Recall can query one or more embedding spaces. The fusion/scoring layer treats
each space as a distinct signal; optimizer/recipe config supplies the weights.
This is the anti-RAG property: embedding similarity is one tunable evidence
source inside the recall ecology, not the system.

## Result envelope status

Every recall result envelope exposes the embedding lane/provider status, one of:
**real-local** (bundled or user local model), **BYO-remote** (user's remote
endpoint), **deterministic** (the permanent federation-grade vector lane —
explicitly NOT semantic, but a designed permanent lane, not a stand-in), or
**unavailable** (no provider configured for the semantic lane). The status
labeling distinguishes the permanent federation-grade deterministic lane from a
genuinely-unavailable semantic lane, so the deterministic status never implies a
degraded state. A beta surface presenting the deterministic lane *as semantic
recall* is a failure; presenting it as the (non-semantic) federation lane is
correct.

## Platform adapters

The seam does not care which runtime produces the vector. Concrete adapters are
chosen **per platform**, and at least one **real local** provider path must
exist for every shipped platform, plus BYO endpoint support:

- **Apple (macOS/iOS):** CoreML local adapter (bundled small model) as the
  zero-config local-first default.
- **Windows/Linux (Rust):** a Rust-compatible local runtime/service adapter.
  The concrete runtime is deliberately NOT pinned here — candidates include
  ONNX Runtime, Candle, a llama.cpp-style local server, or Ollama. The
  architecture says "local embedding adapter"; the blessed concrete runtime is
  an open question (below). **MLX is not the generic Windows/Linux answer** and
  must not be baked into the cross-platform layer (it is Apple-only).
- **Any platform:** BYO remote endpoint adapter (OpenAI/Cohere/Voyage/Ollama/
  local service) — the text-in seam makes this trivial: send text, receive
  vector; tokenization is the endpoint's problem.

## Rejected alternatives

- **Single baked-in model (one CoreML MiniLM everywhere).** Rejected: this is
  the fancy-RAG collapse — one space, one similarity notion, embedding ceases
  to be a tunable signal.
- **Tokens-in as the global contract.** Rejected: makes CorpusKit own
  WordPiece/SentencePiece for every model, turning each integration into a
  tokenizer-port project; backwards relative to who owns the embedding space.
- **Deterministic provider as a silent semantic default.** Rejected: an
  unbacked capability claim. The deterministic provider is never branded as
  semantic recall. It is, however, retained permanently as the federation-grade
  vector lane (byte-identical cross-device/cross-port — the reproducibility
  federation requires), in addition to its conformance/test/offline uses. It is
  not demoted or removed; it simply never makes a semantic-meaning claim.

## Doctrine interactions

- **C-1 zero-external-dependency.** The seam itself stays dependency-free (pure
  Swift/Rust, a closure/trait + descriptors). Concrete adapters that need a
  runtime (ONNX Runtime, Candle, etc.) or a network client are a separate,
  **explicitly-approved-per-crate** concern under
  `DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28` — not granted by this ADR. The
  BYO-remote adapter uses the platform HTTP client, not a new SDK dependency.
- **BYOAI / privacy.** `locality=remote` providers send content text off-device.
  `privacyClass` must gate against entity sensitivity so a `secret`-tier drawer
  is never embedded by a remote provider the user has not authorized for that
  tier. This is a security-review surface (BYOAI threat model, API-key handling).
- **Parity / Windows mandate.** Both ports get the registry, the descriptor, the
  provenance storage, and the text-in seam. The concrete local adapter differs
  per platform (that is the point), but the contract is identical.

## Beta scope: real embedding model is v1.1

The **embedded (real, on-device) embedding model is OUT of beta** — it is
v1.1, **Apple-first** (CoreML down the Apple lane). Beta does **not** require any
real embedding provider on any platform. This supersedes the earlier
"≥1 real provider per platform in beta" recommendation entirely.

**What beta IS (both ports, the one-way-door seam — ships now):**
- `TextEmbeddingProvider` registry, descriptor, **provenance stamping** on every
  vector, **space-aware vector storage**, **compatibility enforcement** (refuse
  cross-`embeddingSpaceID` comparison), and **recall-status surfacing**. These
  are the parts you cannot retrofit once vectors are in the ground, so they ship
  in beta even though no real model does — making v1.1 a clean drop-in
  (register + wire), never a schema migration.
- The **deterministic provider is the beta default, labeled non-semantic.** The
  hard invariant holds absolutely: no surface presents it as semantic. Semantic-
  by-meaning recall surfaces as **unavailable / arrives in v1.1**, never silent
  hash-noise.

**What beta is NOT (→ v1.1):**
- The **real embedding model itself** (CoreML local on Apple first; then the
  Rust/Windows local adapter (open Q1) and/or BYO-remote). This is the "embedded
  LLM" deferred out of beta scope.
- *Automatic* optimizer-learned selection/weighting among multiple active spaces
  (needs real multi-space data that does not exist pre-beta).

**Why beta is still not a fancy RAG without it:** the differentiator is the
recall *ecology* — lexical, structural, temporal fan-out, KG, bitmap, trust,
over a substrate with audit/custody/supersession. Embedding-by-meaning is one
lane, and it arrives in v1.1. Beta ships the other lanes plus the seam that
lets the embedding lane drop in cleanly.

**Both correlated AND dissimilar retrieval are delivered in beta WITHOUT the
embedding** (correcting a RAG-framing error): "generally
correlated" and "dissimilar-for-analysis" are computed from the substrate's own
geometry — **SimHash fingerprints + Hamming distance** (correlated = low Hamming,
dissimilar = high), the **co-occurrence/temporal correlation matrices**, and
**KG/bitmap structure** (contradiction/divergence/drift lenses). These need no
learned model; the math/matrices/bitmaps ARE the correlation engine, and that
engine is the token-offload mechanism. The v1.1 embedding adds a *complementary
distributional-semantic* similarity lane (catches paraphrase/synonymy that
shingle-based SimHash misses) — **additive evidence, not the engine.** Corollary:
the real production dependency for the correlated/dissimilar modes is that the
correlation matrices be *populated* — which is gated by the standing-signal
emission loop being live, NOT by the embedding lane.

**Re-embedding workflow** (below) becomes a v1.1 concern alongside the first
real provider — it does not gate beta, since beta has no real space to switch
to. The seam must still record provenance so the v1.1 re-embed has the data it
needs.

**The re-embedding workflow is real engineering, not a checkbox.** Changing an
estate's active space is a resumable batch re-embed of the whole estate; on a
BYO-remote provider it costs the user money and network latency, and it rides
the dual-path intake (hot write + QueueKit drain). It ships in beta as a fully
tracked operation (trigger, terminal state, resumability, force-test) — it is
the largest single piece inside this cut.

**The hard invariant (binds every platform, every configuration state):**
> No surface ever presents deterministic vectors as semantic recall — in any
> configuration state, on any platform.

This is what makes BYO-as-the-Rust-path safe. A fresh install with **no provider
configured** has no real semantic path; it must report **semantic recall =
unavailable / configure a provider** and serve recall on the other lanes
(lexical/structural/temporal) — it must NOT silently rank on deterministic hash
vectors and call the result semantic. "Honest unavailable" beats "silent false."

## Conformance consequence (deliberate doctrinal departure)

Once real host models enter, embedding vectors are **NOT** a four-way
bit-identical-conformance quantity like the substrate kernels. CoreML on Apple
and a Rust local runtime will not produce byte-identical vectors for the same
text, and that is correct, not a defect. The conformance target for the
embedding layer **moves up** from bytes to: descriptor correctness, refusal of
incompatible-space comparison, and recall-behaviour gates (does recall rank
sensibly). The exception is **narrow, not a blank check** — pin it precisely:
- **Deterministic space:** byte-identical four-way (reproducible by
  construction) — the conformance harness keeps full teeth here.
- **Remote provider:** identical across ports by construction (both ports call
  the same endpoint).
- **Local model, same runtime both ports:** byte-identical expected.
- **Local model, different runtime per platform** (CoreML vs a Rust runtime):
  the ONLY place ports legitimately diverge — and the gate there is
  **ranking-order agreement within tolerance on a shared fixture**, NOT vector
  bytes. This single case is the entire scope of the doctrine exception.

## Implementation plan (post-acceptance — NOT launched by this ADR)

Phased, both ports, sized as real engineering (this is the largest remaining
lane and is scheduled as its own effort, separate from the current release):

1. **Seam + registry + descriptor + provenance** (CorpusKit both ports): the
   `TextEmbeddingProvider` protocol/trait, the registry, the descriptor type,
   stored-vector provenance fields, cross-space comparison refusal, recall
   status envelope. The deterministic provider is retained as the permanent,
   federation-grade vector lane (it is NOT demoted or removed) and is labeled
   non-semantic; this phase ADDS the learned semantic lane as a second,
   independent lane alongside it rather than replacing it.
   Demote token-based slots to provider-private.
2. **BYO-remote adapter** (text-in over the platform HTTP client; key handling;
   privacyClass gating) — likely the fastest real path, no tokenizer work.
3. **Apple CoreML local adapter** + bundled small model (zero-config default).
4. **Rust local adapter** (runtime TBD — see open questions).
5. **Optimizer integration**: embedding space(s) as ablatable signal(s) with
   recipe-config weights; multi-space recall.

## Open questions (NOT decided — require a further ruling before the relevant phase)

1. **Rust local runtime.** Which concrete adapter is blessed for Windows/Linux
   (ONNX Runtime / Candle / llama.cpp-server / Ollama)? Decides phase 4 and a
   C-1 per-crate dependency approval.
2. **External-dependency approvals.** Each concrete adapter needing a runtime or
   SDK requires explicit per-crate sign-off; not granted here.
3. **Privacy enforcement mechanics.** Exact gate between `privacyClass` and
   entity sensitivity tiers (default-deny? per-estate allowlist of remote
   providers?). Security review.
4. **Existing deterministic vectors.** Disposition of vectors already stamped by
   the deterministic provider when a real space comes online — re-embed on
   access, background re-embed, or leave as a separate (clearly-labeled)
   space. Pre-v1.0 there is no shipped data, so likely "fresh space, no
   migration," but confirm.
5. **Beta scope.** Which phases are in the beta envelope vs v1.x: is BYO-remote +
   one bundled local default sufficient for beta, with the full multi-space
   optimizer integration following?

## Status

**Decided** on the five settled axes (2026-06-12). Open questions above
remain for further decision before their phases begin. No implementation lane is
launched by this record; this ADR exists to fix the seam shape once, before any
code, so it is decided up front rather than discovered during implementation.

---

## Architectural correction — 2026-06-13

**The federation dimension was missing from this ADR.** The ADR above correctly
captures that the deterministic provider must not be silently branded as
semantic recall. That constraint stands unchanged. However, the ADR did not
capture a second, orthogonal role that the deterministic provider plays.

**Corrected two-vector architecture:**

The system operates with two coexisting vector lanes, not one:

1. **Permanent, federation-grade deterministic lane (`.deterministic`,
   `EmbeddingModelConfig::Deterministic`)** — FNV-1a tokenization + FloatSimHash
   projection, model-free, byte-identical cross-device and cross-port. This is
   PERMANENT INFRASTRUCTURE present in every version (v1.0 through any future
   version), because FEDERATION REQUIRES IT: the same content yields a
   byte-identical vector on every device/database, which is what the federation
   sync engine needs. It captures surface/lexical signal, not learned semantic
   meaning. It is NOT a placeholder, stand-in, or temporary fallback — it is the
   permanent federation vector.

2. **ADDITIVE v1.1 on-device learned semantic lane (`.miniLM`, `.mpNet`,
   `.embeddingGemma`)** — model-dependent vectors for richer on-device search
   and semantic similarity (catches paraphrase/synonymy that the deterministic
   lane misses). This lane is on-device-only: being model-dependent, it cannot
   serve as the federation vector (model weights differ across devices). It does
   not replace the deterministic lane; both coexist.

**HMM analogy (same principle as NLTagger):** The deterministic/portable
representation federates; the model/platform-specific one is an on-device
enhancement that forfeits federation reproducibility.

**What this corrected in the ADR above (now folded into the body):** the
original 2026-06-12 body framed the deterministic provider as a demoted
test/conformance/offline-only fallback. That framing has been revised throughout
the body to match this correction — the body now states the deterministic lane is
permanent federation-grade infrastructure. The specific revisions:
- "Deterministic stays test/conformance/offline only" (Rejected alternatives) —
  was CORRECT for the semantic-recall dimension but omitted the federation role.
  The body now states the deterministic lane is also the permanent federation
  vector in production, in addition to its conformance/test/offline roles.
- "deterministic-fallback (stand-in — explicitly NOT semantic)" (result envelope
  status) — the label accurately said NOT semantic (correct), but implied a
  degraded state. The result-envelope status is now `deterministic` (the
  permanent federation-grade lane), distinguished from `unavailable`
  (no provider configured for the semantic lane).
- "Demote the deterministic provider to labeled fallback" (implementation plan
  phase 1) — REVISED: the deterministic lane is not demoted; it remains the
  primary lane for federation-synchronized vectors. Phase 1 now ADDs the learned
  semantic lane as a second independent lane, not replacing the deterministic
  lane.

**The hard invariant from this ADR stands unchanged:**
> No surface ever presents deterministic vectors as semantic recall.

The correction is only that the deterministic vector is permanent federation
infrastructure — not that it gains a semantic-meaning claim it does not have.

---

## Changelog

- **1.1.0 (2026-06-14)** — Folded the 2026-06-13 architectural correction into
  the body. The body previously stated the deterministic provider was demoted to
  a labeled/test-only fallback; it now states (in the Decision axis, Rejected
  alternatives, result-envelope status, Context, and implementation-plan phase 1)
  that the deterministic provider is permanent federation-grade infrastructure
  present in every version — matching `EmbeddingModel.deterministic` /
  `EmbeddingModelConfig::Deterministic` in CorpusKit (Swift + Rust). The
  correction section is retained as the historical record of those revisions.
- **1.0.0 (2026-06-12)** — Initial decision; 2026-06-13 architectural correction
  appended.
