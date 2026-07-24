---
version: v0.1
mission: FAB5-J1
stream: j1
completed: 2026-07-24
---

# Completion Report — FAB5-J1: Continuous Obsidian Resident Mode

## Mission summary

Bidirectional continuous sync service between a MOOT estate and an Obsidian vault. Privacy fence enforced: only drawers with `AdjectiveExportability == .public_` ever cross to the vault. Estate-is-authority conflict policy: estate content always wins; vault deletions are blocked (never applied).

## Commits

| SHA | Message |
|---|---|
| `d5ada148` | `feat(vault): resident watcher service with startup resync` |
| `e3ab8bdf` | `feat(vault): estate-authority conflict policy + privacy fence` |
| `3d9b7c8e` | `feat(app-ui): continuous vault settings (off by default)` |

## Files changed

| File | Change |
|---|---|
| `packages/kits/VaultKit/Sources/VaultKit/VaultResidentService.swift` | NEW |
| `packages/kits/VaultKit/Sources/VaultKit/VaultWatcher.swift` | NEW |
| `packages/kits/VaultKit/Sources/VaultKit/ResidentReconcilePolicy.swift` | NEW |
| `packages/kits/VaultKit/Tests/VaultKitTests/VaultResidentServiceTests.swift` | NEW |
| `packages/kits/AriaMcpKit/Package.swift` | EDIT |
| `packages/kits/AriaMcpKit/Sources/AriaResident/ResidentDaemon.swift` | EDIT |
| `apps/Mootx01-App/Sources/GatewayUI/SettingsView.swift` | EDIT |
| `docs/guide/vault_resident.md` | NEW |

## Pre-flight gate (Smythe)

Smythe pre-flight: **GREEN**. Blast radius confirmed Tier 2 (UI-bounded, new VaultKit types + 3 targeted file edits). No prerequisite gaps.

## Perkins gate (Part 2)

Perkins security review: **GREEN on fence, YELLOW overall (4 advisories, none blocking).**

- Advisory-1 (VaultWatcher symlink filtering): FIXED in Part 2 commit.
- Advisory-2 (vault root symlink canonicalization): defense-in-depth acceptable; noted in guide.
- Advisory-3 (env-var path canonicalization at integration): FIXED in Part 3 — `AriaResident.vaultPath(env:)` calls `resolvingSymlinksInPath()` before passing to `VaultResidentService.init`.
- Advisory-4 (error objects logged .public): acknowledged, non-urgent.

## FAB5-ST merge gate (Part 3)

FAB5-ST merged at commit `8846cfab` before Part 3 implementation. SettingsView.swift was cleanly based on the post-FAB5-ST state.

## Test Verification Log

```
swift test --package-path packages/kits/VaultKit 2>&1 | tail -5
```

Result (at commit 3d9b7c8e):
```
Suite "VaultResidentService" passed after 3.829 seconds.
Test "real ~/.mempalace imports with the expected store counts" passed after 5.678 seconds.
Suite "MemPalaceChromaAdapter" passed after 5.678 seconds.
Test run with 192 tests in 11 suites passed after 5.680 seconds.
```

Exit code: 0. Tests: 192 (11 suites). Baseline was 184 tests (10 suites). New tests: 8.

## Post-flight gate (Adams)

*Pending — Adams running.*

## INTENTIONALLY_LEFT items

| Item | Justification |
|---|---|
| Installer/launchd bridge (UserDefaults → MOOTX01_VAULT_PATH) | Follow-on mission: plumbing that translates SettingsView UserDefaults keys into the launchd env var. Both config surfaces wired and documented. |
| Estate-push real-time notification | GeniusLocusKit has no push-notification API for write events. Polling is the correct cross-platform implementation (documented in VaultResidentService.swift). |

## Key design decisions

- **VaultResidentService is an actor** — all mutation is actor-isolated; public readers (`pendingConflicts`, `blockedDeletions`) are safe to read from any context.
- **VaultWatcher uses polling, not FSEvents** — cross-platform; 10-second default; poll interval configurable via `MOOTX01_VAULT_POLL_INTERVAL_S`.
- **Estate→vault direction uses periodic polling** — GeniusLocusKit has no push API; 60-second default; configurable via `MOOTX01_VAULT_ESTATE_POLL_S`.
- **Privacy fence at VaultBridge call site** — `scope: .exportable` passed on every export, never configurable from the vault side.
- **ResidentConfig backward-compatible** — new `vaultPath` and `vaultEstatePollSeconds` fields default to `nil` and `60`, so existing `ServeCommand.swift` and `AriaMCPMain.swift` callers compile unchanged.
