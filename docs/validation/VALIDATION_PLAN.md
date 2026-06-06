---
status: accepted
created: 2026-05-22
ratified: 2026-05-22
last_updated: 2026-05-22
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

| Phase | Title                              | Status       | Routing       | Depends on |
|-------|------------------------------------|--------------|---------------|------------|
| A     | Claims ledger                      | in_progress  | direct        | (none)     |
| B     | Invariant negative-test suite      | not_started  | direct        | A          |
| C     | Theorem demonstrations             | not_started  | direct        | A          |
| D     | MemPalace migration benchmark      | not_started  | direct (+wormhole bounded) | A, B, C |
| E     | Adversarial harness                | not_started  | wormhole      | B, C       |
| F     | Continuous performance gates       | not_started  | wormhole      | B, C       |

## Phases

### Phase A: Claims ledger

Enumerate every empirical claim the substrate makes, in one
flat ledger row per claim. Claims come from the cookbook v0.36
(invariants, theorems, hot-path budgets, protocol contracts),
the committed decision records, the eight Mission 8 mission
specs, and the KG facts on `GeniusLocusKit`. Each row carries
its claim type, spec citation, current validation status, and
an evidence pointer (commit SHA, test path, or "pending").

Entry criteria: this plan committed (skeleton sufficient;
ratification not required to start).

Exit criteria: every claim in scope appears as a ledger row,
each row has `claim_evidenced_by` or `claim_evidence_pending`
recorded both in the ledger and as a KG fact.

Output: `docs/validation/CLAIMS_LEDGER.md` committed, the gap
list extracted into a "Pending Evidence" section, KG facts
filed.

### Phase B: Invariant negative-test suite

For each I-1 through I-14 (plus any new invariants introduced
by accepted decision records), confirm a negative test exists
that attempts to violate the invariant and fails appropriately.
Many already exist in Mission 8 test files under operation
names; the work is mapping them to the numbered invariant
surface and authoring tests for gaps.

Entry criteria: Phase A's invariant rows complete, including
each invariant's evidence status.

Exit criteria: every invariant row in the ledger points to a
negative test that runs and passes, KG fact
`claim_evidenced_by` recorded per invariant.

Output: new tests under existing Swift test targets, committed.

### Phase C: Theorem demonstrations

Each of the 8 theorems gets a runnable demonstration as code,
not just a proof in the manuscript. Mission 8's GLK-08 covered
Thms 4, 6, 7, 8 and met the Thm 5 hot-path budget. Phase C
fills in Thms 1, 2, 3 (and verifies the existing four still
hold post-Mission-8).

Entry criteria: Phase A's theorem rows complete with evidence
status per theorem.

Exit criteria: every theorem has a runnable demonstration that
passes, KG fact `claim_evidenced_by` recorded.

Output: theorem demonstration code, committed.

### Phase D: MemPalace migration benchmark

The load-bearing validation. Migrates the existing MemPalace
corpus (Bob's working memory substrate, several months of
content) into a GeniusLocus estate via the four-branch
parallel-run methodology already KG-recorded. Compares each
branch's recall quality, structural fidelity, and behavioral
parity against the MemPalace baseline.

This is the work that proves GLK does what it was designed to
do as a deep memory substrate, not just as a spec implementation.

Entry criteria: Phase A complete; Phase B and C substantially
complete (the threshold for "substantially" is: every invariant
and theorem has either evidenced status or a recorded waiver).

Exit criteria: migration produces zero silent concept loss
under at least one branch, recall quality of the winning branch
meets or exceeds the MemPalace baseline on a curated query set,
benchmark report committed.

The winning branch promotion is a separate decision that gates
MemPalace retirement. Phase D ends when the report commits; the
promotion gate is a subsequent decision.

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

Extends GLK-08's perf gate pattern to recall, dreaming tick,
federation handshake, and standing-signals dispatch latency.
CI-gated so regressions get caught at PR time.

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

Phase D winning branch promoted → MemPalace retired, Skippy
reads from GeniusLocus on next session. This is a separate
decision, not part of Phase D itself.

## Routing policy

Default: direct work in this chat for richer context curation
and authenticity of the record. The recursive insight is that
the validation work is also the corpus-building work for
Phase D, so dense diary entries and KG facts during Phases A
through C make Phase D's migration benchmark more substantive.

Bilby and the wormhole are escape valves for bounded mechanical
missions only, flagged per-item in the ledger. Phase E and F
default to wormhole because the work is largely template-fitting
(fuzz harness pattern, CI gate pattern); the rest default to
direct.

Once GLK passes Phase D and the winning branch promotes, bilby
gains substrate-grade memory (GLK as primary, MemPalace as
backstop) and the routing default inverts for NeuronKit and
CognitionKit: bilby primary, direct work for architecture and
analysis. The validation work bootstraps the tooling for the
work that follows it.

## KG predicate vocabulary

Declared for cross-session structured validation querying.
Sessions writing validation KG facts use these predicates
exclusively (extend the vocabulary by appending to this list).

- `validation_phase_status`: phase_id → not_started | in_progress | blocked | done
- `claim_evidenced_by`: claim_id → commit SHA or test path or runnable demonstration path
- `claim_evidence_pending`: claim_id → short reason
- `claim_violation_found_in`: claim_id → commit SHA or test path describing the violation
- `claim_waived_with_rationale`: claim_id → short rationale (used when a claim is deferred or deemed out of scope; Phase D entry criterion accepts waivers)
- `migration_branch_recall_parity_against_mempalace`: branch_id → numeric score plus methodology pointer
- `validation_session_checkpoint`: session date → short summary plus commit SHA

