---
title: AriaLexiconLib Specification
version: 1.0.0
status: active
date: 2026-06-14
description: "Behavioral specification for AriaLexiconLib: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/ARIALEXICONLIB_INTERFACE.md  (the API surface this spec contracts)
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md  (§4.1 storage taxonomy, §5.5 adjective layout, §7.2 acceptance matrix, invariants I-7 / I-8)
  - docs/concepts/ARIA_LEXICON.md  (the canonical prose statement of the grammar)
purpose: |
  AriaLexiconLib reifies the ARIA grammar as data: one noun (the
  Drawer), nine verbs, four adjective categories, and the verb-noun
  acceptance matrix. It carries the words and their relationships and
  nothing else — no behavior, no storage, no state. Every MOOTx01 kit
  and every ARIA surface conforms to this vocabulary, so the Swift and
  Rust ports are conformance-gated to agree on the words themselves.
  The companion INTERFACE document carries the type signatures.
---

# AriaLexiconLib Specification

## § 1 — What this package is

AriaLexiconLib is the single source of truth for the vocabulary every
consumer uses to talk to a MOOTx01 estate. It states the ARIA grammar
in one sentence — *every call is one verb applied to a noun, optionally
constrained by adjectives* — and reifies the pieces of that sentence as
enumerations: the `Noun` shapes the substrate persists, the nine
`Verb`s, the four `Adjective` categories, and the `Acceptance` matrix
that says which verbs each shape accepts. Consumers (LocusKit,
GeniusLocusKit, aria-mcp) import these types so their surfaces speak one
agreed vocabulary instead of forking their own.

This package is a **Lib**: pure vocabulary with no managed state, no
actors, and no lifecycle. Every member is a value type or a pure static
function; the package gives values back and manages nothing.

## § 2 — Scope

This specification defines:

- The noun vocabulary: the eight storage shapes, the one primary noun
  (`Drawer`), and each shape's role relative to it.
- The verb vocabulary: the nine verbs, fixed at nine, and their
  partition into three initiation flows.
- The adjective vocabulary: the four cross-noun categories, fixed at
  four.
- The verb-noun acceptance matrix: which verbs each noun accepts.
- The grammar contract string.
- The cross-port conformance obligation (Swift and Rust agree on every
  value).

This specification does NOT define:

- API signatures — those live in `ARIALEXICONLIB_INTERFACE.md`.
- The *values within* each adjective category (e.g. the specific state
  or trust levels) — those are a bitmap-layout concern owned by
  `GENIUSLOCUS_ARCHITECTURE_SPEC.md` §5.5 and reified as value
  enums in LocusKit. This lexicon names the four categories, not their
  members, so the two do not fork.
- Verb *semantics* (what `capture` does to storage) — those live in the
  consuming kits' specs (LocusKit, GeniusLocusKit).

## § 3 — Position in the kit family

```
AriaLexiconLib  ← (no dependencies)
      ▲
      │  conformed to by
      ├── LocusKit          (estate verb surface, adjective value enums)
      ├── GeniusLocusKit    (unified nine-verb surface)
      └── aria-mcp          (projects the matrix onto MCP tools)
```

**Depends on:** nothing. Zero-dependency by design — it sits beneath
everything that speaks ARIA.

**Consumed by:** LocusKit, GeniusLocusKit, aria-mcp, and any future ARIA
surface. Consumers conform to the vocabulary; the lexicon never reaches
back up to them.

## § 4 — Invariants

**I-1 (verb count, = architecture spec I-7):** the verb set has exactly
nine members: `capture, reanchor, mutate, withdraw, expunge, recall,
propose, associate, learn`. New domain operations compose these; they do
not extend the vocabulary.

**I-2 (adjective category count, = architecture spec I-8):** the
adjective set has exactly four categories: `state, trust, sensitivity,
exportability`. Every persisted row carries a value in each, whatever
its storage shape.

**I-3 (one primary noun):** exactly one noun is `primary` — the
`Drawer`. Every other shape has a non-primary role (`rung`, `structure`,
or `product`).

**I-4 (cross-port value identity):** the Swift and Rust ports declare
the same cases, in the same names, in the same order, and the same
`Acceptance` matrix. Neither port leads; both must agree (conformance
gate, § 7).

**I-5 (data, not behavior):** every member is a value type or pure
function. The package holds no mutable state and performs no I/O.

## § 5 — Behavioral contracts

**B-1 (total acceptance matrix):** `Acceptance.verbs(for:)` is total over
`Noun` — it returns a defined verb set for every noun, including the
empty set for `Vector` (the substrate-managed rung is not directly
verb-addressable).

**B-2 (role partition):** `Noun.role` partitions the eight shapes —
`Drawer` → `primary`; `KGFact`, `Vector` → `rung`; `Tunnel`,
`DiaryEntry`, `Association` → `structure`; `Proposal`,
`LearnedReference` → `product`.

**B-3 (flow partition):** `Verb.flow` partitions the nine verbs — the
six caller-driven verbs (`capture, reanchor, mutate, withdraw, expunge,
recall`), the two substrate-driven verbs (`propose, associate`), and the
one grounding-driven verb (`learn`).

**B-4 (determinism):** every accessor is a pure function of its input —
same input, same output, no ordering or environmental dependence.

## § 6 — Error model (conceptual)

Not applicable. AriaLexiconLib has no failable operations: every member
is a value or a total pure function, so there is no error enum and no
recovery posture. (A consumer that *rejects* an illegal (verb, noun)
pair raises its own error — e.g. GeniusLocusKit's
`VerbError.rejectedByLexicon` — citing this matrix; that error lives in
the consumer, not here.)

## § 7 — Conformance requirements

**C-1:** `Verb.allCases.count == 9` and `Adjective.allCases.count == 4`
(I-1, I-2). The Rust version's `Verb::ALL` and `Adjective::ALL` have the
same lengths.

**C-2:** `Noun.primary == .drawer`, and exactly one noun reports
`role == .primary` (I-3).

**C-3:** the `Acceptance` matrix matches architecture spec § 7.2 for
every noun: drawer accepts {capture, reanchor, mutate, withdraw,
expunge, recall}; tunnel {capture, mutate, withdraw, expunge, recall};
kgFact {mutate, withdraw, expunge, recall}; vector {}; diaryEntry
{recall}; proposal {mutate, withdraw, expunge, recall}; association
{mutate, expunge, recall}; learnedReference {learn, mutate, withdraw,
expunge, recall}.

**C-4:** the flow partition (B-3) and role partition (B-2) hold for
every verb and noun.

**C-5 (cross-port, I-4):** the Swift version and the Rust version produce
identical case names, ordering, flow/role assignments, and acceptance
sets. The shared conformance harness asserts this; a divergence fails
the gate before either port ships.

## Changelog

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
