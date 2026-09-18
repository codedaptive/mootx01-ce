---
title: ContextDistillLib Specification
version: 1.2.0
status: active
date: 2026-09-15
description: Complete-content distillation and separately invoked prototype ordering and skim contracts.
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/CONTEXTDISTILLLIB_INTERFACE.md
  - docs/reference/SUBSTRATEML_SPEC.md
  - docs/reference/GENIUSLOCUSKIT_SPEC.md
---

# ContextDistillLib Specification

## § 1 — What this package is

ContextDistillLib is a **Lib**: pure text functions and value types, without
managed state or a model lifecycle. Its normal product use is post-retrieval
complete-content distillation. Separate orderReducer and Skim APIs take already
distilled text. Ordering remains a prototype.

Complete distillation compacts representation, not a selected passage subset.
The explicit older v23.2 recipe remains; selectable v22 is retired.

## § 2 — Scope

This contract covers complete compaction, converter identity, provenance,
dependency-group ordering, byte-budgeted skim, fallback and cross-port parity.
The companion INTERFACE owns signatures. Storage, retrieval ranking, lens
selection, wire authorization and model-assisted rewriting are outside scope.

## § 3 — Position in the kit family

**Depends on:** Foundation/CryptoKit in Swift; serde, serde_json and
substrate-kernel (SHA-256) in Rust. No kit dependencies, network or runtime file I/O.

**Consumers:** GeniusLocusKit shared hydration and SubstrateML's text-rendering
compatibility path. NeuronKit retains its structural confidence/success contract.
Consolidation renders complete combined source through the shared renderer;
fingerprint-only paths disable rendering. The old core-first/tail assembly is
removed, not maintained as a competing renderer.

## § 4 — Invariants

**I-1 — Pure:** identical source, recipe and deterministic counter yield identical
output. No wall clock, randomness, model or estate mutation.

**I-2 — Source authority:** original text stays immutable. Digests are lowercase
SHA-256 over UTF-8. Smaller representation is not proof of AI comprehension.

**I-3 — Separation:** Distiller never implicitly orders or skims. The view APIs
never redistill. ARIA explicitly composes complete distillation with source-order
Skim through `moot_memory_get(depth: "skim")`; ordinary distillation stays complete.

**I-4 — Coordinates:** spans are half-open Unicode scalar/code-point offsets,
not grapheme or UTF-16 offsets. Distillation carries parallel UTF-8 offsets.
Skim budgets and returned sizes count UTF-8 bytes, not tokens.

**I-5 — Accounting:** complete compaction gates use the supplied deterministic,
nonnegative counter, including legends. Standard dispatch uses an advisory
estimator, not a model tokenizer. No fixed savings percentage is guaranteed.

**I-6 — Bounded on the read path:** a distillation requested by a live read
(ARIA `moot_memory_get` at depth `distilled` or `full`) does a bounded amount
of work. Sources over 32768 UTF-8 bytes are admitted whole without
distillation; inside that, more than 256 atoms or more than 100 000 selector
comparison units ends selection and returns the complete source as the core,
marked `compression_skipped`. Budget exhaustion never yields a truncated
prefix. Offline distillation is not bounded and keeps the frozen recipe.
The byte ceiling is the settings key `recall_distillation.max_source_bytes`,
which configuration may lower but not raise. Both ports share the ceilings.

## § 5 — Behavioral contracts

### § 5.1 — Complete Distiller

Identity: `complete-form@complete-form-visible-v6`; pure reducer version:
`complete-form-visible-v6`. The bounded chain applies eligible clock compaction,
ordered JSON tables, repeated-line references, JSON blocks, duplicate declarations,
timestamp-prefix factoring and visible-reference rendering. Each transformation
has an eligibility/savings gate. Ineligible material passes through. No passage
selection, source-passage reordering or invented paraphrase is performed.

Reserved visible-reference input is validated. JSON object encounter order and
supported integer values are preserved. Unsupported/ambiguous forms (floating-point
forms, duplicate keys, signed zero) stay unchanged. JSON nesting is bounded at
128 and decimal integers at 4,300 digits. Surrounding line separators survive,
including CRLF and Unicode separators. Swift uses Foundation regular expressions
in the complete grammar; Rust uses scanners. The previous library-wide no-regex
prohibition no longer describes the code; older intent scanners are unchanged.

Repeated-text reconstruction is bounded before every append by the product
settings `context_distill.reference_expansion_max_bytes` (default 8,388,608)
and `context_distill.reference_expansion_max_ratio` (default 64). Both limits
measure UTF-8 bytes. Crossing either limit preserves the exact input and returns
a structured `reference_expansion_limit_exceeded` error in the result instead
of materializing the requested expansion.

Pure results carry text, version, source/representation digests, visible-reference
status and counts. Model-assistance and quality-qualified flags are false:
mechanical reconstruction is not semantic qualification.

### § 5.2 — Dispatch, envelope and v23.2

Standard input contains original text and an optional explicit enrichment trailer.
Complete dispatch preserves that trailer intact. Core is the complete reducer's
output or unchanged source on representation error. Both `aiText` and
`miningBody` are core combined with trailer. Combination inserts one space
when both operands are nonempty, otherwise returns the nonempty operand.

