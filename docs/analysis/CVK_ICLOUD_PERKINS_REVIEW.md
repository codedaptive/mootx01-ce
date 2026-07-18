---
mission: CVK-ICLOUD P4-M4
title: Security review — ConvergenceKit iCloud arm
reviewer: Perkins
date: 2026-07-17
reviewed_head: f7f7b088e989adad4ceefcf80e533b6c579d0057
version: v0.2
---

# CVK-ICLOUD P4-M4 — Perkins Security Review

Reviewed at develop/1.1.x HEAD `f7f7b088e989adad4ceefcf80e533b6c579d0057`
(P3-M3 zone subscription + remote-wake merged). This re-executes and
supersedes the discarded first pass, which reviewed a stale tree.

Scope: all four Swift targets under `packages/kits/ConvergenceKit/Sources/`
plus `rust/src/`, against `CONVERGENCEKIT_SPEC.md` (v1.2-draft),
`CONVERGENCEKIT_PLAYGROUND_RULES.md`, and
`DECISION_CONVERGENCEKIT_CONCURRENT_MULTIDEVICE_2026-07-16.md`.

Threat model: estates hold personal memory data with sensitivity tiers
(normal / elevated / restricted / secret). The CloudKit private DB relays
rows between one user's machines. The relevant adversaries are (a) data
leaving the boundary the user expects, (b) a compromised peer device on
the same iCloud account crafting adversarial records, (c) forged push
payloads, (d) retention of content the user deleted.

One boundary fact frames several verdicts below: a compromised device on
the same iCloud account holds full read/write on the entire private
database. No client-side control can defend the registry, the records, or
the tombstones against that principal — it can already delete or rewrite
everything directly. Findings are therefore graded by what the *client*
can and should defend: honest-path robustness, quarantine of adversarial
bytes, and retention/propagation guarantees.

## Verdict summary

| # | Area | Verdict |
|---|------|---------|
| 1 | Estate content crossing the boundary | ADVISORY |
| 2 | Slot registry abuse | SAFE |
| 3 | Tombstone / skew / parked-entry privacy | ADVISORY |
| 4 | Integrity hook surface | SAFE |
| 5 | Wire decode hardening | SAFE |
| 6 | Notification spoofing | SAFE |
| 7 | Crypto / key posture | SAFE |

No BLOCKING findings. No escalation.

---

## 1. Estate content crossing the boundary — ADVISORY

There is no sensitivity-tier gate anywhere in the kit. Verified by
search: zero occurrences of any sensitivity vocabulary in
`Sources/`, the SPEC, the PLAYGROUND_RULES, or the multidevice
decision doc. `SyncManifest` (`Sources/ConvergenceKit/SyncTypes.swift:131`)
is table-scoped; the only filtering primitive is
`SyncedTable.excludedColumns` (`SyncTypes.swift:69`), which is
**column**-scoped exclusion for derived/recomputed values (R2). It cannot
express "rows at tier restricted or above do not sync." Every row of a
manifested table ships wholesale via `recordOutbound`
(`Engine/CloudKitStateActor.swift:412`).

**Prior recommendation status: VALIDATED, with two amendments.**

Validated: a consumer-side `SensitivityFilteredStorage` wrapper plus a
`syncCeiling`, not manifest predicates. The current code confirms this is
the right seam. The engine's only ingestion point for outbound content is
the storage observer stream (`CloudKitStateActor.swift:344`); a wrapper
that suppresses observer emission (or strips rows) for above-ceiling rows
gates everything before the outbox, and the kit stays
sensitivity-ignorant. Manifest predicates would put tier semantics into a
kit that has no schema knowledge — wrong layer, confirmed.

Amendment 1 — hook writes ride the same gate only if the consumer passes
the *wrapped* storage to `enable()`. `AppliedBatch.storage`
(`Sources/ConvergenceKit/IntegrityHook.swift:56`) hands the hook the same
handle the engine holds, and hook writes deliberately carry
`origin == .local` and flow into the outbox (hook-writes-must-ship, Kong
Q2). If P5-M1 constructs the wrapper anywhere other than the single
handle given to `enable()`, integrity-hook repairs on restricted rows
leak past the ceiling. State this as an invariant in the P5-M1 spec.

