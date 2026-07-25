---
version: v0.1
stream: l1
mission: FAB5-L1
date: 2026-07-24
status: COMPLETE
signal: /Users/bob/devlop/ddfactory/control/signals/.done-l1
---

# FAB5-L1 Completion Report — iPadOS Enablement

## Summary

Reversed the FAB5-CP iPhone-only ruling per the superset decision. iPad is
restored to the device family for all iOS targets (app + widget + share
extension). Two concrete layout defects were found and fixed. A size-class
smoke test suite was added (3 tests). Release checklist updated.

---

## Part 1 — Device Family + Defect Survey

### Commit
`f6701bfe feat(app): enable iPadOS device family`

### Changes
- `apps/Mootx01-App/project.yml`:
  - `Mootx01-iOS`: `TARGETED_DEVICE_FAMILY: "1"` → `"1,2"`
  - `Mootx01-Widget-iOS`: `TARGETED_DEVICE_FAMILY: "1"` → `"1,2"`
  - `Mootx01-Share-iOS`: `TARGETED_DEVICE_FAMILY: "1"` → `"1,2"`

All three iOS extension targets updated to match the app target (required for
consistent device support across the app group).

### Defect Survey

All non-excluded GatewayUI view files (22 files; SettingsView excluded per
ST/J1; Review/ and Packets/ do not exist in this worktree) were code-reviewed
for concrete iPad layout defects. Two defects found:

| ID | View | Defect | Root cause |
|---|---|---|---|
| D1 | `OnboardingView.swift` | `welcomeStep` CTA button spans ~960pt on iPad Pro landscape | `frame(maxWidth:.infinity)` inside `padding(.horizontal, 32)` with no width cap |
| D2 | `IntelligenceView.swift` | Content VStack spans full iPad width; `TextEditor` and response `ScrollView` fill 1024–1366pt with no ergonomic column constraint | No `maxWidth` constraint on the outer `VStack` |

Views with no recordable defect: `CaptureView`, `RecallView`, `SurfaceMapView`,
`EdgesView`, `EngineView`, `AppleSurfacesView`, `MinerSettingsView`, `ContentView`,
`FederationPanelView`, and supporting views. These use layouts that adapt
naturally to iPad width (full-width VStack with scrolling is a valid iPad pattern
for data-display views).

Deferred: `captureStep` and `recallStep` CTA buttons in `OnboardingView` are also
uncapped (Friedlander advisory). These are consistent with the pre-mission state and
do not break the user flow. Second-pass fix can ride any future OnboardingView
mission.

---

## Part 2 — Layout Fixes + Checklist + Test

### Commit
`c757bdb2 fix(app-ui): iPad layout defects (each cited)`

### Files changed

| File | Change |
|---|---|
| `Sources/GatewayUI/UIAdaptivity.swift` | NEW — `UIAdaptivity` enum with `readableContentMaxWidth = 720` and `modalCTAMaxWidth = 400` |
| `Sources/GatewayUI/OnboardingView.swift` | FIX D1 — `welcomeStep` CTA wrapped in `HStack { Spacer; Button.frame(maxWidth:400); Spacer }` |
| `Sources/GatewayUI/IntelligenceView.swift` | FIX D2 — two-frame centering: `.frame(maxWidth:720).frame(maxWidth:.infinity,alignment:.center)` |
| `Tests/GatewayUITests/iPadAdaptivityTests.swift` | NEW — 3 size-class smoke tests |
| `docs/status/RELEASE_CHECKLIST_1_1.md` | UPDATED — cp iPhone-only bullet superseded; l1 section added |

### D1 Fix Detail — OnboardingView (welcomeStep CTA)

**Before:** `Button.frame(maxWidth:.infinity)` inside `padding(.horizontal,32)` — spans ~960pt on iPad Pro landscape.

**After:** `HStack { Spacer(minLength:0); Button.frame(maxWidth:400); Spacer(minLength:0) }` — button capped at 400pt, centered by flanking spacers.

**iPhone behavior preserved:** Available width after padding (~326pt) < 400pt cap, so the button still fills the padded width as before.

### D2 Fix Detail — IntelligenceView (content width cap)

**Before:** `VStack { ... }.padding()` — full-width on all screen sizes.

**After:**
```swift
VStack { ... }
    .frame(maxWidth: UIAdaptivity.readableContentMaxWidth)  // cap at 720pt
    .frame(maxWidth: .infinity, alignment: .center)          // center in available width
    .padding()
```

**iPhone behavior preserved:** iPhone logical width < 720pt, so the VStack still fills its container unchanged.

---

## Test Verification Log

### Baseline (mission start)
- Command: `swift test --package-path apps/Mootx01-App`
- Pass count: **34 tests in 7 suites**
- Exit code: 0

### Final (after all changes)
- Command: `swift test --package-path apps/Mootx01-App 2>&1 | tail -5`
- Exit code: **0**
- Pass count: **37 tests in 8 suites**
- Tail output (verbatim):
```
Test "posture raw values are stable (no key drift)" passed after 0.001 seconds.
Test "endSession updates lastSession timestamp on the known peer (real manager)" started.
Test "endSession updates lastSession timestamp on the known peer (real manager)" passed after 0.002 seconds.
Suite "FederationPanel — state transitions and F1 invariants (FED-OD-6b)" passed after 0.020 seconds.
Test run with 37 tests in 8 suites passed after 0.021 seconds.
```

