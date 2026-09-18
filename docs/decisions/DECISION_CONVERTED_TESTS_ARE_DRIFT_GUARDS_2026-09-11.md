---
status: accepted
question: Must every v1 test converted to v2 be green before v2 reaches origin?
authors: MOOTx01 maintainers
date: 2026-09-11
relates_to:
  - docs/engineering/ARIA_INTERFACE_LANE_DECISIONS.md
supersedes: none
context:
  - About 324 v1 test cases were deleted with the v1 surface (adc99bcb1) rather than converted; three independent audits found 0 unreachable capabilities and 0 defects, so the damage was evidence, not product
  - Batches 1 and 2 are converted; batch 3 (64-76 cases) is not dispatched; eight cases pin v1 transport or argument names
  - Every plan since 2026-09-10 assumed the push waited on all of them
---

# Converted tests are drift guards, not push gates

## Decision

The converted v1 tests are tests of code that is already done. They are validators against drift.
More of them landing is better; none of them blocks the push. The design audit of the v2
surface, the review of the 26 operations that only fixture or catalog tests ever exercised,
stays last, and takes the error contract and egress presentation decisions as its criteria.

## Consequences

Conversion batch 3 and the eight-case pending pile leave the push path and run beside the code
work. The benchmark head is the integrated code head, not the fully converted suite.
