# FAB5-G2 — Review Center Views — Completion Report

**Stream:** g4
**Mission:** `docs/missions/inflight/MISSION_FAB5_G2.md`
**Branch:** `stream/g4-review-center-views` (from `develop/1.1.x`)
**Base commit:** `d38728a9` — verified equal to `origin/develop/1.1.x` and to
`git merge-base HEAD origin/develop/1.1.x` at mission start (zero drift),
verified independently by Smythe at pre-flight
**Depends on:** FAB5-G1 (TASK-MXC-2026-0063, merged at `d38728a9`)
**Worker:** Bilby
**Date:** 2026-07-25
**Status:** COMPLETE — Adams' CRITICAL and both WARNINGs fixed in-cycle; final
verdict recorded in the Adams section below

---

## What shipped

The user-facing Review Center. A **Review** tab in the Standard profile —
third, between Recall and Intelligence — hosting the four reviews the roadmap
names, rendering the `ReviewReport` values FAB5-G1 produces. Nine new source
files under `apps/Mootx01-App/Sources/GatewayUI/Review/`, three new test files,
and exactly two pre-existing source/test edits.

| File | Role |
|---|---|
| `Review/ReviewCenterView.swift` | The tab shell — segmented picker over the four reviews — plus `ReviewCenterModel`: per-review load state, the report cache, and the one clock read |
| `Review/ReviewReportView.swift` | The one renderer all four reviews use, plus `ReviewSectionView`, `ReviewItemRow`, `ReviewActionableReportView` (renderer + confirmation prompt), and `ReviewActionRow` |
| `Review/ReviewDisplayStrings.swift` | G1's dotted localization keys → display prose, with a humanizing fallback |
| `Review/ReviewActionPerforming.swift` | `ReviewAction`, the mutation seam, and `ReviewActionCoordinator` — the two-phase gate |
| `Review/DashboardView.swift` | "What your estate remembers now." |
| `Review/MorningReviewView.swift` | "The context and open work that matter today." |
| `Review/EndOfDayReviewView.swift` | "What changed, what was decided, what still needs attention." |
| `Review/WeeklyReviewView.swift` | "Memories that may be stale, contradicted, or ready to retire." |
| `Tests/GatewayUITests/Review/ReviewCenterTests.swift` | Key resolution, row/report formatting, fixture rendering of all four reports, the load state machine |
| `Tests/GatewayUITests/Review/ReviewActionTests.swift` | The no-mutation-without-a-tap gate, tool routing, the suggestion policy, and the honesty of the confirmation text |
| `Tests/GatewayUITests/Review/ReviewCenterLiveSmokeTests.swift` | The live-estate walk (mission Verification) — added during Part 3, so the Blast Radius Report, written at mission start, lists only the two above |

Pre-existing edits: `Sources/GatewayUI/ContentView.swift` (the tab wire),
`Tests/GatewayUITests/FirstRunAndTabProfileTests.swift` (Standard 4 → 5 tabs),
and `docs/guide/MOOTX01_APP_USER_GUIDE.md` (the guide page). Nothing else.

### The three things the view layer actually decides

**1. G1's title keys had to be resolved somewhere.** `ReviewSection.title` and
the two drift measures' `ReviewItem.title` are dotted localization keys
(`review.section.momentum`), but this app localizes English-as-key with no
catalog shipped, so passing a dotted key to `String(localized:)` prints the key
on screen. `ReviewDisplayStrings.title(forKey:)` maps all sixteen keys G1 emits
to English prose; an unrecognized `review.*` key is humanized
(`review.section.newThing` → "New thing") so a section G1 adds later can never
render as a raw slug; and a string that is not a key at all — a drawer UUID, a
room name, a fact subject, a journal stamp, which is what most item titles are —
is returned untouched, because estate data is never localized.

**2. Provenance became the "inspectable" half of the roadmap promise.** G1 made
`ReviewProvenance` mandatory on every item precisely so a consumer could answer
"where did this come from?" without a second query. Every row carries a
collapsed **Where this came from** disclosure showing the registered tool name,
the arguments it was called with (key-sorted, so the same call renders the same
text), and the verbatim response line the row was parsed out of.

**3. `magnitude` is a lens score, not a percentage.** Momentum, centrality, and
divergence are whatever the lens computed. Rendered as a bare decimal through
`NumberFormatter` at four fraction digits — enough that 0.0654 and 0.0177 stay
distinct on a real estate — with the sign preserved, because a negative momentum
is what makes a room "fading". No `%`, no multiplication.

