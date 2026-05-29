# Agent howto: working on the substrate

This document orients an agentic programming agent (Claude or
otherwise) picking up substrate engineering work. It is the
agent-facing complement to the human-facing
`docs/decisions/README.md` and `docs/validation/substrate_math_performance/README.md`.

Read time: 15 minutes. Assumes you can read the cookbook and the
decision records on demand but have not yet done so.

## What kind of work this is

The substrate is a math-first engineering project. The cookbook
(`GENIUSLOCUS_ENGINEERING_COOKBOOK_v0.36_2026-05-16.md`) is the
constitutional specification; the reference implementations
(Swift `GeniusLocusReference/`, Rust `rust/`) satisfy it; the
test harness (`test-harness/`) measures and validates.

Engineering decisions are made by measurement, not opinion. The
methodology gate at
`docs/decisions/METHODOLOGY_DATA_MANIPULATOR_GATE_2026-05-17.md`
codifies the protocol. Every claim is reproducible from a
stress-test invocation at a cited commit on cited hardware. Every
decision document follows the same template and cites date +
hardware tag + commit hash.

This is not a startup. The substrate runs on a single user's
device and federates with paired estates. Performance budgets are
real and bandwidth-bound. Premature optimization is forbidden; so
is shipping a kernel before measurement. The methodology gate
exists because paper analysis was wrong in five of eight Phase 2
findings; the protocol catches the wrong-direction findings before
they ship.

## What you read first

In order:

1. `docs/decisions/README.md` — the navigable index
2. `docs/decisions/PHASE_2_NARRATIVE.md` — chronological story of
   the 16 Phase 2 commits
3. `docs/decisions/DECISION_PHASE_2_FINAL_SELECTION_2026-05-18.md` —
   the entry point document; one row per documented production
   need with the selected approach and the proof
4. `docs/decisions/METHODOLOGY_DATA_MANIPULATOR_GATE_2026-05-17.md` —
   the protocol that produced the selection table
5. The per-op decision record for the op you are extending
   (or_reduce, hamming, simhash, or top-K)
6. The cookbook (`GENIUSLOCUS_ENGINEERING_COOKBOOK_v0.36_2026-05-16.md`)
   §4.4 (portable kernel layer) and §17 (performance budgets, including
   the new §17.6 measured outcomes)
7. The reference implementation for the op
   (`GeniusLocusReference/glref-swift-PortableKernel-{Kernel}.swift`)

You do not read the entire cookbook unless you are introducing a
new primitive or amending the spec; those are upstream concerns.
Kernel work touches §4.4 and §17 only.

## How the work is structured

Phase 2 was organized into greek-letter sub-phases:

  Phase 2.α (alpha):  foundation + or_reduce
  Phase 2.β (beta):   hamming + three measured rejections
  Phase 2.γ (gamma):  simhash + methodology gate in operation
  Phase 2.δ (delta):  deferred backlog + two declines

A typical sub-phase has these commits in order:

  1. SCOPING commit. The scoping doc walks the 5-axis methodology
     template and triages candidates into "measure" vs "decline
     with math." It is committed BEFORE any implementation work.

  2. IMPLEMENTATION commits. One per candidate. Each commit adds
     the candidate kernel, runs conformance, runs the benchmark
     sweep, captures JSON output. Decision record gets an
     addendum citing measured numbers.

  3. CLOSURE commit. Final selection table for the sub-phase.
     May decline late candidates with architectural math.

Each commit message is structured. Read the existing commit
messages for the pattern; they follow Bob's voice (no em-dashes,
no double hyphens, no marketing language, measured confidence).

## Engineering by wallet: the protocol

The central rule: **for any candidate kernel, do not commit to
the implementation before doing the measurement that would
falsify it.**

A candidate goes through these gates:

  Gate A — scoping. Is the candidate plausibly competitive on
    this hardware? If the architectural math says no, decline
    here. Cite the math.

  Gate B — conformance. Does the candidate produce byte-identical
    output to the scalar reference for every test vector? If no,
    fix until yes. Conformance is non-negotiable.

  Gate C — measurement. Run the candidate against the stress-test
    sweep. Capture the JSON. Compare against the selected default
    (currently SimdKernel for every documented op).

  Gate D — disposition. If the candidate wins, update the per-op
    decision record's selection. If it loses, write a rejection
    addendum. Either way the candidate stays in the source tree
    for future re-measurement.

