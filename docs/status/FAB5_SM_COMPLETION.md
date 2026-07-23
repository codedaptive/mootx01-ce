---
title: FAB5-SM Completion Report
version: v0.1
status: COMPLETE
date: 2026-07-23
stream: sm
---

# Completion Report: FAB5-SM
# iCloudSync Master Preference (Settings surface)

Status: COMPLETE

## What Was Done

FAB5-SM adds a first-class Settings surface for the MOOTx01 app and makes
`SyncPolicy.masterEnabled` the single authoritative iCloud sync gate.

### Part 1 — SyncPolicy master gate (commit 8d113923)

- Added `masterEnabledKey = "iCloudMasterEnabled"` to `SyncPolicy`.
- Added `migrateIfNeeded(defaults:)`: one-shot migration from the legacy WB2
  key (`"iCloudSyncEnabled"`) to `masterEnabledKey`. No-op when master key
  already present (idempotent on subsequent launches). Clears the legacy key
  after migration.
- Updated `isEnabled(defaults:)` to read from `masterEnabledKey`.
- `defaultsKey` retained as public constant (migration source; referenced in
  test suite).
- Updated `Mootx01App.swift` both macOS and iOS startup tasks to call
  `SyncPolicy.migrateIfNeeded()` before `configure()`.

### Part 2 — SettingsView with master switch (commit 9e5d7fbe)

- New `SettingsView.swift` (GatewayUI): Sync section with master Toggle bound
  to `SyncPolicy.masterEnabledKey`. `onChange` wires the same driver pattern
  as SyncTileView (configure + syncNow on enable).
- macOS: `Settings { SettingsView() }` scene in `Mootx01App.swift` — system
  Preferences window (Cmd+,). No ContentView.swift touch needed.
- iOS/iPadOS: `.toolbar` gear button in `EngineView.swift` presents
  SettingsView as a sheet.
- `SyncTileView` `@AppStorage` migrated from `defaultsKey` → `masterEnabledKey`.
  Both SettingsView and SyncTileView bind to the same UserDefaults key; no
  second source of truth.
- Placeholder "Sensitive Tiers" section header reserved for mission st.

### Part 3 — Tests + guide update (commit 7876793d)

- New `SettingsSyncPolicyTests.swift` (MootGatewayTests, 4 tests):
  - masterEnabled defaults false on clean install
  - migrateIfNeeded honors WB2 key once, then idempotent
  - isEnabled reads masterEnabledKey after migration
  - Driver gate (syncNow returns false while disabled)
- `SyncPolicyTests.swift` round-trip test updated to use `masterEnabledKey`
  (blast-radius fix — isEnabled now reads master key, not legacy key).
- `MOOTX01_APP_USER_GUIDE.md` v0.3 → v0.4: Settings section is the primary
  entry point; "Turning iCloud Sync on or off" updated to describe both macOS
  (Cmd+,) and iOS (gear toolbar) paths; Engine tile described as a mirror.

## Navigation Decision

Smythe pre-flight identified ContentView.swift not in mission scope as the
primary concern. Resolution:
- macOS: system Settings scene (`Settings { SettingsView() }`) — standard
  macOS app pattern, no ContentView.swift needed.
- iOS: toolbar gear button on EngineView presenting SettingsView as sheet.
- ContentView.swift NOT modified.

## Test Verification Log

### Baseline (mission start)
- Command: `swift test --package-path apps/Mootx01-App`
- Exit code: 0
- GatewayUITests: 25 tests in 5 suites
- MootGatewayTests: ~140 tests in 26 suites

### Final
- Command: `swift test --package-path apps/Mootx01-App`
- Exit code: 0
- GatewayUITests: **25 tests in 5 suites** ✅
- MootGatewayTests: **144 tests in 27 suites** ✅ (4 new: SettingsSyncPolicyTests)
- Notable: SyncPolicyTests round-trip test fixed (was failing after Part 1
  changed isEnabled() to read masterEnabledKey; fixed in Part 3 commit).

