---
status: decided
question: Should queue draining be a central, process-global dispatcher with a bounded worker pool (instead of independent per-estate drainers), and is that a 1.0 or 1.1 change?
authors: MOOTx01 maintainers
date: 2026-06-23
relates_to:
  - docs/reference/GENIUSLOCUSKIT_SPEC.md
  - docs/reference/NEURONKIT_SPEC.md
  - docs/decisions/DECISION_SIMHASH_BACKENDS_2026-05-18.md
supersedes: none
context:
  - "Today each estate's encode queue has its OWN drain worker, spawned at mountEncodeQueue (Swift Task / Rust std::thread). There is no central drain master."
  - "The Brain/standing-signal scheduler is a second QueueKit queue with its own drain; DreamingDaemon + MaintenanceDaemon are tick-pumped by the autonomic governor (not their own queues)."
  - "QueueKit is the shared queue primitive used by all of them; none registers with a master."
  - "The encode drain was observed running effectively serial (one core) on a 49,261-record import — the dominant CPU consumer and the thing that 'pegs'."
---

# Decision: Central Drain Master + Global Bounded Worker Pool (deferred to 1.1)

## Decision

Build a **central drain master** owning a **single process-global worker pool** sized to a configured fraction of cores, fed fair-share by every estate's queue, with the heavy background duties (encode + dreaming/maintenance) all drawing from that one budget. **Deferred to 1.1.** For 1.0, the encode throughput problem is solved by adding a bounded worker pool *inside the existing per-estate drain* (see "1.0 stepping stone" below); the global cross-estate CPU cap is the 1.1 value the central master adds.

## Why a central master (and why per-estate cannot do it)

The motivating guarantee: **"mootx01 never uses more than N% of the machine's cores at any time, regardless of how many estates it hosts or what they're doing"** (N is a configured fraction — e.g. 0.5).

- A central master owns ONE global pool of `poolSize = max(1, round(fraction × cores))` workers. Every estate's queue feeds it; the master pops fair-share across them and dispatches to the pool. Because concurrency is bounded by the fixed worker count, total concurrent compute is `≤ poolSize` **no matter how many estates** — 1 or 50. The cap is enforced by worker COUNT, not by throttling each worker.
- **Per-estate drainers cannot guarantee this.** Each sees only its own queue; five estates each spinning up to `poolSize` workers = `5 × poolSize` = machine overrun. No estate has the global view to back off. Only a shared budget bounds the total.

## Mechanism

- `poolSize = max(1, round(fraction × cores))`, `fraction` from config (static at startup; could later be adaptive under thermal/battery pressure). Define the denominator explicitly (logical cores vs performance-cores-only on Apple Silicon).
- Master holds a registry of `(estate → queue)`. Estates register at provision, deregister at close (replacing today's per-estate worker spawn).
- Fair-share pop policy (round-robin across registered queues) so one busy estate cannot starve others.
- Compute parallel, **write serial**: the pool parallelizes the embed compute (independent per workload — the bit-identity-safe axis); per-estate SQLite writes still funnel (single-writer). Output stays deterministic (results keyed/ordered before write).
- **For a TRUE total cap**, the DreamingDaemon and MaintenanceDaemon pumps must draw from the same global budget — otherwise the cap is "poolSize for encode" + whatever the daemons use concurrently. Routing all heavy background work through the one budget is what makes the cap process-wide. (This also retires the QoS hack: a real budget beats "be polite on efficiency cores.")
- Reconcile the encode queue's three existing drain paths into the master: the per-estate background worker (replaced), the governor's `drain_encode_queue_once` tick pump, and the synchronous `await_encode_drain` barrier (bulk/test) must coordinate with the master rather than drain independently.

## Cost

Subsystem-level: ~1,500–2,500 lines across both ports + ~500 tests + spec/INTERFACE updates. New subsystem (master+pool), touching GLK intake, CorpusKit ingest (compute/write split — partly done via M3), NeuronKit governor (daemon budget), and the resident-daemon startup. Must be actor/thread-correct on both ports and conformance-gated (deterministic under pool scheduling).

## 1.0 stepping stone (separate-pump fix)

For 1.0 we add the worker pool **inside the existing per-estate drain** (no master, no registry, no daemon-budget): ~800–1,000 lines both ports. Delivers multi-core encode, un-pegged, fast import — the 1.0 goal. It does NOT deliver the global cross-estate cap. ~70% of it (the Corpus concurrent-compute) carries forward into this central master unchanged; only the pool's LOCATION (per-estate → master) + fair-share/registry get reworked when 1.1 lands.

## Status

Decided: build the central drain master in **1.1**. 1.0 ships the per-estate worker pool. This record is the target-architecture spec; a 1.1 implementation mission cites it.
