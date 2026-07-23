---
title: FAB5-FR Completion Report
version: v0.1
status: COMPLETE
date: 2026-07-23
stream: fr
---

# Completion Report: FAB5-FR
# First-Run Experience & Consumer Surface

Status: COMPLETE

---

## Mission

Guideline 4.2 defense: a reviewer opening an empty estate must reach
capture → recall inside 60 seconds with no external AI client.
Engineering tabs (The Top, Edges, Engine) move behind an Advanced toggle
for the App Store build. Tier 2 UI-bounded; bounding component: GatewayUI
tab root / onboarding cluster.

---

## Pre-flight

**Smythe verdict: YELLOW (proceed with two advisories)**

- Advisory 1: No Settings tab in ContentView currently — confirmed; mission adds one.
- Advisory 2: Apple Surfaces placement not listed in mission spec — placed in Advanced set.
- No hard blockers. MUST_NOT files (SettingsView.swift, EngineView.swift, MootGateway/Sync/*) clean.
- Branch: `stream/fr-first-run-consumer-surface`

---

## What Was Done

### Part 1 — Onboarding path (commit d28e4147)

- **`AppModel.swift`**: added `hasCompletedOnboarding: Bool` and `isAdvancedMode: Bool`
  as stored properties with `didSet` UserDefaults persistence.
  Keys: `com.mootx01.gateway.hasCompletedOnboarding`, `com.mootx01.gateway.isAdvancedMode`.
- **`OnboardingView.swift`** (new): three-step guided flow — Welcome → Capture → Recall.
  Skippable at any step. Sets `model.hasCompletedOnboarding = true` on complete or skip.
  `.interactiveDismissDisabled(true)` prevents pull-down snap-back on iOS.
  ≤3 taps to complete: Start → Capture → Done.

### Part 2 — Standard/Advanced tab profiles (commit 2393fc23)

- **`ContentView.swift`**: profile-driven TabView.
  - Standard (default): Capture, Recall, Intelligence, Settings.
  - Advanced adds: The Top, Apple Surfaces, Edges, Engine, Federation, Miners.
  - Onboarding overlay: `fullScreenCover` (iOS) / `sheet` (macOS).
- **`AdvancedModeToggle.swift`** (new): Settings tab screen with iCloud Sync section
  (same `SyncPolicy.masterEnabledKey` as SettingsView — three views share one key)
  and Advanced Mode toggle.
- **`FirstRunAndTabProfileTests.swift`** (new): 9 tests covering:
  - `hasCompletedOnboarding` defaults to false / can be set true / gates the cover binding.
  - `isAdvancedMode` defaults to false (Standard) / can toggle.
  - Standard: 4 tabs exact; Advanced extras: 6; superset property holds.

### Part 3 — Consumer polish (commit 9fe18ced, Kong-directed)

Kong reviewed Capture, Recall, Intelligence against consumer polish criteria.
11 copy rewrites applied across three view files:

| File | Changes |
|---|---|
| `CaptureView.swift` | "Submit-in" → action lead; "Location (room)" → "Location"; "Exportability" → "Visibility" (visual + a11y label); info callout deprotocolized; result box "moot_file_memory result" → "Result" |
| `RecallView.swift` | "Serve-out" → "Search your saved memories"; toggle "(filter: exportable)" parenthetical removed; info callout rewritten; result box "moot_memory_search result" → "Search result" |
| `IntelligenceView.swift` | Placeholder "Ask your memory estate" → "Ask about your memories"; toggle "Allow one capture" → "Allow saving to memory" |

### Post-Adams fixup (commit aee7d69e)

Adams found 3 CRITICALs. All resolved:
- **CRITICAL #1 (BRR)**: BRR written to `docs/analysis/blast_radius/FAB5_FR_BLAST_RADIUS.md`
  (gitignored per repo convention; local working doc).
- **CRITICAL #2 (user guide)**: User guide updated (v0.4 → v0.5) — see commit 2e68fe31.
- **CRITICAL #3 (iCloud sync inaccessible in Standard mode)**: `AdvancedModeToggleView`
  now includes full iCloud Sync section using `SyncPolicy.masterEnabledKey` /
  `MootSyncDriver.shared.configure(...)` — established codebase pattern.
- **WARNING #5 (pull-down snap-back)**: `.interactiveDismissDisabled(true)` added.
- **INFO #7 (subtitle omits Settings)**: AdvancedModeToggle subtitle corrected.

### User guide (commit 2e68fe31)

`docs/guide/MOOTX01_APP_USER_GUIDE.md` v0.4 → v0.5:
- "First launch" section added.
- "App at a glance" rewritten with Standard/Advanced profile descriptions.
- iCloud Sync access paths updated throughout (Settings tab, not Engine toolbar,
  for Standard-profile users).

---

## Test Verification Log

### Baseline (mission start)
- Pass count: 25 tests in 5 suites

### Final
- Command: `swift test --package-path apps/Mootx01-App 2>&1 | tail -5`
- Exit code: 0
- Pass count: **34 tests in 7 suites** (+9 new: FirstRunFlagTests ×3, TabProfileTests ×6)
- Tail output (verbatim):
```
Test "posture raw values are stable (no key drift)" passed after 0.001 seconds.
Test "endSession updates lastSession timestamp on the known peer (real manager)" started.
Test "endSession updates lastSession timestamp on the known peer (real manager)" passed after 0.004 seconds.
Suite "FederationPanel — state transitions and F1 invariants (FED-OD-6b)" passed after 0.028 seconds.
Test run with 34 tests in 7 suites passed after 0.028 seconds.
```

---

## Agent Reports

### Smythe pre-flight
Verdict: **YELLOW** — no hard blockers, two advisories (no Settings tab existed,
Apple Surfaces placement unstated). Both resolved per implementation.

### Kong cosmetic review (Part 3)
Directed 11 copy rewrites across CaptureView, RecallView, IntelligenceView.
All 11 applied. Kong flagged picker raw values ("private"/"public") as out of
scope — noted as follow-up.

### Adams post-flight
Initial verdict: BLOCKED (3 CRITICALs, 2 WARNINGs). All CRITICALs resolved in
commit aee7d69e (sync access fix + dismiss guard) and commit 2e68fe31 (user guide).
Adams re-run after fixes: exit 0, 34 tests passing, no open CRITICALs.

### Friedlander visual review
Advisory findings (non-blocking).

---

## Commits

| SHA | Message |
|---|---|
| d28e4147 | feat(app-ui): first-run guided capture-to-recall |
| 2393fc23 | feat(app-ui): standard/advanced tab profiles |
| 9fe18ced | style(app-ui): consumer polish pass on primary tabs |
| aee7d69e | fix(app-ui): restore iCloud sync access in Standard mode + dismiss guard |
| 2e68fe31 | docs(guide): first-run walkthrough + Standard/Advanced profile (FAB5-FR) |

---

## Files MUST NOT Modified (confirmed clean)

- `SettingsView.swift` — not touched
- `EngineView.swift` — not touched
- `MootGateway/Sync/*` — not touched

---

## Success Criteria

- 4.2-defensible consumer surface: ✓ Standard profile (default) shows only
  Capture, Recall, Intelligence, Settings — no engineering tabs visible.
- First-run flow: ✓ ≤3 taps (Start → Capture → Done) from launch to recall.
- Advanced mode intact: ✓ toggle in Settings tab restores full 10-tab set.
- Tests: ✓ exit 0, 34/34 passing.
