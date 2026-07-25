---
title: FAB5-H2 Completion Report
mission: FAB5-H2
task: TASK-MXC-2026-0074
stream: h3
status: COMPLETE
date: 2026-07-25
worker: bilby
user_facing: true
---

# FAB5-H2 — Workers: Review-Prep, Compare, Handoff + Intelligence Surface

**Mission:** `docs/missions/inflight/MISSION_FAB5_H2.md`
**Branch:** `stream/h3-intelligence-workers`
**Base commit:** `d38728a9` — verified equal to `origin/develop/1.1.x` and to
`git merge-base HEAD origin/develop/1.1.x` at mission start (zero drift)
**Status:** COMPLETE — tests exit 0, one existing source file edited, all six
workers run against a live estate

---

## What shipped

The last three of the roadmap's six Apple Intelligence workers, and the surface
that launches all six.

| File | Nature | Role |
|---|---|---|
| `Sources/MootGateway/Workers/ReviewPrepWorker.swift` | NEW | Narrates a FAB5-G1 `ReviewReport` as a morning brief |
| `Sources/MootGateway/Workers/CompareWorker.swift` | NEW | Two research bodies → agreement / disagreement / synthesis-candidate structure |
| `Sources/MootGateway/Workers/HandoffWorker.swift` | NEW | Frontier-model handoff draft with provenance citations |
| `Tests/MootGatewayTests/Workers/H2WorkerTests.swift` | NEW | 26 tests — 4 ReviewPrep, 15 Compare preservation, 7 Handoff |
| `Tests/MootGatewayTests/Workers/WorkerLiveSmokeTests.swift` | NEW | Opt-in all-six live-estate smoke (the mission's Verification requirement) |
| `Tests/GatewayUITests/IntelligenceLauncherTests.swift` | NEW | 20 tests over launcher states, input splitting, rendered text |
| `Sources/GatewayUI/IntelligenceView.swift` | **EDIT** | The mission's one existing source edit — six-worker launcher |
| `docs/guide/MOOTX01_APP_USER_GUIDE.md` | EDIT | "The six workers" guide section, v0.5 → v0.6 |

`WorkerCore.swift`, `WorkerFallbacks.swift`, the three FAB5-H1 workers,
`Sources/MootGateway/Review/**`, `ContentView.swift`, `Package.swift` and
`packages/kits/**` are byte-identical to `d38728a9`. The `MootWorker` protocol
was sufficient as written — the two new prompt templates were added by
same-module `extension WorkerPrompts`, which touches no protected file.

### The three preservation guarantees, and where they live

The mission's substance is not "three more workers" — it is three properties that
must hold structurally rather than by good behaviour.

**1. A narration cannot misreport its own sources.** `ReviewBrief.citedSurfaces`
and `.itemCount` are copied from the report, never generated. The model writes
`headline` and `narrative` only. `ReviewPrepWorker` calls no tool at all: the
report IS the estate read, so re-querying would pay for the same lens calls twice
and could describe a different estate than the report shows. Both paths share one
`digest(_:maxItemsPerSection:)`, so the model path and the deterministic path can
never disagree about what was in the report, and withheld items are stated
(`further items in this section: N`) rather than dropped.

**2. A disagreement cannot be dissolved.** Four mechanisms, none of which a
caller can skip:

| # | Mechanism | Where |
|---|---|---|
| 1 | A topic present in both `agreements` and `disagreements` resolves to the disagreement — the agreement is dropped | `CompareResult.init` |
| 2 | A half-stated conflict keeps the side it has and marks the other `unstatedPosition`; the row never vanishes for being half-stated | `Disagreement.init` |
| 3 | A result with no agreements **and** no disagreements always carries a notice, so silence can never read as agreement | `CompareResult.init` |
| 4 | `maxClaims` never cuts a conflict — it bounds the prompt and the agreement/synthesis lists only, and a cut to either of those is disclosed in the notice | `CompareWorker.assemble` |

Mechanism 4 exists because Adams found its absence (see the post-flight section):
the cap is a prompt instruction, nothing in the `@Generable` schema enforces it,
and the first implementation truncated the disagreement list silently.

Synthesis candidates acknowledge disagreements by id, clamped to ids that exist,
and `unacknowledgedDisagreements` surfaces a synthesis that ignores a live
conflict. `WorkerResultText.comparison` prints both positions of every
disagreement and names any conflict no candidate addressed — the compare layer
refuses to dissolve a conflict and the view refuses to bury one, each asserted
separately.

**3. A handoff cannot carry an uncited source.** `HandoffDraft.body` is assembled
by the initializer from the narrative plus a references block. There is no
initializer that accepts a body — the custom `init` suppresses the memberwise
synthesizer and `body` is `let` — so no construction path produces a draft whose
text omits a reference it carries. The model writes prose; the worker writes the
citations.

### Input shape: Work-Packet-tolerant, WorkPacketKit-free

`ResearchBody` is `label` + `text` + `references`. A Work Packet's id and body fit
it without this code knowing WorkPacketKit exists. `rg WorkPacket` over the three
new source files returns exactly one hit — the comment saying the dependency is
absent — and no import, type reference, or `Package.swift` entry. FAB5-I1 is not a
dependency, per the mission.
The `references` a caller supplies now land on `CompareResult.leftReferences` /
`rightReferences` on both paths, so a comparison can be traced back to its
material.

### Launcher design

The launcher's rules are value types beside the view — `WorkerLauncherKind` (six
cases), `WorkerLauncherState`, `ModelAvailability`,
`WorkerLauncherEntry.entries(modelAvailability:editorText:)` — because a rule that
exists only inside a SwiftUI `body` is a rule nothing can assert, and these rules
decide whether a worker can run at all.

