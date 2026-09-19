---
status: accepted
question: When the daemon has more than one estate loaded, which estates may the overlap and divergence lenses read?
authors: MOOTx01 maintainers
date: 2026-09-11
relates_to:
  - docs/engineering/ARIA_INTERFACE_LANE_DECISIONS.md
  - packages/kits/AriaMcpKit/Sources/AriaMCP/AriaV2LensLower.swift
  - docs/reference/GENIUSLOCUSKIT_SPEC.md
supersedes: none
context:
  - v1 handed the lenses an unrestricted registered-estate resolver (resolvePeer, now only in the dark v1 table)
  - v2 declared comparisonHandles (AriaV2LensLower.swift:30), defaulted it empty, and never populated it, so both lenses always refused
  - The previous orchestrator stopped on this as an authority decision
---

# Cross-estate lenses read any estate the daemon has loaded

## Decision

If the daemon has authenticated and loaded an estate, a lens may read it. Which estate a row
lives in is data organisation, not authorization. The comparison-handle map is populated from
the daemon's pool of open estates through one predicate, "is this open estate a member of the
lens pool", which returns true for every loaded estate today.

That predicate is the seam. In 1.2 each estate gains an option to join or exclude itself from
the pool, and the option plugs into the predicate. The seam is code with a comment naming the
1.2 option, not a comment alone. Everything federated is deferred to 1.2 and 1.3.

## Alternatives rejected

- Per-request separately authorized handles. Deferred, not rejected: it is the 1.2 join/exclude
  option, and building it now would put federation work into 1.1.
- Leave the lenses refusing. Rejected: a v1 capability with no v2 route is a migration defect.

## Consequences

Finish-plan Block C5. Both ports. Re-enable estateDivergenceDispatchRoutesSecondEstate and add a
real two-estate case, since nothing in the tree has exercised two mounted estates through a lens.
