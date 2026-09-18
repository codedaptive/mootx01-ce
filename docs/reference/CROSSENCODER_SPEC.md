---
title: CrossEncoder Specification
version: 1.0.4
status: accepted-1.1-target
date: 2026-09-14
description: "The retrieval-time cross-encoder: the packaged pair classifier, the pair-scoring contract in CorpusKit, the span selection and fusion rule of the GeniusLocusKit stage, its lifecycle, gates, failure behaviour, diagnostics and manifest limits."
spec_type: encoder
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/CROSSENCODER_INTERFACE.md
  - docs/reference/CORPUSKIT_SPEC.md
  - docs/reference/GENIUSLOCUSKIT_SPEC.md
---

# CrossEncoder Specification

## § 1 — What this package is

The cross encoder is a retrieval-time reranker. After every recall lane, the
fusion and the §11.18 admission gate have produced the authorized final list,
a BERT pair classifier scores (query, span) pairs for the HEAD of that list,
takes the best logit per candidate and fuses the cross order back into the
incoming order with reciprocal-rank fusion. The tail beyond the head is never
touched and membership never changes. It runs only when a recall request
carries an explicit `apply` directive; an absent directive is bypass.

This is not a package of its own. It is a contract that spans two kits
along the same layering as the span encoder: the pair-scoring contract and
the packaged profile live in CorpusKit (`Encoder/`), the native runtimes in
the provider targets (CoreML on Apple, candle on Linux and Windows), the
stage, its lifecycle and the manifest limits in GeniusLocusKit, and the
model packaging in `tools/encoder-models`. No new table, no new process, no
runtime download.

## § 2 — Scope

This specification defines:

- the one packaged profile and its identity (§ 4, § 5.1)
- the pair-scoring contract every scorer satisfies (§ 5.2)
- the pair tokenization rule (§ 5.3)
- how the stage selects spans, scores and fuses (§ 5.4 to § 5.6)
- where the stage sits in recall and what it may change (§ 5.7)
- the request directive, the report and the degradation vocabulary (§ 5.8, § 6)
- the per-estate lifecycle and the manifest limits (§ 5.9)
- the compile gates (§ 5.10)
- packaging and the model directory (§ 5.11)

This specification does NOT define:

- API signatures — those live in `CROSSENCODER_INTERFACE.md`
- when a caller SHOULD ask for the stage (a recall strategy decision that
  belongs to a later library; the stage only consumes the decision)
- the ARIA verb surface that will carry the directive (deferred with the
  Distiller, orderRanked and Skim surface work)
- quality claims or tuning of the reranker (a separate follow-up effort)

## § 3 — Position in the kit family

```
CorpusKit (contract)          CorpusKitProviders / corpus-kit-providers (runtimes)
  CrossEncoderProfile           CoreMLPairInference  (Apple, FP32 .mlmodelc)
  PairScorer, PairInference     CandlePairScorer     (feature candle)
  ProviderPairScorer            PairScorerFactory
  RerankDirective               ModelDirectoryResolver (known hash + files)
        │
        ▼
GeniusLocusKit (composition)
  CrossEncoderStage (fuse, selectSpans, reorder)   CrossEncoderReport
  RecallDirector.recall / recall_scored            manifest limits
  pairScorers[handle] (lazy load, close drops)
```

**Depends on:** CorpusKit `Spanner` (word split and windows), the span
rerank seams when registered (`SpanRerankEncoding`, `SpanVectorReading`),
`ModelDirectoryResolving`.

**Consumed by:** any caller that builds a `GLKRecallRequest`. Today no ARIA
tool sets the directive; internal callers pass none.

## § 4 — Invariants

- **I-1 One profile.** The packaged profile is
  `cross-encoder/ms-marco-MiniLM-L-6-v2` at HF revision
  `233902d25c440f23af6f7d6e94d2946bac0bee0a`, identity
  `ms-marco-minilm-l6-cross-v1`, FP32, pair limit 512 tokens, pool 50, head
  30, spans 3, RRF k 60. `CrossEncoderProfile.minilmL6` / `minilm_l6()` is
  byte-identical across ports.
- **I-2 Off unless asked.** A request without a directive, or with
  `bypass`, produces hits byte-identical to a request built without the
  field. Only `apply` runs the stage.