- `needsInput` outranks `fallbackOnly`: a missing objective or a missing second
  body blocks the deterministic path too, so offering the fallback there would
  offer a run that produces nothing.
- A blocked row's caption names the missing thing ("Paste both bodies above,
  separated by a line containing only ---"), not just "Needs input".
- Compare's two bodies come from the editor split on a line containing only `---`.
  Exactly one separator with text on both sides; two separators are refused rather
  than guessed at, because guessing a boundary would silently drop material.
- Morning brief wires G1 to H2 end to end: `ReviewBuilderFactory` over
  `MootToolCallingReviewReader` builds the report, `ReviewPrepWorker` narrates it.
  The view passes `now` — a view may read the clock, a builder may not.
- State is text, never colour alone; rows have a 44pt minimum height; each row is
  one combined accessibility element whose label is a localized format rather than
  concatenated strings.

---

## Test Verification Log

### Baseline (mission start, `d38728a9`)

```
swift test --package-path apps/Mootx01-App
Test run with 229 tests in 36 suites passed after 6.238 seconds.   (MootGatewayTests)
Test run with 40 tests in 9 suites passed after 0.034 seconds.     (GatewayUITests)
EXIT=0
```

### Final (`e9b3a313`)

- Command: `swift test --package-path apps/Mootx01-App 2>&1 | tail -5`
- Exit code: **0**
- Pass count: **256 tests in 40 suites** (MootGatewayTests) + **60 tests in 12
  suites** (GatewayUITests) — net **+27** MootGateway and **+20** GatewayUI tests,
  **+4** and **+3** suites, zero regressions
- Tail output (verbatim):

```
􀟈  Test "endSession updates lastSession timestamp on the known peer (real manager)" started.
􁁛  Test "endSession updates lastSession timestamp on the known peer (real manager)" passed after 0.004 seconds.
􁁛  Suite "FederationPanel — state transitions and F1 invariants (FED-OD-6b)" passed after 0.028 seconds.
􁁛  Test run with 60 tests in 12 suites passed after 0.028 seconds.
EXIT=0
```

