---
title: Decision — ContextDistillLib
version: 1.0.0
status: superseded
date: 2026-09-06
description: The deterministic dense-context distiller becomes its own foundation-tier library, ContextDistillLib, in Swift and Rust, with the converter ID as its versioning contract and the Python prototype as its conformance oracle. Addendum 2026-09-03 activates intent-span v23.2 as the product converter and adds the source digest to the stored representation.
superseded_by: ../decisions/DECISION_RETIRED_TECHNIQUES_LEDGER.md
---

> Superseded on 2026-09-06. See [the retirement ledger](../decisions/DECISION_RETIRED_TECHNIQUES_LEDGER.md).
> This document is preserved as history.

# Decision — ContextDistillLib

## Context

The stored dense representation of a drawer (the `distilled` field) is
produced today by the p2.3 pipeline inside GeniusLocusKit's distillation
stage. Blind evaluation on the sample30 and Blind-200 sets showed that
p2.3 loses operative content in heterogeneous records and appends an
episodic tail that carries no mining value. A replacement distiller,
`intent-span`, was developed as an offline Python prototype and frozen
at `intent-span@intent-span-v22-authority-closure`. It is deterministic,
byte-reproducible across independent conversions, and blind-graded
effective on Debug-7 (7/7) and sample30 (29/30 with one recorded
evaluator disagreement). Its weighted output size is 58.5% of source
bytes on sample30.

The prototype has three properties that make it a library rather than a
kit feature:

- It is a pure function from source bytes to a representation plus an
  attribution record. It touches no persistence, no model, no clock, and
  no estate structure.
- It is consumed by more than one surface: the product distillation
  stage, the benchmark overlay tool, and any future `mootx01 upgrade`
  step that re-distills populated estates.
- Its correctness is defined by conformance to canonical vectors, the
  same discipline SubstrateLib applies to its kernels.

## Decision

1. **A new foundation-tier library, `ContextDistillLib`,** is created
   under `packages/libs/`, with Swift and Rust implementations. It has
   zero dependencies on other MOOT kits and zero external dependencies.
   It sits at the same tier as SubstrateLib and AriaLexiconLib.

2. **The converter ID moves with the library** and is its public
   versioning contract. Every representation the library produces is
   attributed with a converter ID of the form
   `<candidate>@<ruleset-version>`, for example
   `intent-span@intent-span-v22-authority-closure`. The ID is stored in
   the drawer's `distilledPipelineVersion` field. A change to any
   selection, closure, or compaction rule bumps the ruleset version. Two
   representations with the same converter ID and the same source digest
   are byte-identical by contract.

3. **The Python prototype is the conformance oracle, not a product
   path.** Its output on Debug-7, sample30, and Blind-200 becomes the
   canonical test-vector set. Both ports must reproduce those bytes
   exactly before the library is used by any product surface. Neither
   port leads; both must agree with the vectors and with each other.

4. **GeniusLocusKit's distillation stage becomes a consumer.** The
   p2.3 producer is replaced by a call into ContextDistillLib. No bridge
   between the two producers is kept. The benchmark overlay tool
   consumes the same library, so harness and product provably run the
   same code.

5. **Initial benchmark measurements may use the Python payloads.** The
   first judging runs that test whether Model-Plus mining improves
   results use the prototype's overlay output. Those results remain valid
   after the port because the port is gated to the same bytes. The
   official Swift path is measured again and the results updated at the
   beta-to-stable transition.

6. **The residual error floor is reported, not chased.** A deterministic
   distiller has no repair loop. Structural misses, such as the
   two-line heading-plus-dated-fact shape found in Blind-200, are
   expected at roughly one percent. They are enumerated per converter ID
   and fixed by rule with a ruleset bump, never by a model.

7. **Publication.** The library is a candidate for the public SDK
   venues. Its zero-dependency profile places it in `moot-core`
   alongside SubstrateLib. Venue assignment is confirmed at the first
   publish, not here.

## Consequences

- Populated estates carry p2.3 representations. Re-distilling them is a
  migration delivered through `mootx01 upgrade`, keyed on
  `distilledPipelineVersion`. Every drawer whose stored converter ID
  differs from the current one is a regeneration candidate.
- The `distilled` field's four companion columns are unchanged. The
  converter ID reuses `distilledPipelineVersion`; no schema change is
  needed for attribution.
- The library needs its own `CONTEXTDISTILLLIB_SPEC.md` and
  `CONTEXTDISTILLLIB_INTERFACE.md` under `docs/reference/` before the
  first consumer lands.
- The benchmark artifact estates must have every dense field
  recomputed under the new converter ID before comparative judging.
  That recompute is a one-time cost per converter ID and is scheduled
  as its own work item.

## Addendum — 2026-09-03: intent-span v23.2 is the product converter

Ruling (Bob, 2026-09-03): search over the dense lane built from the
distilled text is stable (LoCoMo drift ≈ 0.01 Hit@10), so the product's
active converter is `intentSpanV23Attributed` /
`IntentSpanV23Attributed`, converter ID
`intent-span-v23-attributed@intent-span-v23.2-attributed-prose`. The v22
ruleset stays in the library with its beds; the product routes to no
other converter, applies no classifier at distillation time, and carries
no fallback route.

One product distillation path: the same library implementation runs for
new records, schema upgrade, backfill, and artifact redistillation, always
from the complete authoritative original content, which is never altered;
the enrichment trailer derived from that content is appended.

Stored identity: the row carries the converter ID
(`distilledPipelineVersion`) AND the source digest
(`distilledSourceDigest`, SHA-256 hex of the complete content — the
library's `sourceDigest` / `source_digest`), a schema change delivered as
LocusKit v18 and GeniusLocusKit estate format 1.3. A representation is
current iff both match the active converter and the row's content; stale
output is regenerated by the sweep. Identical source under an identical
converter ID stores identical bytes and an identical digest.

Decision 2 above is amended accordingly: the converter ID alone identified
the representation; the pair (converter ID, source digest) now does.
Consequence "no schema change is needed for attribution" no longer holds:
the digest column is that schema change.

## Rejected alternatives

- **Keep the distiller inside GeniusLocusKit.** Rejected because the
  overlay tool and the migration path would each need their own copy or
  a reach-around into the kit, violating the layering rule.
- **Ship the Python as the product distiller.** Rejected because the
  product is Swift and Rust, and the prototype exists only to define
  the bytes the ports must match.
- **Store the converter ID in a new column.** Rejected because
  `distilledPipelineVersion` already carries exactly that meaning.

## Changelog

- v0.2 (2026-09-03): accepted; addendum records the activation of
  intent-span v23.2 as the product converter and the source digest on the
  stored representation.
- v0.1 (2026-09-02): initial proposal.

## Supersession changelog

### 1.0.0 -- 2026-09-06

Archived the retired contract. The retirement ledger records its disposition.