- **I-3 Membership is preserved for distinct ids.** The stage reorders within
  the pool it was handed and never adds or re-hydrates a hit. Duplicate ids
  within the pool are dropped, so the output can be shorter than the pool;
  membership is preserved only for distinct ids. The tail beyond the pool
  keeps its order.
- **I-4 Every failure degrades.** No path of the stage throws to the caller.
  An `apply` that cannot run returns the incoming order, a report with a
  reason, and `recall.cross_encoder_degraded` on `degradedStages`.
- **I-5 Maxima never rise.** The estate manifest may lower pool, head and
  spans; a stored value above the profile is clamped to the profile on read.
- **I-6 Same pairs, both ports.** The pair tokenization (`[CLS] q [SEP] s
  [SEP]`, segment ids 0 / 1, longest-first truncation, ties trim the query)
  yields identical ids in both ports for identical text; the fixture pins
  them.
- **I-7 Same fusion, both ports.** `fuse` reproduces the lab's reference
  order for every case of `cross_encoder_parity.json`.
- **I-8 Reserved name.** `RecallShape.presetNames` does not include
  `cross_encoder`; the name stays reserved for the surface work.

## § 5 — Behavioral contracts

### 5.1 Profile

`CrossEncoderProfile` carries `modelID`, `modelVersion` (short revision),
`tokenizerHash` (SHA-256 of `vocab.txt`, the same uncased BERT vocabulary
the floor sentence encoder ships), `maxSequence`, `pool`, `head`, `spans`
and `rrfK`. `artifactName` is the Pascal-cased model id
(`MsMarcoMinilmL6CrossV1`), the base name of the Apple artifact. Serialised
field names are column-style (`model_id`, `rrf_k`, …). The profile is not
persisted per estate.

### 5.2 Pair scoring