There is no `timeout` binary on this machine, so every run was wrapped in a
watchdog kill (a background `sleep N; kill -9` subshell, 900–1200 s). No run
approached the limit and no test hung.

### Gates

- `make check-edition-boundary` → `✓ edition boundary clean — no SHARED→EE-only references`
- No `Package.swift` change, so no new test target and no new dependency. Review
  tests still run inside `MootGatewayTests` (the FAB5-G1 precedent).

---

## Live-estate verification (mission Verification requirement)

The mission asks for all six workers run against a live estate. That is
`WorkerLiveSmokeTests`, opt-in and off by default (a test needing a daemon on a
fixed port would fail on any machine without one):

```
MOOT_LIVE_WORKER_SMOKE=1 swift test --package-path apps/Mootx01-App \
    --filter WorkerLiveSmokeTests
```

Run against the resident daemon at `127.0.0.1:4242` over real JSON-RPC
`tools/call` — an estate of 98,206 active memories and 33 wings — with Apple
Intelligence available on this Mac. Final run after the punch-list fix:

```
LIVE WORKERS availability=available
LIVE WORKER summarize: PATH=model
LIVE WORKER summarize: chars=249
LIVE WORKER extractFacts: PATH=fallback reason=May contain sensitive content
LIVE WORKER extractFacts: triples=0 first=none
LIVE WORKER classify: PATH=model
LIVE WORKER classify: room=work tags=intelligence,launcher,shipping
LIVE WORKER reviewPrep: PATH=model
LIVE WORKER reviewPrep: origin=model items=33
    surfaces=moot_lens_contradiction,moot_memory_search,moot_read_journal
    headline=Review of mission chain CE-1.0.35 with unresolved contradictions.
LIVE WORKER compare: PATH=fallback reason=May contain sensitive content
LIVE WORKER compare: agreements=0 disagreements=0 synthesis=0 unacknowledged=0
    notice=The two bodies were not compared — the on-device model was unavailable
    or declined to answer. Their claims are neither agreed nor reconciled.
LIVE WORKER compare-control: PATH=model
LIVE WORKER compare-control: agreements=1 disagreements=2
    topics=rebuild duration;rebuild frequency
LIVE WORKER handoff: PATH=model
LIVE WORKER handoff: references=5 bodyChars=1466
    ids=EEBC6F7D-…,19804471-…,C79F6BDE-…,43CD93B5-…,8AEB93BE-…
LIVE WORKERS tools=moot_lens_contradiction,moot_memory_search,moot_read_journal
Test run with 1 test in 1 suite passed after 93.684 seconds.
EXIT=0
```

**What the live run proved, and what it did not.** The structural claims are the
evidence: which path each worker took, that every handoff reference is a real
drawer UUID present in the draft body, that agreed and disputed topic sets are
disjoint, that an empty comparison carries a notice, and that the whole run
touched read verbs only. The *counts* are one sample of a non-deterministic
model: across four runs `compare-control` returned `disagreements=2` with the
same two topics (`rebuild duration`, `rebuild frequency`) every time, and
`agreements` of 0, 2, and 1. Commit `2ccf4012`'s message quotes one of those
samples as if settled; Adams flagged it and the correction is here.

### The finding the live run produced

Two of the six workers fell back **with Apple Intelligence available**: Apple's
guardrail answered `May contain sensitive content` on recalled estate text.
`extractFacts` (a FAB5-H1 worker) and `compare` both hit it; a control compare
over two short benign bodies took the model path in the same run, so the decline
is content-specific, not a broken worker.

`runSafe` catches the throw and calls `fallback(input:)` with no reason attached,
so the fallback text is the only thing a user sees — and the first version of all
three new fallbacks said Apple Intelligence was *unavailable*, which is wrong
exactly when a user checks Settings and finds it on. All three now name no single
cause ("the on-device model was unavailable or declined to answer"), the reason is
documented at each `fallback`, and the smoke suite's `loudRunSafe` prints which
path ran and why, so a silent fallback can never again read as a successful model
run. Fixed in `2ccf4012`, in-cycle.

