---
version: 0.2.1
status: accepted
date: 2026-09-06
description: >
  Recall result ordering contract: score in the payload; (score DESC,
  subject ASC) as the only ordering; windowed tie resolution at the
  presentation boundary (4x gate); no UUID in ordering; no third
  tie-break. 0.2.1: wording only — hedging vocabulary removed from the
  prose; no decision change.
---

# Decision: Score-Transparent Ordering

## Rulings (Bob, 2026-08-24)

1. **Windowed tie resolution at the presentation boundary (4x bound).**
   A result limit is a request about presentation size; a tie is a fact
   about the data. For a requested limit N the system works with a 2N
   view; a tie group that starts inside the top N and extends past the
   view triggers ONE widening to 4N, hunting the group's break point:
   - Break found within 4N → the WHOLE tie group is returned (count > N,
     honestly expanded — the limit yields to the facts).
   - Break NOT found within 4N → return FEWER than N: only the
     determinate prefix above the unbroken group, plus the disclosure
     "additional results share this score on a non-deterministic tie;
     refine the query." No arbitrary member of an unresolved tie group
     is ever returned — the system hands back only what the scores
     determine, and the message steers the AI toward a more
     discriminating query.
   4x the requested window is the hard throttle gate. Internal gates
   (scan cap, pool caps) keep their existing hard caps — no expansion —
   but cut along the stable (score, subject) order and record a
   disclosure flag when a cut lands inside a tie group.

2. **Sort by (score DESC, subject ASC) and nothing else.** The subject
   is content-derived, deterministic across builds, and human-legible.
   No other ordering key exists anywhere in the recall path.

3. **No third tie-break.** Rows equal in both score and subject are
   presentationally interchangeable: if they are duplicates the order is
   meaningless; if they are meaningfully different, the scoring should —
   and eventually will — say so. Their mutual order is unspecified by
   design.

4. **The score travels in the return payload.** The consumer sees the
   tie instead of inferring a false priority from row order. The payload
   exposes the discriminating information. Rendering: a trailing
   4-decimal column (` · %.4f`) on each dense row. The visible score
   column is the SOLE tie disclosure in the reply body — the header does
   not name tie groups (Bob, 2026-08-24).

5. **No UUID anywhere in ordering.** UUIDs are minted per estate build;
   any ordering influence makes same-data estates answer differently
   (measured 2026-08-24: 12/25 same-recipe synthesize outputs differed
   on UUID-order effects alone).

## Problem this settles

Ranking questions are frequently underdetermined: when ten rows share
the top score, "the top five" is not a fact about the data. The prior
behavior silently returned an arbitrary five (tie-broken by per-build
random UUIDs at several truncation points), which (a) presented an
underdetermined answer as determined, (b) made two estates built from
the same data give different answers, and (c) made benchmark
comparisons measure the UUID coin rather than the system.

## Consequences

- Result COUNT may exceed the requested limit (resolved tie group) or
  fall short of it (unresolved tie, determinate prefix only + message).
  Callers and the MCP surface document this: a limit is a request, not
  a guarantee; the scores decide.
- The dense-row payload gains a score field (surface change; SPEC and
  INTERFACE bumps; token cost is one short number per row).
- Every internal truncation cuts along the stable (score, subject)
  order, so set composition is deterministic end to end; the prior
  content-key tie-break patches (RD-01 family) are subsumed and retired
  where redundant.
- Benchmark figures measured before this contract are not comparable to
  figures measured after it. The full re-measure (already ruled) runs
  ON this contract, once.

## Validation

Measured on the 25x25 study (three same-recipe estates: two fresh
builds, one charter-surgeried artifact; commit 18defd878): pairwise
identical synthesize answers (UUID-masked) went 13/25, 13/25, 15/25 to
25/25 on all three pairs from the content-stable candidate order and
score column alone — before the windowed tie resolution lands.

## Changelog

- v0.2 (2026-08-24) — accepted. Score rendering fixed at 4 decimals;
  score column ruled the sole tie disclosure (no header naming);
  validation result recorded.
- v0.1 (2026-08-24) — initial draft from the ordering design session.

### 0.2.1 -- 2026-09-06

Removed the retired adornment analogy from the score-presentation rationale.
