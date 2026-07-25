---
version: v0.1
stream: vh
date: 2026-07-23
status: TEMPLATE — Bob uploads and records findings
---

# TestFlight Submission Log — MOOTx01 1.1

Round-by-round record of Beta App Review submissions.
Bob uploads; agents triage blockers into owning streams.

---

## Upload Steps (Bob executes)

1. **Build archive**
   ```
   xcodebuild archive \
     -scheme Mootx01-iOS \
     -archivePath ~/Desktop/Mootx01-1.1.xcarchive \
     -allowProvisioningUpdates
   ```

2. **Upload via Xcode Organizer**  
   Organizer → Archives → Mootx01-1.1 → Distribute App → App Store Connect  
   Method: App Store Connect (not Ad Hoc)  
   Strip Swift symbols: Yes  
   Upload symbols: Yes  

3. **Record build in ASC**  
   App Store Connect → TestFlight → Builds → note the build number

4. **Export compliance (automatic)**  
   `ITSAppUsesNonExemptEncryption = false` is present in Info.plist — ASC
   auto-approves. No manual declaration required.

5. **Add to Internal Testing**  
   TestFlight → Internal Groups → Add build → notify internal testers

6. **External TestFlight (after internal pass)**  
   TestFlight → External Groups → Submit for Beta App Review  
   Review notes: paste from `APPSTORE_REVIEWER_NOTES.md`

---

## Round Log

### Round 1

| Field | Value |
|---|---|
| Upload date | |
| Build number | |
| SDK version | |
| Submitted for Beta App Review | |
| Beta App Review verdict | ☐ Approved ☐ Rejected |
| Verdict date | |

#### Internal Test Results (before External submission)

| Scenario | Tester | Device | Result | Notes |
|---|---|---|---|---|
| Cold install — all defaults off | | | | |
| iCloud Sync enable/disable | | | | |
| Concurrent writes (2 devices) | | | | |
| Kill / restore (single device) | | | | |
| Offline rejoin (10+ records) | | | | |

#### Beta App Review Findings (if rejected)

| # | Finding description | Severity | Owning stream | Resolution | Commit |
|---|---|---|---|---|---|
| | | | | | |

**Internal test verdict:** ☐ PASS — proceed to External submission  
**Internal test verdict:** ☐ FAIL — blockers listed above

---

### Round 2 (if needed)

| Field | Value |
|---|---|
| Upload date | |
| Build number | |
| Change summary (vs Round 1) | |
| Submitted for Beta App Review | |
| Beta App Review verdict | ☐ Approved ☐ Rejected |
| Verdict date | |

#### Beta App Review Findings

| # | Finding description | Severity | Owning stream | Resolution | Commit |
|---|---|---|---|---|---|
| | | | | | |

---

### Round 3 (if needed)

(Copy Round 2 block)

---

## Blocker Triage Protocol

When Beta App Review rejects:

1. Read the rejection reason carefully — note the exact policy cited.
2. Determine the owning stream:
   - Purpose string or permission issue → **cp**
   - Sync behavior, crash, data loss → **sm** or **ev**
   - LAN/network exposure → **fr**
   - Sensitive tier behavior → **st**
   - Docs or metadata (reviewer notes, privacy labels) → **cp** or **dt**
   - Build / archive / entitlement → Bob escalates directly
3. File the finding in this log with stream attribution.
4. The owning stream author fixes and submits to develop; Bob re-archives.
5. Re-upload and proceed to Round N+1.

---

## External TestFlight Status

| Status | Date | Notes |
|---|---|---|
| External submission approved | | |
| External group live | | |
| External testers notified | | |
| App Store submission opened | | Target: ~September 8 |

---

## Automated Conformance (record each round)

```bash
cd packages/kits/ConvergenceKit && swift test 2>&1 | tail -3
```

| Round | Date | Exit code | Test count | Pass? |
|---|---|---|---|---|
| Pre-upload Round 1 | 2026-07-23 | 0 | 272 | ✅ |
| Pre-upload Round 2 | | | | |
| Pre-upload Round 3 | | | | |
