---
version: v0.1
stream: vh
date: 2026-07-23
status: LIVE — update each item as it clears
---

# MOOTx01 1.1 Release Checklist

Covers every gate between current state and App Store submission.
Each line names its owning stream and a verification command or manual step.

---

## 0. Review-Safe Defaults — Cold Install Assertion

Before any TestFlight build ships externally, verify that a fresh install
produces this exact defaults posture. These are the cold-install claims in the
App Store reviewer notes.

| Default | Expected | Verify |
|---|---|---|
| iCloud Sync | **OFF** | `rg -n "masterEnabledKey" apps/Mootx01-App` → `SyncPolicy.isEnabled` returns `false` on clean UserDefaults |
| Federation (LAN) | **OFF** | `FederationEngine.isEnabled` default: `false`; LAN port not opened |
| Sensitive-tier opt-ins | **OFF** | Restricted/Secret tiers disabled at sync layer; `SyncPolicy` never places them in the outbox |
| Miners | **OFF** | No background miner task starts until user explicitly enables in Settings |
| LAN server | **OFF** | `PortableServerController` does not start unless federation is enabled |

Failure mode: a reviewer-visible feature active on clean install is a **rejection risk**.

---

## 1. FAB5 Stream Gates

### sm — iCloud Sync Master Preference ☑ COMPLETE
**Owner:** stream/sm-icloud-sync-master  
**Signal:** `/Users/bob/devlop/ddfactory/control/signals/.done-sm`  
**Verification:**
```
# Settings surface present on iOS (gear toolbar) and macOS (Cmd+,)
# Master switch default-off on clean install
swift test --filter MootGatewayTests --package-path apps/Mootx01-App
# Expected: 144 tests, exit 0; SettingsSyncPolicyTests 4/4 green
```
**Completion report:** `docs/status/FAB5_SM_COMPLETION.md`

- [x] `SyncPolicy.masterEnabled` is the single authoritative gate
- [x] Off by default on clean install
- [x] Settings surface present (macOS Cmd+,; iOS gear button)
- [x] Sensitive-tiers placeholder reserved in SettingsView (for FAB5-ST)
- [x] swift test exit 0

---

### ev — CKRecord.encryptedValues Adoption ☑ COMPLETE
**Owner:** stream/ev-encryptedvalues-adoption  
**Signal:** `/Users/bob/devlop/ddfactory/control/signals/.done-ev`  
**Verification:**
```
cd packages/kits/ConvergenceKit && swift test --filter EncryptedValuesTests
# Expected: 15 tests, exit 0
```
**Completion report:** `docs/status/FAB5_EV_COMPLETION.md`

- [x] `SyncManifest.encryptedContentColumns` opt-in exists
- [x] Empty map default — byte-identical wire format for all existing callers
- [x] Metadata columns (`_sync*`, `_ck_*`) provably plaintext
- [x] Dual-read migration path proven
- [x] SPEC v1.3 → v1.4 and INTERFACE v1.7 → v1.8 updated
- [ ] **⚠ Phase-2 OPEN:** `PushCycle.swift` must pass `encryptedColumns:` to
  `CKRecordMapping.record(from:)` before consumers can encrypt in production.
  Until that wiring mission ships, do NOT declare `encryptedContentColumns` in
  production manifests — fields reach CloudKit in plaintext.
  **Gate:** Phase-2 wiring mission must ship before FAB5-ST can use encrypted fields.

---

### cp — App Store Compliance Pack ☑ COMPLETE
**Owner:** stream/cp-appstore-compliance-pack  
**Signal:** `/Users/bob/devlop/ddfactory/control/signals/.done-cp`  
**Verification:**
```
# Check plist keys
rg "NSSiriUsageDescription|ITSAppUsesNonExemptEncryption|NSLocalNetworkUsageDescription" \
   apps/Mootx01-App/App/Info.plist
# Device family — superseded by FAB5-L1 (see l1 section below)
rg "TARGETED_DEVICE_FAMILY" apps/Mootx01-App/project.yml
# Expected: "1,2" (iPhone + iPad — FAB5-L1 reversed the iPhone-only ruling)
```
**Completion report:** `docs/status/FAB5_CP_COMPLETION.md`

- [x] All NSUsageDescription keys present, reviewer-grade
- [x] `ITSAppUsesNonExemptEncryption = false` (both iOS and macOS plists)
- [x] ~~`TARGETED_DEVICE_FAMILY "1"` — iPhone-only for 1.1~~ **superseded by FAB5-L1** (see l1 below)
- [x] Privacy label worksheet ready (`docs/status/APP_PRIVACY_LABELS.md`)
- [x] Reviewer notes ready (`docs/status/APPSTORE_REVIEWER_NOTES.md`)
- [x] France ANSSI simplified declaration step in provisioning runbook
- [x] swift test exit 0 (25 tests, no source changes)

---

