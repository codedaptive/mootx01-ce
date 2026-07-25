## Perkins Security Assessment — FAB5-ST (Parts 1-3)

**Verdict: YELLOW — 4 advisory findings, 0 blocking.**

---

### Threat model applied

Surfaces: CloudKit sync boundary, Keychain credential storage, sensitivity tier
enforcement, outbound/inbound data gating, UI auth flow. BYOAI model holds
throughout — no cloud AI calls, no API key surface, no user content in logs.

---

### Findings

---

**[ADVISORY-1] Missing `kSecAttrAccessible` on keychain write** —
`TierAuthorizationStore.swift` / `SystemTierKeychain.write()`

Attack vector: Backup restoration. Without `kSecAttrAccessible` in the `write()`
query, keychain items default to `kSecAttrAccessibleWhenUnlocked`. This excludes
items from iCloud Keychain sync (no `kSecAttrSynchronizable`, correct), but it
does NOT exclude them from device backups. Restoring an iCloud or iTunes backup
to a new device silently carries the tier authorization sentinels across without
biometric re-challenge on the new device.

Impact: Per-device authentication intent is bypassed. A restored backup grants
restricted (or secret, if cleared) sync access on the new device without the
user re-authorizing on that device.

Mitigation: Add `kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
to the query dictionary in `SystemTierKeychain.write()`. The `exists()` query does
not need it — accessibility only governs write-time protection class. The `delete()`
query does not need it either (delete ignores accessibility on the query side).
Note: if items were already written without this attribute, they must be deleted
and re-written to pick up the new protection class.

---

**[ADVISORY-2] Ceiling update ordering in `retractAndLowerCeiling`** —
`SensitivityFilteredStorage.swift:582–603`

Attack vector: Concurrent observer update during ceiling-lowering window.

`retractAndLowerCeiling` executes as: (1) scan rows, (2) yield tombstones to
retraction stream, (3) update ceiling via `_ceiling.withLock`. The observer's
upstream task runs concurrently (separate Swift Task, not actor-isolated). In
the window between step 2 and step 3, `getCeiling()` in the observer still
returns the old (higher) ceiling. An UPDATE event for a row that is above the
new ceiling but below the old ceiling will pass the observer filter, enter the
outbox, and ship on the next push — despite the user having just revoked the
tier.

The tombstone for that same row is in the retraction stream and will also reach
the outbox. Outbox coalescing is newest-HLC-wins per (table, row_key). If the
UPDATE reaches `recordOutbound` after the tombstone does, the UPDATE wins and
the tombstone is discarded. Net result: the row ships. Subsequent updates to
that row will be correctly filtered (ceiling is now lower), but this one UPDATE
slips through.

Practical likelihood is low — it requires a concurrent estate write to an
above-ceiling row at the exact moment the user revokes tier auth in Settings.
The window is tight (between the last `yield` and the `withLock`). Not
trivially triggerable, but real at the Swift concurrency level.

Impact: One restricted (or secret) row payload reaches peer devices that the
user just revoked. The data is already in CloudKit; the tombstone that was
supposed to retract it was coalesced away.

Mitigation: Invert the ordering — update the ceiling first, then scan and emit
tombstones. With the ceiling updated before the scan, any concurrent UPDATE
arriving in the observer after the lock update is already filtered. The
tombstones serve as belt-and-suspenders for rows already in the outbox.

```swift
// Correct ordering:
_ceiling.withLock { $0 = newCeiling }      // 1. gate new events first
for table in tables {
    let rows = (try? await base.rowStore.query(...)) ?? []
    for row in rows {
        guard exceedsCeiling(row.values, ceiling: newCeiling) else { continue }
        // ... yield tombstone
    }
}
```

---

**[ADVISORY-3] `deleteSync` guard — demotion edge case relies on unverified
ConvergenceKit resurrection semantics** —
`SensitivityFilteredStorage.swift:381–399`

Attack vector: Ordered arrival of retraction tombstone and demotion UPDATE.

Scenario: row is promoted to `restricted` (triggers retraction tombstone, ships
to CloudKit), then demoted back to `elevated` before the tombstone self-delivers.
When the tombstone arrives via pull cycle, `deleteSync` checks the current local
sensitivity — the row is now `elevated` (below ceiling), so the guard does NOT
block the tombstone. The row is hard-deleted locally. The demotion UPDATE is in
the local outbox and will ship on the next push.

If ConvergenceKit treats "tombstone at HLC_T followed by UPDATE with HLC_U > HLC_T"
as a resurrection (re-inserting the row on peers), eventual consistency is
preserved. If it does not support resurrection (tombstone wins regardless of
later UPDATE HLC), the row is silently and permanently lost from all non-local
devices.

This is not a data leakage issue. It is a data integrity gap with a user-facing
consequence (restricted memory disappears from peers after demotion). The guard's
local-state check is correct for the primary case (blocking self-delivery of a
retraction tombstone for a still-restricted row). The demotion edge breaks the
assumption.

Mitigation: Confirm in the ConvergenceKit spec that UPDATE with HLC > tombstone
HLC constitutes a resurrection (re-applies the row). If ConvergenceKit does not
guarantee this, the guard needs to be tightened: block the tombstone if the
current row has a local-modification HLC that post-dates the tombstone's HLC,
not just if the row is above-ceiling.

---

**[ADVISORY-4] Tier authorization state in OSLog with `privacy: .public`** —
`MootSyncDriver.swift` (4 sites), `SyncController.swift` (2 sites)

Attack vector: Log file exfiltration or shared-device Console access.

`ceiling.rawValue` and `tier.rawValue` are logged with `privacy: .public` in:
- `log.info("cloud sync enabled (ceiling: \(ceiling.rawValue, privacy: .public))")`
- `log.info("tier revoked: \(tier.rawValue, privacy: .public), new ceiling: ...")`
- `log.info("sync ceiling reconfigured: \(newCeiling.rawValue, privacy: .public)")`
- `log.info("sync enabled: kit ... ceiling \(ceiling.rawValue, privacy: .public)")`
- `log.info("sync ceiling updated: \(newCeiling.rawValue, privacy: .public)")`

The rawValues (0=normal, 16=elevated, 32=restricted, 48=secret) reveal whether
the user has authorized restricted or secret memory sync. On a shared device or
when log files are exported to support, this exposes the user's sensitivity-tier
authorization posture.

Impact: Privacy metadata disclosure. Not user content, but behavioral metadata
about what tiers the user syncs. Mild — no content leaves the device through
this path.

Mitigation: Change `privacy: .public` to `privacy: .private` for `ceiling.rawValue`
and `tier.rawValue` in all six log statements. If operational observability
requires the ceiling value in internal builds, scope it to debug builds via
`#if DEBUG` rather than always-public.

