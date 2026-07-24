---
version: v0.1
mission: FAB5-ST
stream: st2
branch: stream/st2-sensitive-tier-sync
date: 2026-07-24
---

# Blast Radius Report — FAB5-ST: Sensitive-Tier Sync Opt-Ins

## Scope Summary

FAB5-ST adds per-tier sync authorization (restricted, secret) gated by LocalAuthentication
and Keychain. It also fixes a pre-existing silent security bug: `SensitivityFilteredStorage`
was reading the wrong column key (`"adjective_bitmap"` snake_case instead of
`"adjectiveBitmap"` camelCase), which caused the ceiling filter to never match.

---

## MUST_UPDATE — symbols changed or added

| Symbol / File | Change | Status |
|---|---|---|
| `TierAuthorizationStore` (new) | New actor: LAContext + Keychain per-tier authorization. Added `authorize(_:)`, `revoke(_:)`, `effectiveCeiling`, `isAuthorized(_:)`. Testability via `LAContextEvaluating` / `TierKeychainStoring` protocols. | DONE — `43ed1913` |
| `SensitivityFilteredStorage` | struct → `final class`; added `OSAllocatedUnfairLock<AdjectiveSensitivity>` dynamic ceiling; added `AsyncStream<TableChange>` retraction stream; added `retractAndLowerCeiling(to:tables:)` | DONE — `34c2fe0d` |
| `SensitivityFilteredObserver` | Dynamic ceiling reads via `OSAllocatedUnfairLock`; merged retraction stream into drawers observe path | DONE — `34c2fe0d` |
| `SyncController` | Retained `SensitivityFilteredStorage` reference; added `updateCeiling(to:)` | DONE — `34c2fe0d` |
| `MootSyncDriver` | Reads `TierAuthorizationStore.shared.effectiveCeiling` at enable time; added `revokeAndRetract(tier:)` and `reconfigureForAuthorizedTiers()` | DONE — `34c2fe0d` |
| `SyncPolicy.authorizedTiers(store:)` | New async static func returning authorized tier set | DONE — `01e1456e` |
| `MootEstateSyncManifest.standard(...)` | Declares `encryptedContentColumns: ["drawers": ["content"]]` | DONE — `01e1456e` |
| `SettingsView` | Added `sensitiveTierSection` with restricted toggle (auth-gated) and secret toggle (disabled, `#if secretTierCleared`) | DONE — `01e1456e` |
| `SyncConfig.swift` comment | Column key referenced as `adjectiveBitmap` (was: stale `adjective_bitmap`) | DONE — Adams remediation |
| `SensitivityFilteredStorage.swift` continuation comment | Fixed contradictory comment at `continuation.finish()` | DONE — Adams remediation |
| `FederationSessionManagerTests.swift` comments | 16 comment references `adjective_bitmap` → `adjectiveBitmap` | DONE — Adams remediation |
| `SensitivityFilteredStorageTests.swift` comments | 7 references `adjective_bitmap` → `adjectiveBitmap` in comments and test names | DONE — Adams remediation |

---

## Pre-existing Bug Fix (column name)

`SensitivityFilteredStorage.exceedsCeiling()` was checking `"adjective_bitmap"` (snake_case).
The actual estate column key at DrawerStore line 1895 is `"adjectiveBitmap"` (camelCase).
This caused the filter to NEVER match — all rows passed through regardless of sensitivity tier.

Blast radius of the column name fix:
- `SensitivityFilteredStorage.swift` — primary fix
- `FederationSessionManagerTests.swift` — schema `.bitmap("adjectiveBitmap")` and data keys
- `SensitivityFilteredStorageTests.swift` — test data keys

---

## MUST_NOT_MODIFY

The following files were explicitly out of scope for this mission:

- `packages/kits/PersistenceKit/` — substrate replication layer (separate concern)
- `packages/kits/ConvergenceKit/` — federation engine (ceiling enforcement is at SensitivityFilteredStorage layer, not ConvergenceKit)
- `docs/validation/` — harness for substrate math; unrelated to app sync
- `packages/libs/SubstrateTypes/RowBitmaps.swift` — generic bitmap naming convention; `adjective_bitmap` there refers to the abstract field group, not the estate column key

---

## RESCOPE_REQUIRED items (none)

All identified blast radius was contained within the scope of this mission.
No RESCOPE_REQUIRED items were found during implementation or post-flight review.

---

## Perkins security review

Spawned as part of Part 4. Verdict: YELLOW (advisory-only).

| Advisory | Status |
|---|---|
| ADVISORY-1: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` missing from keychain write | REMEDIATED |
| ADVISORY-2: Ceiling lock updated after tombstone emission | REMEDIATED |
| ADVISORY-3: Demotion edge `deleteSync` guard — narrow local-availability gap | DOCUMENTED in code; blocks `secretTierCleared` |
| ADVISORY-4: rawValue log fields at `privacy: .public` | REMEDIATED |

---

## Test coverage added

- `TierAuthorizationStoreTests.swift` — 17 new tests (authorization, revocation, keychain, effective ceiling)
- `SensitivityFilteredStorageTests.swift` — 7 new tests (dynamic ceiling, retraction stream, column key fix)
- `SyncPolicy` authorization tests — 4 new tests in `TierAuthorizationStoreTests.swift`
- `MootEstateSyncManifestTests.swift` — 1 new test (encryptedContentColumns)

Total added: 29 tests. Total suite: 203 (169 MootGatewayTests + 34 GatewayUITests).