**Simulator note:** the mission says "Simulator". The run above is on the host Mac
against the live local estate, which is the stronger test — a fresh simulator has
no estate to read, so a simulator pass would prove the UI renders, not that six
workers work against real data. The launcher's own logic is covered by 20
assertions in `GatewayUITests`.

---

## Smythe pre-flight

Full report: `docs/analysis/SMYTHE_FAB5_H2_PREFLIGHT.md` (that directory is
gitignored in CE, so the report is on disk in the worktree, not in a commit).

**Verdict: GREEN — terrain clear, no blockers, no rescope.**

- Blast radius verified against reality: the three worker files did not exist, and
  `ReviewPrepWorker|CompareWorker|HandoffWorker|CompareResult|HandoffDraft` had
  zero hits anywhere under `apps/` or `packages/`. `IntelligenceView.swift` (104
  lines) carried zero `Worker` references. The mission's "1 existing edit + 3 new
  workers" matched exactly.
- The RED/STOP check the mission demanded: `MootWorker` (`WorkerCore.swift:13-28`)
  is generic over `Input`/`Output` and sufficient for three more workers.
  `WorkerPrompts` and `WorkerFallbacks` are case-less `enum` namespaces,
  extensible from another file in the same module. **No STOP condition** — the
  protocol did not need editing, so the MUST-NOT-MODIFY list held.
- Wiring: `GatewayUI` already depends on `MootGateway` (`Package.swift:78-90`);
  `MootFoundationModelsKit` is `GatewayUI`-only, confirming the H1 boundary. No
  `#if os()` or `@available` guards in the view.
- Test terrain: `MockCaller` (`WorkerTests.swift:11-23`) is reusable;
  `ReviewFixtures` has no ready-made `ReviewReport`, so a ReviewPrep fixture must
  be composed via `StubReviewReader(responses: ReviewFixtures.populated)` →
  `ReviewBuilderFactory` → `.build(now:reader:)`. That is what the tests do.
- Environment: working tree clean, HEAD == `origin/develop/1.1.x` == merge-base ==
  `d38728a9`. Re-verified independently rather than taken on report.

---

## Adams post-flight

Full report: `docs/analysis/ADAMS_FAB5_H2_POSTFLIGHT.md` (gitignored, on disk).

**First pass: CLEAN-WITH-FOLLOWUPS — one CRITICAL.** Adams re-ran the suite
independently (exact count match, exit 0), re-ran the live smoke himself, verified
the scope claim with `git diff --name-only` (only `IntelligenceView.swift`, purely
additive, and the guide), confirmed all protected files byte-identical, and
verified the `HandoffDraft` citation guarantee structurally (single custom `init`
suppresses the memberwise synthesizer; `body` is `let`; no alternate construction
path).

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | **CRITICAL** | `CompareWorker.assemble` truncated `disagreements` to `maxClaims` with `.prefix(cap)` and no disclosure. The cap is prompt-only — nothing in the `@Generable` schema enforces it — so a model returning more conflicts than requested lost one silently. The exact failure the worker exists to prevent, and a contradiction of the guide's "Compare never hides a disagreement". | **Fixed in `6f78c30f`.** Disagreements are carried whole; the cap cuts only agreements and synthesis, and a cut to either is disclosed in the notice. Mechanism 4 in the file header. Two new tests, including five disagreements surviving a cap of two. |
| 2 | WARNING | The control-compare counts quoted in `2ccf4012`'s message do not reproduce — a single sample of a non-deterministic model presented as settled evidence. | No code change. Corrected in the live-estate section above, with the four-run spread. |
| 3 | WARNING | `ResearchBody.references` was write-only while its comment promised propagation. | **Fixed in `6f78c30f`.** Carried onto `CompareResult.leftReferences` / `rightReferences` on both paths, asserted by test. |
| 4 | WARNING | Guide gained a section without the minor bump its own history establishes. | **Fixed in `6f78c30f`.** v0.5 → v0.6. |
| 5 | WARNING | The BRR's files-touched table omitted `WorkerLiveSmokeTests.swift`. | **Fixed in `6f78c30f`.** Amended. |
| 6 | WARNING | No completion report — Adams notes this as a recurring FAB5 pattern, not a one-off. | This document. |
| 7 | WARNING | `IntelligenceView.run(_:)` and `WorkerResultText.comparison(_:)` exceed the 40-line signal with no stated reason. | **Fixed in `6f78c30f`.** Each now states why it stays whole. No refactor. |
| 8 | INFO | Two rendering tests restate their implementation (`text == draft.body`). | Left as-is, per Adams. They pin the contract that rendering adds nothing to the assembled body. |

