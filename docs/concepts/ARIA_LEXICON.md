---
title: ARIA Lexicon
status: canon
authors: MOOTx01 maintainers
date: 2026-06-14
version: 1.0.0
description: The grammar of MOOTx01 — one noun, nine verbs, four adjectives, and the verb-noun acceptance matrix that compose every ARIA call.
---

# ARIA_LEXICON

*The grammar of MOOTx01: one noun, nine verbs, four adjectives.*

---

ARIA is a language, and a language has a grammar. This document is that grammar. It is the vocabulary every consumer uses to talk to a MOOTx01 estate, stated as the parts of speech they actually compose. [ARIA.md](ARIA.md) is the interface overview; this is the lexicon underneath it.

The grammar is one sentence:

> Every call is one verb applied to a noun, optionally constrained by adjectives.

That sentence is the whole contract. A consumer names an action, names the data it acts on, and may narrow the result by the data's attributes. Nothing else is grammar. Everything else is storage, math, or behavior.

---

## Provenance

This grammar is not new. It was set with the substrate's action vocabulary and written into the architecture spec as "The action vocabulary," in exactly these words: every kit-API call is one of these verbs applied to a noun, optionally with adjectives that constrain the result. Earlier revisions of the spec kept the tables that enumerate the verbs and the adjectives but dropped the sentence that names the grammar, so the spine went implicit. This document restores it and makes it first-class. The verb count and the adjective count are part of the contract, fixed by invariants I-7 and I-8 of the architecture spec.

---

## The noun

The noun is the Drawer. The Drawer is the atomic unit of memory: one verbatim capture, immutable at its core, sitting in a room inside a wing inside an estate. When a consumer thinks of the data, the consumer thinks of a drawer. The noun is the data.

The substrate stores other shapes, and the architecture spec has loosely called all of them "nouns" in its storage taxonomy. They are not nouns in the language. They are facets of the drawer or the residue of verbs acting on it:

- KGFact and Vector are rungs of a drawer, its content rendered as subject-predicate-object triples (rung 1.5) and as a dense embedding (rung 3). They represent the drawer; they are not separate things to think in.
- Tunnel, DiaryEntry, and Association are structure: the edges between drawers and the chronological events about them.
- Proposal and LearnedReference are what verbs leave behind: a candidate awaiting confirmation, and an external reference grounded by `learn`.

The storage shapes remain a LocusKit and GeniusLocusKit concern, each with its own operational bitmap. They do not multiply the noun. There is one noun, and it is the Drawer.

---

## The verbs

A verb is an action on the data. There are nine, fixed. New domain operations compose these rather than extending the vocabulary. The verbs partition into three flows by who initiates them.

| Verb | Flow | The action on the data |
|---|---|---|
| `capture` | caller-driven | Bring user content into the estate as a verbatim drawer. |
| `reanchor` | caller-driven | Move where a drawer sits in structure without changing its identity. |
| `mutate` | caller-driven | Change a drawer's structural state, cascading where the design requires. |
| `withdraw` | caller-driven | Retire a drawer from active circulation while preserving its history. |
| `expunge` | caller-driven, irreversible | Hard-erase a drawer, its audit included. |
| `recall` | caller-driven | Read drawers back by any criteria the estate exposes. |
| `propose` | substrate-driven | Emit a candidate awaiting confirmation. |
| `associate` | substrate-driven | Accumulate connective weight between two objects. |
| `learn` | grounding-driven | Ingest a canonical external reference. |

Caller-driven verbs are invoked synchronously by the application. Substrate-driven verbs are emitted by the standing signals of the Brain layer, not called directly. The grounding-driven verb brings authoritative outside reference in. The naming discipline carried in the Loci Mode tooling reflects the same grammar: an action tool is `<verb>_<noun>`, a query tool is `<noun>_<verb>`.

---

## The adjectives

An adjective describes the noun and constrains a recall. There are four categories, fixed at four by invariant I-8. They are cross-noun: every row carries a value in each, whatever its storage shape. They are stored in the adjective bitmap.

| Adjective | What it describes |
|---|---|
| state | Where the drawer sits in the epistemic timeline: active, pending, contested, superseded, decayed, withdrawn, expired, rejected, accepted, tombstoned. |
| trust | How the content was established: verbatim, observed, imported, proposed, derived, canonical. |
| sensitivity | How exposed the content may be: normal, elevated, restricted, secret. |
| exportability | Whether the content may leave the access perimeter: private or public. |

A recall constrains by adjective. "Recall the trustworthy active drawers" is a verb (`recall`) applied to a noun (drawers) constrained by adjectives (trust, state). That is the grammar doing its work.

---

## Acceptance: which verbs apply

Not every verb applies to every shape. The drawer accepts the full caller-driven set. The facets and residues accept the subset that makes sense for them: `learn` creates a LearnedReference, `associate` produces an Association, a Vector is substrate-managed and not directly verb-addressable. The architecture spec carries the full acceptance matrix in section 7.2. In the language, this reads as which actions apply to the drawer and its facets, not as a grammar of competing nouns.

---

## Reification

The lexicon is a contract, and a contract that is not a first-class object cannot be conformance-tested. Today the grammar lives in method names and scattered enums, which is why two implementations cannot be checked for agreement on the vocabulary itself. The AriaLexiconLib module makes the grammar explicit:

- A `Noun` value naming the drawer and its storage shapes.
- A `Verb` value naming the nine actions and their flows.
- An `Adjective` value naming the four categories.
- The verb-noun acceptance matrix as data.

The module carries no behavior. It is the vocabulary, nothing more, so that everything above it can conform to one definition and a harness can check the Swift and Rust ports against each other.

The lexicon sits at the foundation, above SubstrateLib and PersistenceKit and below LocusKit, VectorKit, and CorpusKit, because every one of them and every ARIA surface conforms to it. GeniusLocusKit implements the unified nine-verb surface against this lexicon as the composition layer. The lexicon defines the words; GeniusLocusKit performs them.

---

## Why the lexicon is its own thing

A library locks the vocabulary to a language. A server locks it to a wire. Method names lock it to whoever wrote them and leave nothing to test. The lexicon is none of those. It is the words, written down once, reified so they hold still, conformance-gated so every implementation speaks them the same way. ARIA is portable because the lexicon is fixed. One noun, nine verbs, four adjectives, and the single sentence that composes them.
