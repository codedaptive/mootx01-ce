# FAB5-G1 — ReviewKit: Lens Aggregation Service — Completion Report

**Stream:** g3
**Mission:** `docs/missions/inflight/MISSION_FAB5_G1.md`
**Branch:** `stream/g3-reviewkit-lens-aggregation` (from `develop/1.1.x`)
**Base commit:** `608306e8` — verified equal to `origin/develop/1.1.x` and to
`git merge-base HEAD origin/develop/1.1.x` at mission start (zero drift)
**Worker:** Bilby
**Date:** 2026-07-25
**Status:** COMPLETE — all tests pass, no existing file modified

---

## What shipped

A net-new Tier 3 service module at
`apps/Mootx01-App/Sources/MootGateway/Review/` — the Review Center's backend and
the typed contract FAB5-G2 (views), FAB5-H2 (review-prep worker), and FAB5-K1
(moot-mgr panes) consume. Five source files, five test files, zero edits to
pre-existing code.

| File | Role |
|---|---|
| `Review/ReviewModels.swift` | `ReviewKind`, `ReviewSurface`, `ReviewProvenance`, `ReviewItem`, `ReviewItemStatus`, `ReviewSection`, `ReviewReport` + ISO8601 wire coders |
| `Review/ReviewSchedule.swift` | `ReviewWindow`, the four windows, morning/end-of-day next-run instants |
| `Review/ReviewSurfaceReader.swift` | `ReviewSurfaceReading` read seam + `MootToolCallingReviewReader` adapter |
| `Review/ReviewBuilder.swift` | `ReviewBuilder` protocol, `ReviewConfiguration`, the four builders, `ReviewBuilderFactory` |
| `Review/ReviewLineParsing.swift` | one parser per ARIA response format |
| `Tests/MootGatewayTests/Review/*` | models, schedule, builder, fixtures, live-estate smoke |

No lens math was written. Every number in a report was computed by an existing
lens and parsed out of that lens's response.

### The four builders and the surfaces each composes

| Review | Sections (ids) | Surfaces read |
|---|---|---|
| Dashboard | `momentum`, `keystones`, `conflicts` | `moot_lens_theme_weather`, `moot_lens_keystones`, `moot_lens_contradiction` |
| Morning | `journal`, `context`, `open-work` | `moot_read_journal`, `moot_memory_search`, `moot_lens_contradiction` (proposed edges only) |
| EndOfDay | `changes`, `decisions`, `attention` | `moot_memory_search`, `moot_fact_search` (window-clipped), `moot_lens_cohesion` |
| Weekly | `fading`, `drift`, `contradicted`, `retire-ready`, `duplicates` | `moot_lens_theme_weather` (negative momentum), `moot_lens_drift`, `moot_lens_contradiction` (one call, parsed twice) |

Windows: dashboard unbounded; morning from the start of yesterday; end-of-day
from the start of today; weekly a trailing seven calendar days. `now` and the
`Calendar` are both injected — nothing in the module reads the clock.

---

## Deviations from the mission text (both deliberate, both verified)

**1. `DaemonController` is not reachable and was not used.** The mission says
builders read the estate "via the resident daemon's local API the app already
uses (DaemonController)". They cannot: `DaemonController` is defined in
`Sources/GatewayUI/DaemonController.swift`, `GatewayUI` depends on `MootGateway`
and never the reverse (`apps/Mootx01-App/Package.swift`), the type is
`@MainActor` and `#if os(macOS)`, and `Sources/GatewayUI/**` is on this mission's
MUST-NOT-MODIFY list. The real in-target seam to the ARIA tool surface is
`MootToolCalling` (MootIntentKit), which `MootBridge` conforms to — the same seam
the FAB5-H1 workers read through. Builders depend on a narrow
`ReviewSurfaceReading` protocol; `MootToolCallingReviewReader` adapts the live
bridge to it. Transport choice (embedded vs managed daemon vs HTTP) stays
`MootBridge`'s business. Smythe flagged this at pre-flight; Adams adjudicated the
substitution as correct and confirmed it introduces no bridge helper, shim, or
wrapper-over-deprecated-type.