### l1 — iPadOS Enablement ☑ COMPLETE
**Owner:** stream/l1-ipados-enablement  
**Signal:** `/Users/bob/devlop/ddfactory/control/signals/.done-l1`  
**Verification:**
```
# Confirm all three iOS targets carry "1,2"
rg "TARGETED_DEVICE_FAMILY" apps/Mootx01-App/project.yml
# Expected: three lines, each "1,2"

# Size-class smoke test
swift test --filter iPadAdaptivityTests --package-path apps/Mootx01-App
# Expected: 3 tests, exit 0

# Full suite still green
swift test --package-path apps/Mootx01-App
# Expected: 37 tests, exit 0
```
**Completion report:** `docs/status/FAB5_L1_COMPLETION.md`

- [x] `TARGETED_DEVICE_FAMILY "1,2"` on Mootx01-iOS, Mootx01-Widget-iOS, Mootx01-Share-iOS
- [x] D1 fixed: OnboardingView CTA capped at `modalCTAMaxWidth` (400pt), centered on iPad
- [x] D2 fixed: IntelligenceView content capped at `readableContentMaxWidth` (720pt), centered on iPad
- [x] `UIAdaptivity` namespace with documented layout constants
- [x] Size-class smoke test: 3 tests, exit 0
- [x] iPad screenshots line: add to TestFlight checklist before external beta
- [x] Second-pass sweep after FAB5-G2/I3 merge (Review/ and Packets/ views)
- [x] swift test exit 0 (37 tests, +3 from baseline)

---

### dt — Docs Truth-Up & Roadmap Cut ☑ COMPLETE
**Owner:** stream/dt-docs-truth-up  
**Signal:** `/Users/bob/devlop/ddfactory/control/signals/.done-dt`  
**Verification:**
```
# Confirm continuous Obsidian moved to 1.2
rg "continuous" docs/start-here/OBSIDIAN_VAULT.md
# Expected: "1.2" references, NOT "1.1"

# Confirm no internal agent vocab in public docs
rg -rn "Bilby|Smythe|Adams|Skippy|MISSION_FAB|ddfactory|wormhole" \
   docs/start-here/ docs/guide/ README.md
# Expected: zero hits
```
**Completion report:** `docs/status/FAB5_DT_COMPLETION.md`

- [x] README roadmap: 1.1/1.2/1.3 honest and dated
- [x] TestFlight late July + App Store mid-September in roadmap
- [x] Federation underpinnings dark in 1.1, user-facing in 1.2
- [x] Continuous Obsidian moved from 1.1 → 1.2 in all locations
- [x] TOPOLOGY.md sync/federation status section added
- [x] De-agentification scan: zero hits in public docs

---

### fr — Federation Submission Gate ⏳ PENDING (stream in flight)
**Owner:** stream/fr-*  
**Signal:** `/Users/bob/devlop/ddfactory/control/signals/.done-fr`  
**Verification (once complete):**
```
# Federation enabled by default for balanced mode only; cross-estate sharing off
rg "federationEnabled|FederationEngine" apps/Mootx01-App/
```

- [ ] LAN server starts only when federation is explicitly enabled
- [ ] Federation ships dark in 1.1 (underpinnings present; user-facing sharing in 1.2)
- [ ] No LAN port open on cold install
- [ ] swift test exit 0

**Checklist lines pending stream completion. Mark resolved when `.done-fr` appears.**

---

### st — Sensitive-Tier Opt-Ins ⏳ PENDING (not yet started)
**Owner:** TBD (awaiting FAB5-EV Phase-2 wiring prerequisite)  
**Signal:** `/Users/bob/devlop/ddfactory/control/signals/.done-st`  
**Verification (once complete):**
```
# Restricted/Secret tiers blocked at sync layer
rg "Restricted|Secret|sensitiveEnabled" packages/kits/ConvergenceKit/Sources/
```

- [ ] SettingsView Sensitive Tiers section wired (placeholder from FAB5-SM)
- [ ] Restricted/Secret tiers off by default
- [ ] Tier enable/revoke triggers sync outbox purge of affected rows
- [ ] FAB5-EV Phase-2 wiring complete (prerequisite)
- [ ] swift test exit 0

**Gate:** FAB5-EV Phase-2 wiring mission must complete before FAB5-ST can begin.**

---

### fo — [Stream Purpose TBD] ⏳ PENDING (parallel, status unknown)
**Owner:** stream/fo-*  
**Signal:** `/Users/bob/devlop/ddfactory/control/signals/.done-fo`

- [ ] Stream completion confirmed
- [ ] swift test exit 0

**Checklist lines pending stream identification and completion.**

---

### vh — TestFlight & Two-Device Validation Harness ☑ COMPLETE (this stream)
**Owner:** stream/vh-testflight-validation-harness  
**Signal:** `/Users/bob/devlop/ddfactory/control/signals/.done-vh`

