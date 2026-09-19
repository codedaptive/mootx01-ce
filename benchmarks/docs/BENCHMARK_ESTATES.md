---
title: Benchmark Estates
release: "1.1"
date: 2026-08-28
description: The storage projection behind every external benchmark artifact: the two filing rules, the room and wing structure, and the two artifact forms.
---

# Benchmark Estates

This document describes how benchmark datasets are projected into estates. It covers the two filing rules, the room and wing structure, the two artifact forms, and the build pipeline.

---

## 1. The governing principle

The artifacts model the way the system actually stores things. Each benchmark is projected into the estate the product would have built if a user had saved the same material. Retrieval is then measured against that estate through the same MCP call a client would make.

The data is stored in the form an AI agent would discover and use through the ARIA surface, and the form a developer using the SDK would select. The diagrams show an example of how an AI stores data in moot, and the artifacts take exactly that shape.

An agent left unguided could choose an overly simple filing approach. Skills, hooks, and rules are continuously tuned to help the AI learn to use the full richness of mootx01 to match the problem it is handed. That guidance also lives inside ARIA itself: the tool language, the teachme guides, and the result payloads carry tips that reinforce good filing and recall habits at the moment of use.

---

## 2. The two filing rules

**Rule 1, session transcripts:** LongMemEval, LoCoMo, LMEB/ConvoMem. One drawer per session. The body is the transcript verbatim, as "role: content" lines. The session date is the drawer's event time. Attribution lives in the subject wrapper, for example "Session with Priya Calder, 2023-05-30". Bodies are never rewritten.

**Rule 2, topical drawers with facts:** MemBench. One drawer per person, place, or event a persona tracks. Each dated statement becomes a knowledge-graph fact on that drawer (predicate = the shipped attribute, object = the shipped value). MemBench ThirdAgent ships pre-parsed rel/attr/value triples, so it gets drawers plus facts. FirstAgent ships dialog threads with no triples, so it gets drawers only.

**Third-person conversion:** each instance gets a deterministic persona name. Questions are rewritten to name the persona in third person. A mechanical rewriter does this; 0 of 26,504 questions retain first or second person. Bodies stay verbatim.

---

## 3. Rooms

Twelve coarse topical rooms plus a general fallback: people, work, health, home, money, food, travel, hobbies, media, tech, learning, events, general. One work/crm sub-room exists because a corpus survey found work at 65% of ConvoMem with distinctive crm/sales/pipeline vocabulary.

Rooms are provenance-blind. A room per benchmark is forbidden: it would leak the answer key into the structure. A keyword-lexicon classifier assigns the room from the body.

---

## 4. Wings

Estate-per-instance units and the LongMemEval estate use two life wings: Professional for work rooms, Personal for everything else. Wing-per-instance estates use neutral persona or pair names as wings (never dataset names). The wing-to-dataset mapping lives only in harness config, never in the artifact.

Wings let an estate go deep and narrow on some topics and wide and shallow on others. Thanks to wing filters, your AI can choose the saving strategy that works best for each problem space you hand it.

---

## 5. Entity drawers and tunnels (ConvoMem)

Recurring people and companies across sessions get one topical drawer each,
with a `references` tunnel to every session that mentions them. This models
the cross-references a user would have asked for. The ConvoMem projection
contains 40 entity drawers and 6,379 tunnels.

---

## 6. The two artifact forms

**Form 1, estate-per-instance:** one estate per benchmark instance, exactly the
published protocol shape: a fresh collection per question with one document
per session.

**Form 2, one estate per benchmark:** two files each (a Swift lane file and a Rust lane file, differing only in embedding-provider state).

Where haystacks do not overlap (LoCoMo, ConvoMem, MemBench), each instance becomes a wing. A wing-scoped run reproduces the official per-instance protocol inside one file. An unscoped run is hard mode: every question faces every other instance's material as distractors.

LongMemEval is the only set whose haystacks overlap (3,942 shared sessions, 4,672 duplicate references). It gets no instance wings. Instead it is one deduplicated estate of 19,195 unique sessions, and its questions run unscoped in third person. The overlap is dissolved rather than worked around. Duplicating shared sessions into instance wings would deflate IDF for the duplicated terms estate-wide, overweight repeated chunks in basis training, and crowd top-k with identical vectors. Splitting shared sessions across owner wings would strip about 18% of the distractors from every wing, a protocol deviation. Deduplication is the only shape that keeps the estate clean and the protocol intact.

---

## 7. The complete estate

One estate holds every external dataset: 185,480 drawers, 185,345 facts, and
6,379 tunnels on the two life wings. Record identifiers carry a dataset prefix
in the build plumbing only; rooms and subjects carry no benchmark marker.

The `complete-aggregate` scale measures every dataset against this estate. Its
report is kept separate from the official per-instance `unit` scale. Operators
use the paired reports to quantify the effect of cross-dataset distractors.

---

## 8. Artifact cardinalities

The build produces the following Form-2 artifacts from the release 1.1 seed
set. `make status` is the authority for physical readiness; these counts define
the expected logical shape.

| Artifact | Drawers | Facts | Tunnels | Wings | Questions |
|---|---:|---:|---:|---:|---:|
| `lme-s` deduplicated estate | 19,195 | 0 | 0 | 2 | 500 |
| `locomo` wing estate | 272 | 0 | 0 | 10 | 1,986 |
| `convomem` wing estate | 13,817 | 0 | 6,379 | 5,869 | 5,867 |
| `membench` wing estate | 152,196 | 185,345 | 0 | 20,137 | 20,137 |
| complete estate | 185,480 | 185,345 | 6,379 | 2 | all external questions |

Form-1 unit fleets use the same seed records. Artifact size is an output of the
provider state and is recorded by the build receipts rather than fixed in this
design contract.

---

## 9. Build and measure pipeline

Seeders are Python scripts in `seeding/`:

- `seed_lme_s.py`: also the shared module (personas, room lexicon, wings, question rewriter).
- `seed_locomo.py`
- `seed_convomem.py`
- `seed_membench.py`
- `corpus_survey.py`: the pre-parse survey for the crm sub-room and entity tunnels.
- `build_complete.py`
- `import_units.py`: windowed MCP import, at most 120,000 rows per call, with an id-map capture and a drain gate on corpus_encode and distillation.

Each seed record carries content, subject, room, wing, and event_time. Import is through `moot_json_import` with `return_id_map`. Measurement is the `artifact-recall` subcommand of the benchmarker in both ports. It replays each dataset's questions through `moot_memory_search`, wing-scoped or estate-wide, and scores hit@k and MRR against the answer session ids via the id map.

---

## 10. Diagrams

Two diagrams accompany this document:

- `diagrams/estate-anatomy.svg`: wings, rooms, drawers, facts, and tunnels, with a Rule-1 session drawer and a Rule-2 topical drawer shown. Every structure shown is present in the built artifacts. This is the subset of the estate model the benchmarks exercise, and an example of how an AI stores data in moot.
- `diagrams/artifact-forms.svg`: the four artifact shapes (unit fleet, wing-per-instance estate, the deduplicated LongMemEval estate, the complete estate).