**2. Tests are in `Tests/MootGatewayTests/Review/`, not `Tests/ReviewKitTests/`.**
The mission names the latter, but a new test target requires a `Package.swift`
edit, and the same mission's Blast Radius Scope says "Net-new files only … Adams
verifies the no-edit claim at post-flight." The explicit no-edit constraint won
over the incidental test path. FAB5-H1 set the precedent (`Tests/MootGatewayTests/Workers/`,
no `Package.swift` touch). Adams ruled the choice defensible. Consequence for
downstream missions: there is no `ReviewKitTests` target; Review tests run as
part of `MootGatewayTests`.

---

## Test Verification Log

### Baseline (mission start, commit 608306e8)

```
swift test --package-path apps/Mootx01-App
Test run with 181 tests in 32 suites passed after 5.290 seconds.   (MootGatewayTests)
Test run with 37 tests in 8 suites passed after 0.027 seconds.     (GatewayUITests)
EXIT=0
```

### Final (commit dd8e92d5)

- Command: `swift test --package-path apps/Mootx01-App 2>&1 | tail -5`
- Exit code: **0**
- Pass count: **229 tests in 36 suites** (MootGatewayTests) + **37 tests in 8
  suites** (GatewayUITests) — net **+48** tests, **+4** suites, zero regressions
- Tail output (verbatim):

```
􁁛  Suite "FederationPanel — state transitions and F1 invariants (FED-OD-6b)" passed after 0.024 seconds.
􁁛  Test run with 37 tests in 8 suites passed after 0.024 seconds.
EXIT=0
```

Every run was wrapped in a hard watchdog kill (900–1200 s); no run approached it,
and no test hung.

### Gates

- `make check-edition-boundary` → `✓ edition boundary clean — no SHARED→EE-only references`
- No `Package.swift`, `project.yml`, `Sources/GatewayUI/**`, or `packages/kits/**`
  change: `git diff --diff-filter=M --name-only 608306e8..HEAD` was empty through
  the first three commits (Adams verified independently); the only modified-file
  entries in the final diff are files this mission itself created.

---

## Live-estate smoke run (mission Verification requirement)

All four reports built against a **live local estate** — the running resident
daemon at `127.0.0.1:4242`, real JSON-RPC `tools/call` over HTTP, no fixtures.
Suite: `ReviewLiveSmokeTests`, env-gated so a machine without a daemon is not
failed by it.

```
MOOT_LIVE_REVIEW_SMOKE=1 swift test --package-path apps/Mootx01-App \
    --filter ReviewLiveSmokeTests

LIVE SMOKE dashboard: items=30 sections[momentum=12 keystones=5 conflicts=13]
    surfaces=moot_lens_theme_weather,moot_lens_contradiction,moot_lens_keystones
LIVE SMOKE morning:   items=33 sections[journal=1 context=19 open-work=13]
    surfaces=moot_lens_contradiction,moot_memory_search,moot_read_journal
LIVE SMOKE endOfDay:  items=24 sections[changes=19 decisions=0 attention=5]
    surfaces=moot_lens_cohesion,moot_memory_search
LIVE SMOKE weekly:    items=75 sections[fading=7 drift=2 contradicted=13
    retire-ready=53 duplicates=0]
    surfaces=moot_lens_theme_weather,moot_lens_contradiction,moot_lens_drift
Test run with 1 test in 1 suite passed after 28.282 seconds.
EXIT=0
```

Two real findings came out of the first live run, both fixed before this report:

1. **`moot_memory_search` exceeded the transport's 30 s default timeout** on this
   estate (hybrid recall over ~6k facts and the full drawer set), which emptied
   the morning `context` and end-of-day `changes` sections with a timeout notice.
   The builders degraded correctly — one dead surface, one explained section — but
   production callers must give the transport headroom. The smoke reader now uses
   90 s. **This is a live-estate performance observation for FAB5-G2 to act on,
   not a defect in this module.**
2. **`ReviewReport` encodes ISO8601 at whole-second resolution**, so a report built
   with a sub-second `Date()` did not round-trip byte-identically. Now documented
   on the coders and pinned by a test; the smoke run passes a whole-second instant.
   Every instant the estate emits and every instant `ReviewSchedule` produces is
   already whole-second.

