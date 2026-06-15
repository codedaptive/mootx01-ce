---
status: accepted
created: 2026-05-22
last_updated: 2026-06-14
---

# Substrate Design Constraints

The constitutional constraints that hold across every design
decision in the substrate kit graph. These constraints sit
alongside the validation plan and the claims ledger as the
reviewable record of substrate design boundaries. Constraint
violations surface immediately on proposal rather than after
artifact landing.

## C-1: No external runtime dependencies for substrate features

The substrate (LocusKit, VectorKit, CorpusKit, GeniusLocusKit,
ConvergenceKit, PersistenceKit, QueueKit, SubstrateLib,
AriaLexiconLib) depends only on:

- Pure Swift and pure Rust source compiled from the controlled
  toolchain.
- Reference data committed to the repo as reviewable artifacts
  (JSON, plaintext, gazetteers, schedules).
- Language standard library facilities.
- Source-reviewable embedded libraries with stable, public, and
  reproducible build provenance (for example, the SQLite source
  consumed by LocusKit's storage layer).

The substrate explicitly excludes:

- External ML runtimes (ONNX Runtime, TensorFlow, PyTorch, Core ML
  consumption at the substrate layer).
- API calls to external services (LLM completions, classifiers,
  embedding services, any network call as part of a substrate
  primitive).
- Neural inference engines that require binary model files inside
  the substrate's compliance boundary.
- Third-party binary dependencies without source-level review.

ML capabilities live above the substrate in NeuronKit and
CognitionKit. Those kits carry their own compliance posture and
are not load-bearing for substrate behavior. The substrate has
a slot for vector representations (rung 3) and lattice anchors,
but the substrate's own population path for both is deterministic
and in-tree; richer populations come through the I-14 provenance
path from above.

## C-2: Optional acceleration must preserve the deterministic reference

The substrate may offer compile-time acceleration paths (the Rust
`simd-nightly` flag for the kernel layer, the proposed Swift
`apple-nlp-accel` flag for the linguistic pipeline) provided
that:

- The deterministic reference implementation is always available.
- The acceleration is conformance-gated against the reference.
- The build configuration is auditable from the manifest.
- Acceleration paths that orphan cross-language conformance
  (because the accelerated library is single-platform) are
  explicitly flagged as federation-disabled in the build
  configuration.

## C-3: Provenance is mandatory and audited

Every anchor, every drawer, every rung, every association carries
provenance recorded at write time per Invariant I-14. Provenance
identifies the path that produced the data: in-tree extractor
version, externally-submitted classification, human curation,
framework-specific classifier, and so on. The provenance bitmap
is audited on mutation. Federation, recall scoring, and
retrospective drift recovery all depend on provenance being
honest. Two anchors with different provenance can co-exist on
the same row only if the audit log records the transition.

## C-4: Reference data is in-tree and versioned

Any reference data the substrate depends on (the UDC schedule,
the curated Wikidata subset, the Snowball stemmer outputs, the
framework profile gazetteers) commits to the repo as a reviewable
artifact and carries its own version. Updates to reference data
go through the same review path as source updates. The substrate
records the reference data version in the manifest so behavior is
reproducible.

## History

This document opened during the anchor-extractor design
conversation on 2026-05-22, after two consecutive proposals
(an LLM API call, then ONNX Runtime as a substrate dependency)
that violated the unstated but constitutional
no-external-dependencies rule. C-1 was articulated explicitly in
response; C-2 follows from the kernel-ladder pattern already in the
substrate; C-3 formalizes Invariant I-14; C-4 follows from the
audit and reproducibility requirements.

An earlier record naming EmbeddingGemma_300M as the production
default embedding model is superseded by this document. The
substrate's vector representation tier uses TF-IDF over
framework-profile vocabulary; neural embedding models are a
NeuronKit-layer concern, not a substrate concern.