## Pre-flight (Smythe)

Verdict: **YELLOW → clear**.

- Terrain: all call sites of `SyncPolicy.isEnabled` and `SyncPolicy.defaultsKey`
  confirmed within mission scope. No leakage.
- No fr stream conflict (no active branch).
- ContentView.swift navigation concern resolved via macOS Settings scene + iOS
  toolbar sheet (no ContentView touch).
- No existing SettingsView.swift conflict.

## Self-Review

### Step 0 — Blast Radius Scope
- 7 files in diff: all accounted for (4 production, 2 test, 1 docs).
- SyncPolicyTests.swift: classified "Covered" in BRR but required a fix when
  isEnabled() key changed — found and fixed before tests passed.
- `defaultsKey` used only in `migrateIfNeeded()` migration; no @AppStorage
  binds to it in production code post-mission.

### Standard Checks
- Accessibility: Toggle has .accessibilityLabel + .accessibilityHint;
  gear button has .accessibilityLabel ✅
- Palette: no system Color() calls in new code ✅
- Secrets: no credentials (one match on display string "Secret memories") ✅
- Orphan code: none. `defaultsKey` intentionally retained as migration source ✅
- Prohibited patterns: none ✅
- Localization: all display strings use String(localized:) ✅

## Post-flight (Adams)

Verdict: **CLEAN-WITH-FOLLOWUPS**

### Findings

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | WARNING | `@State private var syncRunning` in SettingsView was dead state — set in `.onChange` Task but never read in view computation; no render reaction | Removed the state var and its two write sites. Sync activity is surfaced by SyncTileView in EngineView; a second indicator in Settings would be redundant. |
| 2 | INFO | BRR Step 0 captured GatewayUITests baseline only (25 in 5); MootGatewayTests baseline not documented | Noted. Both targets documented in final Test Verification Log below. |
| 3 | INFO | BRR classified `SyncPolicyTests.swift` as INTENTIONALLY_LEFT; it actually needed a fix (round-trip test wrote to wrong key) | Bilby made the right call fixing it. BRR classification was wrong; diff is correct. Future note: a test naming a migrated symbol is MUST_UPDATE. |

### Adams Test Verification (re-run)

- MootGatewayTests: `swift test --filter MootGatewayTests` — exit 0, 144 tests in 27 suites
- GatewayUITests: exit 0, 25 tests in 5 suites
- All 4 new SettingsSyncPolicyTests confirmed present in the 144 count
- Blast radius: all MUST_UPDATE files present in diff; no MUST_NOT_TOUCH files touched
- `migrateIfNeeded()` before `isEnabled()` confirmed in both macOS and iOS startup tasks
- `isEnabled()` reads `masterEnabledKey` not `defaultsKey` — confirmed
- Zero `@AppStorage(SyncPolicy.defaultsKey)` in production source — confirmed
- Localization: all Text() calls use String(localized:defaultValue:) — clean

### Post-Adams Fix

Finding #1 resolved: removed dead `syncRunning` state and its write sites from SettingsView.
Tests re-run after fix: exit 0, all counts unchanged.

## Commits

| SHA | Message |
|---|---|
| 8d113923 | feat(app-sync): SyncPolicy masterEnabled gate, off by default |
| 9e5d7fbe | feat(app-ui): SettingsView master iCloudSync switch |
| 7876793d | test(app-sync): cold-start default-off assertions + guide update |

## Success Criteria Checklist

- [x] Master switch is the single authoritative gate (`masterEnabledKey`)
- [x] Off by default on fresh install
- [x] EngineView tile mirrors it (same UserDefaults key, no second source)
- [x] Settings is the primary UI entry point (macOS: Cmd+,; iOS: gear button)
- [x] Docs updated in same mission
- [x] Tests: default-off, migration, toggle round-trip, driver gate all pass
- [x] swift test exit 0
