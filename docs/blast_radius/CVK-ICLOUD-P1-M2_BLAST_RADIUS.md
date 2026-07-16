# Blast Radius Report — CVK-ICLOUD P1-M2

**Baseline:** swift test pass count at mission start: 71
**Mission:** Device slot registry core (N2, transport-agnostic half)
**Stream:** worktree-agent-a32a46d239988ba45

---

## Symbols being changed

### Symbol 1: `SyncError` (Swift) — additive case additions

**Change class:** semantic extension (two new enum cases added)
**Scope:** public (ConvergenceKit core, `SyncTypes.swift`)

New cases: `reenrollRequired(slot: Int, staleEpoch: Int, currentEpoch: Int)`,
`slotExhausted(activeCount: Int)`

#### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| Sources/ConvergenceKit/SyncTypes.swift | 135 | grep | MUST_UPDATE | The enum definition — new cases added here |
| docs/reference/CONVERGENCEKIT_INTERFACE.md | 836 | grep | MUST_UPDATE | Concordance table row currently classifies new error cases as Swift-only; must be updated to reflect Rust vocabulary parity added in this mission |
| Sources/ConvergenceKitFederation/FederationSyncEngine.swift | various | grep | INTENTIONALLY_LEFT | Throws specific named cases; no exhaustive switch over SyncError exists; new cases do not affect these sites |
| Sources/ConvergenceKitCloudKit/CKRecordMapping.swift | various | grep | INTENTIONALLY_LEFT | Throws specific cases (.decodingFailure, .encodingFailure, .corruptRemoteIdentity); non-exhaustive |
| Sources/ConvergenceKitCloudKit/Engine/PullCycle.swift | 68 | grep | INTENTIONALLY_LEFT | `catch let err as SyncError` — open catch, new cases propagate correctly |
| Sources/ConvergenceKitCloudKit/Engine/PushCycle.swift | various | grep | INTENTIONALLY_LEFT | Throws specific cases; non-exhaustive |
| Sources/ConvergenceKitCloudKit/Engine/CloudKitStateActor.swift | 75 | grep | INTENTIONALLY_LEFT | Throws .alreadyEnabled only; non-exhaustive |
| Sources/ConvergenceKitNone/ConvergenceKitNone.swift | various | grep | INTENTIONALLY_LEFT | Throws .notEnabled/.alreadyEnabled; non-exhaustive |
| Sources/ConvergenceKit/SyncRecord.swift | 9 | grep | INTENTIONALLY_LEFT | Comment reference only; not a code site |

**Summary:**
- MUST_UPDATE: 2 sites (SyncTypes.swift, CONVERGENCEKIT_INTERFACE.md)
- INTENTIONALLY_LEFT: 7 sites (no exhaustive switch over SyncError exists anywhere)
- RESCOPE_REQUIRED: 0

---

### Symbol 2: `SyncError` (Rust) — additive variant additions

**Change class:** semantic extension (two new enum variants)
**Scope:** pub (`rust/src/types.rs`)

New variants: `ReenrollRequired { slot: i32, stale_epoch: i64, current_epoch: i64 }`,
`SlotExhausted { active_count: usize }`

#### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| rust/src/types.rs | 196–217 | grep | MUST_UPDATE | `impl Display for SyncError` has an exhaustive `match self` — new arms required or it won't compile |
| rust/tests/none_engine_tests.rs | 41, 49–50 | grep | INTENTIONALLY_LEFT | Uses `matches!(...)` with specific variants; non-exhaustive patterns |
| rust/src/federation.rs | various | grep | INTENTIONALLY_LEFT | Constructs named variants via struct-expression; no match over all variants |
| rust/src/none.rs | various | grep | INTENTIONALLY_LEFT | Constructs specific variants only |

**Summary:**
- MUST_UPDATE: 1 file (rust/src/types.rs Display impl)
- INTENTIONALLY_LEFT: 3 sites
- RESCOPE_REQUIRED: 0

---

### Symbol 3: `CloudKitStateActor.hlcGenerator` initialization

**Change class:** semantic — initialization deferred from declaration to `enable()` body
**Scope:** internal actor property (`Engine/CloudKitStateActor.swift`)

#### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| Sources/ConvergenceKitCloudKit/Engine/CloudKitStateActor.swift | 68 | grep | MUST_UPDATE | Declaration + default initializer — strategy changes from random-per-launch to identity-backed |
| Sources/ConvergenceKitCloudKit/Engine/CloudKitStateActor.swift | 74+ | grep | MUST_UPDATE | `enable()` — add DeviceIdentityStore.ensureSchema + loadOrMint + hlcGenerator reset |
| Sources/ConvergenceKitCloudKit/Engine/PushCycle.swift | 53 | grep | INTENTIONALLY_LEFT | Reads `hlcGenerator.send(now:)` via actor isolation; field type (`HLCGenerator`) unchanged; no call-site change needed |

**Summary:**
- MUST_UPDATE: 1 file (CloudKitStateActor.swift, two locations within)
- INTENTIONALLY_LEFT: 1 (PushCycle.swift — reads field, type unchanged)
- RESCOPE_REQUIRED: 0

---

## Purely additive (no blast radius protocol required)

- `Sources/ConvergenceKit/DeviceRegistry/DeviceSlot.swift` — new file
- `Sources/ConvergenceKit/DeviceRegistry/SlotTable.swift` — new file
- `Sources/ConvergenceKit/DeviceRegistry/DeviceIdentityStore.swift` — new file
- `Tests/ConvergenceKitTests/SlotTableTests.swift` — new test file
- `Tests/ConvergenceKitCloudKitTests/DeviceIdentityStoreTests.swift` — new test file
- `docs/status/CVK_ICLOUD/P1-M2.md` — completion report

---

## MUST_UPDATE checklist

- [ ] `Sources/ConvergenceKit/SyncTypes.swift` — add reenrollRequired + slotExhausted
- [ ] `docs/reference/CONVERGENCEKIT_INTERFACE.md` — update SyncError concordance row
- [ ] `rust/src/types.rs` — add two variants + Display arms
- [ ] `Sources/ConvergenceKitCloudKit/Engine/CloudKitStateActor.swift` — defer hlcGenerator to enable()
