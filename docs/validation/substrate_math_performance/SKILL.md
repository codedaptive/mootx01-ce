---
name: substrate-engineering
description: |
  Substrate engineering work on the GeniusLocus nexus repo
  (/Users/bob/devlop/mootx01). Trigger when working on kernel
  implementation, performance measurement, decision records, or
  the engineering-by-wallet methodology. Covers the per-op kernel
  dispatch architecture (or_reduce, hamming, simhash, top-K),
  the conformance gate (byte-identical to scalar reference), and
  the two formal decline gates for candidate rejection without
  measurement. Trigger on phrases including "substrate", "kernel",
  "GeniusLocus", "SimdKernel", "MetalKernel",
  "cookbook §4.4", "Phase 2", "methodology gate", "engineering
  by wallet", "stress-test", "topk-bench", "validate-vectors",
  or "decision record". Do NOT trigger on general performance
  optimization in other repos; substrate work is specific to the
  nexus repo at /Users/bob/devlop/mootx01.
when_to_use: |
  Use when the work is in /Users/bob/devlop/mootx01 AND involves
  any of:
    - Kernel implementation under
      docs/validation/substrate_math_performance/GeniusLocusReference/
      or packages/libs/SubstrateLib/rust/
    - Decision record authoring under docs/decisions/
    - Performance measurement via the test-harness binaries
      (stress-test, topk-bench, validate-vectors)
    - Cookbook references (§4.4 portable kernel layer, §17
      performance budgets)
    - The engineering-by-wallet methodology
when_not_to_use: |
  Do NOT use when:
    - Work is in a different repo (ddfactory, forge, etc.)
    - Work is on cookbook math content (read-only per Bob's
      [MODE: SCOPE+DRAFT] constraint)
    - Work is on v0.35 spec files (those are upstream)
    - General performance questions unrelated to the substrate
---

# substrate-engineering skill

Operating guide for substrate kernel work in the nexus repo. The
substrate is a math-first engineering project. Cookbook is
constitutional; reference implementations satisfy it; the test
harness measures and validates. Engineering decisions are made
by measurement, not opinion.

## Workspace

Location: `/Users/bob/devlop/mootx01`. Branch: `develop`. Bob works
in `[MODE: SCOPE+DRAFT]` for substrate engineering.

Read-only:
  - `docs/canon/`, `docs/specs/` (cookbook math, v0.35 spec)
  - `GENIUSLOCUS_ENGINEERING_COOKBOOK_v0.36_2026-05-16.md`
    (Bob owns; updates require his sign-off)

Write authority:
  - `docs/decisions/` (decision records)
  - `docs/validation/substrate_math_performance/` (kernel implementations,
    test harness, AGENT_HOWTO, this SKILL)

## Read first

Before any kernel work:

  1. `docs/decisions/README.md` — navigable index
  2. `docs/validation/substrate_math_performance/AGENT_HOWTO.md` — agent
     orientation
  3. `docs/decisions/DECISION_PHASE_2_FINAL_SELECTION_2026-05-18.md` —
     entry point; one row per documented production need

If you have not read these in the current session, read them
before proposing any kernel change.

## The methodology gate (engineering by wallet)

Central rule: for any candidate kernel, do not commit to the
implementation before doing the measurement that would falsify it.

Four gates per candidate:

  Gate A — scoping (architectural plausibility)
  Gate B — conformance (byte-identical to scalar reference)
  Gate C — measurement (stress-test sweep)
  Gate D — disposition (selection update or rejection addendum)

Two formal decline gates (skip Gate C with measured bounds):

  Decline Gate 1 — crossover beyond harness range, with both floor
    and slope measured. Used in Phase 2.γ-3.

  Decline Gate 2 — bandwidth floor approached within measurement
    noise, candidate cannot beat it. Used in Phase 2.δ-3.

Both decline gates require **measured** bounds. Paper estimates
never suffice for decline.

## Production default (as of 2026-05-18)

```swift
PortableKernel.kernelForCurrentPlatform():
    #if arch(arm64)
    return SimdKernel()
    #else
    return ScalarKernel()
    #endif
```

SimdKernel dominates every documented production need on aarch64.
No learned dispatch. No per-batch-size thresholds.

## Tone and writing voice

Bob's voice (apply to commit messages, decision records, code
comments):

  - Turabian discipline. Complete sentences.
  - No em-dashes, no double hyphens.
  - No emojis, no marketing hype, no rhetorical fragments.
  - No cascading tricolons.
  - Measured confidence. Clarity over cleverness.

Bob goes by "Bob" in all materials, never "Robert J." Commit
message format follows the existing pattern; read recent commits
for the model.

## Quick command reference

Build:
  `cd docs/validation/substrate_math_performance/test-harness/swift`
  `swift build -c release`

Conformance:
  `.build/release/validate-vectors ../vectors/<file>.json --kernel <name>`

Stress-test:
  `.build/release/stress-test --kernel <name> --quick`
  `.build/release/topk-bench --kernel <name> --quick`

Rust mirror:
  `cd ../rust && cargo build --release && cargo test`

## When to ask Bob

  - Before modifying the cookbook
  - Before adding a new top-level documentation document
  - Before declining a candidate WITHOUT measurement (unless both
    bounds for Gate 1 or Gate 2 are measured)
  - Before changing the production dispatcher
  - When measurements are ambiguous (wins on some batch sizes,
    loses on others)

Not required to ask before:

  - Running benchmarks
  - Writing decision-doc addenda
  - Adding candidate kernels
  - Cleaning gitignored build artifacts

## Anti-patterns

  - **Skipping conformance.** Byte-identical CRC is non-negotiable.
  - **Citing paper without measurement.** Five of eight Phase 2
    findings had paper wrong. Cite measurements, not estimates.
  - **Editing existing decision records.** Use addenda or
    supersedes-records. Typo fixes are fine.
  - **Adding documents without authorization.** Bob owns the
    documentation surface.
  - **Running paper-only experiments.** Either measure or invoke
    a formal decline gate with measured bounds.

## When you finish

For a kernel addition:
  Source file + registry + conformance PASS + benchmark JSON +
  decision-doc addendum + commit (with selection-table update if
  production default changes).

For a sub-phase closure:
  Final selection table + methodology ledger update + Phase 2.ε
  backlog reconciliation + closure commit.

The Phase 2 work (commits d8602d4 through d87d824) is the model.
Match the pattern.