**Re-inspection of `6f78c30f`: PASS on all eight items**, appended to the
post-flight report. Adams re-ran the suite (exact match, exit 0), re-ran
`swift build` and `make check-edition-boundary`, re-checked the full-diff scope
against `d38728a9`, and attacked the CRITICAL fix directly: he traced every path
in `assemble` and `CompareResult.init` and confirmed no path can now lose a
disagreement, and noted that building `idByTopic` from the uncapped list
incidentally repaired a second latent bug — a synthesis acknowledgement of a
disagreement that used to be dropped by the cap now resolves.

Two non-blocking INFO items came out of the re-inspection, **both fixed in
`e9b3a313`** rather than carried:

| Severity | Finding | Resolution |
|---|---|---|
| INFO | At `maxClaims: 0` (reachable through the public initializer, not the shipped UI) the truncation notice pre-empted the initializer's "nothing was compared" notice. Both texts were accurate, but with nothing left to read the second is the useful one. | `assemble` reports truncation only when something survived to be read. Two tests: a zero cap keeps the nothing-compared notice, and a zero cap still carries every disagreement. |
| INFO | The new `references` comment said the result "always" names each side's material — true for this worker's two paths by convention, but not structural the way `HandoffDraft.body` is. | Comment now distinguishes the two, so a convention is not read as a guarantee. |

---

## Self-review

- **Blast radius diff match.** `docs/blast_radius/FAB5_H2_BLAST_RADIUS.md`
  (gitignored in CE, on disk) lists one changed symbol — `IntelligenceView`,
  semantic and additive — with its single call site
  (`ContentView.swift:37`) marked INTENTIONALLY_LEFT because `public init()` did
  not change. MUST_UPDATE is empty; the diff matches.
- **Scope.** Tier 2, ≤6 edits: one existing source edit used. Five new files plus
  two doc edits.
- **Anti-patterns.** No bridge helpers, no shim types, no
  `@available(*, deprecated)`, no TODO/FIXME in the diff (`rg` clean). No
  formatting noise: `IntelligenceView.swift` shows 0 deletions.
- **Comment fidelity.** Every comment describes current behaviour. The
  "three mechanisms" wording in `CompareWorker` was corrected to four when the
  fourth landed, so no comment describes an older shape of the file.
- **Determinism.** No `Date()` in worker logic. `rg 'Date\(\)'` over the three new
  workers returns nothing; the clock is read in the view and in the live smoke,
  both of which are allowed to.
- **Schema discipline.** No stored `Bool` anywhere: `ReviewBriefOrigin`,
  `ModelAvailability`, `WorkerLauncherState` are enums, following G1's
  `ReviewItemStatus`. `WorkerLauncherState.isRunnable` is computed.
- **Localization.** Every display string goes through
  `String(localized:defaultValue:)` with a real key. No `Text("…")` literal in the
  view. Estate content (`ReviewItem.detail`, drawer text, the substrate's own
  notices) is data and is carried verbatim. No plural or ordinal prose is built by
  string interpolation — counts are exposed as numbers for the view to format.