---

### Positive findings

**Keychain item class:** `kSecClassGenericPassword` with `kSecUseDataProtectionKeychain: true`
is correct. Items use data protection keychain, not the old-style macOS keychain.

**Cross-device sync via iCloud Keychain:** Does not occur. No `kSecAttrSynchronizable`
key is set; the default is false. Tier auth sentinels are device-local. The
concern is backup-only, not live sync.

**LAPolicy.deviceOwnerAuthentication:** Correct for this threat model. Passcode
fallback is appropriate — anyone who can enter the device passcode already has
full local access to restricted content. Biometry-only would break users without
enrolled biometrics for no security gain.

**Secret tier UI isolation:** Clean. The `#if secretTierCleared` conditional
correctly excises the live toggle, the `@State` variable, the `.task` auth query,
and the `.onChange` handler. The static `Toggle(isOn: .constant(false)).disabled(true)`
has no binding that could be mutated. No plumbing is reachable without the flag.

**Retraction completeness:** `retractAndLowerCeiling` queries with `limit: nil`,
fetching all rows. No pagination gap. Every above-ceiling row receives a tombstone.
The unbounded fetch is a performance concern for large estates but not a security
gap.

**Outbound filter fail-safe:** The `[weak self]` capture in `ceilingGetter`
returns `.elevated` on deallocation — the safe (restrictive) default. No
permissive fail-open.

**Inbound gate:** `insertSync`/`upsertSync` throw `SensitivityCeilingError` on
ceiling violation. `PullCycle`'s per-record catch is the correct handler. The row
is not written. No content reaches local storage.

**BYOAI model:** Holds for all paths reviewed. No cloud AI calls. No API key
surface. No user content in any log statement.

---

### Verdict

YELLOW. No blocking findings. 4 advisory items. Advisory-1 (missing
`kSecAttrAccessible`) and Advisory-2 (ceiling update ordering) are the two
items I would prioritize before shipping the restricted-tier feature to users.
Advisory-2 has the higher security weight: the backup concern (Advisory-1) only
affects the user's own devices, while the ordering race (Advisory-2) could send
restricted content to a peer device the user just revoked.

Secret tier remains correctly gated behind `secretTierCleared` pending resolution
of Advisory-2 and Bob's explicit clearance.