## Phase D prerequisites: anchor extractor work

A design conversation on 2026-05-22 surfaced a substrate-level
gap and a design constraint that together gate Phase D more
tightly than the original plan recorded.

The gap: the substrate has the slot for lattice anchors
(`Drawer.udcCode`, `Drawer.wikidataConcept`) and the recall
scoring depends on them, but no in-tree code populates them
from text content. Phase D's MemPalace migration benchmark
needs anchors on every migrated drawer.

The constraint, articulated in `DESIGN_CONSTRAINTS.md` C-1:
the substrate cannot depend on external ML runtimes, LLM API
calls, or neural inference engines. Anchor extraction must be
implemented in-tree, deterministic, in both languages, and
conformance-gated.

Three bounded missions sit between the current state and
Phase D entry:

### M1: Deterministic in-tree linguistic pipeline

Build a Unicode-aware tokenizer, Snowball stemmer integration,
gazetteer matcher, and UDC + Wikidata classifier. Pure Swift
and pure Rust source, reference data committed to repo (UDC
schedule top 3 levels, curated Wikidata subset of common
entities). Conformance-gated against shared vectors in the
existing test-harness pattern.

Routing: direct work in chat. Context-dense, design-sensitive,
in-tree implementation.

### M2: Apple NaturalLanguage compile-time acceleration

Add a Swift-only `apple-nlp-accel` compile-time flag that
delegates the linguistic pipeline to Apple's NaturalLanguage
framework (NLTokenizer, NLTagger, NLLanguageRecognizer) where
the flag is enabled. Same pattern as the kernel layer's
`simd-nightly` flag per `DESIGN_CONSTRAINTS.md` C-2. The flag
is mutually exclusive with cross-language conformance and is
declared federation-disabled in the build configuration.

Routing: direct work in chat.

### M3: Anchor agreement test

Measures how closely the deterministic in-tree extractor and
the Apple-accelerated path agree on the MemPalace corpus.
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

Routing: direct work in chat. Day-sized once M1 and M2 land.

### Phase D entry criteria amendment

M1 and M2 must land before Phase D can begin. M3 runs as part
of Phase D's opening pass and informs whether MemPalace data
gets one canonical anchor set or two parallel ones during the
migration benchmark.

## Session protocol

Every session that touches validation work follows the same
opening and closing sequence so cross-session continuity holds.

Opening, before any work:

1. Read the diary for `skippy/mootx01`, last 3 entries.
2. Query the KG for `validation_phase_status` and for the
   active phase's relevant entities.
3. Run `mempalace_search` on the active phase's topic.
4. Read `VALIDATION_PLAN.md`, `DESIGN_CONSTRAINTS.md`, and
   `CLAIMS_LEDGER.md` to confirm phase status, constitutional
   constraints, entry criteria, and the next step.

Closing, after the work:

5. Update this plan's Session log subsection with what landed.
6. Update KG facts using the declared vocabulary above.
7. Write a diary entry tagged `validation-phase-X-checkpoint`.
8. Commit any deliverable that landed.

## Session log

Append-only. Most recent at the top.

### 2026-05-22 (late): Design conversation; constraints doc opened; Phase D prerequisites recorded

Design conversation surfaced two corrections that materially
revise the substrate's text-to-anchor story. First, Skippy
reached for an LLM API call as a deployment option; Bob rejected
on determinism and supply-chain grounds. Second, Skippy reached
for ONNX Runtime as a model runtime; Bob rejected on the same
grounds and articulated the broader constitutional rule that
the substrate has no external runtime dependencies, period.

`DESIGN_CONSTRAINTS.md` opened to record the four constitutional
constraints (C-1 through C-4). The session protocol in this
plan is amended to read the constraints doc at the opening of
every session.

Anchor extractor is now deterministic in-tree, both languages,
conformance-gated. Vector tier rung 3 is TF-IDF over
framework-profile vocabulary; the prior KG fact recording
EmbeddingGemma_300M as production default is superseded.

Three bounded missions (M1, M2, M3) sit between the current
state and Phase D entry. They are recorded in the new Phase D
prerequisites section above.

MemPalace's role clarified: test and profile corpus, not
generative classification map. Its code and techniques (AAAK
encoding, cross-tunnel mechanism, KG triple temporal validity,
search heuristics) compose with LocusKit; the MemPalace
framework profile becomes Phase D's first concrete artifact
showing how a domain-specific classification maps onto
LocusKit primitives.

The Apple NaturalLanguage compile-time acceleration follows the
kernel-ladder architectural pattern: deterministic reference
always available, acceleration opt-in for self-contained
deployments that disable federation.

### 2026-05-22: Plan skeleton committed; Phase A started

Plan committed in skeleton form, status `proposed`. KG predicate
vocabulary declared. `CLAIMS_LEDGER.md` stub committed.
First batch of claims (the 14 numbered invariants from cookbook
section 3) enumerated as ledger rows. Phase A continues next
session with theorems, hot-path budgets, protocol contracts,
and decision-record claims.

Initial routing decision: Phases A through D run direct from
this chat per Bob's directive on curation and context
authenticity. Phases E and F default to wormhole when they
arrive. The directive's deeper rationale: the validation work
is also the corpus-building work for Phase D, and direct work
produces richer KG facts and diary entries that the migration
benchmark will then have to preserve and recall correctly.