Amendment 2 — row identity still crosses even when content is gated.
Tombstone CKRecords carry rowKey UUID + table identity + delete HLC
(`CKRecordMapping.swift:52`), and `_ck_sync_meta` mirrors them locally.
UUIDs of filtered rows are not content; acceptable. But P5-M1 should
decide whether a row that *later drops below* the ceiling must propagate
as a delete to peers that received it earlier — the current engine has no
"retract" primitive other than the tombstone.

Additional advisory, same boundary: all app-data fields are written as
**standard** CKRecord fields (`CKRecordMapping.swift:118-141`), not
`CKRecord.encryptedValues`. In the private DB, standard fields are not
end-to-end encrypted unless the user has Advanced Data Protection
enabled. For a product whose rows carry tiers named "restricted" and
"secret," P5-M1 should evaluate routing content columns (at minimum
`.text`/`.blob`/`.json` payloads) through `encryptedValues`. This is a
design decision for Bob, not a defect in the shipped arm.

## 2. Slot registry abuse — SAFE

Attack surface: `SlotClaimOperation` CAS flow
(`Registry/SlotClaimOperation.swift:126`), `EpochFence.heartbeat`
(`Registry/EpochFence.swift:67`), eviction windows in
`DeviceRegistry/SlotTable.swift:191`.

- **Mass-evicting active slots / burning epochs / squatting all 15:**
  possible only for a same-account principal, which already owns the
  database outright — it can delete every record in the zone without
  touching the registry. The registry adds no privilege that account
  compromise does not already grant. Not a boundary the client can or
  should defend. No escalation.
- **Honest-path robustness (what the client does defend):** eviction
  requires ghost status (never-heartbeated + 1 h,
  `SlotTable.swift:64`) or 30-day inactivity (`SlotTable.swift:45`);
  active slots are not evictable by a well-formed claim. A wrongly
  evicted device is fenced loudly at its next push — epoch mismatch
  throws `reenrollRequired` *before* any outbox record reaches the wire
  (`EpochFence.swift:114`, `PushCycle.swift:50`), then re-enrolls and
  re-mints (A2). Mis-eviction is self-healing, not silent divergence.
