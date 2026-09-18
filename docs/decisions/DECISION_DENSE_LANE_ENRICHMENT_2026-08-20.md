---
version: 1.0.0
status: superseded
date: 2026-09-06
description: Dense-lane enrichment doctrine — platform-unique evolving dense text, trailer grammar v1, capability-shape parity, engine provenance, benchmark defaults
superseded_by: ../decisions/DECISION_RETIRED_TECHNIQUES_LEDGER.md
---

> Superseded on 2026-09-06. See [the retirement ledger](../decisions/DECISION_RETIRED_TECHNIQUES_LEDGER.md).
> This document is preserved as history.

# DECISION: Dense-Lane Enrichment

## Ruling (Bob, 2026-08-20)

The Dense Lane text (the drawer's `distilled` representation and everything
derived from it) is **platform-unique, optimized, and evolving** for
interaction with the LLM and LLM-driven retrieval, to the best abilities of
the host OS. It is "a hyperplane shape optimized and evolving for
interaction with the LLM — it empowers the deterministic layer without
attempting to be the deterministic layer."

Consequences:

1. **Parity covers the capability shape, never the text.** Both ports MUST:
   run the enrichment sweep, honor the freshness/invalidation semantics
   (operational bit 19 `hasCurrentRepresentation` + pipeline-version
   mismatch → re-enrich; every body-mutating verb clears both atomically),
   parse the trailer grammar below, and record engine provenance. The
   enrichment TEXT produced on each platform is data, not a conformance
   surface — an AI never writes the same body twice, and the dense lane
   inherits that nature.
2. **Deterministic enrichment is the default engine** (tagger + FDC/
   Wikidata lookup + recency coreference; cheap, both ports, always
   available). LLM enrichment is an opt-in quality upgrade gated by cost,
   availability, and user consent — NOT by determinism.
3. **Engine provenance is mandatory**: `distilled_pipeline_version` carries
   the producing contract + engine (e.g. `p2-det`, `p2-llm-apple`), so any
   enrichment is auditable and re-dreamable.

## Trailer grammar v1

Category/entity enrichment is welded to the END of the distilled body as a
parenthetical trailer:

```
(*[ kind: hobby, entity: painting, place: rio de janeiro, country: brazil, fdc: arts ]*)
```

- Delimiters `(*[` and `]*)` — chosen because the pair cannot occur in
  natural prose. Parsed by a scanner, never regex-on-structure.
- Fixed label vocabulary v1: `kind` (hypernym/category of a body noun),
  `entity` (the noun as normalized), `place` (toponym), `country`
  (resolved country of a place), `fdc` (FDC frame label of the drawer's
  or noun's classification). Labels lowercase; values lowercase; entries
  comma-separated; label extension requires a version bump of this record.
- Dense lane ONLY. The verbatim `content` column never carries a trailer.
- The trailer is part of the distilled text: it feeds `effectiveDenseText`
  (all embedding lanes) and is served with `depth: distilled` payloads.
  BM25 remains verbatim-content-only by architecture and is untouched.

## Benchmark defaults

- Benchmarking runs against estates WITHOUT LLM enrichment. The
  deterministic engine is the default, benchmarkable-by-both-ports mode
  (namespace tag `-enrich_det`).
- LLM-generated estates are an optional mode intended to be benchmarked by
  ONE port only — the port whose engine generated them. That scope is
  carried by FILE NAME CONVENTION ONLY (e.g. `-enrich_apple-swiftonly`,
  `-enrich_<engine>-rustonly`): either code base can still read the
  estate; there is no code gate. Single-port figures are never compared
  cross-port.
- Enrichment is a provenance axis: run keys append `-enrich_<tag>` (absent
  for legacy/none) and `artifact.json` records the `enrichment` field.

## Acceptance rulings (Bob, 2026-08-20)

- **p2-det is the accepted shipping default** (search door +0.084 any@10
  over base, exceeding the oracle's lexical arm; worst regression
  noise-level). The deterministic engine remains the benchmarkable
  default per the benchmark-defaults section.
- **Wikidata property subset: green-lit** (vendor policy: fetch script +
  in-repo table, both ports; QID → P17 country / P31 instance-of /
  P279 subclass-of labels, sized to the FDC canon's QID coverage).
  Target: close the fact-quality gap the acceptance cells measured
  (temporal door captured ~10% of ceiling; 0/11 miss rescues vs 2/11).

## Changelog

- **v0.2 (2026-08-20)** — Acceptance rulings: p2-det default accepted; Wikidata property subset green-lit.

- **v0.1 (2026-08-20)** — Initial record from the enrichment program
  planning session (Gaps 1/2/3, oracle-gated waves).

## Supersession changelog

### 1.0.0 -- 2026-09-06

Archived the retired contract. The retirement ledger records its disposition.