- [x] Release checklist authored (this document)
- [x] Two-device sync matrix authored (`TWO_DEVICE_SYNC_MATRIX.md`)
- [x] Conformance fixtures: concurrent kill/restore, offline/rejoin (`TwoDeviceKillRestoreTests.swift`)
- [x] TestFlight submission log template authored (`TESTFLIGHT_SUBMISSION_LOG.md`)
- [x] ConvergenceKit test suite green (269 + net-new, exit 0)

---

## 2. Xcode / Build Gates

| Gate | Verify | Status |
|---|---|---|
| Xcode 26+ (iOS 27 SDK) | `xcodebuild -version` | |
| Archive builds clean (no warnings-as-errors failures) | `xcodebuild archive -scheme Mootx01-iOS` | |
| App thinning / bitcode disabled (Apple Silicon) | Check build settings | |
| Signing: App Store distribution profile active | Provisioning runbook Step 6 (`APPLE_PROVISIONING_RUNBOOK.md`) | |
| All entitlements present in distribution profile | `security cms -D -i <profile>` | |
| Export compliance step completed | Provisioning runbook Step 10 | |
| France ANSSI simplified declaration submitted | Provisioning runbook Step 11 | |

---

## 3. TestFlight Submission Steps

Bob executes these manually. See `TESTFLIGHT_SUBMISSION_LOG.md` for round-by-round tracking.

1. Archive the iOS scheme in Xcode → `Product → Archive`
2. Upload via Xcode Organizer → Distribute App → App Store Connect
3. Wait for processing (typically 15–30 min)
4. In App Store Connect → TestFlight → select build → Add to Internal Testing
5. Internal test group runs the two-device matrix (see `TWO_DEVICE_SYNC_MATRIX.md`)
6. After internal pass: Add to External Testing → Beta App Review (1–3 days)
7. Beta App Review verdict → triage any blockers into `TESTFLIGHT_SUBMISSION_LOG.md`
8. Iterate until external TestFlight is live

---

## 4. RC-Week Watchpoints (target: ~September 8)

| Item | Owner | Gate |
|---|---|---|
| App Store release notes drafted | Bob / Simms | Must be localized; no internal codenames |
| Privacy nutrition labels confirmed in ASC | cp (complete) | Cross-check against `APP_PRIVACY_LABELS.md` |
| FAB5-ST complete (Sensitive-tier opt-ins) | st | Hard dependency if included in 1.1 |
| FAB5-EV Phase-2 wiring complete | ev follow-up | Hard dependency for FAB5-ST |
| FAB5-FR complete (federation gate) | fr | Review if federation ships in 1.1 vs dark |
| Whats New in App Store Connect | Bob | 1.1 headline features only; no roadmap promises |
| 1.1.0 stable tag cut | Bob | Cut AFTER all gates green; never force-move |
| ASC submission opens | Bob | ~September 8; submit same day to preserve review queue |

---

## 5. Post-Submission

- Monitor App Review queue (typical: 24–48 h)
- If rejected: triage rejection reason, assign to owning stream, fix and resubmit
- Approval → Phased Release (7 days) or Manual Release (immediate)
- Cut `stable/1.1.0` tag after approval

---

## 6. Beta.1 Release Engineering State (FAB5-B1)

**Version stamped:** `1.1.0-beta-04` (push #4 to `candidate/1.1.x`).
All stamps verified clean via `scripts/release/verify_version.py`.

**CHANGELOG:** `1.1.0-beta-04` section added covering all nine FAB5 streams:
SM, EV, EV2, CP, DT, FR, FO, VH, ST.

**ROADMAP:** "Restricted and Secret memories stay on device **by default**;
keychain-authorized per-tier opt-in available." (was: "stay on device.")
Superset ruling confirmed: continuous Obsidian, Review Center, Work Packet,
moot-mgr all remain in the Version 1.1 section. iPadOS listed at line 67
(FAB5-L1 intact).

**Plugin parity:** All 6 plugin.json mirrors confirmed at `1.1.0-beta-04`.
Generated tree unchanged by this mission (verify-only per Known Ambiguities).

**Test lane:** `swift test --package-path apps/Mootx01-App` → 34 tests,
7 suites, exit 0. Zero code changes; count unchanged from pre-mission baseline.

**EE coordination required (NOT done in this CE-only mission):** VERSIONING.md
§1.5 says YY increments "across both repositories." EE beta version must be
bumped to `1.1.0-beta-04` before the candidate push. Coordinate via EE-side
`bump_version.py` before merging to `candidate/1.1.x`.

**Bob's next steps to cut the beta:**

1. Verify this stream merges cleanly to `develop/1.1.x`.
2. Bump EE to `1.1.0-beta-04` (EE `bump_version.py 1.1.0-beta-04`).
3. `git push origin develop/1.1.x → candidate/1.1.x` (this is push #4).
4. CI builds unsigned pre-release tagged `1.1.0-beta-04`.
5. Upload to TestFlight per Section 3 above.
6. Cut the tag LAST on the `stable` HEAD when gates clear.