A `PairScorer` returns one finite logit per span, in span order
(`count == spans.count`); an empty span list returns empty without touching
the model. Higher is more relevant; the scale is the model's own and is only
compared within one call. `ProviderPairScorer` drives a `PairInference` seam
(text pairs in, raw logits out) in `batchSize` chunks (default 8) and raises
`EncoderError.inferenceFailed` when a batch returns the wrong count or a
non-finite value. Every scorer names its `backend` (`coreml`, `candle`, or a
test double's own name).

### 5.3 Pair tokenization

`[CLS] query-pieces [SEP] span-pieces [SEP]`, segment ids `0` through the
first `[SEP]` and `1` after. While the two piece lists together exceed
`maxSequence - 3`, the last piece of the LONGER list is dropped; on a tie the
query's. This is the reference `truncation="longest_first"`. Swift performs
it in `WordPieceTokenizer.tokenizePair`; Rust through the `tokenizers` crate
pair encode with `TruncationStrategy::LongestFirst` and pad-to-longest.

The effective `maxTokens` for the tokenizer is clamped to `min(profile.maxSequence,
model.fixedLength)` when the compiled model carries a positional ceiling tighter
than the profile's nominal limit. Swift derives this ceiling from the CoreML
`input_ids` shape constraint (`CoreMLPairInference.fixedLength`); Rust derives
it from `max_position_embeddings` in `config.json`. When the clamped value is
smaller than `profile.maxSequence`, the factory rebuilds the tokenizer with the
tighter budget before constructing the scorer.

### 5.4 Span selection

For each scored candidate the stage builds up to `spans` texts:

1. When the estate has a registered span rerank source and the query
   encodes, the candidate's stored int8 span rows under the registered
   encoder's model id are ranked by their cosine against the query
   (`SpanRerankStage.dotQuery`, ties by span index) and the best `spans`
   are rebuilt from the hydrated content's word list (`Spanner.words`) by
   `[startWord, endWord)`.
2. Otherwise, or when no usable row exists, the content is windowed with the
   Spanner (`windowWords` and `overlapDivisor` of the registered encoder's
   spec, the floor spec's when none; at most `spans` spans) so a record
   whose span rows have not drained is still scored.

Empty spans are dropped. A candidate with no hydrated content, or no
non-empty span, is unscored and keeps its incoming rank.

### 5.5 Scoring

The head is the first `head` candidates of the pool. Each head candidate
with spans is scored in one `PairScorer.score(query, spans)` call; its
logit is the maximum over its spans. A scorer failure on any candidate
degrades the whole apply (`scorer_failed`).

### 5.6 Fusion

`fuse(incoming, head, logits, k)`, the lab's rule reproduced exactly:

1. `head` = the first `head` of `incoming`; the rest is the tail, returned
   unchanged after the fused head.
2. Scored head candidates are ordered by max logit descending, ties by
   incoming rank ascending, then id; unscored candidates follow in incoming
   order. Cross rank is 1-based over that list.
3. `score(c) = 1/(k + incoming) + 1/(k + cross)`; the head is sorted by score
   descending, ties by incoming rank, then id.

The stage then reorders the pool by that id order (`reorder`), leaving
entries beyond the pool in place.

### 5.7 Position in recall and the widened cut

The stage runs in `RecallDirector.recall` / `recall_scored` after the
§11.18 anomalous admission gate and before the trace write and the dreaming
enqueue, so the caller receives, and the trace records, the fused order.

An apply with a packaged profile widens the lanes' presentation cut to the
pool before the lanes run: the director raises the lane request's `limit` to
`pool` when the caller's limit is smaller; `frontierK` is computed from the
caller's limit and is unchanged, so the candidate pool the lanes score is
identical with or without a directive. After the stage the hits are re-cut
to the caller's limit. The incoming order the stage sees, and the order a
degraded apply hands back, is therefore the head of that pool-wide page. A
bypass, an absent directive or an unknown profile never widens and returns
the lanes' own cut untouched. `result.request` is always the caller's
request.

### 5.8 Directive and report

`RerankDirective { action: bypass | apply, profileID, reason? }` travels on
`GLKRecallRequest.rerankDirective` / `rerank_directive` (default none). It
carries no benchmark type, gold answer, expected identifier or difficulty
guess.

`GLKRecallResult.crossEncoder` / `cross_encoder` is nil when the request
carried no directive and otherwise a `CrossEncoderReport`: `status`
(`applied` | `bypassed` | `degraded`), `requested`, `reason` (a degrade
reason, or the directive's own code echoed), `profileID`, `modelVersion`,
`backend`, `pool`, `head`, `spans`, `scored`, `coldLoad`, `stageMillis`.
`summaryLine` renders the one line a composer prints:
`cross_encoder: <status> profile=<id> [reason=…] [backend=…] [pool=… head=…
scored=… [cold_load] [ms=…]]`.

### 5.9 Lifecycle and manifest limits

Nothing loads at open. The first `apply` on an estate resolves the model
directory through the same `ModelDirectoryResolving` the span encoder uses,
builds the scorer with `PairScorerFactory` once under the actor (Swift) or
under one `RefCell` borrow (Rust), and keeps it in `pairScorers[handle]` /
`pair_scorers`. A failed load is remembered as unavailable until `close`,
which drops the slot. A host or test may register a scorer directly
(`registerPairScorer` / `register_pair_scorer`).

Manifest keys, all positive integers as text, read per apply and clamped to
the profile: `cross_encoder_pool` (max candidates entering the stage),
`cross_encoder_head` (max scored), `cross_encoder_spans` (max spans per
candidate). `cross_encoder_profile` names the packaged profile a future
surface default should mean; the stage does not read it today.

### 5.10 Compile gates

Swift trait `CrossEncoder` on GeniusLocusKit defines `MOOTX01_CROSS_ENCODER`
and compiles the scorer load; the request field, the report and the fusion
compile regardless. Rust feature `cross-encoder` (`corpus-kit-providers/candle`)
does the same. With the gate off an `apply` degrades with `capability_off`.
The product targets (`apps/mootx01`, both ports) enable the gate; the kit
default is off.

### 5.11 Packaging and the model directory

`tools/encoder-models/build-all.sh --profile minilm-cross` converts the
sequence classifier to an FP32 CoreML model with three fixed `[1,512]` Int32
inputs (`input_ids`, `attention_mask`, `token_type_ids`) and one Float32
`logits` output of shape `[1,1]`, and copies the HF triple plus `vocab.txt`
for the Rust runtime. The manifests `cross-encoder-models-apple.json` and
`-linux.json` carry `kind: cross_encoder` and the profile fields. Artifacts
stay outside git and resolve through the model directory resolver's three
slots under `<configuration>/models/ms-marco-minilm-l6-cross-v1/`, with
`vocab.txt` hashed as the integrity sentinel. The Rust runtime reads the
pooler and classifier from the same safetensors (`bert.pooler.dense`,
`classifier`).

## § 6 — Error model (conceptual)

Degrade reasons (`CrossEncoderReport.reason` on `degraded`):

| Reason | Meaning |
|---|---|
| `capability_off` | the build carries no cross-encoder runtime |
| `profile_unknown` | the directive names a profile this build does not package |
| `model_unavailable` | no model directory, or the factory refused it (one log line names the detail) |
| `no_query_text` | the request carries no query text to pair spans with |
| `scorer_failed` | the scorer failed while scoring; the incoming order stands |

Every degrade also appends `recall.cross_encoder_degraded` to
`degradedStages`. Factory failures use `EncoderError` (`modelUnavailable`,
`tokenizerMismatch`, `loadFailed`, `inferenceFailed`) in the same order as
the span encoder factory.

## § 7 — Conformance requirements

- Both ports read `SynapseKit/Tests/Fixtures/encoder/cross_encoder_parity.json`
  and reproduce every expected order (I-7).
- Both ports pin the reference pair ids for the lab fixture texts
  (`PairTokenizerTests.swift`, `cross_encoder_candle_tests.rs`) (I-6).
- With the packaged assets present, both native scorers reproduce the lab's
  reference logits (CoreML within 1e-3, candle within 1e-4) and an apply
  through the director reports `applied` with `coldLoad` on the first call
  only (`CrossEncoderStageTests.swift`, `cross_encoder_stage_tests.rs`).
- Absent directive and bypass are byte-identical to no field; every degrade
  reason is reachable and carries the incoming order; `close` drops the slot.

## § 8 — Out of scope

- Any activation policy: the stage consumes a directive, it never decides. Production activation is route 1 of the recall router (`GENIUSLOCUSKIT_SPEC.md § RECALL_ROUTER`): behind the `cross_encoder_routing` estate preference (absent = on), a question that reads as a conversation question — a quoted phrase, a speaker cue or a conversation reference — is given the degradable `.apply(reason: "route:cross_encoder_routing")` directive (the stage reranks when it can run and otherwise degrades with a reason, leaving the lane order standing). The fail-closed `.strictTranscript()` directive is set only by the `moot_memory_recall_transcript` operation; the router never applies it.
- The ARIA verb surface: no tool argument carries the directive yet, and the
  composer prints no line until one does.
- Distribution of the model asset (release asset, installers, app bundle):
  the packaging pipeline produces the artifacts; wiring them into the four
  distribution paths follows the Arctic precedent as its own item.
- Quality or tuning of the reranker.

## § 9 — Open questions

None recorded.

## Changelog

### 1.0.4 -- 2026-09-14

§8: the router's Route 1 transform is the degradable `apply` directive
(reason `route:cross_encoder_routing`); `.strictTranscript()` is the transcript
operation's own. No stage contract change.

### 1.0.3 -- 2026-09-14

§8: production activation stated as recall router route 1 behind the
`cross_encoder_routing` estate preference, with the route's predicate (a
conversation question) and its transform (`.strictTranscript()`). No
contract change.

### 1.0.2 -- 2026-09-14

§8: noted that the production activation path for dialogue queries is the recall router; cross-reference to `GENIUSLOCUSKIT_SPEC.md § RECALL_ROUTER`. No contract change.

### 1.0.1 -- 2026-09-08

- §5.3: added position-limit clamp rule — effective `maxTokens` is
  `min(profile.maxSequence, model.fixedLength)`; Swift reads from CoreML
  `input_ids` shape constraint, Rust from `max_position_embeddings` in
  `config.json`.
- I9-4: Removed mid-sentence bold from "contract that spans two kits" in § 1; prose only, no contract change.

### 1.0.0 -- 2026-09-08

Initial contract: the packaged ms-marco-MiniLM-L-6-v2 profile, the pair
scoring contract and pair tokenization in CorpusKit, the CoreML and candle
runtimes behind `PairScorerFactory`, the GeniusLocusKit stage (span
selection, the lab's fusion rule, the widened cut), the request directive
and the report, the lazy per-estate lifecycle, the manifest limits, the
compile gates and the packaging profile. Both ports.

*End of CrossEncoderSpec*
