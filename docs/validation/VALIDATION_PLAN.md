---
status: in_progress
created: 2026-05-22
last_updated: 2026-06-14
phase: A
description: The phased validation plan for GeniusLocusKit, closing from spec-level claims down to application-level validation.
---

# GeniusLocusKit Validation Plan

This plan is the through-line for validating that GeniusLocusKit
(GLK) does what it was designed to do, ahead of building the
Rust LocusKit port and the kits above GLK in the dependency
graph (NeuronKit, CognitionKit). The plan covers six progressive
phases that close from spec-level claims down to load-bearing
application validation.

The plan itself is the index. The deep content lives in the
artifacts each phase produces, most importantly `CLAIMS_LEDGER.md`.

## Status header

| Phase | Title                              | Status       | Depends on |
|-------|------------------------------------|--------------|------------|
| A     | Claims ledger                      | in_progress  | (none)     |
| B     | Invariant negative-test suite      | not_started  | A          |
| C     | Theorem demonstrations             | not_started  | A          |
| D     | Migration benchmark                | not_started  | A, B, C    |
| E     | Adversarial harness                | not_started  | B, C       |
| F     | Continuous performance gates       | not_started  | B, C       |

## Phases

### Phase A: Claims ledger

Enumerate every empirical claim the substrate makes, in one
flat ledger row per claim. Claims come from the substrate
cookbook (invariants, theorems, hot-path budgets, protocol
contracts), the committed decision records, the GeniusLocusKit
specifications, and the recorded validation status of
`GeniusLocusKit`. Each row carries its claim type, spec
citation, current validation status, and an evidence pointer
(commit SHA, test path, or "pending").

Entry criteria: this plan committed (skeleton sufficient;
ratification not required to start).

Exit criteria: every claim in scope appears as a ledger row,
each row has `claim_evidenced_by` or `claim_evidence_pending`
recorded in the ledger.

Output: `docs/validation/CLAIMS_LEDGER.md` committed, the gap
list extracted into a "Pending Evidence" section.

### Phase B: Invariant negative-test suite

For each I-1 through I-14 (plus any new invariants introduced
by accepted decision records), confirm a negative test exists
that attempts to violate the invariant and fails appropriately.
Many already exist in the existing test suite under operation
names; the work is mapping them to the numbered invariant
surface and authoring tests for gaps.

Entry criteria: Phase A's invariant rows complete, including
each invariant's evidence status.

Exit criteria: every invariant row in the ledger points to a
negative test that runs and passes, with `claim_evidenced_by`
recorded per invariant.

Output: new tests under existing Swift test targets, committed.

### Phase C: Theorem demonstrations

Each of the 8 theorems gets a runnable demonstration as code,
not just a proof in the manuscript. Earlier performance-gate
work covered Thms 4, 6, 7, 8 and met the Thm 5 hot-path budget.
Phase C fills in Thms 1, 2, 3 (and verifies the existing four
still hold).

Entry criteria: Phase A's theorem rows complete with evidence
status per theorem.

Exit criteria: every theorem has a runnable demonstration that
passes, with `claim_evidenced_by` recorded.

Output: theorem demonstration code, committed.

### Phase D: Migration benchmark

The load-bearing validation. Migrates a real-world reference
corpus (a multi-month accumulation of working-memory content)
into a GeniusLocus estate via a four-branch parallel-run
methodology: the corpus is migrated under several distinct
configurations and the branches are compared. Compares each
branch's recall quality, structural fidelity, and behavioral
parity against the source-corpus baseline.

This is the work that proves GLK does what it was designed to
do as a deep memory substrate, not just as a spec implementation.

Entry criteria: Phase A complete; Phase B and C substantially
complete (the threshold for "substantially" is: every invariant
and theorem has either evidenced status or a recorded waiver).

Exit criteria: migration produces zero silent concept loss
under at least one branch, recall quality of the winning branch
meets or exceeds the source-corpus baseline on a curated query
set, benchmark report committed.

The winning branch promotion is a separate decision. Phase D
ends when the report commits; the promotion gate is a
subsequent decision.

Output: `docs/validation/MIGRATION_BENCHMARK_REPORT.md` plus
estate snapshot, committed.

### Phase E: Adversarial harness

Property-based testing of the verb surface and the
standing-signals scheduler. Random verb sequences, concurrent
producers, malformed manifests, partial-failure injection.
Finds the bugs the structured tests miss.

Entry criteria: Phases B and C complete.

Exit criteria: fuzz harness runs for some agreed duration
(starting target: 30 minutes wall-clock per CI invocation) with
zero invariant violations and no panics.

Output: fuzz target under existing test infrastructure,
committed; CI workflow wires it in.

### Phase F: Continuous performance gates

Extends the existing performance-gate pattern to recall,
dreaming tick, federation handshake, and standing-signals
dispatch latency. CI-gated so regressions get caught at PR
time.

Entry criteria: Phases B and C complete.

Exit criteria: CI fails on regression against committed
baseline numbers, with the baseline file checked in and the
threshold per metric documented.

Output: `.github/workflows/geniuslocus-perf-gates.yml` plus
baseline JSON files, committed.

## Milestone triggers

