---
status: decided
question: How should the substrate select among kernel accelerator backends (NEON, AMX, Metal, AVX)?
authors: MOOTx01 maintainers
date: 2026-05-17
supersedes: none
context:
  - Reframes the prior "pick a track" accelerator-routing decision as a learned-dispatch problem.
  - Ratifies the accelerator architecture decision.
---

# Decision: Learned Dispatch for Kernel Accelerator Selection

## Context

After Path 2 (reference + harness) shipped with 18 primitives at
four-way cross-language conformance, the next workstream candidate
was Path 4: kernel accelerator backends (NEON, AVX, Metal). The
journal carried this as "long-running, separate track."

The first scope pass compared
the three backends as competing tracks and recommended NEON first
based on dev-loop ergonomics. That scope had three flaws
surfaced under self-attack and brainstorming review:

1. Every quantitative number in the doc was fabricated — speedup
   ratios, break-even thresholds, session estimates. None was
   measured.
2. The trait was pair-at-a-time when SIMD wants batches. Per-call
   speedup is the wrong metric; the right metric is throughput on
   batched workloads.
3. The premise — pick a backend, ship it, then pick another — is
   not how the substrate handles other empirical questions. The
   substrate already learns Bradley-Terry weights, calibration
   curves, and ranking weights from runtime data. Kernel dispatch
   is the same kind of empirical question and should be solved
   the same way.

The corrective insight: Metal's overhead is lower
than the doc claimed, AMX is reachable through Accelerate as a
black-box auto-dispatcher (specifically via BNNS for ±1 dot
products, which matches SimHash's structure), and the right move
is to run multiple backends, time them on real workloads, and
let the substrate learn the dispatch thresholds.

## Decision

Adopt the following accelerator architecture:

1. **Extend the `SubstrateKernel` trait** with batched variants
   of the bandwidth-bound ops (`hamming_distance_batch`,
   `simhash_block_batch`, `or_reduce_batch`). Default
   implementations are loops over the existing pair-at-a-time
   scalar ops, so the extension is additive and conformance-
   preserving.
2. **Build a stress-test harness** that runs encode-store-
   retrieve loops at varying batch sizes, records per-(op,
   backend, batch-size) latency, and produces a structured
   manifest table of crossover points. This harness doubles as
   the substrate's battle-testing workload.
3. **Implement backends in parallel**, gated by the same
   18-vector conformance suite:
   - **NEON** (Rust intrinsics + Swift C-bridge): general-purpose
     SIMD for all batched ops on Apple Silicon and ARM Linux.
   - **AMX-via-BNNS** (Swift / Accelerate): SimHash batching
     specifically. Apple's auto-dispatcher picks AMX or NEON
     internally; the substrate calls the high-level BNNS API.
   - **Metal** (Swift compute shader): hamming_top_k at large
     batch sizes where dispatch overhead is amortized.
4. **Dispatch is learned, not hardcoded**. The manifest stores
   per-(op, backend-pair) crossover thresholds, seeded from a
   hardware-tier baseline and refined online from runtime
   measurements. This is the same online-learning pattern used
   for Bradley-Terry weights and calibration curves.
5. **AVX is deferred indefinitely**, until a production x86_64
   deployment lands AND x86_64 hardware is available for
   testing. The architecture supports AVX as drop-in additional
   backends when those conditions hold; nothing in this DR
   precludes it.

## Rationale

The substrate has four other learn-from-data parameters in its
manifest (Bradley-Terry tournament weights, Bradley-Terry ranking
weights, LLM calibration curves, matrix decay half-lives). All
four follow the same pattern: ship a sensible default, refine
from observed data, persist. Kernel dispatch thresholds fit this
pattern exactly. Treating it differently (deploy-time guesses,
hardcoded thresholds, "pick one backend") imposes architectural
inconsistency for no benefit.

The trait extension is the missing piece that lets backends
deliver real speedups. With pair-at-a-time ops, even an
8-lane AVX-512 backend pays per-call overhead that eats the win.
With batched ops, the scalar reference still works correctly (via
the default-impl loop), every backend gets a clean SIMD-shaped
surface to optimize, and the conformance gate stays unchanged.

The stress-test harness would have to be
built anyway for battle-testing. Making it produce structured
output that the substrate consumes as a training set for
dispatch decisions makes one workstream serve three purposes
(correctness battle-test, dispatch threshold measurement,
ongoing regression detection).

AMX-via-BNNS is the genuine architectural finding the
brainstorming surfaced. Apple AMX cannot be programmed directly,
but Accelerate's BNNS API specifically supports binary
±1-weighted dot products, which is exactly the SimHash hyperplane
structure. Apple's runtime decides whether to dispatch a given
BNNS call to AMX, NEON, or scalar based on shape and size, and
the decision is opaque to us — which is fine, because the
conformance gate is byte equality against the scalar reference.
If BNNS's output ever diverges from scalar, conformance fails at
CI time and we catch the regression.

Metal's break-even point is closer than the first scope claimed
(roughly 2k candidates rather than 10k) because unified memory
on Apple Silicon eliminates the explicit CPU↔GPU copy that
dominates discrete-GPU dispatch cost. But the right break-even
is unknowable a priori; the stress-test harness measures it.

## Consequences

### Positive

- **No upfront wrong guesses**. Speedup ratios and crossover
  thresholds are measured, not invented.
- **Backends ship independently**. Each new backend (NEON, then
  AMX, then Metal) is one ship event with its own conformance
  test; nothing is gated on completing all three.
- **Self-tuning per hardware tier**. The same code runs optimally
  on M1, M2 Max, M3 Pro, etc., because the manifest table is
  refreshed from on-device measurements.
- **Architectural consistency**. Kernel dispatch becomes the
  fifth manifest-stored learned parameter, fitting the existing
  pattern.
- **Stress-testing infrastructure is byproduct**. The harness
  needed for battle-testing IS the harness needed for dispatch
  measurement.

### Negative

- **Cold-start cost on unknown hardware**. The first launch on a
  device class without pre-measured defaults either uses
  conservative defaults (slower than optimal for ~10 minutes)
  or runs the stress test in the background. Mitigation: ship a
  baseline table covering the realistic Apple Silicon variants.
- **More moving parts than "pick NEON first"**. Three workstreams
  (trait extension, stress harness, backends) instead of one.
  Mitigation: the workstreams compose cleanly; none is blocked
  on another after Phase 1.
- **AVX users get no acceleration**. Anyone running the substrate
  on x86_64 stays on the scalar reference until AVX is added
  later. Acceptable because there is no current x86_64 deployment;
  revisit if one appears.
- **Non-monotonic latency curves may not fit threshold model**.
  If real measurements show a backend whose latency goes
  faster-slower-faster as batch grows, simple thresholds can't
  capture this. Deferred to a Phase-6 refinement if data shows it.

### Neutral

- The trait extension changes the harness's CRCs (since batched
  cases are now part of the conformance vectors). The
  regeneration is recorded in `test-vector-format.md`'s vector
  regeneration log per existing protocol.