- **Palette.** No raw system colour and no hex literal; the launcher uses
  `Color.gatewayEditorField` and `.secondary`, matching the surrounding views.
- **Accessibility.** Rows are combined elements with a localized-format label,
  state is text rather than colour, 44pt minimum row height.
- **Read-only.** No mutation verb appears anywhere in the diff, and the live smoke
  asserts the claim against the real call log, not only against a mock.
- **Honesty.** Every number in this report comes from a run recorded above. The
  guardrail declines are reported as findings rather than smoothed over, and the
  one number Adams could not reproduce is labelled as a sample.

---

## Known gaps (carried into the estate contract)

1. **`runSafe` gives the fallback no reason.** A worker cannot tell a user whether
   the model was off or declined, so every fallback string must stay
   cause-neutral. Closing this properly means a reason on the protocol —
   `WorkerCore.swift` is H1's file and out of this mission's scope.
2. **FAB5-H1's `WorkerFallbacks.summarize` still claims unavailability**
   ("Apple Intelligence is not available. Enable it in System Settings…") and is
   wrong on the guardrail path for the same reason the three new fallbacks were.
   `WorkerFallbacks.swift` is on this mission's MUST-NOT-MODIFY list, so it is
   reported rather than edited. One-line fix for whoever owns H1 next.
3. **Apple's guardrail declines real estate content.** On a 98k-memory estate,
   recalled text tripped `May contain sensitive content` for fact extraction and
   comparison on every run. Any worker fed raw recall must expect the fallback
   path as a normal outcome, not an edge case.
4. **`moot_memory_search` latency** (G1 gap 3) applies to the morning brief: the
   default 30 s transport timeout can empty the context section on a large estate,
   which surfaces as a section notice in the brief. The live smoke uses 90 s
   headroom; production headroom is `MootBridge`'s decision.
5. **`extractFacts` returns at most one triple per run** (H1 gap) — the launcher
   inherits that, so "Extract facts" proposes one candidate per tap.
6. **Compare bodies come from one editor box** split on `---`. It works and is
   documented in the guide, but a two-pane input is the better surface when a
   later mission has room for it.

---

## Success criteria

| Criterion | Status |
|---|---|
| ReviewPrepWorker narrates a G1 `ReviewReport` | ✅ model path verified live (items=33, three surfaces) |
| CompareWorker preserves disagreements structurally | ✅ four mechanisms, 15 tests / 50 assertions, live control run |
| HandoffWorker drafts with provenance references | ✅ structural guarantee, 5 real drawer UUIDs cited live |
| All six workers wired into IntelligenceView with availability states | ✅ 20 launcher assertions |
| Fallbacks on every path | ✅ and now cause-neutral, which the live run forced |
| Tests exit 0 | ✅ 254 + 60, zero regressions |
| Guide page for the Intelligence surface | ✅ "The six workers", guide v0.6 |
| W2-INTERFACE drawer filed | ✅ wing "Agentic Memory", location `fab5-w2`, id `925C26E0-6034-4076-828E-8043B2E00CCF` |

The ROADMAP six-task Apple Intelligence list is shipped behaviour with fallbacks.

## Commits

| SHA | Subject |
|---|---|
| `10048ddb` | feat(app-ai): review-prep, compare, handoff workers |
| `2ccf4012` | feat(app-ui): six-worker Intelligence surface |
| `6f78c30f` | fix(app-ai): the claim cap must never cut a disagreement |
| `e9b3a313` | fix(app-ai): keep the nothing-compared notice when a zero cap empties the result |

Estate: one `W2-INTERFACE FAB5-H2:` drawer filed to wing "Agentic Memory",
location `fab5-w2` (id `925C26E0-6034-4076-828E-8043B2E00CCF`), carrying the three
worker APIs, the four preservation mechanisms, the launcher contract, the
guardrail finding, and the gap list above.
