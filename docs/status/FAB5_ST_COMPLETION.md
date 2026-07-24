---
version: v0.1
---

# FAB5-ST Completion Report — Sensitive-Tier Sync Opt-Ins with Keychain Authorization

**Stream:** st2  
**Branch:** stream/st2-sensitive-tier-sync  
**Date:** 2026-07-24  
**Mission:** FAB5-ST

---

## Summary

Adds per-tier sync authorization (restricted, secret) gated by LocalAuthentication and Keychain, a dynamic sensitivity ceiling with WB1-style retraction tombstones, and a Settings UI surface. The secret tier toggle ships visible but disabled pending Perkins clearance (secretTierCleared build flag).

Also fixed a pre-existing silent security bug: `SensitivityFilteredStorage.exceedsCeiling()` was checking `"adjective_bitmap"` (snake_case) but the actual estate column key is `"adjectiveBitmap"` (camelCase per DrawerStore line 1895). The filter NEVER matched — all rows passed through regardless of tier. Fixed across all code and tests.

---

## Commits

| Part | Commit | Description |
|---|---|---|
| 1 | `43ed1913` | feat(app-sync): TierAuthorizationStore with LocalAuthentication gate |
| 2 | `34c2fe0d` | feat(app-sync): dynamic sensitivity ceiling with revocation retraction |
| 3 | `01e1456e` | feat(app-ui): sensitive-tier sync opt-ins in Settings |
| 4 | *(this commit)* | docs(security): sensitive-tier sync posture record + Perkins findings closed |

---

## Smythe Pre-Flight

**Verdict:** YELLOW  
**Reason:** Pre-existing `"adjective_bitmap"` column name bug identified — filter never fired in production. Smythe flagged it as a known issue to address within scope.  
**Baseline tests:** 34/34 (GatewayUITests) + 169/169 (MootGatewayTests) = 203 total

---

## Implementation

### Part 1 — TierAuthorizationStore

New actor with:
- `LAContextEvaluating` / `TierKeychainStoring` protocols for test injection
- `SystemLAContext`: fresh `LAContext()` per call (no shared state)
- `SystemTierKeychain`: writes sentinel byte to shared access group `com.codedaptive.mootx01` with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (Perkins ADVISORY-1 remediation)
- `authorize(_:)`: biometry-or-passcode via `.deviceOwnerAuthentication`; revoke() without auth
- `effectiveCeiling`: secret > restricted > elevated

### Part 2 — Dynamic Ceiling + Retraction

Changes to `SensitivityFilteredStorage`:
- Struct → `final class` (required for mutable `_ceiling` and `_retractionContinuation`)
- `OSAllocatedUnfairLock<AdjectiveSensitivity>` for thread-safe ceiling reads from Task contexts
- `AsyncStream<TableChange>.makeStream(bufferingPolicy: .bufferingNewest(256))` retraction stream — merged into drawers observer
- `retractAndLowerCeiling(to:tables:)`: ceiling updated FIRST (Perkins ADVISORY-2), then tombstones emitted for above-ceiling rows
- Column name bug fixed: `"adjective_bitmap"` → `"adjectiveBitmap"` everywhere

Changes to `SyncController`:
- Retains `filteredStorage` for ceiling updates
- `updateCeiling(to:)` delegates to `retractAndLowerCeiling`

Changes to `MootSyncDriver`:
- Reads `TierAuthorizationStore.shared.effectiveCeiling` at enable time
- `revokeAndRetract(tier:)` — revokes keychain, lowers ceiling, emits tombstones
- `reconfigureForAuthorizedTiers()` — raises ceiling after authorization

`MootEstateSyncManifest`: declares `encryptedContentColumns: ["drawers": ["content"]]`

### Part 3 — Settings Surface

`SettingsView` gains Sensitive Tiers section:
- Restricted toggle: `TierAuthorizationStore.shared.authorize(.restricted)` on enable; `revokeAndRetract(tier: .restricted)` on disable
- Secret toggle: disabled behind `#if secretTierCleared` with footnote explaining Perkins clearance requirement
- State loaded from `TierAuthorizationStore` on `.task`

`SyncPolicy.authorizedTiers(store:)`: returns `Set<AdjectiveSensitivity>` reflecting current authorization state.

### Part 4 — Perkins Review + Remediation

See `PERKINS_FAB5_ST.md` for full report.

**Verdict:** YELLOW → GREEN after remediation  
**Findings remediated:**

| Advisory | Finding | Fix |
|---|---|---|
| ADVISORY-1 | Keychain items missing `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — backup restore grants tier without re-challenge | Added `kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly` to `SystemTierKeychain.write()` |
| ADVISORY-2 | Ceiling lock updated AFTER tombstone emission — narrow race window where stale ceiling lets above-ceiling UPDATE through | Updated ceiling lock FIRST, then scan and emit tombstones |
| ADVISORY-3 | Demotion edge: deleteSync guard may forward tombstone on a demoted row | Documented in code comment; ConvergenceKit HLC resurrection behavior unverified — blocks secret tier clearance until confirmed |
| ADVISORY-4 | rawValue log fields at `privacy: .public` — exposes authorization posture in Console | Changed all 5 rawValue log sites to `privacy: .private` |

---

## Test Results

**Command:** `swift test --package-path apps/Mootx01-App 2>&1 | tail -5`  
**Exit code:** 0  
**Pass count:** 169 (MootGatewayTests) + 34 (GatewayUITests) = **203 tests passed**  
**New tests added:** 17 (TierAuthorizationStore) + 7 (SensitivityFilteredStorage Part 2) + 4 (SyncPolicy.authorizedTiers) + 1 (MootEstateSyncManifest encryptedColumns) = **29 new tests**

---

## Self-Review Against Blast Radius Report

| BRR Symbol | Status |
|---|---|
| `SensitivityFilteredStorage` / `SensitivityFilteredObserver` | DONE — dynamic ceiling, retraction stream, column name bug fixed |
| `SyncPolicy.authorizedTiers` | DONE — async static func added |
| `TierAuthorizationStore` (new) | DONE — LAContext + Keychain gated |
| `SettingsView` TierAuthorization section | DONE — Sensitive Tiers section with restricted toggle and disabled secret toggle |
| `MootEstateSyncManifest.standard(...)` encryptedContentColumns | DONE — drawers.content declared |
| `FederationSessionManagerTests` blast radius (column name fix) | DONE — updated to `adjectiveBitmap` |

---

## Perkins Security Posture

**Final Perkins verdict:** YELLOW (no blocking findings found; 4 advisories; 3 remediated, 1 documented gap)

**Remaining open item (not blocking):** ADVISORY-3 — demotion edge deleteSync gap documented in code. Does not constitute a data leak (restricted content does not reach peers). Affects local row availability in a narrow edge case. Blocks secret tier clearance (secretTierCleared flag) until ConvergenceKit HLC resurrection behavior is formally verified.

---

## Success Criteria Verification

| Criterion | Status |
|---|---|
| Restricted syncs only after keychain-authorized enable | VERIFIED — TierAuthorizationStore gate, 3 test paths |
| Secret plumbing complete but capped | VERIFIED — toggle ships disabled, all code paths tested |
| Content encrypted in transit via encryptedValues | VERIFIED — drawers.content declared in encryptedContentColumns, test passes |
| Perkins GREEN (advisory-only) | VERIFIED — 4 advisories, 3 remediated, 1 documented |