The two formal decline gates (which skip Gate C):

  Decline Gate 1 — crossover beyond harness range. Used when the
    candidate's floor and slope are both already measured and the
    crossover with the current default lies outside the working
    point space. Phase 2.γ-3 (Metal SimHash) used this.

  Decline Gate 2 — bandwidth floor approached. Used when the
    current default approaches the cookbook §17.5 bandwidth floor
    within measurement noise, and the candidate cannot beat the
    floor (because the bandwidth demand is layout-invariant for
    the op). Phase 2.δ-3 (bit-slice Hamming) used this.

Both decline gates require measured bounds. Paper estimates never
suffice for decline; they only suffice for "investigate further."

## Workspace conventions

Bob works in `[MODE: SCOPE+DRAFT]` for substrate engineering. The
mode constrains read/write authority:

  Read-only on cookbook math (`docs/canon/`, `docs/specs/`,
    anything GeniusLocus/Substrate math).
  Write authority on substrate engineering work
    (`docs/decisions/`, `docs/validation/substrate_math_performance/`,
    reference implementations, test harness).

When in doubt, ask. Do not modify the cookbook without explicit
authorization (Bob owns it; updates require his sign-off). Do not
modify v0.35 spec files. Do modify decision records, reference
implementations, and harness code.

Branch is always `develop`. Commits go directly to develop; no
PR workflow. The substrate is a single-user, single-developer
project at this stage.

Workspace location: `/Users/bob/devlop/mootx01`. Substrate work
under `docs/validation/substrate_math_performance/`. Decision records
under `docs/decisions/`.

## How to add a new kernel

Walked in detail in `docs/validation/substrate_math_performance/README.md`.
Summary:

  1. Read the cookbook §4.4 and the relevant per-op decision record.
  2. Create `glref-{lang}-PortableKernel-{Name}.{ext}` next to
     the existing kernel files.
  3. Implement the `SubstrateKernel` trait. Override only the ops
     the new kernel optimizes; inherit scalar defaults for the rest.
  4. Register in `KernelRegistry.available()` and `KernelSelector.parse()`.
  5. Run `validate-vectors --kernel {name}` against every vector.
     Every CRC must match the scalar reference. If they do not,
     the kernel is broken, not faster.
  6. Run `stress-test --kernel {name}` and `topk-bench --kernel
     {name}` (if applicable). Capture the JSON.
  7. Write a decision-doc addendum in the per-op record.
  8. If the new kernel becomes the production default, update
     `kernelForCurrentPlatform()` and the per-op selection table.
  9. Commit. Commit message follows the existing pattern.

## How to add a new op

Less common. New ops are driven by cookbook additions (a new
primitive at §1.2 P1-P12 or §8 algorithms). Walked in
`docs/validation/substrate_math_performance/README.md`. Summary:

  1. Cookbook addition (separate workstream; not your concern
     unless explicitly authorized).
  2. Add to Swift scalar reference under
     `GeniusLocusReference/glref-swift-{...}.swift`.
  3. Mirror in Rust scalar reference.
  4. Add to `SubstrateKernel` trait with scalar default.
  5. Generate test vectors via `gen-vectors`; commit to
     `test-harness/vectors/{name}.json`.
  6. Validate the Rust scalar against the Swift-generated vectors.
  7. Write a per-op decision record using existing per-op records
     as a template.
  8. Run a measurement sweep across every existing kernel via the
     trait's default; document which kernels would benefit from
     an override.

## Tone and writing conventions

Decision records and commit messages follow Bob's voice:

  - Turabian-style discipline. Periods. Complete sentences.
  - No em-dashes. No double hyphens.
  - No horizontal rules in commit messages (markdown `---` ok
    in decision records as section separators).
  - No emojis.
  - No rhetorical fragments used as punches.
  - No cascading tricolons.
  - No marketing hype.
  - No random bold.
  - Measured confidence. Clarity over cleverness.

