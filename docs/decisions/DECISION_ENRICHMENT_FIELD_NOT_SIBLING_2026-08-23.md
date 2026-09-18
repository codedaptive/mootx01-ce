---
version: v0.1
status: accepted
date: 2026-08-23
description: >
  Project mandate: derived records that improve existing records
  one-for-one are a missing schema field, never sibling records.
  The 1-for-1 test. Third recurrence of the anti-pattern; measured
  consequence recorded.
---

# Decision: Enrichment Is a Field, Not a Sibling (the 1-for-1 test)

## Rule

Before any design mints new records, apply the test: will the new
records stand in roughly one-for-one correspondence with existing
records, existing to improve them? If yes, the design is a missing
FIELD on the existing schema — added with a migration via
`mootx01 upgrade` — never a sibling record. The schema is not frozen
precisely so that this field can be added.

## Rationale

A sibling record must earn its own retrieval reach from zero and must
be kept consistent with its source by additional machinery (links,
cascades, cleanup passes). A field inherits its source record's reach,
lifecycle, and supersession for free: if the source is found, the
enrichment arrives with it; if the source is superseded, the
enrichment goes with it. Sibling-record enrichment competes against
its own source material and loses.

Measured consequence (gold mining, 2026-08-23): claims minted as
sibling drawers changed only 69 of 216 answers and corrected 5 of 151
(3.3%) because each claim had to outrank the very drawers it was
derived from. The field design inherits the source drawer's measured
0.95 any@5 reach by construction.

## Discriminating questions (any "yes" means field, not sibling)

1. Does every record (or nearly every record) of a type want one?
2. Does the new record cite exactly one source record as its reason
   to exist?
3. Is the new record meaningless if the source is deleted?
4. Is the new record only useful when it travels WITH the source in a
   results payload?

A new noun is justified only when the record has independent identity:
its own lifecycle, its own reach, and meaning without any single
source. Derivatives never qualify.

## Precedent in the schema

The per-drawer distillate lane is the standing in-schema pattern for
derived, per-record enrichment returned with the payload.

## History

Third recurrence of this anti-pattern over several months; this record
makes the test a standing gate for every design conversation and every
pre-flight that introduces a record type.
