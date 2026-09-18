---
version: v0.1
date: 2026-08-14
status: accepted
description: Expanding the Observer scope to include a daily performance-health sample trend while preserving the no-aggregation, no-alerting, no-query-surface boundary.
---

# DECISION: Observer Aggregation Boundary Expansion (D6)

## Original ruling (DEBT-3, Bob 2026-06-10)

The Observer scope is defined in `Observer.swift` as verbatim:

> "a minimal live observer loop, NOT a telemetry platform. No aggregation, no alerting, no query surface — the window is a bounded recent buffer and nothing more."

That boundary was correct at the time: the Observer was introduced to prove
liveness and provide a bounded recent window for the status surface. It was
not intended to answer "how fast is ingest this week?" or "is CYCLE creep
getting worse?"

## The expansion (Phase-4 brief §6, approved 2026-08-13)

A daily performance-health duty (A7) derives INGEST and CYCLE timing samples
from the estate audit log (via `NeuronKit.deriveTimings`) and persists them
through the existing `PersistenceStatsSink` write path — the same path the
resident observer uses for live samples.

This is aggregation in the literal sense: per-day derived p50/p95 values
from a window of audit events. The DEBT-3 ruling's literal text ("no
aggregation") would prohibit it. Bob approved the expansion because the
alternative — no retained trend — defeats the duty's purpose. CYCLE creep
across days is the early warning for P6 (tier-3 novel-term latency growth)
and P7 (dream-cycle latency growth). Without a trend, a daily snapshot is
a single point with no reference.

## The new boundary

The expanded scope is:

1. **Daily derived samples** — one derivation per day per estate, paged from
   the audit log watermark. Produces INGEST p50/p95, CYCLE tier-2 through
   tier-4 p50/p95, unbounded-row counts, and sample counts.

2. **Retained trend** — samples are stored in the existing stats store
   (bounded by the sink's existing schema; no new store, no new table beyond
   what `insertMetric` already creates).

3. **Still no alerting** — the duty detects nothing and fires no alerts.
   It writes metrics. Consumers (future dashboards, the autonomic governor)
   read metrics.

4. **Still no general query surface** — the stats store is not a query
   database. The moot-mgr panel (A8, a later mission) may add a read path;
   this decision does not add one.

5. **Still bounded memory** — the `PersistenceStatsSink` write path's
   in-flight cap and the store's retention policy bound unbounded growth
   exactly as before.

## Why history is kept

CYCLE creep across days is the early warning signal the duty exists to
provide. Without retained history, the daily sample is a single value with
no baseline. The trend line is what makes the signal actionable: a p95
CYCLE tier-3 value of 480 ms is fine in isolation; 480 ms today vs 120 ms
last week is a regression the governor can act on.

## Comment update

The `Observer.swift` header comment preserves the DEBT-3 quote and adds a
pointer to this decision record for the updated boundary.

## References

- DEBT-3 ruling: Bob's 2026-06-10 memo in `Observer.swift` header
- A7 implementation: NeuronKit `PerformanceHealthDuty` protocol and
  `EstatePerformanceHealthDuty` adapter
- Phase-4 brief §6: approval of daily health indicator with trend line