Schema remains `1`, converterVersion remains `distill-plus-v1`.
RulesetVersion distinguishes `complete-form-visible-v6` from
`intent-span-v23.2-attributed-prose`. The retained explicit converter identity is
`intent-span-v23-attributed@intent-span-v23.2-attributed-prose`.
V23.2 retains shape/atom selection, trailer projection and attributed-peer
rendering. Its helper classifier does not select between converter recipes.

All envelope fields remain present. Shape classifies original content.
Span unit strings are `unicode-code-point` and `byte`.
Complete dispatch emits no span for empty input, otherwise one `complete-source`
span with `start`, `end`, `start_utf8_byte`, `end_utf8_byte` covering all
original content. V23.2 uses per-atom spans.

Complete metrics: `original_bytes`, `original_tokens_est`, `core_bytes`,
`trailer_bytes`, `applied_trailer_bytes`, `distilled_bytes`,
`distilled_tokens_est`, `compression_ratio_ppm`.
The ratio is returned bytes/original bytes × 1,000,000 (zero for empty source),
including the trailer. Selection details: `mode: complete-form`,
`complete: true`, `rendering: complete-form-visible-v6`,
`count_unit: tokens_estimate`, `model_assistance: false`,
and `fallback_unchanged`.

Output-changing rule revisions require new recipe identities in both ports;
envelope structure changes require a schema revision. Historical v22 fixtures
may test shared primitives but cannot select v22.

### § 5.3 — Prototype orderReducer

Version `dependency-groups-utf8-v1`. Partition into conservative dependency
groups, preserving heading/material, list/fence/label and dependent-opening
relationships. Positional-reference or ambiguous structure may keep the whole
body together. Rank by distinct case-folded lexical query overlap, descending,
with stable source-order ties. Empty queries preserve order. Frozen Unicode
tables stabilize lexical scoring across ports. This is not semantic ranking.

All groups are retained; whitespace separators retain their output slots.
The complete ordered text is not a skim.

### § 5.4 — Skim

Return a leading whole-group prefix of the plain or ordered view under a positive
UTF-8 byte budget. Never skip a group to fit a later group. Return an oversized
first group intact with `budgetHonored: false`. Empty input is a complete empty
view. `text + continuation == fullText`; `complete` means no remainder, not
semantic sufficiency. Returned bytes measure only preview text. Spans and group
order describe the rendered view's groups.

Continuation is a literal local remainder, not an authenticated cursor. A future
wire consumer must choose preview fields rather than transmit fullText alongside
the preview and negate savings. Normal consolidation/lens output is never Skim.

## § 6 — Error model (conceptual)

| Category | Trigger | Recovery |
|---|---|---|
| Invalid representation | Reserved references fail validation/reconstruction | Pure reducer errors; standard dispatch preserves source and marks fallback |
| Unsupported compaction | Form outside supported bounded grammar | Leave unchanged; not a record failure |
| Invalid budget | Zero, or negative in Swift | Error; caller supplies positive budget |
| Oversized first group | Dependency group exceeds budget | Intact output, explicit budget-not-honored flag |

## § 7 — Conformance requirements

**C-1:** Match frozen complete-form output, digests and counts under the same
counter in both ports. Preserve explicit v23.2 golden results.

**C-2:** Match passage text/remainder/full text, spans/order and budget metadata.
Cover empty input, Unicode, fences, invalid budgets, oversized groups,
reconstruction and stable ties.

**C-3:** Test malformed reserved references, bounded JSON and exact integers,
all supported line separators, full-source fallback and intact trailers.

**C-4:** Consumer regressions preserve fingerprint, confidence, SNR and success
math when rendering changes or is disabled. Consolidation preserves full
combined-source boundaries.

Native parity is not blinded semantic qualification. Real comprehension and
useful skim selection are measured separately in the TokenSaver lab.

## § 8 — Out of scope

- Retrieval ranking and ARIA response selection: GeniusLocusKit/ARIA.
- Stored secondary text, reindexing and estate migrations.
- Model use, escalation and user preference gating: future caller policy.
- Authenticated continuation protocol: future access-surface contract.

## § 9 — Open questions

Ordering usefulness and how much Skim can omit without harming record-selection
judgment remain experimental. Conservative grouping may return the entire body.
Neither edge prevents independent use of the complete Distiller.

## Changelog

### 1.2.0 — 2026-09-15

Bound repeated-text expansion by shared byte and ratio settings. Limit failures
preserve the encoded input and carry a structured cross-port error.

### 1.1.0 — 2026-09-15

Add I-6: live reads distill under source-byte, atom and selector-work ceilings
and fall back to the complete source. Paired with INTERFACE 1.1.0.

### 1.0.0 — 2026-09-08

Replace pre-release intent-only contract with native complete-form-v6 and separate
ordering/Skim. Document v22/core-first retirement, actual offsets, fallback,
parser bounds and caller seams.

### 0.2.1 — 2026-09-06

Corrected the library consumer from ingestion to inline hydration.

### v0.2 — 2026-09-02

Added v23.2 attributed converter and rendering metadata.

### v0.1 — 2026-09-02

Initial intent-span specification.