Code is written in the same voice. Comments explain what the
compiler will do (e.g., "lowers to eor.16b + cnt.16b on aarch64"),
why the implementation is shaped as it is (e.g., "parallel arrays
beat tuple arrays for cache behavior"), and what the conformance
contract is (e.g., "Tie-break by ascending index preserved by
the strict >= early exit").

## When to ask Bob

  - Before modifying the cookbook
  - Before adding a new top-level documentation document
  - Before declining a candidate WITHOUT measurement (you may
    invoke Gate 1 or Gate 2 only if both bounds are measured)
  - Before changing the production dispatcher
  - When the methodology gate produces an ambiguous result (e.g.,
    a kernel that wins on some batch sizes and loses on others)

You do NOT need to ask before:

  - Running benchmarks
  - Writing a decision-doc addendum
  - Adding a new candidate kernel (the trait surface accommodates
    it; the conformance gate catches errors)
  - Cleaning build artifacts (they are all gitignored)

## Reproducibility

Every claim in a decision record is reproducible from a stress-
test invocation at a cited commit on cited hardware. The procedure:

  1. `cd /Users/bob/devlop/mootx01`
  2. `git checkout <commit>`
  3. `cd docs/validation/substrate_math_performance/test-harness/swift`
  4. `swift build -c release`
  5. `.build/release/stress-test --kernel {name} --quick` (or
     `.build/release/topk-bench --quick` for top-K)
  6. Compare reported `ns_per_call_min` against the table cited.

Hardware tag (`Hardware.tag()` in the harness) tells you whether
the measurement transfers. apple-m5-max is the Phase 2 baseline.
Other M-series should produce ratios in the same direction; the
SimdKernel selection should hold because kernels were rejected by
ratio, not absolute threshold.

## When you finish a sub-phase

A sub-phase closure looks like:

  1. Final selection table for the sub-phase (in the relevant
     per-op decision record's closing section or a separate
     PHASE_2_X_FINAL.md).
  2. Methodology ledger update (the table of "paper said X,
     measured Y, direction Z").
  3. Phase 2.ε backlog update (track deferred items with
     explicit trigger conditions for revisitation).
  4. Commit closing the sub-phase with the table and ledger.

The final selection for Phase 2 is at
`docs/decisions/DECISION_PHASE_2_FINAL_SELECTION_2026-05-18.md`
as a model for what sub-phase closures look like.

## Common pitfalls

  - **Skipping conformance.** The byte-identical CRC against the
    scalar reference is non-negotiable. A kernel that's "almost
    right" is broken, not faster.
  - **Citing paper estimates without measurement.** The methodology
    gate exists because paper was wrong five of eight times in
    Phase 2. Cite measurements, not estimates.
  - **Editing existing decision records.** Material new content
    goes in addenda or supersedes records, not edits. Typo fixes
    and clarifications are fine.
  - **Adding documents.** Bob owns the documentation surface.
    Adding a new top-level document needs his authorization.
    Adding addenda to existing records does not.
  - **Modifying the cookbook.** Bob owns it. Updates need his
    sign-off. The §17.6 Phase 2 amendments were authorized; future
    cookbook edits require explicit authorization.
  - **Running paper-only experiments.** If you are about to decline
    a candidate without measurement, the candidate must pass either
    Decline Gate 1 or Decline Gate 2 with measured bounds. Otherwise
    measure.

## What "done" looks like

For a single kernel addition:

  - Source file committed under `glref-{lang}-PortableKernel-{Name}.{ext}`
  - Registry updated
  - Conformance gate passes (`validate-vectors` PASS for every vector)
  - Benchmark JSON captured under `benchmarks/results/{date}-{hw}/`
  - Decision-doc addendum committed with the measured numbers
  - If production default changes, dispatcher and selection table updated

For a sub-phase closure:

  - Final selection table for the sub-phase
  - Methodology ledger update
  - Phase 2.ε backlog reconciled
  - Closure commit

The Phase 2 work is the existing reference. Read those commits,
those decision records, that selection table. Match the pattern.
