---
title: The Approach to Memory Retrieval in MOOTx01
release: "1.1"
date: 2026-08-28
description: Public-facing explanation of MOOTx01 retrieval surfaces, measurement-based selection, deterministic limits, and derived-memory markers.
---

# The Approach to Memory Retrieval in MOOTx01

MOOTx01 separates retrieval—locating stored evidence—from answer generation.
The benchmark suite measures both stages, but reports them as distinct metrics.

## Retrieval surfaces

- Lexical matching finds records that share query terms.
- Semantic similarity compares embedding-space meaning.
- Temporal retrieval weights or filters by capture and event time.
- Graph traversal follows stored relationships between facts and memories.
- Structured lookup resolves explicit facts against a known schema.
- Associative retrieval uses partial cues to broaden candidate discovery.

No single surface covers every question shape. Exact lookups, temporal
questions, aggregation, comparison, supersession, vague cues, and multi-step
relations require different evidence paths.

## Measurement-based selection

Configuration decisions are derived from full-coverage, per-question benchmark
records. A comparison holds the corpus, questions, binary, port, scale, and
answering or judging models fixed, then changes only the retrieval surface or
composition under study. Reports declare the complete arm identity.

Rank-fusion, learned matrix scoring, temporal weighting, broad recall, and
staged retrieval are treated as measurable alternatives. An arm result is
comparable only with another arm over the same unit set and evidence contract.
Door configurations and provisioned lane weights retain the reports and run
identifiers from which they were selected.

## Limits of deterministic retrieval

Retrieval can locate evidence; it cannot by itself count occurrences across
many memories, resolve an underspecified user intent, or state a fact that must
be synthesized from several records. Model-based answer scores therefore
measure the full pipeline and name the model. Deterministic evidence-retrieval
scores measure MOOTx01 directly and remain separate.

## Derived-memory markers

The optional dreaming pass examines related memories during idle time and
mints short derived claims with citations. A marker retires when its source
facts change. Markers are stored retrieval targets, so the query path remains
deterministic after they are created. The retrieval path remains functional
when dreaming is disabled.

Derived markers address the boundary between finding and stating without
replacing the retrieval architecture. They make aggregations and multi-record
claims available as cited memories that the normal retrieval surfaces can
locate.

## Verification

`RESULTS.md` catalogs the measured surfaces and required evidence. The
benchmark-specific pages define coverage and reproduction. Every published
figure is traceable to an accepted row in `../RESULTS_RECORD.md`, its report,
binary digest, protocol version, scale, port, and model identities where
applicable.