- The 40-bit HLC truncation hazard in eviction math is already fixed —
  both sides of the inactivity subtraction are masked into the same
  40-bit space (`SlotTable.swift:221-226`, Adams P1 CRITICAL #1). Noted
  because the same bug class recurs unfixed in TombstoneGC (finding 3b).
- Epoch is `Int64`; epoch-burning to overflow is not reachable in any
  realistic timeframe.

## 3. Tombstone / skew / parked-entry privacy — ADVISORY

Deletion propagation for the **live row** is sound: typed tombstone
CKRecords with wire-carried delete HLC (`CKRecordMapping.swift:52`), LWW
gate against stale tombstones (`Engine/ApplyInbound.swift:51`),
edit-beats-delete for fieldLevelLWW (`ApplyInbound.swift:73`), and
persisted tombstone HLC blocking stale resurrection after hard-delete
(`Engine/SyncMetaStore.swift:78`, A6). A skew-held copy of a deleted row
replayed after migration re-enters `applyInbound` and loses to the
persisted tombstone HLC — final state converges to deleted. Correct.

What does NOT purge is the **payload bytes** of deleted rows:

**[ADVISORY] Retention — skew queue.** `_ck_pending_skew` stores the full
JSON `SyncRecord` payload blob (`SkewQueue/PendingSkewQueue.swift:95`).
When a tombstone for the same (table, rowKey) applies, nothing deletes
the held skew entry — no delete-by-rowkey exists in `PendingSkewQueue`,
and `applyInbound` never touches the skew table. The deleted row's full
content persists locally until the next matching-schema `enable()`
replay or cap eviction (cap 512, `PendingSkewQueue.swift:61`).
Mitigation: on tombstone apply, delete skew entries matching
(table_name, row_key). Small, contained change.

**[ADVISORY] Retention — parked outbox.** Parked entries keep their full
values blob indefinitely (`Outbox/OutboxStore.swift:199`): `park` sets
`is_parked = 1` and nothing ever deletes the row — no unpark, no purge
API, no TTL. A locally deleted row *does* coalesce away a pending upsert
(delete replaces it, `OutboxStore.swift:57`), but a *remotely* deleted
row leaves a parked upsert payload in place forever (inbound tombstone
applies via `deleteSync`, which never re-enters the outbox by design,
I-10). Mitigation: purge parked/pending entries for (table, row_key) on
inbound tombstone apply; add a purge API for host-app "clear failed
changes."

**[ADVISORY — must fix before wiring] TombstoneGC 40-bit clock bug.**
`TombstoneGC.compact` extracts the tombstone's physical time as the low
40 bits of the packed HLC (`Sources/ConvergenceKit/TombstoneGC.swift:75`)
but compares it against **full-width** wall-clock millis
(`TombstoneGC.swift:54-56,76`). 2026 Unix-ms (~1.77e12) exceeds 2^40
(~1.10e12), so every stored physical time is truncated to ~6.7e11 —
always older than `cutoffMs`. First production invocation compacts EVERY
tombstone HLC immediately, zero retention, reopening the A6 stale-
resurrect window: a peer offline across the delete can resurrect deleted
(possibly restricted-tier) content. This is the exact bug class Adams
P1 CRITICAL #1 fixed in `SlotTable.swift:221` — the mask was applied
there and not here. Currently latent: `compact` has **no production
caller** in either backend (verified by search; references are the type
itself and one test comment), so it cannot fire at this HEAD — hence
advisory, not blocking. Fix (mask `cutoffMs` into the same 40-bit space,
mirroring SlotTable) is mandatory before any mission wires GC.

**[ADVISORY — note] Zone-side tombstone records are never removed.**
Tombstone CKRecords accumulate in the zone indefinitely (nothing deletes
them; `TombstoneGC` is local-side-table only). They carry row identity
and delete HLC, not content. Acceptable retention posture; record it as
a deliberate decision in the spec when GC ships.

## 4. Integrity hook — SAFE

`postApplyIntegrityHook` receives `AppliedBatch` — table names, row
keys, storage handle (`IntegrityHook.swift:42`). Injection analysis:

- Table names in the batch come only from records that passed the
  manifest whitelist (`Engine/PullCycle.swift:149` —
  `unsupportedTable` otherwise). A peer cannot steer the hook toward
  side tables or unmanifested tables.
- Row keys are UUIDs parsed from `CKRecord.ID` with fabrication rejected
  (`CKRecordMapping.swift:168`, corruptRemoteIdentity).
- A hook throw is contained: counted as one conflict, never aborts the
  cycle (`IntegrityHook.swift:118`).
- Empty-batch guard enforced at both the call site and the helper
  (`IntegrityHook.swift:112`, `PullCycle.swift:207`).

The residual surface is inherent: a peer's crafted row *content* is read
by consumer hook logic during repair. That is the definition of sync —
the same peer could write the rows directly. Guidance for consumers
(belongs in the SPEC's hook section): treat row content as untrusted
input inside hooks; do not interpolate it into identifiers or interpret
it as instructions. No kit defect.

## 5. Wire decode hardening — SAFE

Adversarial-bytes review across every decode surface:

- **Per-record quarantine holds.** Every decode/apply failure inside the
  pull loop is caught per record, counted as a conflict, and the loop
  continues (`PullCycle.swift:161-167`) — the corruptRemoteIdentity
  precedent generalized. A poisoned record cannot abort the batch or
  wedge the token.
- **`SyncValueMap`/`SyncValueBox` recursive array:** decode recursion
  depth is bounded by Foundation's JSON parser nesting limit (throws,
  does not crash), and total size is bounded by CloudKit's ~1 MB
  per-record cap upstream of every blob this kit decodes
  (`_syncColumnHLCs`, `_syncTypeTags`, skew payloads, outbox blobs all
  originate from CK-sized records). Unknown `kind` throws cleanly
  (`SyncRecord.swift:349`). Timestamp encode guards the non-finite /
  out-of-range Int64 trap (`SyncRecord.swift:296`). No crashable path
  found.
- **`ColumnHLCMap`, `_syncTypeTags`, skew re-decode:** all parsed with
  `try?` and degrade to nil/skip (`CKRecordMapping.swift:180,202`;
  `SkewQueue/SkewReplay.swift:63` leaves corrupt payloads unapplied).
  Type-tag restoration only re-tags values whose decoded shape matches
  the tag's guard (fingerprint requires exactly 32 bytes,
  `CKRecordMapping.swift:237`; the unsafe-bytes read is bounds-checked
  by that guard). Unknown tags no-op (`CKRecordMapping.swift:255`).