Phase A done plus B and C substantially evidenced → Rust
LocusKit port mission can begin. The Rust version needs the
spec's claims as its conformance target; threshold-2 validation
(implementation passes the spec's claims) suffices, threshold-3
(application validation via Phase D) is not required for the
port to start.

Phase D done with at least one branch hitting zero silent loss
and recall parity → NeuronKit and CognitionKit work can begin.
Those layers compose on actual learned behavior from a real
corpus; threshold-3 validation is the trigger.

Phase D winning branch promoted → the GeniusLocus estate
becomes the primary store, with the source corpus retained as a
backstop. This is a separate decision, not part of Phase D
itself.

## Validation status vocabulary

The ledger and phase tracking use a fixed set of status
predicates so that progress is queryable across the plan and
its artifacts. Extend the vocabulary by appending to this list.

- `validation_phase_status`: phase_id → not_started | in_progress | blocked | done
- `claim_evidenced_by`: claim_id → commit SHA or test path or runnable demonstration path
- `claim_evidence_pending`: claim_id → short reason
- `claim_violation_found_in`: claim_id → commit SHA or test path describing the violation
- `claim_waived_with_rationale`: claim_id → short rationale (used when a claim is deferred or deemed out of scope; Phase D entry criterion accepts waivers)
- `migration_branch_recall_parity`: branch_id → numeric score plus methodology pointer
- `validation_checkpoint`: date → short summary plus commit SHA

## Phase D prerequisites: anchor extractor work

A substrate-level gap and a design constraint together gate
Phase D more tightly than the original plan recorded.

The gap: the substrate has the slot for lattice anchors
(`Drawer.udcCode`, `Drawer.wikidataConcept`) and the recall
scoring depends on them, but no in-tree code populates them
from text content. Phase D's migration benchmark needs anchors
on every migrated drawer.

The constraint, articulated in `DESIGN_CONSTRAINTS.md` C-1:
the substrate cannot depend on external ML runtimes, LLM API
calls, or neural inference engines. Anchor extraction must be
implemented in-tree, deterministic, in both languages, and
conformance-gated.

Three bounded pieces of work sit between the current state and
Phase D entry:

### Deterministic in-tree linguistic pipeline

Build a Unicode-aware tokenizer, Snowball stemmer integration,
gazetteer matcher, and UDC + Wikidata classifier. Pure Swift
and pure Rust source, reference data committed to repo (UDC
schedule top 3 levels, curated Wikidata subset of common
entities). Conformance-gated against shared vectors in the
existing test-harness pattern.

### Apple NaturalLanguage compile-time acceleration

Add a Swift-only `apple-nlp-accel` compile-time flag that
delegates the linguistic pipeline to Apple's NaturalLanguage
framework (NLTokenizer, NLTagger, NLLanguageRecognizer) where
the flag is enabled. Same pattern as the kernel layer's
`simd-nightly` flag per `DESIGN_CONSTRAINTS.md` C-2. The flag
is mutually exclusive with cross-language conformance and is
declared federation-disabled in the build configuration.

### Anchor agreement test

Measures how closely the deterministic in-tree extractor and
the Apple-accelerated path agree on the reference corpus.
Three levels:

- Level 1: direct anchor agreement (UDC equality at depths 3,
  4, and 5; Wikidata Q-ID equality and semantic equality at
  graph depths 2 and 3; the data graph identifies the
  agreement plateau).
- Level 2: recall behavior agreement (Spearman, Kendall tau,
  K-overlap at K=10, 20, 50 over a curated query set).
- Level 3: sampled human judgment on disagreement cases
  (twenty to fifty samples, surfacing systematic vs noisy
  disagreement).

Decision matrix from the data:

- Agreement at the chosen depths exceeds the co-mingling
  threshold: the compile-time flag stays purely a performance
  and quality choice.
- Agreement is structured but offset: a calibration map
  between the two outputs becomes part of the framework
  profile.
- Agreement is high-variance: parallel operation required;
  provenance bitmap tracks which extractor produced each
  anchor and queries can filter or reconcile.

### Phase D entry criteria amendment

The deterministic in-tree linguistic pipeline and the Apple
NaturalLanguage acceleration must land before Phase D can begin.
The anchor agreement test runs as part of Phase D's opening pass
and informs whether the source corpus gets one canonical anchor
set or two parallel ones during the migration benchmark.

## Design notes

These notes record the rationale behind the constraints that
shape the anchor extractor and Phase D.

The substrate's text-to-anchor story is governed by a hard
constraint: the substrate has no external runtime dependencies.
An LLM API call and an ONNX Runtime model runtime were both
considered as deployment options and rejected on determinism
and supply-chain grounds. `DESIGN_CONSTRAINTS.md` records the
four constitutional constraints (C-1 through C-4) that follow
from this rule.

Accordingly, the anchor extractor is deterministic, in-tree, in
both languages, and conformance-gated. The vector tier's third
rung is TF-IDF over framework-profile vocabulary; no embedding
model is the production default at this tier.

The reference corpus serves as a test and profile corpus, not a
generative classification map. Its techniques (AAAK encoding,
cross-tunnel mechanism, KG-triple temporal validity, search
heuristics) compose with LocusKit; the framework profile derived
from it becomes Phase D's first concrete artifact, showing how a
domain-specific classification maps onto LocusKit primitives.

The Apple NaturalLanguage compile-time acceleration follows the
kernel-ladder architectural pattern: a deterministic reference
path always available, acceleration opt-in for self-contained
deployments that disable federation.