## Alternatives Considered

### Alt A: Ship NEON first (the original scope's recommendation)

Rejected. The framing was wrong — it forced an a-priori bet on
which backend wins which workload, when the substrate is built to
answer that empirically. Also, the NEON-only path leaves SimHash
batching un-accelerated (AMX is the right tool there) and
hamming_top_k at large batch sizes un-accelerated (Metal is the
right tool there). "Ship NEON first" picks one backend for all
ops; the learned-dispatch architecture picks the right backend
per op per batch size.

### Alt B: Hardcoded thresholds per hardware tier

Considered. Ship a manually-tuned table of (op, hardware,
batch_size) → backend, no online refinement. Simpler. Captures
maybe 80% of the value at maybe 30% of the complexity.

Rejected because it doesn't compose with the substrate's existing
manifest-driven learning. Adding a hardcoded table would create
two competing patterns (one for kernel dispatch, one for everything
else). The marginal complexity of online refinement is small
because the infrastructure already exists for the other four
manifest-learned parameters.

That said: hardcoded thresholds **are** the cold-start
fallback. The decision to ship a hardware-tier baseline table is
preserved from Alt B; the difference is that the online refinement
on top of it is the primary mechanism.

### Alt C: Defer all accelerators until a production deployment forces the issue

Considered. Path 4 isn't blocking anything; the scalar reference
correctness-validates LocusKit at the speeds needed for
development. Deferring accelerators until a real bandwidth-
constrained workload appears would let us measure that workload
directly and optimize for it.

Rejected on tactical grounds. The brief called for "the next thing on
the list." Deferring entirely would be a refusal to act, which
doesn't match the brief. But the architectural framing of this DR
preserves the spirit of Alt C: the bulk of the work (trait
extension + stress harness) is the foundation; backend
implementations are added on top as ready, gated by real
workload data. If the project decides after Phase 1 that no backend is
worth shipping yet, the architecture supports that pause cleanly.

## Open Questions

These are deferred to implementation time, not blockers for
adopting this DR:

- **Cold-start baseline coverage**: which Apple Silicon variants
  (M1, M1 Pro/Max/Ultra, M2, M2 Pro/Max/Ultra, M3, M3 Pro/Max,
  M4) need pre-measured baselines? The primary development machine
  provides one; additional baselines come from whoever runs the stress
  test on other hardware. Probably solved opportunistically.
- **Online refinement cadence**: dreaming-pass weekly? Per N
  dispatches? Threshold change-of-mind protection (don't oscillate
  if measurements are noisy near the crossover)? All TBD at
  implementation time.
- **Where does the substrate persist the runtime-refined table?**
  Manifest, or separate kernel-dispatch.json beside the manifest?
  Probably the manifest, but it makes the manifest grow over time.

## Implementation Sequence

Per the architecture doc's §6, four phases:

1. Trait extension + stress-test scaffold
2. NEON backend
3. AMX-via-BNNS backend (Swift, SimHash only)
4. Metal backend (Swift, hamming_top_k at large batch)

Phase 5 (AVX) deferred per §4.4 of the architecture doc.

Phases 2-4 can run in parallel after Phase 1 completes.