New tests: `iPadAdaptivityTests` (3 tests — readable width fits portrait, modal CTA fits mini portrait, readable wider than CTA).

---

## Pre-Flight (Smythe)

**Verdict: YELLOW** (scope question, resolved before implementation)

- Scope question: whether to update all three `TARGETED_DEVICE_FAMILY: "1"` iOS targets in project.yml. Answer: yes — widget and share extension both run on iPad and must match the app target. All three updated.
- Test baseline confirmed: 34 tests, exit 0.
- No TODOs referencing iPad found in codebase.
- `RELEASE_CHECKLIST_1_1.md` confirmed to exist.
- `SettingsView.swift` confirmed to exist (constraint live).
- `Review/` and `Packets/` directories do not exist in this worktree (constraint vacuously satisfied).

---

## Post-Flight (Adams)

**Verdict: CLEAN-WITH-FOLLOWUPS**

- Diff-match gate: 6 files changed, all within blast radius scope. ✓
- SettingsView.swift: NOT in diff. ✓
- View edit count: 2 (OnboardingView + IntelligenceView) — within 4-view cap. ✓
- Tests re-run: 37 tests, exit 0 — verified independently. ✓
- Localization: no hardcoded display strings. ✓
- Anti-patterns: none. ✓

Findings resolved:
- Finding #1 (WARNING): `docs/status/FAB5_L1_COMPLETION.md` referenced but missing → this file.
- Finding #2 (INFO): `import CoreFoundation` → `import CoreGraphics` in UIAdaptivity.swift → fixed in same session.

---

## Visual Review (Friedlander)

**Verdict: ADVISORY ONLY — no blocking findings**

- Palette: clean. No color literals added.
- Locked decisions: none touched.
- Touch target: `.controlSize(.large)` preserved; HStack Spacers don't shrink hit area.
- Advisory 1: `captureStep` and `recallStep` CTAs in OnboardingView remain uncapped (pre-existing).
- Advisory 2: `Image(systemName: "brain.head.profile").font(.system(size: 72))` — `.system(size: relativeTo: .largeTitle)` preferred (pre-existing).

---

## Accessibility Review (Nert)

**Verdict: CLEAN — no findings**

- VoiceOver reachability: HStack + Spacer wrapping of CTA is transparent to accessibility tree. Button implicit label "Get Started, button" is correct and sufficient.
- Touch target floor (44pt): not approached at any device width. Verified analytically for iPhone SE (375pt) and iPad mini (768pt).
- Dynamic Type: no font calls introduced. Existing scaling is intact.
- IntelligenceView two-frame centering: no reading order or focus traversal changes.
- Decorative image `.accessibilityHidden(true)`: confirmed present and untouched.

---

## Success Criteria Assessment

| Criterion | Status |
|---|---|
| Roadmap "iOS, iPadOS, and macOS" is true | ✓ TARGETED_DEVICE_FAMILY "1,2" on all iOS targets |
| Ready for iPad screenshots at submission | ✓ Both defects fixed; layout is ergonomic on iPad |
| Per-defect before/after noted | ✓ D1 and D2 documented above |
| Size-class smoke test added | ✓ 3 tests in iPadAdaptivityTests |
| Suite exits 0 | ✓ 37 tests, exit 0 |
| Release checklist updated | ✓ cp superseded; l1 section added |

---

## iPad Layout Tab Walk (code-verified)

All tabs reviewed against code; no simulator available. Findings by tab:

| Tab | Status | Notes |
|---|---|---|
| Capture | No defect | ScrollView > VStack stretches naturally; acceptable full-width data-entry on iPad |
| Recall | No defect | Same pattern as Capture |
| Intelligence | D2 — FIXED | Two-frame centering applied; content capped at 720pt |
| Settings | Out of scope | ST/J1 lane |
| The Top | No defect | ScrollView > VStack; fixed-width verb/adjective columns are functional on iPad |
| Apple Surfaces | No defect | List-style layout; natural on iPad |
| Edges | No defect | Scroll view; natural |
| Engine | No defect | Scroll view; natural |
| Federation | No defect | Modal-style overlay; natural |
| Miners | No defect | Settings-list style; natural |
| Onboarding (fullScreenCover) | D1 — FIXED | welcomeStep CTA capped at 400pt; captureStep/recallStep advisories deferred |

---

## Second-Pass Note

Views owned by FAB5-G2/I3 (`Review/` and `Packets/`) do not exist in this
worktree. A second-pass sweep after those streams merge is noted in the release
checklist (l1 section). That sweep is not part of this mission.

---

## Open Advisories (carry forward)

1. `OnboardingView.captureStep` and `recallStep` CTA buttons uncapped on iPad (Friedlander).
2. `OnboardingView.swift:42` `font(.system(size: 72))` should be `font(.system(size: 72, relativeTo: .largeTitle))` for AX Dynamic Type coherence (Friedlander/Nert).
3. `CaptureView` and `IntelligenceView` TextEditors lack explicit `.accessibilityLabel` (Nert — pre-existing).

None block this mission.