### Suggestions, and the gate

`ReviewActionCoordinator` is two-phase. `request(_:)` stages an action and calls
nothing; `commitPending()` is the only method that reaches the estate and can
only act on what `request` staged; `cancelPending()` discards. A suggestion row
holds only the staging closure and the performer is `private let`, so there is
no path from a row to a mutation that bypasses the confirmation. The invariant
is a property of the types rather than a promise about view code, and the test
proves it by counting calls on a recorder.

Which row gets which button lives in exactly one function,
`ReviewAction.suggestions(forSectionID:item:)`, grounded in what G1 actually
puts in `subjectID` per section:

| Section | `subjectID` holds | Offered |
|---|---|---|
| `retire-ready` | KG fact row id | Retire |
| `contradicted`, `conflicts`, `open-work` | tunnel id | Accept / Reject — **only while `.proposed`** |
| `keystones`, `context`, `changes` | drawer id | Confirm |
| `momentum`, `fading` | a **room name** | nothing — no mutation verb takes a room name |
| `drift`, `duplicates` | nothing | nothing to act on |

Two guards hold everywhere: an item with no `subjectID` (or an empty one) is
never actionable, and a tunnel is settleable only while `.proposed` — a
`.recorded` edge is already decided and `moot_review_tunnel` refuses it ("a
settled edge cannot be rewritten by a stale review"), so offering the button
would produce a guaranteed refusal.

---

## Deviations from the mission text, and why

**1. Nine new source files, not the mission's "5 new views".** The shared
renderer, the key-mapping table, and the action seam are separate because all
four reviews share them and because the action seam must be substitutable for
the no-tap-no-mutation test. Kong ruling G specified this file set; Smythe
confirmed on request that the Tier 2 cap governs **existing-file edits** — of
which there are two — and re-affirmed no RESCOPE_REQUIRED. Net-new files carry
no blast radius: nothing existed to depend on them.

**2. Merge does not ship.** The mission names Weekly actions as
"retire/**merge**/confirm". No merge or duplicate-detection verb is registered
at the ARIA surface at all — Smythe verified this against `ToolProjection.swift`
and `ToolDispatch.swift`, and it is the same finding that made G1 ship
`duplicates` as an explained gap. So Weekly renders G1's capability-gap notice
verbatim in an info block and offers no button. `ReviewAction` has no merge
case, and a test asserts no action routes to a merge or consolidate tool, so
adding one cannot pass review silently. **Shipping a Merge button with nothing
behind it was the available alternative and it would have been worse than the
honest gap.**

**3. Suggestions ship on all four reviews, not Weekly only.** The mission scopes
actions to Weekly, but Weekly has no drawer-keyed section, so `moot_confirm_memory`
would then have had no home and Confirm would not have shipped at all. Kong's
design memo was internally inconsistent here — its section B said Weekly was the
only actionable view while its section D1 tabled actions on Dashboard, Morning,
and End-of-Day rows. Kong adjudicated the conflict at the polish pass in favour
of D1, on the record. Every review routes through the same
`ReviewActionableReportView` and the same one-function policy, so there is no
per-view action behaviour to drift, and the no-mutation-without-a-tap invariant
applies uniformly rather than only where the mission happened to name it.

**4. No `failed` state in `ReviewCenterModel.LoadState`.** Kong's memo specified
`failed(String)`. A G1 builder never throws and always returns a report — a
refused or timed-out surface becomes a section notice inside the report — so the
only state that is not a report is having no estate attached, which is
`disconnected`. A `failed` case would have been unreachable, and unreachable
code is an orphan-code finding. Kong ACCEPTed. The mid-build bridge-drop case is
already handled one layer down: `MootToolCallingReviewReader` turns a transport
failure into `isError: true` and the builder degrades that section only.

**5. A `NavigationStack` is present.** Kong's memo ruled "no NavigationStack" in
section A and a toolbar Refresh button in section E, which cannot both hold — a
toolbar needs a navigation container. The stack carries the title and Refresh
and has zero push destinations, which is exactly what `PacketListView` does.
Kong ACCEPTed: the ruling was against master-detail navigation, not against the
container.

**6. No Undo button, anywhere.** Covered in its own section below.

**7. The mission's Verification asks for a "simulator walk".** What shipped is a
live-estate walk through the shipped code paths instead — see the live-estate
section. Adams adjudicated this; the ruling is recorded there.

---

## Reversibility: what the roadmap promises and what the substrate delivers

The mission says "every change is inspectable and reversible per roadmap
language". Inspectable is fully delivered. Reversible is not deliverable for two
of the three verbs, and the UI says so in words rather than letting the user
find out afterwards.

| Action | Tool | Reversible at the ARIA surface? | What the UI does |
|---|---|---|---|
| Confirm | `moot_confirm_memory(id:)` | **Yes** — `moot_update_memory(id:, mutation: "contest")` is the inverse, and confirming forecloses nothing | Prompt says "You can contest it later." |
| Accept | `moot_review_tunnel(verdict: "accept")` | No inverse verb, but nothing is destroyed and both memories stay editable | Plain confirmation, not destructive |
| Reject | `moot_review_tunnel(verdict: "reject")` | **No — permanent by design.** "Rejected pairs are never re-proposed" | Destructive role; message says it cannot be undone and the pair will never be suggested again |
| Retire | `moot_retire_fact(id:)` | **No.** No un-retire verb is registered | Destructive role; message says it cannot be undone, **and that re-filing would create a new fact rather than restore this one** |

The `contest` inverse for Confirm is Smythe's finding at pre-flight §4; Kong's
memo did not credit it, and it is the reason Confirm's prompt can honestly
promise something the other three cannot.

No Undo button ships because for Retire and Reject there is nothing an Undo
could do. A re-file flow for a retired fact — reading subject, predicate, and
object back off the item and calling `moot_file_fact` — is technically possible
from the data the row already carries, but it produces a **new row id**, which is
a materially different thing from an undo, and presenting it as one would be the
dishonest option. It is a named gap below, for a mission that can design the
"this is a new fact, not the old one" affordance properly.

Tests pin all of this: exactly the two irreversible verbs are marked permanent,
every permanent action's message contains "cannot be undone", no message
contains "undo it" / "you can undo" / "reversible", and Retire's message names
the new-fact consequence.

---

## Test Verification Log

### Baseline (mission start, commit `d38728a9`)

Measured by Smythe at pre-flight:

```
swift test --package-path apps/Mootx01-App
Test run with 229 tests in 36 suites passed after 6.006 seconds.   (MootGatewayTests)
Test run with  40 tests in  9 suites passed after 0.031 seconds.   (GatewayUITests)
EXIT: 0
```

Note the GatewayUITests baseline is **40 / 9**, not the 37 / 8 recorded in G1's
report: three tests and one suite landed between G1 merging and g4 cutting.
Smythe re-confirmed 40 / 9 is what the tree at `d38728a9` actually produces, so
the delta below is a true delta.

### Final (commit `604109e4`)

- Command: `swift test --package-path apps/Mootx01-App 2>&1 | tail -5`
- Exit code: **0**
- Pass count: **229 tests in 36 suites** (MootGatewayTests — unchanged, zero
  regressions) + **96 tests in 18 suites** (GatewayUITests) — net **+56** tests,
  **+9** suites
- Zero compiler warnings
- Tail output (verbatim):

```
􀟈  Test "endSession updates lastSession timestamp on the known peer (real manager)" started.
􁁛  Test "endSession updates lastSession timestamp on the known peer (real manager)" passed after 0.004 seconds.
􁁛  Suite "FederationPanel — state transitions and F1 invariants (FED-OD-6b)" passed after 0.030 seconds.
􁁛  Test run with 96 tests in 18 suites passed after 0.031 seconds.
```

Adams re-ran the suite independently at `e4ad1dd9` and reported 229 / 36 and
95 / 18, exit 0 — an exact match to the claim at that commit. The 96th
GatewayUITests case is the SF Symbol pin added while fixing Adams' own
finding #2.

Every run was wrapped in a hard watchdog kill (900 s) per fleet doctrine, with a
`pgrep` check for stale swiftpm lock-holders first. No run approached the
watchdog; nothing hung.

### Gates

- `make check-edition-boundary` → `✓ edition boundary clean — no SHARED→EE-only references`
- Pre-existing files modified: `git diff --diff-filter=M --name-only d38728a9..HEAD`
  returns exactly `ContentView.swift`, `FirstRunAndTabProfileTests.swift`, and
  `docs/guide/MOOTX01_APP_USER_GUIDE.md`. No `Package.swift`, no `project.yml`,
  no `Sources/MootGateway/**`, no `packages/kits/**`.

### What the tests actually cover

Reports under test are built by the **real FAB5-G1 builders** from the same tool
responses G1 captured live from a local estate on 2026-07-24, re-declared in the
UI test target because a test target cannot import another test target. They are
copies, truncated in row count only, and the one transcribed-rather-than-captured
surface (`moot_fact_search`) is labelled as such, exactly as G1 labelled it. So
these tests exercise the shapes the app actually renders rather than
hand-assembled ones that could drift from the builders.

Coverage beyond the mission's asks: no G1 key resolves to itself or leaks its
namespace and no two sections share a label; the section either/or holds (empty
⇒ notice, populated ⇒ no notice) on all four reports and on an empty estate;
the dashboard's coverage line never prints its `distantPast` window start; a
review is cached after one build and rebuilt only on refresh; a `disconnected`
review retries once the bridge attaches, unlike a cached one; a report round-trips
the G1 wire coders after the clock read is floored to a whole second; and the
Review tab's index in the Standard profile is asserted, so a reorder cannot pass
a bare count check.

---

## Live-estate walk (mission Verification requirement)

The mission asks for a simulator walk. What ran instead is a walk of all four
reviews through the **shipped code paths** against a live estate:
`ReviewCenterModel` — the same type the Review tab uses — builds each report over
real JSON-RPC `tools/call` against the running resident daemon, and the walk then
asserts the view layer's own decisions on the live rows. Suite:
`ReviewCenterLiveSmokeTests`, env-gated on `MOOT_LIVE_REVIEW_UI_SMOKE=1` via an
`.enabled(if:)` trait so a machine without a daemon **skips** rather than fails.

Estate: 98,207 active memories, 6,140 active KG facts (`moot_estate_status`).

```
MOOT_LIVE_REVIEW_UI_SMOKE=1 swift test --package-path apps/Mootx01-App \
    --filter ReviewCenterLiveSmokeTests

LIVE UI dashboard: items=28 sections[momentum=10 keystones=5 conflicts=13]
    surfaces=moot_lens_contradiction,moot_lens_keystones,moot_lens_theme_weather
    actions=moot_confirm_memory,moot_review_tunnel
    coverage="28 items · as of 12:29 AM"
LIVE UI morning:   items=33 sections[journal=1 context=19 open-work=13]
    surfaces=moot_lens_contradiction,moot_memory_search,moot_read_journal
    actions=moot_confirm_memory,moot_review_tunnel
    coverage="33 items · Jul 24, 2026 at 12:00 AM – Jul 25, 2026 at 12:29 AM"
LIVE UI endOfDay:  items=23 sections[changes=19 decisions=0 attention=4]
    surfaces=moot_lens_cohesion,moot_memory_search
    actions=moot_confirm_memory
    coverage="23 items · Jul 25, 2026, 12:00 – 12:29 AM"
LIVE UI weekly:    items=72 sections[fading=4 drift=2 contradicted=13
    retire-ready=53 duplicates=0]
    surfaces=moot_lens_contradiction,moot_lens_drift,moot_lens_theme_weather
    actions=moot_retire_fact,moot_review_tunnel
    coverage="72 items · Jul 18, 2026 at 12:29 AM – Jul 25, 2026 at 12:29 AM"
Test run with 1 test in 1 suite passed after 51.170 seconds.
EXIT=0
```

The walk is **provably read-only**: the coordinator it holds is wired to a
recording performer, and the walk asserts the recorder's call log is empty and
nothing was settled at the end. That is what makes it safe to run against a real
estate. On every live row it checked that the section title resolved to prose,
the item title rendered, provenance was present, every offered suggestion
carried a real estate id matching the item's own, and the room-keyed and
aggregate sections offered nothing — then that each report survived an
encode/decode round-trip through the G1 wire coders, which is the same JSON
FAB5-K1 will consume.

**A defect this walk found, fixed before this report.** Formatting the two ends
of a window independently produced `Jul 18, 2026 at 12:19 AM – 12:19 AM` for the
weekly review: the end instant had dropped its date, so a seven-day window read
as a zero-minute one. The span now goes through the range format style, which
decides per locale which components to repeat — end-of-day correctly collapses to
`Jul 25, 2026, 12:00 – 12:21 AM` while weekly names both dates. A test covers a
multi-day span and the zero-width window that would otherwise trap on `Range`'s
lower < upper requirement. **A fixture-only test suite would not have caught
this**; it took real window arithmetic against a real clock.

**Not covered by this walk, and honestly outside it:** actual on-device
rendering — Dynamic Type reflow at AX5, VoiceOver reading order, and touch-target
geometry. Those are simulator or device observations. The code satisfies the
rules by construction (standard type styles inside a `ScrollView`,
`ViewThatFits` for the action row, 44 pt minimum frame heights, explicit
`accessibilityLabel` on every button and status glyph, distinct glyphs rather
than colour for status), and Nert and Friedlander are the right gates for
verifying it visually.

---

## Smythe pre-flight

Full report: `docs/analysis/SMYTHE_FAB5_G2_PREFLIGHT.md` (that directory is
gitignored in CE, so the report lives on disk in the worktree, not in the
commit — the same arrangement FAB5-G1 shipped under).

**Verdict: YELLOW on the first pass, GREEN after Bilby's stated approach.**

Terrain verified clean: `GatewayUI/Review/` did not exist; zero symbol
collisions for all five named views across `apps/` and `packages/`; the Standard
profile was exactly four tabs at `ContentView.swift:30-41`; `GatewayUITests`
already existed in `Package.swift:119-129` so no manifest edit was needed. HEAD,
`origin/develop/1.1.x`, and the merge-base all `d38728a9`, working tree clean —
re-verified by Bilby rather than taken on trust.

Three YELLOW items, all resolved before the commit they gated:

- **Y-1 (localization).** The dotted-key problem above. Smythe confirmed no
  `.strings`, `.stringsdict`, or `.xcstrings` file exists anywhere in
  `apps/Mootx01-App/`. Resolved by `ReviewDisplayStrings`.
- **Y-2 (reversibility).** Smythe's §4 established that neither `moot_retire_fact`
  nor `moot_review_tunnel(reject)` has an inverse, flagged the mission's
  "reversible" language as at odds with two of three mutation paths, and
  recommended escalating to Kong. Kong had already been running in parallel;
  ruling D3 resolved it. Smythe's `contest` finding for Confirm survives into the
  shipped prompt text.
- **Y-3 (tab profile test).** `FirstRunAndTabProfileTests.swift:65` and `:78`,
  both updated in the same commit as the `ContentView` edit.

Smythe also confirmed, on being asked, that the nine-new-file set stays inside
Tier 2 (the cap governs existing-file edits) and that the 40 / 9 baseline was a
live measurement at `d38728a9` rather than a cached figure.

---

## Kong design and polish

Design memo: `docs/analysis/KONG_FAB5_G2_DESIGN.md`. Polish memo:
`docs/analysis/KONG_FAB5_G2_POLISH.md`. Both on disk, both gitignored.

The mission is design-flagged with Kong leading, so Kong ruled the tab position
and symbol, the picker-not-navigation shell, the one-renderer-four-wrappers
shape, the key-mapping approach, the action policy per section, the
confirmation-and-permanence model, the loading state machine, and the
accessibility requirements before any code was written.

**Polish pass: zero ship-blocking findings, three POLISH items, all three
applied** in `e4ad1dd9`:

| # | Finding | Fix |
|---|---|---|
| P-1 | The confirmation prompt led with the estate row's UUID, burying the sentence that informs the decision | Explanation first, id after as a cross-reference |
| P-2 | `ReviewActionTests` pinned the dashboard's `momentum` and `keystones` sections but skipped `conflicts`, its tunnel-action section | `conflicts` now pinned like `open-work`: Accept/Reject on a proposed edge, nothing on a settled one, and never a fact verb on a tunnel row |
| P-3 | Two bordered buttons overflow a narrow phone at the largest accessibility type sizes, and a clipped action button is an unreachable action | `ViewThatFits` falls back to a stacked layout; both candidates share one button builder so they cannot drift |

Kong also reviewed and cleared, with reasons: the `readableContentMaxWidth`
nesting (siblings, not nested, matching `PacketDetailView` and
`IntelligenceView`); the per-row provenance disclosure density on a 75-item
report; the `AnyView` in the action provider; UUID truncation via
`.truncationMode(.middle)` rather than a fixed 8 characters; the coverage line's
typography; `.secondary` rather than `.blue` for the notice icon; and comment
fidelity across all twelve files. It confirmed independently that no path exists
from a row to the estate that bypasses `commitPending()`.

One thing Kong's memos got wrong and corrected on the record: sections B and D1
of the design memo contradicted each other on which reviews carry actions.

---

## Adams post-flight

Full report: `docs/analysis/ADAMS_FAB5_G2_POSTFLIGHT.md` (gitignored, on disk).

**First pass at `e4ad1dd9`: BLOCKED on one CRITICAL.** Two WARNINGs, three
INFOs. Adams re-ran the suite independently and confirmed 229 / 36 and 95 / 18,
exit 0, counts matching the claim exactly; verified the base commit and zero
drift itself; read `iPadAdaptivityTests.swift` in full to confirm it encodes no
tab count; confirmed both `ContentView(model:)` construction sites need no edit;
re-ran the BRR's own greps for drift and found no new call sites; confirmed all
seven MUST-NOT-MODIFY paths absent from the diff and all three commits authored
as Bilby.

All three actionable findings were **fixed in-cycle** in `604109e4` rather than
catalogued:

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | **CRITICAL** | `ReviewDisplayStrings.humanized`'s comment example read `"retireReady" → "retire Ready"`, but the loop lowercases the boundary letter, so the real intermediate is `"retire ready"` and the function returns `"Retire ready"`. A comment that overstates what the algorithm preserves is how the next agent builds on a wrong premise. | Comment rewritten to state the lowercasing as the deliberate choice it is (sentence case, not Title Case) and to carry the value through both steps, so the reader can see where the capital comes from. |
| 2 | WARNING | The proposed-status glyph shipped as `questionmark.circle` where Kong ruling B named `circle.badge.questionmark` — an undocumented deviation from the design. | Switched to Kong's symbol, **after verifying the glyph exists**: both names checked against the system symbol manifest (`circle.badge.questionmark` since 2023, `checkmark.circle` since 2019, both under the 27 floor). That check is load-bearing — a misspelled SF Symbol is not a compile error, it renders as nothing, and an empty glyph would silently reduce status to a colour difference and defeat the no-colour-only rule the glyph exists to satisfy. Both names are now behind `ReviewItemRow.statusSymbolName(_:)` and pinned by a test, so a future typo fails the suite. |
| 3 | WARNING | No completion report existed when Adams looked. | This document. |

Two INFOs Adams adjudicated ACCEPT, recorded here rather than dropped:

- **#4** The Blast Radius Report was authored at mission start and lists two new
  test files; **three** shipped, because `ReviewCenterLiveSmokeTests.swift` was
  added during Part 3 as the Verification evidence. No blast radius — nothing
  depends on it, and it is inside the "tests (new)" scope the mission names.
- **#6** `itemCountText`'s explicit plural branches stand in for the
  `.stringsdict` that localization rule 3 prescribes, because this app ships no
  catalog at all. Documented in-code and reviewed by Kong.

Adams also independently verified the two claims most worth doubting:

- **The action gate.** Traced end-to-end and ruled it airtight: `request(_:)`
  stages and calls nothing; the confirmation prompt's confirm button is the only
  reachable call site of `commitPending()`; the `guard let action = pending,
  !isPerforming` has no suspension point before `isPerforming = true`, so on
  `@MainActor` it is atomic and a second tap cannot race it; `pending` is cleared
  before the `await`; and `performer` is `private let` so no external code can
  reach it.
- **The no-Undo claim.** Re-verified against `ToolProjection.swift` and
  `ToolDispatch.swift` rather than taken from the pre-flight: no
  `moot_unretire_fact`, no un-activate verb for a tunnel, and
  `moot_review_tunnel(verdict: "reject")` permanent by design.

Adams adjudicated the live-walk-instead-of-simulator substitution **ACCEPT**, on
three grounds: G1 set the precedent with the same pattern; `ReviewCenterModel` is
the production object the view instantiates and whose output drives what renders,
so driving it exercises the code a tab tap would run; and the read-only proof is
a measurement rather than a convention. It flagged explicitly what the walk does
not cover — SwiftUI rendering, screen layout, Simulator — which is the gap
recorded at item 7 of the known gaps below.

All five mission deviations ruled ACCEPT.

**Re-inspection at `604109e4`: PASS.** Verbatim: "All three actionable findings
(1 CRITICAL, 2 WARNINGs) confirmed closed in commit `604109e4`. Tests pass:
229/36 + 96/18, exit 0, independently verified." Adams re-ran the suite rather
than accepting the new count — 96 is only knowable from a fresh run, since the
SF Symbol pin was added after its first pass.

One inconsistency in Adams' own report, noted rather than smoothed over: it
updated its header to PASS and to `HEAD at final verdict: 604109e4`, but left
the "Verification Pass" table at the bottom showing findings 1–3 as
pending/open. The header, the closure statement, and the re-measured 96 count
are the verdict; the stale table is a documentation slip in the report, not an
open finding against the code.

---

## Self-review

- **Blast radius diff match.** The BRR's three MUST_UPDATE entries
  (`ContentView.swift`, and `FirstRunAndTabProfileTests.swift` at both `:65` and
  `:78`) all appear in the diff. Every INTENTIONALLY_LEFT entry holds:
  `ContentView(model:)`'s signature is unchanged so the two construction sites at
  `App/Mootx01App.swift:63,78` need no edit; `iPadAdaptivityTests.swift` encodes
  no tab count or label list (read, not assumed); `Package.swift`, `project.yml`,
  `MootGateway/Review/**`, `SettingsView.swift`, `EngineView.swift`, and
  `GatewayTransport.swift` are all absent from the diff.
- **No RESCOPE_REQUIRED.** G1's API was sufficient. `ReviewBuilderFactory` plus
  `MootToolCallingReviewReader` was the whole integration surface, as G1's
  interface drawer promised.
- **Scope.** Tier 2, bounded by the Review view cluster. Two pre-existing
  source/test edits against a cap of six, plus one guide edit.
- **Anti-patterns.** No bridge helpers, no shim or wrapper types, no
  `@available(*, deprecated)`, no TODO/FIXME anywhere in the diff (`rg` clean on
  both the diff and the new directories). No formatting noise: the `ContentView`
  diff is the nine lines that add the tab plus one header line that listed the
  Standard profile's tabs and would otherwise have become stale.
- **Comment fidelity.** Every comment describes current behaviour. The one place
  that could have gone stale — `ReviewCenterView`'s note that the `endOfDay` and
  `weekly` switch arms were unreachable while only two reviews shipped — was
  rewritten in Part 2 when they became reachable, not left behind. Comments cite
  the Kong ruling or G1 file that justifies a non-obvious choice, so the next
  agent can find the reasoning rather than re-deriving it.
- **Localization.** Every piece of display chrome goes through
  `String(localized:)`. Two interpolated string literals in SwiftUI positions
  were fixed in Part 3: `Text("…\(x)…")` and `.accessibilityLabel("…\(x)…")`
  select the `LocalizedStringKey` initializer and would have taken the whole
  interpolated result as a catalog key — both now compose a `String` first
  (`Text(verbatim:)` and a hoisted local). Numbers go through `NumberFormatter`.
  No `.left`/`.right`. On plurals: rule 3 wants a `.stringsdict` and this app
  ships no catalog at all, so `itemCountText` writes both cases out explicitly
  rather than interpolating a count into one half-sentence, which is the failure
  the rule exists to prevent.
- **Estate data is never localized.** `item.detail`, `section.notice`,
  `provenance.responseLine`, and the substrate's action reply are shown verbatim.
  `ReviewDisplayStrings.title(forKey:)` returns a non-key string unchanged, so a
  drawer UUID cannot be run through a catalog lookup.
- **Accessibility.** Status is a distinct glyph plus a VoiceOver label, never
  colour alone. Every action button has an `accessibilityLabel` distinct from its
  visible label — a screen reader hears it out of visual context, so "Retire"
  alone is ambiguous — plus a hint that speaks the permanence, so
  destructiveness is not a colour-only signal. 44 pt minimum frame height rather
  than padding, so it holds at every type size. No swipe actions and no reorder
  are used, so `swift.md`'s `.accessibilityActions`-mirroring requirement does not
  engage.
- **Schema invariants.** No entity is defined or persisted here. `ReviewCenterModel`
  and `ReviewActionCoordinator` hold view state, and their two `Bool`s
  (`isPerforming`, and the `Bool` returns of predicate helpers) are transient UI
  state on a `@MainActor` class, not stored properties on an estate entity.
- **Determinism.** One clock read per build, in `ReviewCenterModel.build(_:)`,
  floored to a whole second because the G1 wire coders carry no fractional part.
  The clock is injected, so every test is deterministic; `rg` confirms no other
  `Date()` in the shipped Review sources.
- **Read-only where it claims to be.** The four builders reach only
  `ReviewSurface`, which contains no mutation verb. The action seam is the only
  mutation path, its verb set is closed at four cases, and a test asserts none of
  them routes to `moot_erase_memory`, `moot_withdraw_memory`, or
  `moot_consolidate` — a review is housekeeping, not deletion.
- **Secrets.** None. `rg` for key/token/password/bearer patterns over the new
  sources returns nothing.
- **Honesty.** Every fixture string is labelled with its provenance class
  (live-captured 2026-07-24 and truncated in row count only, or transcribed from
  the producing formatter). No test asserts a behaviour the code does not have.
  The gap list below is the complete one.

---

## Known gaps (carried into the estate contract)

1. **No merge, and no duplicate detection.** Inherited from G1 gap 1 and
   unchanged: no read-only similarity surface and no merge verb exist, so
   Weekly's `duplicates` section is an explained gap and the roadmap's
   "duplicated" facet is not yet true in-app. Closing it needs substrate work.
2. **No undo for a retired fact.** The honest reversal would be a re-file flow
   that reads subject, predicate, and object back off the row and calls
   `moot_file_fact` — possible from data the row already carries, but it creates a
   **new row id**, so it needs an affordance that says "this is a new fact, not
   the old one restored". Deliberately not invented here.
3. **No undo for an accepted or rejected tunnel.** No inverse verb exists.
   Rejection is permanent by design in the substrate, so this is a substrate
   decision rather than a UI gap.
4. **`momentum` and `fading` rows show a room UUID, not a room name.**
   `moot_lens_theme_weather` returns room ids and no name-lookup surface exists,
   so the UUID is the honest rendering. Fixing it means adding room names to the
   lens response — G1's layer or below, not this one.
5. **`context` and `changes` are not window-clipped.** Inherited from G1 gap 2:
   `moot_memory_search` reports no filed instant, so those sections are ordered
   by the tool's own recency ranking. The coverage line therefore states the
   review's window, which those two sections do not strictly honour.
6. **Reports are not refreshed on a schedule.** `ReviewSchedule` supplies
   next-run instants, but acting on them is FAB5-H2's review-prep worker. The
   views are pull-only: build on first selection, rebuild on Refresh.
7. **On-device rendering is unverified.** Dynamic Type reflow at AX5, VoiceOver
   reading order, and touch-target geometry are satisfied by construction but not
   observed on a device. Nert and Friedlander are the gates for that.
8. **A live `moot_memory_search` can be slow.** G1 gap 3. It does not bite the
   shipped app — the production path is the in-process transport with no timeout
   — but the live smoke harness sets 90 s explicitly because the 30 s
   `HTTPTransport` default is not enough on a real estate.

---

## Success criteria

Met. The ROADMAP's "Ask what MOOT remembers" section is demonstrably true
in-app: all four named reviews exist as their own views, build against a live
estate of 98k memories, and render with per-row provenance. "MOOTx01 will
suggest. You remain in control" is enforced structurally rather than by
convention — there is no code path from a suggestion to a mutation that skips the
confirmation. "Memory changes stay inspectable and reversible" is met on
inspectable in full, and on reversible to exactly the extent the substrate
allows, with the two permanent verbs saying so in words instead of implying an
undo that does not exist.

## Commits

| SHA | Subject |
|---|---|
| `34b94c15` | feat(app-ui): Review Center tab with Dashboard and Morning views |
| `df698fd0` | feat(app-ui): EOD and Weekly reviews with reversible suggestions |
| `e4ad1dd9` | style(app-ui): Review Center polish (Kong-directed) + guide |
| `604109e4` | fix(app-review): Adams post-flight punch list |

Estate: one `W2-INTERFACE FAB5-G2:` drawer filed to wing "Agentic Memory",
location `fab5-w2`, id `CCC1B0A6`, carrying the view APIs, the localization-key
resolution, the action-routing table, the reversibility limits, the rendering
decisions downstream should not re-litigate, and the gap list above.