- **SQL injection via attacker-controlled column names:** inbound values
  keys are attacker-controlled and are interpolated as SQL identifiers
  downstream — but PersistenceKit validates every table and column
  identifier against `[A-Za-z_][A-Za-z0-9_]*` before interpolation
  (CAND-047 / SECFIX-WS2-PK F9 guard in the SQLite, Postgres, and Rust
  backends). Verified present on the insert and upsert paths this arm
  uses. Hostile identifiers throw; the record quarantines as a conflict.
- **Reserved-field hygiene:** all `_sync*` keys are stripped from app
  values at decode (`CKRecordMapping.swift:187`), so a peer cannot smuggle
  metadata keys into application rows.

One consistency note, no action required now: the wire packing
(`CKRecordMapping.packed`, 48/12/4) and the storage packing
(`HLC.packed`, 8/16/40) coexist; every stored comparison value
round-trips through the 40-bit form on both sides of every comparison,
so ordering is internally consistent. The scheme inherits a 2^40-ms
wrap (~year 2039) that SlotTable already documents; when that is
revisited, TombstoneGC (finding 3) and this note resolve together.

## 6. Notification spoofing — SAFE

`handleRemoteNotification(userInfo:)` (`Engine/RemoteWake.swift:65`)
reads exactly one value from the payload: `ck.met.zid` as a non-empty
String (`RemoteWake.swift:101`), compares it for equality against the
enabled manifest's zone identifier, and on match emits
`.remoteWakeReceived` and calls `nudge()`. Nothing else in the payload
is reachable: no record data, no token, no identifiers are parsed or
trusted. A forged or malformed payload either returns `false` (no zone
match, engine disabled, wrong types) or, at worst, triggers one pull
against the user's own private database through the normal
quarantining pull path — at-most-a-nudge holds. Delivery itself
requires APNs, which third parties cannot inject for this app's token.
Correctness never depends on the notification (polling is the
guarantee, `Engine/ZoneSubscription.swift:5-10`); dropping or flooding
notifications degrades to poll cadence. Subscription registration is
silent-push only with user-facing fields explicitly cleared
(`ZoneSubscription.swift:90-96`).

## 7. Crypto / key posture — SAFE

- No custom crypto in the CloudKit arm: zero CryptoKit imports in
  `ConvergenceKitCloudKit` and `ConvergenceKit` core (verified by
  search). Transport security is CloudKit's.
- Federation Ed25519 untouched by this arm: `FederationIdentity.swift`
  last changed in a pre-CVK-ICLOUD merge (`39c274fe`); no CVK-ICLOUD
  mission modified it.
- Side tables hold no secrets: `_ck_device_identity` stores
  (deviceUUID, slot, epoch, claimedAt) only
  (`DeviceRegistry/DeviceIdentityStore.swift:42-78`); slot registry
  records store (device_uuid, epoch, last_active_hlc, claimed_at)
  (`Registry/SlotRecordMapping.swift`). Device UUIDs are identifiers,
  not credentials — possession grants nothing that private-DB access
  does not already grant.
- No key material, tokens, or credentials appear in any `Logger` call
  in the arm (reviewed all logging sites; logs carry table names, slot
  numbers, counts, UUIDs, and error descriptions — no row content, no
  payload blobs).

---

## Disposition

- **Blocking:** none.
- **Advisory, queue for P5:** sensitivity ceiling wrapper (finding 1,
  shapes P5-M1, with the two amendments), skew/parked payload purge on
  tombstone apply (finding 3), TombstoneGC 40-bit mask fix gated before
  any GC wiring (finding 3), `encryptedValues` evaluation for content
  columns (finding 1), hook-input-is-untrusted guidance in the SPEC
  (finding 4).