`endOfDay decisions=0` is correct behaviour, not a gap: the estate's most recent
KG facts predate the review window, and the section's notice says so verbatim
(`moot_fact_search: facts: 6140 — none filed inside the review window`).

---

## Smythe pre-flight

Full report: `docs/analysis/SMYTHE_FAB5_G1_PREFLIGHT.md` (that directory is
gitignored in CE, so the report lives on disk in the worktree, not in the commit).

**Verdict: YELLOW** — terrain clear, no rescope, two items to resolve on read:

- Blast radius verified clean: `Sources/MootGateway/Review/` did not exist; zero
  hits for `ReviewReport|ReviewBuilder|ReviewModels|ReviewSchedule|ReviewKit`
  anywhere under `apps/` or `packages/`. `moot_review_tunnel` is name-adjacent and
  semantically unrelated — no conflict.
- Environment: HEAD, `origin/develop/1.1.x`, and the merge-base all `608306e8`;
  working tree clean. I re-verified this myself rather than taking the report's word.
- YELLOW item 1: the `DaemonController` reference is wrong (see Deviation 1).
- YELLOW item 2: `Tests/ReviewKitTests/` conflicts with the no-edit constraint
  (see Deviation 2).
- Tool-surface facts confirmed against `AriaMcpKit/Sources/AriaMCP/{LensTools,ToolProjection,ToolDispatch}.swift`:
  the eight exact registered names now encoded as `ReviewSurface` raw values.
- Constraint notes: no stored `Bool` on entities (this module carries none —
  `ReviewItemStatus` is an enum precisely so no boolean state exists); ISO8601
  dates; determinism via injected `now`; no external Swift dependencies; section
  titles are localization keys because the view layer localizes at render.

---

## Adams post-flight

Full report: `docs/analysis/ADAMS_FAB5_G1_POSTFLIGHT.md` (gitignored, on disk).

**Verdict: PASS-WITH-WARNINGS — zero CRITICAL findings.**

Adams re-ran the suite independently and confirmed both pass counts exactly, confirmed
`make check-edition-boundary`, and confirmed the no-edit claim byte-for-byte
(`git diff --diff-filter=M --name-only 608306e8..HEAD` empty; all changed files
additions). Both deviations above were adjudicated as correct and defensible.

Five findings; the four code findings were **fixed in-cycle** in commit `dd8e92d5`
rather than catalogued as known items:

| # | Finding | Resolution |
|---|---|---|
| 1 | WARNING — tunnel rows were disambiguated from conflicting-fact group headers by the *absence* of `" contradicts "`; a fact predicate containing that word would surface as a phantom tunnel item | Tunnel rows now require both ` contradicts ` and `(tunnel `; group headers require a leading `[` and the absence of `(tunnel `. Test added. |
| 2 | INFO — `bracketed(_:)` is not nesting-aware; a bracket inside a fact object truncated the value | `facts(_:_:)` now cuts at `  filed=` and reads the object to the LAST `]` in that head. Test added with a real-shaped bracketed object value. |
| 3 | WARNING — `WeeklyReviewBuilder` called `moot_lens_contradiction` twice per build (tunnel walk + KG scan, paid twice) | One call, parsed twice, via a non-async `section(...)` overload taking an already-fetched response. Test asserts exactly one call. |
| 4 | WARNING — the duplicate-gap notice claimed `moot_consolidate` "reasons about redundancy"; it distills individual memories instead | Corrected in the builder comment and in the user-visible notice text. The gap conclusion was right; the stated reason was wrong. |
| 5 | WARNING — no completion report, and the dispatch signal absent | This document, and the signal filed after it. |

**Adams re-inspection of `dd8e92d5`: PASS.** Adams verified each fix line-by-line
against the producing code, re-ran the full suite independently (229 + 37, exit 0,
exact match), re-checked `make check-edition-boundary`, and confirmed the no-edit
claim still holds. Finding 3 was verified structurally — the new sync overload's
body is the same lines the async overload used to hold inline, so notice semantics
are identical by construction rather than by inspection.

One non-blocking INFO remains and is now documented in the code: the shared
`bracketed(_:)` helper is still first-`]` matching and is used for the fact SUBJECT
field only. Subjects observed on a real estate are short slugs; a subject
containing a literal `]` would truncate the same way an object used to. The
asymmetry with the object path (which now spans to the last `]`) is deliberate and
commented at the helper, so the next agent is not misled into thinking both fields
share one rule.

---

## Self-review

- **Blast radius diff match.** No pre-existing symbol was changed, so there is no
  MUST_UPDATE list to satisfy: this is net-new-only work and the no-edit claim was
  independently verified. `docs/blast_radius/` therefore has no report for this
  mission — the honest equivalent is the verification above.
- **Scope.** Tier 3, no cap. Ten new files. Nothing outside
  `Sources/MootGateway/Review/` and `Tests/MootGatewayTests/Review/`.
- **Anti-patterns.** No bridge helpers, no shim types, no `@available(*, deprecated)`,
  no TODO/FIXME anywhere in the diff (`rg` clean). No formatting noise: no
  pre-existing file was touched at all.
- **Comment fidelity.** Every comment describes current behaviour. No comment
  references a removed approach or a stale mission id. The two places that mention
  the mission's `DaemonController` wording explain why the code does something
  else — that is current-state rationale, not stale history.
- **Determinism.** No `Date()` call exists in the module (only in the opt-in live
  smoke test, and there truncated to a whole second). Verified by `rg`.
- **Honesty.** Every fixture in `ReviewFixtures.swift` is labelled either
  live-captured (2026-07-24, truncated in row count only) or transcribed from the
  producing code — the `moot_fact_search` table is the one transcribed case and
  says so at its definition. No parser fabricates an item, score, or notice that no
  response line produced; a malformed number yields `nil` magnitude rather than 0.
- **Localization.** Section titles are localization keys (`review.section.*`),
  asserted by test. Substrate text (`detail`, `notice`) is estate data carried
  verbatim, not UI copy — the view layer localizes chrome around it.
- **Secrets.** None. `rg` for key/token/password patterns returns only a local
  variable named `token` and a comment about the Restricted/Secret sensitivity tier.
- **Read-only by construction.** `ReviewSurface` contains no mutation verb, and a
  test asserts every case against the mutation-verb list. The builders cannot reach
  a write path.

---

## Known gaps (carried into the estate contract)

1. **Duplicate detection has no read-only surface.** Weekly ships `duplicates` as
   an explained empty gap section rather than a near-miss mapping. Closing it needs
   a read-only similarity surface in the substrate — not work this layer can do.
2. **`moot_memory_search` reports no filed instant**, so `context`/`changes`
   sections are ordered by the tool's own recency ranking and are not clipped to
   the review window. `withinWindow` keeps nil-instant items deliberately;
   dropping them would empty those sections entirely.
3. **`moot_memory_search` latency on a real estate exceeds a 30 s transport
   timeout** (see the smoke section). FAB5-G2 must configure headroom.
4. **`moot_fact_search`'s header count is the total match count, not the emitted
   row count** — a section notice can read `facts: 6140` while only `limit` rows
   were examined. The wording is the surface's own; consumers should not read it as
   an examined-row count.
5. **No `ReviewKitTests` target exists** (Deviation 2).
6. **`bracketed(_:)` truncates a fact subject containing a literal `]`** — first-`]`
   matching, unconfirmed in practice (all observed subjects are short slugs), and
   documented at the helper. The object path is already hardened.

## Success criteria

Met. FAB5-G2 / H2 / K1 consume `ReviewReport` without touching lens plumbing:
`ReviewBuilderFactory.builder(for:configuration:schedule:)` plus
`MootToolCallingReviewReader(caller: bridge)` is the entire integration surface.

## Commits

| SHA | Subject |
|---|---|
| `504d3f14` | feat(app-review): ReviewKit models and builder protocol |
| `56c52daa` | feat(app-review): four review builders over GLK lens surfaces |
| `fca17458` | test(app-review): live-estate smoke + second-resolution contract |
| `dd8e92d5` | fix(app-review): Adams post-flight punch list |

Estate: one `W2-INTERFACE FAB5-G1:` drawer filed to wing "Agentic Memory",
location `fab5-w2`, carrying the type shapes, builder API, decisions, and the
gaps above for downstream missions.
